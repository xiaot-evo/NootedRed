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
#include <libkern/libkern.h>
#include <libkern/sysctl.h>
#include <mach/clock_types.h>
#include <string.h>
#include <PatchProfile.hpp>
#include <UserPatchBackend.hpp>

static const char* bootargOff   = "-NRedUserPatchOff";
static const char* bootargDebug = "-NRedUserPatchDebug";
static const char* bootargBeta  = "-NRedUserPatchBeta";

// XNU's kernel build string.  It is populated when launchd (PID 1) writes `kern.osversion` once
// during user-space bring-up; before that it is empty.  See readActualBuild().
extern "C" char osversion[];

namespace
{

    constexpr size_t kBuildTextSize = 24;

    // Bounded diagnostics refresh schedule (milliseconds).  AppliedPages/FindMismatches are only
    // meaningful once user-space has faulted the driver pages, so the counters are republished a
    // finite number of times instead of running an endless timer.
    constexpr UInt32 kRefreshDelaysMs[] = {5000, 15000, 30000, 60000, 120000, 240000};
    constexpr UInt32 kRefreshCount      = sizeof(kRefreshDelaysMs) / sizeof(kRefreshDelaysMs[0]);

    // Bounded running-build discovery retry policy.  `kern.osversion` is writable by design and is set
    // exactly once by launchd (PID 1) via the sysctl_osversion handler, which also calls
    // IORegistrySetOSBuildVersion() to publish the IODeviceTree root "OS Build Version" property
    // (XNU bsd/kern/kern_sysctl.c).  The plugin entry points run during kernel initialization, long
    // before launchd, so all three build sources are legitimately empty at that time.  Identity
    // discovery therefore retries on a bounded 1 s cadence until launchd has published the actual
    // running build.  This is discovery retry, not a fallback: no value is guessed or accepted from a
    // hint, and until the actual build is readable the engine stays inert.
    constexpr UInt32 kIdentityRetryDelayMs = 1000;
    constexpr UInt32 kIdentityRetryLimit   = 40;

    const char* const kProfileProperty   = "NRedOffsetProfile";
    const char* const kBuildHintProperty = "NRedSystemBuild";

    // Last observed values of every running-build source, filled by readActualBuild().  Diagnostics
    // only; an unreadable or malformed source is reported as "none".
    struct BuildReadings
    {
        char        deviceTree[kBuildTextSize]{"none"};
        char        sysctl[kBuildTextSize]{"none"};
        char        xnu[kBuildTextSize]{"none"};
        const char* source{"none"};
    };

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

    void storeReading(char* const out, const size_t outSize, const bool present, const char* const value)
    {
        if (present && value != nullptr) {
            strlcpy(out, value, outSize);
        }
        else {
            strlcpy(out, "none", outSize);
        }
    }

    // Reads the running build from the IODeviceTree root.  The kernel publishes this property through
    // IORegistrySetOSBuildVersion() when launchd writes kern.osversion, so it is empty during kernel
    // initialization and appears with the same value as the sysctl.
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
    // an unresolvable identity (fail closed), never a preference order.  `readings` is filled for the
    // diagnostics properties on every attempt, including attempts where nothing is readable yet.
    bool readActualBuild(char* const out, const size_t outSize, BuildReadings& readings)
    {
        char deviceTreeBuild[kBuildTextSize]{};
        char sysctlBuild[kBuildTextSize]{};
        char xnuBuild[kBuildTextSize]{};

        const bool haveDeviceTree = readDeviceTreeBuild(deviceTreeBuild, sizeof(deviceTreeBuild))
                                    && PatchProfile::isValidBuildString(deviceTreeBuild);
        const bool haveSysctl = readSysctlBuild(sysctlBuild, sizeof(sysctlBuild))
                                && PatchProfile::isValidBuildString(sysctlBuild);
        const bool haveXnu = readXnuBuild(xnuBuild, sizeof(xnuBuild)) && PatchProfile::isValidBuildString(xnuBuild);

        storeReading(readings.deviceTree, sizeof(readings.deviceTree), haveDeviceTree, deviceTreeBuild);
        storeReading(readings.sysctl, sizeof(readings.sysctl), haveSysctl, sysctlBuild);
        storeReading(readings.xnu, sizeof(readings.xnu), haveXnu, xnuBuild);
        readings.source = "none";

        const char* resolved = nullptr;
        const char* source   = "none";

        if (haveDeviceTree) {
            resolved = deviceTreeBuild;
            source   = "deviceTree";
        }
        if (haveSysctl) {
            if (resolved != nullptr && strcmp(resolved, sysctlBuild) != 0) {
                SYSLOG("init", "running build sources disagree (device tree vs kern.osversion); identity unresolved");
                return false;
            }
            if (resolved == nullptr) {
                resolved = sysctlBuild;
                source   = "sysctl";
            }
        }
        if (haveXnu) {
            if (resolved != nullptr && strcmp(resolved, xnuBuild) != 0) {
                SYSLOG("init", "running build sources disagree (kernel global vs detected); identity unresolved");
                return false;
            }
            if (resolved == nullptr) {
                resolved = xnuBuild;
                source   = "xnu";
            }
        }

        if (resolved == nullptr) { return false; }

        readings.source = source;
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

    // Bounded comma-separated index list builder for the applied-page diagnostics.  Never runs in a
    // validation hook: it only formats a handful of bytes for the IORegistry publication.
    void appendPageIndex(char* const buffer, const size_t size, size_t& position, const UInt32 index, bool& truncated)
    {
        if (truncated || position >= size) {
            truncated = true;
            return;
        }

        const int written = snprintf(buffer + position, size - position, position == 0 ? "%u" : ",%u",
                                     static_cast<unsigned>(index));
        if (written < 0 || static_cast<size_t>(written) >= size - position) {
            truncated = true;
            return;
        }
        position += static_cast<size_t>(written);
    }

    // Fills the hex profile-page applied mask plus the applied/unapplied page index lists.  The mask
    // covers the v1 limit of 256 page records (four 64-bit words, highest word first).
    void buildAppliedPageDiagnostics(const PatchProfile& profile, char* const maskText, const size_t maskSize,
                                     char* const appliedText, const size_t appliedSize, char* const unappliedText,
                                     const size_t unappliedSize)
    {
        UInt32 topWord = PatchProfile::kAppliedMaskWords;
        while (topWord > 0 && profile.appliedMaskWord(topWord - 1) == 0) { topWord -= 1; }

        size_t pos = 0;
        if (topWord == 0) {
            snprintf(maskText, maskSize, "0x%016llX", 0ULL);
        }
        else {
            int written = snprintf(maskText, maskSize, "0x%016llX",
                                   static_cast<unsigned long long>(profile.appliedMaskWord(topWord - 1)));
            pos = written > 0 ? static_cast<size_t>(written) : 0;
            for (UInt32 word = topWord - 1; word > 0; word--) {
                if (pos >= maskSize) { break; }
                written = snprintf(maskText + pos, maskSize - pos, "%016llX",
                                   static_cast<unsigned long long>(profile.appliedMaskWord(word - 1)));
                if (written < 0 || static_cast<size_t>(written) >= maskSize - pos) { break; }
                pos += static_cast<size_t>(written);
            }
        }

        size_t appliedPos   = 0;
        size_t unappliedPos = 0;
        bool   appliedTruncated   = false;
        bool   unappliedTruncated = false;
        for (UInt32 pageIndex = 0; pageIndex < profile.pageCount(); pageIndex++) {
            if (profile.pageApplied(pageIndex)) {
                appendPageIndex(appliedText, appliedSize, appliedPos, pageIndex, appliedTruncated);
            }
            else {
                appendPageIndex(unappliedText, unappliedSize, unappliedPos, pageIndex, unappliedTruncated);
            }
        }
        if (appliedPos == 0) { strlcpy(appliedText, "none", appliedSize); }
        if (unappliedPos == 0) { strlcpy(unappliedText, "none", unappliedSize); }
    }

    // Member-function-pointer based accessors let the runtime-diagnostic mask/list builders stay
    // generic over the applied/observed/offset-mismatch/offset-seen page masks.
    using PageMaskWordGetter = UInt64 (PatchProfile::*)(UInt32) const;
    using PageBitGetter      = bool (PatchProfile::*)(UInt32) const;

    void formatPageMaskHex(const PatchProfile& profile, const PageMaskWordGetter getter, char* const out,
                           const size_t outSize)
    {
        UInt32 topWord = PatchProfile::kAppliedMaskWords;
        while (topWord > 0 && (profile.*getter)(topWord - 1) == 0) { topWord -= 1; }

        if (topWord == 0) {
            snprintf(out, outSize, "0x%016llX", 0ULL);
            return;
        }

        int    written = snprintf(out, outSize, "0x%016llX",
                                  static_cast<unsigned long long>((profile.*getter)(topWord - 1)));
        size_t pos     = written > 0 ? static_cast<size_t>(written) : 0;
        for (UInt32 word = topWord - 1; word > 0; word--) {
            if (pos >= outSize) { break; }
            written = snprintf(out + pos, outSize - pos, "%016llX",
                               static_cast<unsigned long long>((profile.*getter)(word - 1)));
            if (written < 0 || static_cast<size_t>(written) >= outSize - pos) { break; }
            pos += static_cast<size_t>(written);
        }
    }

    void buildPageIndexList(const PatchProfile& profile, const PageBitGetter getter, char* const out,
                            const size_t outSize)
    {
        size_t pos       = 0;
        bool   truncated = false;
        for (UInt32 pageIndex = 0; pageIndex < profile.pageCount(); pageIndex++) {
            if ((profile.*getter)(pageIndex)) { appendPageIndex(out, outSize, pos, pageIndex, truncated); }
        }
        if (pos == 0) { strlcpy(out, "none", outSize); }
    }

    // First pager offset at which each profile page's full-page content was observed, e.g.
    // "0:0x8000,1:none,2:0x1000".  Bounded and truncated for pathological profiles.
    void buildObservedOffsetList(const PatchProfile& profile, char* const out, const size_t outSize)
    {
        size_t pos       = 0;
        bool   truncated = false;
        for (UInt32 pageIndex = 0; pageIndex < profile.pageCount(); pageIndex++) {
            if (truncated) { break; }

            UInt64    offset  = 0;
            const bool present = profile.firstObservedOffset(pageIndex, offset);
            int        written = 0;
            if (present) {
                written = snprintf(out + pos, outSize - pos, pos == 0 ? "%u:0x%llX" : ",%u:0x%llX",
                                   static_cast<unsigned>(pageIndex), static_cast<unsigned long long>(offset));
            }
            else {
                written = snprintf(out + pos, outSize - pos, pos == 0 ? "%u:none" : ",%u:none",
                                   static_cast<unsigned>(pageIndex));
            }
            if (written < 0 || static_cast<size_t>(written) >= outSize - pos) {
                truncated = true;
                break;
            }
            pos += static_cast<size_t>(written);
        }
        if (pos == 0) { strlcpy(out, "none", outSize); }
    }

    // Decisive classification for every profile page that was never applied:
    //   offsetMismatch       - the full-page hash matched at a chunk whose pager offset differs from
    //                          the record's required offset (offset namespace mismatch);
    //   siteOrWriteMismatch  - hash and offset matched, but a site find or the write failed;
    //   contentMismatch      - the expected pager offset was delivered but the page hash differs;
    //   neverPresented       - no chunk with the expected pager offset was ever delivered;
    //   unobserved           - offset-free record whose content was never observed.
    const char* classifyUnappliedPage(const PatchProfile& profile, const UInt32 pageIndex)
    {
        if (profile.offsetMismatch(pageIndex)) { return "offsetMismatch"; }
        if (profile.hashObserved(pageIndex)) { return "siteOrWriteMismatch"; }
        if (profile.offsetSeen(pageIndex)) { return "contentMismatch"; }
        if (profile.pageRequiresOffset(pageIndex)) { return "neverPresented"; }
        return "unobserved";
    }

    void buildUnappliedDiagnostics(const PatchProfile& profile, char* const out, const size_t outSize)
    {
        size_t pos = 0;
        for (UInt32 pageIndex = 0; pageIndex < profile.pageCount(); pageIndex++) {
            if (profile.pageApplied(pageIndex)) { continue; }

            const int written = snprintf(out + pos, outSize - pos, pos == 0 ? "%u:%s" : ",%u:%s",
                                         static_cast<unsigned>(pageIndex),
                                         classifyUnappliedPage(profile, pageIndex));
            if (written < 0 || static_cast<size_t>(written) >= outSize - pos) { break; }
            pos += static_cast<size_t>(written);
        }
        if (pos == 0) { strlcpy(out, "none", outSize); }
    }

    // "index:0xHASH" for every recorded expected-offset delivery (bounded per-page slot list).
    void buildExpectedOffsetHashes(const PatchProfile& profile, char* const out, const size_t outSize)
    {
        size_t pos    = 0;
        bool   filled = false;
        for (UInt32 pageIndex = 0; pageIndex < profile.pageCount() && !filled; pageIndex++) {
            const UInt32 count = profile.expectedOffsetHashCount(pageIndex);
            for (UInt32 slot = 0; slot < count; slot++) {
                UInt64 hash = 0;
                UInt32 found = 0;
                UInt32 total = 0;
                if (!profile.expectedOffsetHashEntry(pageIndex, slot, hash, found, total)) { continue; }

                const int written = snprintf(out + pos, outSize - pos, pos == 0 ? "%u:0x%016llX" : ",%u:0x%016llX",
                                             static_cast<unsigned>(pageIndex),
                                             static_cast<unsigned long long>(hash));
                if (written < 0 || static_cast<size_t>(written) >= outSize - pos) {
                    filled = true;
                    break;
                }
                pos += static_cast<size_t>(written);
            }
        }
        if (pos == 0) { strlcpy(out, "none", outSize); }
    }

    // "index:<matched>/<total>" site-find counts for every recorded expected-offset delivery.
    void buildExpectedOffsetSiteCounts(const PatchProfile& profile, char* const out, const size_t outSize)
    {
        size_t pos    = 0;
        bool   filled = false;
        for (UInt32 pageIndex = 0; pageIndex < profile.pageCount() && !filled; pageIndex++) {
            const UInt32 count = profile.expectedOffsetHashCount(pageIndex);
            for (UInt32 slot = 0; slot < count; slot++) {
                UInt64 hash = 0;
                UInt32 found = 0;
                UInt32 total = 0;
                if (!profile.expectedOffsetHashEntry(pageIndex, slot, hash, found, total)) { continue; }

                const int written = snprintf(out + pos, outSize - pos, pos == 0 ? "%u:%u/%u" : ",%u:%u/%u",
                                             static_cast<unsigned>(pageIndex), static_cast<unsigned>(found),
                                             static_cast<unsigned>(total));
                if (written < 0 || static_cast<size_t>(written) >= outSize - pos) {
                    filled = true;
                    break;
                }
                pos += static_cast<size_t>(written);
            }
        }
        if (pos == 0) { strlcpy(out, "none", outSize); }
    }

    // Pages where at least one expected-offset delivery still matched every generated site find.
    // Returns the number of such pages.
    UInt32 buildSiteFindAllMatchedPages(const PatchProfile& profile, char* const out, const size_t outSize)
    {
        size_t pos       = 0;
        bool   truncated = false;
        UInt32 matchedPages = 0;
        for (UInt32 pageIndex = 0; pageIndex < profile.pageCount(); pageIndex++) {
            const UInt32 count = profile.expectedOffsetHashCount(pageIndex);
            bool allMatched = false;
            for (UInt32 slot = 0; slot < count; slot++) {
                UInt64 hash = 0;
                UInt32 found = 0;
                UInt32 total = 0;
                if (!profile.expectedOffsetHashEntry(pageIndex, slot, hash, found, total)) { continue; }
                if (total != 0 && found == total) {
                    allMatched = true;
                    break;
                }
            }
            if (allMatched) {
                matchedPages += 1;
                appendPageIndex(out, outSize, pos, pageIndex, truncated);
            }
        }
        if (pos == 0) { strlcpy(out, "none", outSize); }
        return matchedPages;
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

// Orchestrates the asynchronous entry points (Lilu patcher load and IOService start) plus a bounded
// identity-discovery retry into one deterministic first-wins transition:
//
//   1. the NRPT profile is copied and validated exactly once (service start);
//   2. the APU family and iGPU device ID are detected once in the sleepable patcher-load callback;
//   3. the authoritative running build is resolved from the kernel/bootloader sources; because
//      kern.osversion is only populated later by launchd, this step retries on a bounded 1 s cadence
//      instead of failing at the early entry points;
//   4. while the actual build is not readable yet, the injected NRedSystemBuild hint may unblock
//      matching provisionally, but only when it is a valid build string and exactly equals the parsed
//      profile build (IdentityProvisional=1).  Once the actual build is readable it is authoritative:
//      exact equality confirms the provisional state, any disagreement is a hard error that revokes
//      the profile and stops future writes (early writes are reported, never rolled back);
//   5. after the retry budget is exhausted without an actual build the plugin fails closed; the hint
//      is never promoted to the final identity.
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

    // Where the injected profile was copied/validated.  Published as a diagnostic: a page faulted before
    // the profile is active is cached by the kernel and never revalidated, so this stage matters.
    enum class ProfileLoadStage : UInt8
    {
        kNone = 0,
        kPatcherLoad,
        kServiceStart,
        kAbsent,
    };

    void loadProfileLocked(IOService* service, ProfileLoadStage stage);
    const char* profileLoadStageName() const;
    void resolveIdentityLocked(IOService* service);
    void afterTransition();
    void startIdentityRetriesIfNeeded();
    void identityRetryStep();
    void scheduleIdentityRetry();
    void publishDiagnostics();
    void scheduleRefresh(UInt32 delayMs);
    void refreshStep();
    static void identityRetryCallback(thread_call_param_t param0, thread_call_param_t param1);
    static void refreshCallback(thread_call_param_t param0, thread_call_param_t param1);

    // Static publication buffers keep UserPatchRuntime::publishDiagnostics() off the kernel stack
    // (-Wframe-larger-than applies to kernel code).  Serialised by publishLock_.
    struct DiagnosticsText
    {
        char appliedMask[24]{"0x0000000000000000"};
        char appliedPageList[256]{"none"};
        char unappliedPageList[256]{"none"};
        char observedHashMask[24]{"0x0000000000000000"};
        char observedHashPageList[256]{"none"};
        char offsetMismatchMask[24]{"0x0000000000000000"};
        char offsetMismatchPageList[256]{"none"};
        char offsetSeenMask[24]{"0x0000000000000000"};
        char offsetSeenPageList[256]{"none"};
        char observedOffsetList[512]{"none"};
        char unappliedDiagnostics[384]{"none"};
        char expectedOffsetSeenMask[24]{"0x0000000000000000"};
        char expectedOffsetHashes[1024]{"none"};
        char expectedOffsetSiteCounts[768]{"none"};
        char siteFindAllMatchedList[256]{"none"};
        char vnodeRejectedMask[24]{"0x0000000000000000"};
        char vnodeRejectedPageList[256]{"none"};
        char alreadyPatchedMask[24]{"0x0000000000000000"};
        char alreadyPatchedPageList[256]{"none"};
        char hashOnlyAppliedMask[24]{"0x0000000000000000"};
        char hashOnlyAppliedPageList[256]{"none"};
    };

    IOLock* lock_{nullptr};
    IOLock* publishLock_{nullptr};
    DiagnosticsText diag_{};

    bool disabled_{false};
    bool profileHandled_{false};
    bool identityResolved_{false};
    bool identityRetryActive_{false};
    bool provisionalLogged_{false};
    UInt32 identityAttempts_{0};
    ProfileLoadStage profileLoadStage_{ProfileLoadStage::kNone};

    char actualBuild_[kBuildTextSize]{};
    char injectedBuild_[kBuildTextSize]{};
    bool injectedBuildValid_{false};

    // Last observed running-build sources, published as diagnostics.
    char deviceTreeBuild_[kBuildTextSize]{"none"};
    char sysctlBuild_[kBuildTextSize]{"none"};
    char xnuBuild_[kBuildTextSize]{"none"};
    char resolvedBuildSource_[16]{"none"};

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
    this->publishLock_ = IOLockAlloc();
    if (this->lock_ == nullptr || this->publishLock_ == nullptr) {
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
        // Load/validate the injected profile before the code-signing routes are installed: a page that
        // faults before the profile is active has its validation result cached by the kernel and is
        // never presented to the hooks again.  Lilu's cached DeviceInfo is already available here
        // (createCached() runs before the patcher-load callbacks), so hardware identity and the
        // provisional build gate can also complete before routing.  If the IOKit service instance is
        // not visible yet this defers to IOService::start.
        this->loadProfileLocked(ADDPR(selfInstance), ProfileLoadStage::kPatcherLoad);

        // Sleepable, IOKit-safe context: this is the only place hardware identity is detected.
        UserPatchBackend::singleton().detectHardwareIdentity();

        this->resolveIdentityLocked(ADDPR(selfInstance));

        // Unconditional install: a missing or rejected profile must never delay kernel-text routing.
        UserPatchBackend::singleton().install(patcher);
    }
    IOLockUnlock(this->lock_);

    this->afterTransition();
    this->startIdentityRetriesIfNeeded();
}

void UserPatchRuntime::onServiceStart(IOService* const service)
{
    if (this->lock_ == nullptr) { return; }

    IOLockLock(this->lock_);
    if (!this->disabled_) {
        this->loadProfileLocked(service, ProfileLoadStage::kServiceStart);
        this->resolveIdentityLocked(service);
    }
    IOLockUnlock(this->lock_);

    this->afterTransition();
    this->startIdentityRetriesIfNeeded();
}

void UserPatchRuntime::loadProfileLocked(IOService* const service, const ProfileLoadStage stage)
{
    if (this->profileHandled_) { return; }

    // The IOKit service instance (and thus the injected personality properties) may not be visible
    // during the early patcher-load callback: leave the profile unhandled so IOService::start retries.
    if (service == nullptr) { return; }

    auto* const property = service->getProperty(kProfileProperty);
    auto* const data     = OSDynamicCast(OSData, property);
    if (data == nullptr) {
        if (stage == ProfileLoadStage::kServiceStart) {
            this->profileHandled_    = true;
            this->profileLoadStage_  = ProfileLoadStage::kAbsent;
            PatchProfile::singleton().noteAbsentProfile();
        }
        return;
    }

    this->profileHandled_   = true;
    this->profileLoadStage_ = stage;

    // Read the injected build hint before the properties are removed.  It is a sanity check only.
    char injected[kBuildTextSize]{};
    if (readInjectedBuild(service, injected, sizeof(injected))) {
        strlcpy(this->injectedBuild_, injected, sizeof(this->injectedBuild_));
        this->injectedBuildValid_ = true;
    }

    // Validate and copy the whole profile while the OSData property is still alive.  The engine keeps
    // only its own bounded static tables, so the property bytes may be freed afterwards.
    PatchProfile::singleton().loadFromData(data->getBytesNoCopy(), data->getLength());

    service->removeProperty(kProfileProperty);
    service->removeProperty(kBuildHintProperty);

    SYSLOG("init", "profile loaded at stage %s", this->profileLoadStageName());
}

const char* UserPatchRuntime::profileLoadStageName() const
{
    switch (this->profileLoadStage_) {
        case ProfileLoadStage::kPatcherLoad: return "patcherLoad";
        case ProfileLoadStage::kServiceStart: return "serviceStart";
        case ProfileLoadStage::kAbsent: return "absent";
        default: return "none";
    }
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

    BuildReadings readings{};
    char          actual[kBuildTextSize]{};
    const bool    resolved = readActualBuild(actual, sizeof(actual), readings);

    // Publish the last observed source values even when the build is not readable yet: this is what
    // makes a "build unavailable" report conclusive without another debug build.
    strlcpy(this->deviceTreeBuild_, readings.deviceTree, sizeof(this->deviceTreeBuild_));
    strlcpy(this->sysctlBuild_, readings.sysctl, sizeof(this->sysctlBuild_));
    strlcpy(this->xnuBuild_, readings.xnu, sizeof(this->xnuBuild_));
    strlcpy(this->resolvedBuildSource_, readings.source, sizeof(this->resolvedBuildSource_));

    if (resolved) {
        strlcpy(this->actualBuild_, actual, sizeof(this->actualBuild_));
        this->identityResolved_ = true;

        const bool accepted =
            PatchProfile::singleton().confirmRunningBuild(this->actualBuild_,
                                                          this->injectedBuildValid_ ? this->injectedBuild_ : nullptr);
        SYSLOG("init", "running build resolved as %s (source %s): %s", this->actualBuild_, this->resolvedBuildSource_,
               accepted ? "confirmed" : "rejected");
        return;
    }

    // The actual build is not published yet (launchd writes kern.osversion later).  The injected hint
    // may unblock early matching provisionally, but only when it is valid and exactly equals the
    // parsed profile build; the profile engine enforces that and never stores an invalid/mismatched
    // hint.  The identity retry chain keeps running until the actual build confirms or contradicts it.
    if (!this->identityResolved_
        && PatchProfile::singleton().setProvisionalBuild(this->injectedBuildValid_ ? this->injectedBuild_ : nullptr))
    {
        if (!this->provisionalLogged_) {
            this->provisionalLogged_ = true;
            SYSLOG("init", "running build not published yet; matching provisionally on NRedSystemBuild %s",
                   this->injectedBuild_);
        }
    }
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

void UserPatchRuntime::startIdentityRetriesIfNeeded()
{
    bool start = false;
    IOLockLock(this->lock_);
    if (!this->disabled_ && this->profileHandled_ && !this->identityResolved_ && !this->identityRetryActive_
        && PatchProfile::singleton().state() != PatchProfile::State::kNoOp)
    {
        this->identityRetryActive_ = true;
        this->identityAttempts_    = 0;
        start                      = true;
    }
    IOLockUnlock(this->lock_);

    if (start) {
        SYSLOG("init", "running build not published yet (launchd sets kern.osversion); retrying identity discovery");
        this->scheduleIdentityRetry();
    }
}

void UserPatchRuntime::identityRetryStep()
{
    if (this->lock_ == nullptr) { return; }

    bool reschedule = false;
    bool exhausted  = false;

    IOLockLock(this->lock_);
    auto& profile = PatchProfile::singleton();
    if (!this->disabled_ && this->identityRetryActive_) {
        this->identityAttempts_ += 1;
        this->resolveIdentityLocked(ADDPR(selfInstance));

        if (this->identityResolved_ || profile.state() == PatchProfile::State::kNoOp) {
            this->identityRetryActive_ = false;
        }
        else if (this->identityAttempts_ >= kIdentityRetryLimit) {
            // Bounded discovery is exhausted and the authoritative running build was never readable:
            // fail closed.  The injected NRedSystemBuild hint is never used as an acceptance fallback.
            this->identityRetryActive_ = false;
            exhausted                  = true;
            profile.failUnconfirmedBuild();
        }
        else {
            reschedule = true;
        }
    }
    IOLockUnlock(this->lock_);

    if (exhausted) {
        SYSLOG("init", "running build identity unavailable after %u attempt(s); page backend stays inert",
               static_cast<unsigned>(kIdentityRetryLimit));
    }

    this->afterTransition();
    this->startIdentityRetriesIfNeeded();

    if (reschedule) { this->scheduleIdentityRetry(); }
}

void UserPatchRuntime::scheduleIdentityRetry()
{
    thread_call_t call = thread_call_allocate(identityRetryCallback, nullptr);
    if (call == nullptr) {
        SYSLOG("init", "failed to allocate identity retry call; failing closed");
        IOLockLock(this->lock_);
        this->identityRetryActive_ = false;
        PatchProfile::singleton().failUnconfirmedBuild();
        IOLockUnlock(this->lock_);
        this->afterTransition();
        return;
    }

    UInt64 deadline = 0;
    clock_interval_to_deadline(kIdentityRetryDelayMs, static_cast<uint32_t>(NSEC_PER_MSEC), &deadline);
    if (thread_call_enter1_delayed(call, call, deadline)) {
        // Cannot happen for a freshly allocated call; never free a possibly pending call.
        SYSLOG("init", "identity retry call was unexpectedly pending");
    }
}

void UserPatchRuntime::identityRetryCallback(thread_call_param_t, thread_call_param_t param1)
{
    auto* const thisCall = static_cast<thread_call_t>(param1);
    singleton().identityRetryStep();
    if (thisCall != nullptr) { thread_call_free(thisCall); }
}

void UserPatchRuntime::publishDiagnostics()
{
    auto* const service = ADDPR(selfInstance);
    if (service == nullptr || this->publishLock_ == nullptr) { return; }

    // Serialise formatting and publication so concurrent entry points / retry / refresh contexts cannot
    // interleave the shared static diagnostic buffers.  The lock order is publishLock_ -> lock_.
    IOLockLock(this->publishLock_);

    // Snapshot the runtime-owned strings under the state lock.
    char   deviceTreeBuild[kBuildTextSize]{"none"};
    char   sysctlBuild[kBuildTextSize]{"none"};
    char   xnuBuild[kBuildTextSize]{"none"};
    char   buildSource[16]{"none"};
    char   actualBuild[kBuildTextSize]{};
    UInt32 identityAttempts = 0;
    bool   identityResolved = false;
    if (this->lock_ != nullptr) {
        IOLockLock(this->lock_);
        strlcpy(deviceTreeBuild, this->deviceTreeBuild_, sizeof(deviceTreeBuild));
        strlcpy(sysctlBuild, this->sysctlBuild_, sizeof(sysctlBuild));
        strlcpy(xnuBuild, this->xnuBuild_, sizeof(xnuBuild));
        strlcpy(buildSource, this->resolvedBuildSource_, sizeof(buildSource));
        strlcpy(actualBuild, this->actualBuild_, sizeof(actualBuild));
        identityAttempts = this->identityAttempts_;
        identityResolved = this->identityResolved_;
        IOLockUnlock(this->lock_);
    }

    auto& profile = PatchProfile::singleton();
    auto& backend = UserPatchBackend::singleton();

    // Applied-page diagnostics: hex mask plus index lists.  Together with Pages this identifies every
    // profile record that was never applied (the per-page "applied once" bit is permanent for the boot).
    auto& diag = this->diag_;
    buildAppliedPageDiagnostics(profile, diag.appliedMask, sizeof(diag.appliedMask), diag.appliedPageList,
                                sizeof(diag.appliedPageList), diag.unappliedPageList,
                                sizeof(diag.unappliedPageList));

    // Bounded per-page runtime diagnostics (hash observations, offset-gate rejections, first pager
    // offset, and the decisive classification of every unapplied record).
    formatPageMaskHex(profile, &PatchProfile::observedHashMaskWord, diag.observedHashMask,
                      sizeof(diag.observedHashMask));
    buildPageIndexList(profile, &PatchProfile::hashObserved, diag.observedHashPageList,
                       sizeof(diag.observedHashPageList));
    formatPageMaskHex(profile, &PatchProfile::offsetMismatchMaskWord, diag.offsetMismatchMask,
                      sizeof(diag.offsetMismatchMask));
    buildPageIndexList(profile, &PatchProfile::offsetMismatch, diag.offsetMismatchPageList,
                       sizeof(diag.offsetMismatchPageList));
    formatPageMaskHex(profile, &PatchProfile::offsetSeenMaskWord, diag.offsetSeenMask, sizeof(diag.offsetSeenMask));
    buildPageIndexList(profile, &PatchProfile::offsetSeen, diag.offsetSeenPageList, sizeof(diag.offsetSeenPageList));
    buildObservedOffsetList(profile, diag.observedOffsetList, sizeof(diag.observedOffsetList));
    buildUnappliedDiagnostics(profile, diag.unappliedDiagnostics, sizeof(diag.unappliedDiagnostics));

    // Expected-offset content evidence: the actual delivered hashes and site-find match counts for
    // chunks that arrived at a record's exact required pager offset (even when the page hash differs).
    formatPageMaskHex(profile, &PatchProfile::vnodeRejectedMaskWord, diag.vnodeRejectedMask,
                      sizeof(diag.vnodeRejectedMask));
    buildPageIndexList(profile, &PatchProfile::vnodeRejected, diag.vnodeRejectedPageList,
                       sizeof(diag.vnodeRejectedPageList));
    formatPageMaskHex(profile, &PatchProfile::alreadyPatchedMaskWord, diag.alreadyPatchedMask,
                      sizeof(diag.alreadyPatchedMask));
    buildPageIndexList(profile, &PatchProfile::alreadyPatched, diag.alreadyPatchedPageList,
                       sizeof(diag.alreadyPatchedPageList));
    formatPageMaskHex(profile, &PatchProfile::hashOnlyAppliedMaskWord, diag.hashOnlyAppliedMask,
                      sizeof(diag.hashOnlyAppliedMask));
    buildPageIndexList(profile, &PatchProfile::hashOnlyApplied, diag.hashOnlyAppliedPageList,
                       sizeof(diag.hashOnlyAppliedPageList));
    formatPageMaskHex(profile, &PatchProfile::expectedOffsetSeenMaskWord, diag.expectedOffsetSeenMask,
                      sizeof(diag.expectedOffsetSeenMask));
    buildExpectedOffsetHashes(profile, diag.expectedOffsetHashes, sizeof(diag.expectedOffsetHashes));
    buildExpectedOffsetSiteCounts(profile, diag.expectedOffsetSiteCounts, sizeof(diag.expectedOffsetSiteCounts));
    const UInt32 siteFindAllMatchedPages =
        buildSiteFindAllMatchedPages(profile, diag.siteFindAllMatchedList, sizeof(diag.siteFindAllMatchedList));

    const char* const buildText = profile.build()[0] != '\0'
                                      ? profile.build()
                                      : (actualBuild[0] != '\0' ? actualBuild : "none");

    service->setProperty("NRedUserPatchState", profile.stateName());
    service->setProperty("NRedUserPatchReason", profile.reasonName());
    service->setProperty("NRedUserPatchBuild", buildText);
    service->setProperty("NRedUserPatchBuildSource", buildSource);
    service->setProperty("NRedUserPatchDeviceTreeBuild", deviceTreeBuild);
    service->setProperty("NRedUserPatchSysctlBuild", sysctlBuild);
    service->setProperty("NRedUserPatchXnuBuild", xnuBuild);
    service->setProperty("NRedUserPatchIdentityResolved",
                         static_cast<unsigned long long>(identityResolved ? 1 : 0), 32);
    service->setProperty("NRedUserPatchIdentityAttempts", static_cast<unsigned long long>(identityAttempts), 32);
    service->setProperty("NRedUserPatchIdentityProvisional",
                         static_cast<unsigned long long>(profile.provisionalBuild() ? 1 : 0), 32);
    service->setProperty("NRedUserPatchProfileLoadStage", this->profileLoadStageName());
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
    service->setProperty("NRedUserPatchAppliedPageMask", diag.appliedMask);
    service->setProperty("NRedUserPatchAppliedPageList", diag.appliedPageList);
    service->setProperty("NRedUserPatchUnappliedPageList", diag.unappliedPageList);
    service->setProperty("NRedUserPatchObservedHashPageMask", diag.observedHashMask);
    service->setProperty("NRedUserPatchObservedHashPages", diag.observedHashPageList);
    service->setProperty("NRedUserPatchOffsetMismatchPageMask", diag.offsetMismatchMask);
    service->setProperty("NRedUserPatchOffsetMismatchPages", diag.offsetMismatchPageList);
    service->setProperty("NRedUserPatchOffsetSeenPageMask", diag.offsetSeenMask);
    service->setProperty("NRedUserPatchOffsetSeenPages", diag.offsetSeenPageList);
    service->setProperty("NRedUserPatchObservedPageOffsets", diag.observedOffsetList);
    service->setProperty("NRedUserPatchUnappliedPageDiagnostics", diag.unappliedDiagnostics);
    service->setProperty("NRedUserPatchOffsetMismatchEvents",
                         static_cast<unsigned long long>(profile.offsetMismatchEvents()), 32);
    service->setProperty("NRedUserPatchPendingObservations",
                         static_cast<unsigned long long>(profile.pendingObservations()), 32);
    service->setProperty("NRedUserPatchVnodeGate", profile.vnodeGateActive() ? "active" : "legacy-offset");
    service->setProperty("NRedUserPatchVnodeRejectedPages",
                         static_cast<unsigned long long>(profile.vnodeRejectedPages()), 32);
    service->setProperty("NRedUserPatchVnodeRejectedEvents",
                         static_cast<unsigned long long>(profile.vnodeRejectedEvents()), 32);
    service->setProperty("NRedUserPatchVnodeRejectedPageMask", diag.vnodeRejectedMask);
    service->setProperty("NRedUserPatchVnodeRejectedPageList", diag.vnodeRejectedPageList);
    service->setProperty("NRedUserPatchAlreadyPatchedPages",
                         static_cast<unsigned long long>(profile.alreadyPatchedPages()), 32);
    service->setProperty("NRedUserPatchAlreadyPatchedPageMask", diag.alreadyPatchedMask);
    service->setProperty("NRedUserPatchAlreadyPatchedPageList", diag.alreadyPatchedPageList);
    service->setProperty("NRedUserPatchHashOnlyAppliedPages",
                         static_cast<unsigned long long>(profile.hashOnlyAppliedPages()), 32);
    service->setProperty("NRedUserPatchHashOnlyAppliedPageMask", diag.hashOnlyAppliedMask);
    service->setProperty("NRedUserPatchHashOnlyAppliedPageList", diag.hashOnlyAppliedPageList);
    service->setProperty("NRedUserPatchExpectedOffsetSeenPageMask", diag.expectedOffsetSeenMask);
    service->setProperty("NRedUserPatchExpectedOffsetActualHashes", diag.expectedOffsetHashes);
    service->setProperty("NRedUserPatchExpectedOffsetSiteFindCounts", diag.expectedOffsetSiteCounts);
    service->setProperty("NRedUserPatchSiteFindAtExpectedOffsetPages", diag.siteFindAllMatchedList);
    service->setProperty("NRedUserPatchSiteFindAtExpectedOffsetCount",
                         static_cast<unsigned long long>(siteFindAllMatchedPages), 32);

    IOLockUnlock(this->publishLock_);
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
        // Fallback load point: the patcher-load callback usually already copied/validated the injected
        // NRedOffsetProfile and started provisional matching before the validators were routed.  If the
        // service instance was not visible then, this is where the profile is loaded.
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
