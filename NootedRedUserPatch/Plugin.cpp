// NootedRedUserPatch plugin entry point and profile orchestration
//
// Copyright (C) 2026  ChefKiss.
//
// Licensed under the ChefKiss Open Knowledge License version 1.
//
// This work is licensed to you under the terms of the ChefKiss Open Knowledge
// License, either version 1 of the License, or (at your option) any later
// version published by ChefKiss.
//
// This work may not be used to train or develop artificial intelligence,
// and may not be used with artificial intelligence in any other way. See
// the ChefKiss Open Knowledge License for details.
//
// This work is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// ChefKiss Open Knowledge License for more details.
//
// You should have received a copy of the ChefKiss Open Knowledge License
// along with this work.  If not, see https://git.chefkiss.dev/ChefKiss/OpenKnowledge/raw/branch/master/LICENSE-v1.md.

// The satellite needs a later data-loading entry point than Lilu's plugin-start callback: the kernel
// build string and the IOKit registry may not be ready when the plugin kmod starts.  Defining this for
// the whole target (including Lilu's Library/plugin_start.cpp) makes the IOKit subclass below the only
// definition, so Plugin.cpp owns both the service-start entry point and the IOService identity.
#ifndef LILU_CUSTOM_IOKIT_INIT
#define LILU_CUSTOM_IOKIT_INIT 1
#endif

#include <Headers/kern_api.hpp>
#include <Headers/kern_util.hpp>
#include <Headers/kern_version.hpp>
#include <Headers/plugin_start.hpp>
#include <IOKit/IODeviceTreeSupport.h>
#include <IOKit/IOKitKeys.h>
#include <IOKit/IOLocks.h>
#include <IOKit/IOService.h>
#include <kern/clock.h>
#include <kern/thread_call.h>
#include <libkern/c++/OSData.h>
#include <libkern/c++/OSString.h>
#include <libkern/sysctl.h>
#include <mach/clock_types.h>
#include <string.h>
#include <PatchProfile.hpp>
#include <UserPatchBackend.hpp>

static const char* bootargOff   = "-NRedUserPatchOff";
static const char* bootargDebug = "-NRedUserPatchDebug";
static const char* bootargBeta  = "-NRedUserPatchBeta";

// XNU's boot-supplied build string.  It is only a fallback source for the authoritative running build
// when the device-tree property and the kern.osversion sysctl are both unreadable.
extern "C" char osversion[];

namespace
{

    constexpr size_t kBuildTextSize = 24;

    // Bounded diagnostics refresh schedule (milliseconds).  AppliedPages/FindMismatches are only
    // meaningful once user-space has faulted the driver pages, so the counters are republished a
    // finite number of times instead of running an endless timer.
    constexpr UInt32 kRefreshDelaysMs[] = {5000, 15000, 30000, 60000, 120000, 240000};
    constexpr UInt32 kRefreshCount      = sizeof(kRefreshDelaysMs) / sizeof(kRefreshDelaysMs[0]);

    const char* const kProfileProperty = "NRedOffsetProfile";
    const char* const kBuildHintProperty = "NRedSystemBuild";

    bool copyBuildText(const char* const source, char* const out, const size_t outSize)
    {
        if (source == nullptr || outSize == 0) { return false; }

        size_t length = 0;
        while (length < outSize && source[length] != '\0') { length++; }
        if (length == 0 || length >= outSize || length > PatchProfile::kMaxBuildLength) { return false; }

        memcpy(out, source, length);
        out[length] = '\0';
        return true;
    }

    // Reads the bootloader-provided build string from the IODeviceTree root.  This is the same value
    // the kernel publishes as kern.osversion on this platform and is available before any kext runs.
    bool readDeviceTreeBuild(char* const out, const size_t outSize)
    {
        auto* const root = IORegistryEntry::fromPath("/", gIODTPlane);
        if (root == nullptr) { return false; }

        bool found = false;
        auto* const property = root->getProperty(kOSBuildVersionKey);
        if (auto* const stringValue = OSDynamicCast(OSString, property)) {
            found = copyBuildText(stringValue->getCStringNoCopy(), out, outSize);
        }
        else if (auto* const dataValue = OSDynamicCast(OSData, property)) {
            const size_t length = dataValue->getLength();
            const auto* const bytes = static_cast<const UInt8*>(dataValue->getBytesNoCopy());
            if (bytes != nullptr && length >= 1 && length < outSize) {
                memcpy(out, bytes, length);
                out[length] = '\0';
                found       = true;
            }
        }
        root->release();
        return found;
    }

    bool readSysctlBuild(char* const out, const size_t outSize)
    {
        char   buffer[kBuildTextSize]{};
        size_t size = sizeof(buffer);
        if (sysctlbyname("kern.osversion", buffer, &size, nullptr, 0) != 0) { return false; }
        buffer[sizeof(buffer) - 1] = '\0';
        return copyBuildText(buffer, out, outSize);
    }

    bool readXnuBuild(char* const out, const size_t outSize)
    {
        return osversion[0] != '\0' && copyBuildText(osversion, out, outSize);
    }

    // Resolves the authoritative running build.  Every available source must agree; a disagreement is
    // an unresolvable identity (fail closed), never a preference order.
    bool readActualBuild(char* const out, const size_t outSize)
    {
        char deviceTreeBuild[kBuildTextSize]{};
        char sysctlBuild[kBuildTextSize]{};
        char xnuBuild[kBuildTextSize]{};

        const bool haveDeviceTree = readDeviceTreeBuild(deviceTreeBuild, sizeof(deviceTreeBuild))
                                    && PatchProfile::isValidBuildString(deviceTreeBuild);
        const bool haveSysctl = readSysctlBuild(sysctlBuild, sizeof(sysctlBuild))
                                && PatchProfile::isValidBuildString(sysctlBuild);
        const bool haveXnu = readXnuBuild(xnuBuild, sizeof(xnuBuild)) && PatchProfile::isValidBuildString(xnuBuild);

        const char* resolved = nullptr;
        if (haveDeviceTree) { resolved = deviceTreeBuild; }
        if (haveSysctl) {
            if (resolved != nullptr && strcmp(resolved, sysctlBuild) != 0) {
                SYSLOG("init", "running build sources disagree (device tree vs kern.osversion); identity unresolved");
                return false;
            }
            resolved = sysctlBuild;
        }
        if (haveXnu) {
            if (resolved != nullptr && strcmp(resolved, xnuBuild) != 0) {
                SYSLOG("init", "running build sources disagree (kernel global vs detected); identity unresolved");
                return false;
            }
            resolved = xnuBuild;
        }

        if (resolved == nullptr) { return false; }
        strlcpy(out, resolved, outSize);
        return true;
    }

    // The injected NRedSystemBuild hint is an early sanity input only.  It never replaces the
    // authoritative running build comparison.
    bool readInjectedBuild(IOService* const service, char* const out, const size_t outSize)
    {
        if (service == nullptr) { return false; }

        auto* const property = service->getProperty(kBuildHintProperty);
        if (auto* const value = OSDynamicCast(OSString, property)) {
            return copyBuildText(value->getCStringNoCopy(), out, outSize);
        }
        if (auto* const value = OSDynamicCast(OSData, property)) {
            const size_t length = value->getLength();
            const auto* const bytes = static_cast<const UInt8*>(value->getBytesNoCopy());
            if (bytes != nullptr && length >= 1 && length < outSize) {
                memcpy(out, bytes, length);
                out[length] = '\0';
                return true;
            }
        }
        return false;
    }

}    // namespace

// EXPORT keeps the metaclass symbols externally visible.  Without it the target-wide
// -fvisibility=hidden (AppleForge) makes the class private, and the release link+strip removes the
// symbols IOKit needs to instantiate the IOService personality.
class EXPORT PRODUCT_NAME : public IOService
{
    OSDeclareDefaultStructors(PRODUCT_NAME)

public:
    IOService* probe(IOService* provider, SInt32* score) override;
    bool       start(IOService* provider) override;
    void       stop(IOService* provider) override;
};

extern EXPORT PRODUCT_NAME* ADDPR(selfInstance);

// Orchestrates the two asynchronous entry points (Lilu patcher load and IOService start) into one
// deterministic first-wins transition:
//
//   1. the NRPT profile is copied and validated exactly once (service start);
//   2. the running build is resolved from the kernel/bootloader, the injected hint is only a sanity
//      check;
//   3. the APU family and iGPU device ID are detected once in the sleepable patcher-load callback;
//   4. once all of the above are known the profile engine decides Loaded/NoOp exactly once; a
//      deterministic failure is terminal and a missing identity is a fail-closed NoOp.
//
// Validation hooks never take this lock: they only acquire-load the profile engine publication flag
// and update its atomics.
class UserPatchRuntime
{
public:
    static UserPatchRuntime& singleton();

    void init();
    void onPatcherLoad(KernelPatcher& patcher);
    void onServiceStart(IOService* service);

private:
    UserPatchRuntime() = default;
    ~UserPatchRuntime() = default;
    UserPatchRuntime(const UserPatchRuntime&) = delete;
    UserPatchRuntime& operator=(const UserPatchRuntime&) = delete;
    UserPatchRuntime(UserPatchRuntime&&) = delete;
    UserPatchRuntime& operator=(UserPatchRuntime&&) = delete;

    void loadProfileLocked(IOService* service);
    void resolveIdentityLocked(IOService* service);
    void finalizeIdentityLocked();
    void afterTransition();
    void publishDiagnostics();
    void scheduleRefresh(UInt32 delayMs);
    void refreshStep();
    static void refreshCallback(thread_call_param_t param0, thread_call_param_t param1);

    IOLock* lock_{nullptr};

    bool disabled_{false};
    bool patcherLoadDone_{false};
    bool serviceStartDone_{false};
    bool profileHandled_{false};
    bool identityResolved_{false};

    char actualBuild_[kBuildTextSize]{};
    char injectedBuild_[kBuildTextSize]{};
    bool injectedBuildValid_{false};

    UInt32 refreshIndex_{0};
    bool   refreshArmed_{false};
};

UserPatchRuntime& UserPatchRuntime::singleton()
{
    static UserPatchRuntime instance;
    return instance;
}

void UserPatchRuntime::init()
{
    if (checkKernelArgument(bootargOff)) {
        // Lilu's PluginConfiguration disables the plugin before this runs; keep the check as a
        // defensive guard in case the disable-argument handling changes.
        this->disabled_ = true;
        SYSLOG("init", "disabled by boot argument %s", bootargOff);
        return;
    }

    this->lock_ = IOLockAlloc();
    if (this->lock_ == nullptr) {
        SYSLOG("init", "failed to allocate the state lock; satellite will stay inert");
        this->disabled_ = true;
        return;
    }

    SYSLOG("init", "NootedRedUserPatch %s starting (generic NRPT profile engine)", kextVersion);
    SYSLOG("init", "patch data comes only from the injected %s personality property", kProfileProperty);

    lilu.onPatcherLoadForce([](void* const, KernelPatcher& patcher) {
        UserPatchRuntime::singleton().onPatcherLoad(patcher);
    });
}

void UserPatchRuntime::onPatcherLoad(KernelPatcher& patcher)
{
    if (this->lock_ == nullptr) { return; }

    IOLockLock(this->lock_);
    if (!this->disabled_) {
        this->patcherLoadDone_ = true;

        // Unconditional install: a missing or rejected profile must never delay kernel-text routing.
        UserPatchBackend::singleton().install(patcher);

        // Sleepable, IOKit-safe context: this is the only place hardware identity is detected.
        UserPatchBackend::singleton().detectHardwareIdentity();

        this->resolveIdentityLocked(ADDPR(selfInstance));
        this->finalizeIdentityLocked();
    }
    IOLockUnlock(this->lock_);

    this->afterTransition();
}

void UserPatchRuntime::onServiceStart(IOService* const service)
{
    if (this->lock_ == nullptr) { return; }

    IOLockLock(this->lock_);
    if (!this->disabled_) {
        this->serviceStartDone_ = true;
        this->loadProfileLocked(service);
        this->resolveIdentityLocked(service);
        this->finalizeIdentityLocked();
    }
    IOLockUnlock(this->lock_);

    this->afterTransition();
}

void UserPatchRuntime::loadProfileLocked(IOService* const service)
{
    if (this->profileHandled_) { return; }
    this->profileHandled_ = true;

    if (service == nullptr) {
        PatchProfile::singleton().noteAbsentProfile();
        return;
    }

    // Read the injected build hint before the properties are removed.  It is a sanity check only.
    char injected[kBuildTextSize]{};
    if (readInjectedBuild(service, injected, sizeof(injected))) {
        strlcpy(this->injectedBuild_, injected, sizeof(this->injectedBuild_));
        this->injectedBuildValid_ = true;
    }

    // Validate and copy the whole profile while the OSData property is still alive.  The engine keeps
    // only its own bounded static tables, so the property bytes may be freed afterwards.
    auto* const property = service->getProperty(kProfileProperty);
    auto* const data     = OSDynamicCast(OSData, property);
    if (data != nullptr) {
        PatchProfile::singleton().loadFromData(data->getBytesNoCopy(), data->getLength());
    }
    else {
        PatchProfile::singleton().noteAbsentProfile();
    }

    service->removeProperty(kProfileProperty);
    service->removeProperty(kBuildHintProperty);
}

void UserPatchRuntime::resolveIdentityLocked(IOService* const service)
{
    if (this->identityResolved_) { return; }

    if (!this->injectedBuildValid_) {
        char injected[kBuildTextSize]{};
        if (readInjectedBuild(service, injected, sizeof(injected))) {
            strlcpy(this->injectedBuild_, injected, sizeof(this->injectedBuild_));
            this->injectedBuildValid_ = true;
        }
    }

    char actual[kBuildTextSize]{};
    if (!readActualBuild(actual, sizeof(actual))) {
        // Deferred until both plugin entry points have run; finalizeIdentityLocked() then fails
        // closed instead of guessing a build.
        return;
    }

    strlcpy(this->actualBuild_, actual, sizeof(this->actualBuild_));
    this->identityResolved_ = true;

    PatchProfile::singleton().setRunningBuild(this->actualBuild_,
                                              this->injectedBuildValid_ ? this->injectedBuild_ : nullptr);
}

void UserPatchRuntime::finalizeIdentityLocked()
{
    if (this->identityResolved_ || !this->patcherLoadDone_ || !this->serviceStartDone_) { return; }

    // Both entry points ran and the authoritative running build is still unreadable: fail closed.
    PatchProfile::singleton().setRunningBuild(nullptr, nullptr);
}

void UserPatchRuntime::afterTransition()
{
    this->publishDiagnostics();

    bool armRefresh = false;
    IOLockLock(this->lock_);
    if (!this->disabled_ && PatchProfile::singleton().loaded() && !this->refreshArmed_) {
        this->refreshArmed_ = true;
        armRefresh          = true;
    }
    IOLockUnlock(this->lock_);

    if (armRefresh) {
        this->refreshIndex_ = 1;
        this->scheduleRefresh(kRefreshDelaysMs[0]);
    }
}

void UserPatchRuntime::publishDiagnostics()
{
    auto* const service = ADDPR(selfInstance);
    if (service == nullptr) { return; }

    auto& profile = PatchProfile::singleton();
    auto& backend = UserPatchBackend::singleton();

    const char* const buildText = profile.build()[0] != '\0'
                                      ? profile.build()
                                      : (this->actualBuild_[0] != '\0' ? this->actualBuild_ : "none");

    service->setProperty("NRedUserPatchState", profile.stateName());
    service->setProperty("NRedUserPatchReason", profile.reasonName());
    service->setProperty("NRedUserPatchBuild", buildText);
    service->setProperty("NRedUserPatchDataSource", profile.parsed() ? "personality:NRedOffsetProfile" : "none");
    service->setProperty("NRedUserPatchErrorCode", profile.errorCode());
    service->setProperty("NRedUserPatchErrorContext", profile.errorContext());
    service->setProperty("NRedUserPatchApuMask", static_cast<unsigned long long>(profile.apuMask()), 32);
    service->setProperty("NRedUserPatchDeviceID", static_cast<unsigned long long>(profile.deviceID()), 32);
    service->setProperty("NRedUserPatchPages", static_cast<unsigned long long>(profile.pageCount()), 32);
    service->setProperty("NRedUserPatchSites", static_cast<unsigned long long>(profile.siteCount()), 32);
    service->setProperty("NRedUserPatchHooks", static_cast<unsigned long long>(backend.pageHookInstalled() ? 1 : 0),
                         32);
    service->setProperty("NRedUserPatchRangeHook",
                         static_cast<unsigned long long>(backend.rangeHookInstalled() ? 1 : 0), 32);
    service->setProperty("NRedUserPatchLoaded", static_cast<unsigned long long>(profile.loaded() ? 1 : 0), 32);
    service->setProperty("NRedUserPatchAppliedPages", static_cast<unsigned long long>(profile.appliedPages()), 32);
    service->setProperty("NRedUserPatchFindMismatches", static_cast<unsigned long long>(profile.findMismatches()), 32);
    service->setProperty("NRedUserPatchMatchedPages", static_cast<unsigned long long>(profile.matchedPages()), 32);
    service->setProperty("NRedUserPatchChunkCalls", static_cast<unsigned long long>(profile.chunkCalls()), 32);
    service->setProperty("NRedUserPatchWriteFailures", static_cast<unsigned long long>(profile.writeFailures()), 32);
}

void UserPatchRuntime::scheduleRefresh(const UInt32 delayMs)
{
    thread_call_t call = thread_call_allocate(refreshCallback, nullptr);
    if (call == nullptr) {
        SYSLOG("init", "failed to allocate status refresh call; diagnostics keep their last values");
        return;
    }

    UInt64 deadline = 0;
    clock_interval_to_deadline(delayMs, static_cast<uint32_t>(NSEC_PER_MSEC), &deadline);
    if (thread_call_enter1_delayed(call, call, deadline)) {
        // Cannot happen for a freshly allocated call; never free a possibly pending call.
        SYSLOG("init", "status refresh call was unexpectedly pending");
    }
}

void UserPatchRuntime::refreshStep()
{
    this->publishDiagnostics();

    if (this->refreshIndex_ < kRefreshCount) {
        this->scheduleRefresh(kRefreshDelaysMs[this->refreshIndex_]);
        this->refreshIndex_ += 1;
    }
}

void UserPatchRuntime::refreshCallback(thread_call_param_t, thread_call_param_t param1)
{
    auto* const thisCall = static_cast<thread_call_t>(param1);
    singleton().refreshStep();
    if (thisCall != nullptr) { thread_call_free(thisCall); }
}

OSDefineMetaClassAndStructors(PRODUCT_NAME, IOService)

EXPORT PRODUCT_NAME* ADDPR(selfInstance) = nullptr;

IOService* PRODUCT_NAME::probe(IOService* provider, SInt32* score)
{
    ADDPR(selfInstance) = this;
    setProperty("VersionInfo", kextVersion);
    auto* const service = IOService::probe(provider, score);
    return ADDPR(startSuccess) ? service : nullptr;
}

bool PRODUCT_NAME::start(IOService* provider)
{
    ADDPR(selfInstance) = this;

    if (!IOService::start(provider)) {
        SYSLOG("init", "failed to start the parent");
        return false;
    }

    if (ADDPR(startSuccess)) {
        // Reads and validates the injected NRedOffsetProfile property before user-space pages can be
        // validated, then resolves the running identity and publishes the diagnostics state.
        UserPatchRuntime::singleton().onServiceStart(this);
    }

    return ADDPR(startSuccess);
}

void PRODUCT_NAME::stop(IOService* provider)
{
    ADDPR(selfInstance) = nullptr;
    IOService::stop(provider);
}

PluginConfiguration ADDPR(config){
    xStringify(PRODUCT_NAME),
    parseModuleVersion(xStringify(MODULE_VERSION)),
    LiluAPI::AllowNormal | LiluAPI::AllowInstallerRecovery | LiluAPI::AllowSafeMode,
    &bootargOff,
    1,
    &bootargDebug,
    1,
    &bootargBeta,
    1,
    KernelVersion::Catalina,
    KernelVersion::Tahoe,
    []() { UserPatchRuntime::singleton().init(); },
};
