// NootedRedUserPatch plugin entry point and runtime orchestration
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
// build string (`kern.osversion`), the IOKit registry and the data volume may not be ready when the
// plugin kmod starts.  Defining this for the whole target (including Lilu's Library/plugin_start.cpp)
// makes the IOKit subclass below the only definition, so Plugin.cpp owns both the service-start retry
// point and the IOService identity.
#ifndef LILU_CUSTOM_IOKIT_INIT
#define LILU_CUSTOM_IOKIT_INIT 1
#endif

#include <Headers/kern_api.hpp>
#include <Headers/kern_util.hpp>
#include <Headers/kern_version.hpp>
#include <Headers/plugin_start.hpp>
#include <IOKit/IOLocks.h>
#include <IOKit/IOService.h>
#include <kern/clock.h>
#include <mach/clock_types.h>
#include <kern/thread_call.h>
#include <libkern/c++/OSIterator.h>
#include <PatchData.hpp>
#include <UserPatchBackend.hpp>

static const char* bootargOff   = "-NRedUserPatchOff";
static const char* bootargDebug = "-NRedUserPatchDebug";
static const char* bootargBeta  = "-NRedUserPatchBeta";

namespace
{

    // Bounded delayed retry (review D3).  Covers a build string / IOKit state that is not ready at
    // patcher-load or service-start time.  The retries are deliberately finite and never touch page
    // pointers.
    constexpr UInt32 kMaxLoadRetries   = 15;
    constexpr UInt32 kLoadRetryDelayMs = 2000;

    // The Info.plist declares org.ChefKiss.NootedRed in OSBundleLibraries, so the kext loader itself only
    // loads this plugin when NootedRed is installed.  This lookup is a diagnostic only.
    bool nootedRedServiceVisible()
    {
        auto* const matching = IOService::serviceMatching("NootedRed");
        if (matching == nullptr) { return false; }

        auto* const iterator = IOService::getMatchingServices(matching);
        if (iterator == nullptr) { return false; }

        const bool visible = iterator->getNextObject() != nullptr;
        iterator->release();
        return visible;
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

// Single-threaded state machine for load/install/retry transitions (review D4).
//
// Entry points:
//   - plugin kmod start (`init`): allocate the lock, register `onPatcherLoadForce`; no IOKit/VFS work.
//   - Lilu patcher load (`onPatcherLoad`): install both code-signing routes UNCONDITIONALLY (review D2),
//     then attempt the data load, then arm the bounded retry if work remains.
//   - IOService start (`serviceStart`): retry data load only.  It never routes
//     kernel text, and it cannot install a second time (installation happens only at patcher load).
//   - delayed `thread_call` (retryCallback): bounded retries of data load in a kernel thread.
//
// All shared mutable state is guarded by `lock_` (an IOLock).  The validation hooks do not take this
// lock: they only acquire-load the published data flag, and their
// counters are atomics inside UserPatchBackend.
class UserPatchRuntime
{
public:
    static UserPatchRuntime& singleton();

    void init();
    void onPatcherLoad(KernelPatcher& patcher);
    void serviceStart();

private:
    UserPatchRuntime() = default;
    ~UserPatchRuntime() = default;
    UserPatchRuntime(const UserPatchRuntime&) = delete;
    UserPatchRuntime& operator=(const UserPatchRuntime&) = delete;
    UserPatchRuntime(UserPatchRuntime&&) = delete;
    UserPatchRuntime& operator=(UserPatchRuntime&&) = delete;

    // Snapshot of the state machine for IORegistry diagnostics.  Filled under the lock so property
    // publication never runs with `lock_` held.
    struct PublishSnapshot
    {
        UserPatchData::State  state;
        UserPatchData::Reason reason;
        char                  build[16];
        char                  buildSource[64];
        char                  dataSource[48];
        UInt32                apuMask;
        UInt32                appliedApuMask;
        UInt32                pages;
        UInt32                sites;
        bool                  pageHook;
        bool                  rangeHook;
        UInt32                appliedPages;
        UInt32                loadAttempts;
        bool                  retryPending;
    };

    // All *Locked helpers require `lock_` to be held.
    void ensureLocked();
    void snapshotLocked(PublishSnapshot& snapshot) const;
    static void publish(const PublishSnapshot& snapshot);
    void logStateLocked(const char* prefix) const;
    bool retryNeededLocked() const;
    UInt32 retryDelayMs() const;

    void clearRetryFlag();
    void startRetryCall();
    void startStatusRefresh();
    void statusRefresh();
    static void statusRefreshCallback(thread_call_param_t param0, thread_call_param_t param1);

    static void retryCallback(thread_call_param_t param0, thread_call_param_t param1);

    IOLock* lock_{nullptr};
    bool    disabled_{false};
    bool    finalNoOp_{false};
    bool    retryScheduled_{false};
    UInt32  loadAttempts_{0};
};

UserPatchRuntime& UserPatchRuntime::singleton()
{
    static UserPatchRuntime instance;
    return instance;
}

void UserPatchRuntime::init()
{
    if (checkKernelArgument(bootargOff)) {
        // Lilu's PluginConfiguration disables the plugin before this runs; keep the check as a defensive
        // guard in case the Lilu disable-argument handling changes.
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

    SYSLOG("init", "NootedRedUserPatch %s starting", kextVersion);
    SYSLOG("init", "embedded PatchData selected at runtime; no filesystem access");
    lilu.onPatcherLoadForce([](void* const, KernelPatcher& patcher) {
        UserPatchRuntime::singleton().onPatcherLoad(patcher);
    });
}

void UserPatchRuntime::onPatcherLoad(KernelPatcher& patcher)
{
    if (this->lock_ == nullptr) { return; }

    SYSLOG("init", "parent NootedRed service: %s (kext dependency is enforced by the loader)",
           nootedRedServiceVisible() ? "visible" : "not visible yet");

    bool needRetry = false;
    PublishSnapshot snapshot{};
    IOLockLock(this->lock_);
    if (!this->disabled_) {
        // Unconditional install: an unreadable data volume must never delay kernel-text routing (D2).
        UserPatchBackend::singleton().install(patcher);

        this->ensureLocked();
        this->snapshotLocked(snapshot);
        needRetry = this->retryNeededLocked();
        if (needRetry) {
            if (this->retryScheduled_) {
                needRetry = false;
            }
            else {
                this->retryScheduled_ = true;
                snapshot.retryPending = true;
            }
        }
    }
    IOLockUnlock(this->lock_);

    if (!this->disabled_) { publish(snapshot); }
    if (needRetry) { this->startRetryCall(); }
}

void UserPatchRuntime::serviceStart()
{
    if (this->lock_ == nullptr) { return; }

    bool needRetry = false;
    PublishSnapshot snapshot{};
    IOLockLock(this->lock_);
    if (!this->disabled_) {
        // Load only: hooks are installed exclusively at patcher load, so this entry point
        // can never route kernel text late or install a second time (D2).
        this->ensureLocked();
        this->snapshotLocked(snapshot);
        needRetry = this->retryNeededLocked();
        if (needRetry) {
            if (this->retryScheduled_) {
                needRetry = false;
            }
            else {
                this->retryScheduled_ = true;
                snapshot.retryPending = true;
            }
        }
    }
    IOLockUnlock(this->lock_);

    if (!this->disabled_) { publish(snapshot); }
    if (needRetry) { this->startRetryCall(); }
    this->startStatusRefresh();
}

void UserPatchRuntime::ensureLocked()
{
    if (this->disabled_ || this->finalNoOp_) { return; }

    auto& patchData = UserPatchData::singleton();
    if (patchData.loaded()) { return; }

    this->loadAttempts_ += 1;
    if (patchData.load()) { return; }

    if (!patchData.retryable()) {
        this->finalNoOp_ = true;
        SYSLOG("init", "data load failed permanently after %u attempt(s); hooks stay installed and inert",
               static_cast<unsigned>(this->loadAttempts_));
    }
}

bool UserPatchRuntime::retryNeededLocked() const
{
    if (this->disabled_ || this->finalNoOp_) { return false; }

    auto& patchData = UserPatchData::singleton();

    if (!patchData.loaded()) { return this->loadAttempts_ < kMaxLoadRetries; }
    return false;
}

UInt32 UserPatchRuntime::retryDelayMs() const
{
    return kLoadRetryDelayMs;
}

void UserPatchRuntime::clearRetryFlag()
{
    if (this->lock_ == nullptr) { return; }

    IOLockLock(this->lock_);
    this->retryScheduled_ = false;
    IOLockUnlock(this->lock_);
}

void UserPatchRuntime::startRetryCall()
{
    const UInt32 delay = this->retryDelayMs();

    thread_call_t call = thread_call_allocate(retryCallback, nullptr);
    if (call == nullptr) {
        SYSLOG("init", "failed to allocate the delayed retry thread call; stopping retries");
        this->clearRetryFlag();
        return;
    }

    UInt64 deadline = 0;
    // mach_absolute_time is nanosecond-based on x86_64 (timebase 1:1), so NSEC_PER_MSEC is the correct
    // scale for a millisecond delay.  (Passing 1000 here made every retry run ~1000x too early and the
    // whole bounded chain fired during bsd_init before kern.osversion was populated.)
    clock_interval_to_deadline(delay, static_cast<uint32_t>(NSEC_PER_MSEC), &deadline);

    // TRUE means the call was already pending; for a freshly allocated call that cannot happen, but never
    // free a call that may be pending.
    if (thread_call_enter1_delayed(call, call, deadline)) {
        SYSLOG("init", "delayed retry call was unexpectedly already pending; stopping retries");
        this->clearRetryFlag();
        return;
    }

    SYSLOG("init", "delayed retry armed in %u ms", static_cast<unsigned>(delay));
}

void UserPatchRuntime::retryCallback(thread_call_param_t, thread_call_param_t param1)
{
    auto& self = singleton();
    auto* const thisCall = static_cast<thread_call_t>(param1);

    bool needNext     = false;
    bool publishState = false;
    PublishSnapshot snapshot{};
    if (self.lock_ != nullptr) {
        IOLockLock(self.lock_);
        self.retryScheduled_ = false;

        if (!self.disabled_) {
            if (!self.finalNoOp_) {
                self.ensureLocked();
            }

            self.snapshotLocked(snapshot);
            publishState = true;

            needNext = self.retryNeededLocked();
            if (needNext) {
                self.retryScheduled_ = true;
                snapshot.retryPending = true;
            }
            else {
                self.logStateLocked("delayed retries finished");
            }
        }
        IOLockUnlock(self.lock_);
    }

    if (publishState) { publish(snapshot); }
    if (needNext) { self.startRetryCall(); }
    if (thisCall != nullptr) { thread_call_free(thisCall); }
}

void UserPatchRuntime::startStatusRefresh()
{
    constexpr UInt32 kStatusRefreshMs = 5000;

    if (this->disabled_) { return; }

    thread_call_t call = thread_call_allocate(statusRefreshCallback, nullptr);
    if (call == nullptr) {
        SYSLOG("init", "failed to allocate status refresh call");
        return;
    }

    UInt64 deadline = 0;
    clock_interval_to_deadline(kStatusRefreshMs, static_cast<uint32_t>(NSEC_PER_MSEC), &deadline);
    if (thread_call_enter1_delayed(call, call, deadline)) {
        SYSLOG("init", "status refresh call was already pending");
    }
}

void UserPatchRuntime::statusRefresh()
{
    if (this->lock_ == nullptr || this->disabled_) { return; }

    PublishSnapshot snapshot{};
    IOLockLock(this->lock_);
    this->snapshotLocked(snapshot);
    IOLockUnlock(this->lock_);

    publish(snapshot);
}

void UserPatchRuntime::statusRefreshCallback(thread_call_param_t, thread_call_param_t param1)
{
    auto* const thisCall = static_cast<thread_call_t>(param1);
    singleton().statusRefresh();
    if (thisCall != nullptr) { thread_call_free(thisCall); }
}

void UserPatchRuntime::snapshotLocked(PublishSnapshot& snapshot) const
{
    auto& patchData = UserPatchData::singleton();
    auto& backend   = UserPatchBackend::singleton();

    snapshot.state              = patchData.state();
    snapshot.reason             = patchData.reason();
    strlcpy(snapshot.build, patchData.buildString(), sizeof(snapshot.build));
    strlcpy(snapshot.buildSource, patchData.buildSource(), sizeof(snapshot.buildSource));
    strlcpy(snapshot.dataSource, patchData.dataSource(), sizeof(snapshot.dataSource));
    snapshot.apuMask            = patchData.apuMask();
    snapshot.appliedApuMask     = patchData.matchedApuMask();
    snapshot.pages              = patchData.pageCount();
    snapshot.sites              = patchData.siteCount();
    snapshot.pageHook           = backend.pageHookInstalled();
    snapshot.rangeHook          = backend.rangeHookInstalled();
    snapshot.appliedPages       = backend.appliedPageCount();
    snapshot.loadAttempts       = this->loadAttempts_;
    snapshot.retryPending       = this->retryScheduled_;
}

void UserPatchRuntime::publish(const PublishSnapshot& snapshot)
{
    auto* const service = ADDPR(selfInstance);
    if (service == nullptr) { return; }

    service->setProperty("NRedUserPatchState", UserPatchData::stateName(snapshot.state));
    service->setProperty("NRedUserPatchReason", UserPatchData::reasonName(snapshot.reason));
    service->setProperty("NRedUserPatchBuild", snapshot.build);
    service->setProperty("NRedUserPatchBuildSource", snapshot.buildSource);
    service->setProperty("NRedUserPatchDataSource", snapshot.dataSource);
    service->setProperty("NRedUserPatchApuMask", static_cast<unsigned long long>(snapshot.apuMask), 32);
    service->setProperty("NRedUserPatchAppliedApuMask",
                         static_cast<unsigned long long>(snapshot.appliedApuMask), 32);
    service->setProperty("NRedUserPatchPages", static_cast<unsigned long long>(snapshot.pages), 32);
    service->setProperty("NRedUserPatchSites", static_cast<unsigned long long>(snapshot.sites), 32);
    service->setProperty("NRedUserPatchHooks", snapshot.pageHook ? 1ULL : 0ULL, 32);
    service->setProperty("NRedUserPatchRangeHook", snapshot.rangeHook ? 1ULL : 0ULL, 32);
    service->setProperty("NRedUserPatchAppliedPages",
                         static_cast<unsigned long long>(snapshot.appliedPages), 32);
    service->setProperty("NRedUserPatchLoadAttempts", static_cast<unsigned long long>(snapshot.loadAttempts), 32);
    service->setProperty("NRedUserPatchRetryPending", snapshot.retryPending ? 1ULL : 0ULL, 32);
}

void UserPatchRuntime::logStateLocked(const char* const prefix) const
{
    auto& patchData = UserPatchData::singleton();
    auto& backend   = UserPatchBackend::singleton();

    SYSLOG("init", "%s: data=%s reason=%s loadAttempts=%u hooks=%s range=%s", prefix,
           patchData.stateName(), patchData.reasonName(), static_cast<unsigned>(this->loadAttempts_),
           backend.pageHookInstalled() ? "installed" : "absent",
           backend.rangeHookInstalled() ? "installed" : "absent");
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
        UserPatchRuntime::singleton().serviceStart();
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
