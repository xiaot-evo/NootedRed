// NootedRedUserPatch generic NRPT profile engine
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

#pragma once
#include <Headers/kern_util.hpp>
#include <stddef.h>
#include <stdint.h>

// Generic consumer for the NRPT v1 profile format (docs/PatchProfile-Spec.md).
//
// The class owns only generic engine state: the parsed and fully validated page/site records copied
// out of the injected `NRedOffsetProfile` OSData property, the running-system identity gates and the
// per-chunk matcher used by the code-signing hooks.  It contains no patch data of its own: every page
// offset, page hash, site offset and find/replace byte comes from the profile.
//
// The profile is authoritative and fail-closed: a profile that violates any structural rule in the
// specification is rejected as a whole, and a page is only written after the running build, the
// running APU family (and optionally the iGPU PCI device ID) passed and the full-page hash and every
// site find of the matched record passed.
//
// Concurrency: loadFromData()/setRunningBuild()/setRunningApu() are called from sleepable plugin
// contexts (IOService start and the Lilu patcher-load callback) and are serialised by the plugin.
// Once loaded() returns true the parsed tables are immutable for the rest of the boot.  applyChunk()
// runs inside the _cs_validate_page/_cs_validate_range hooks and only reads the immutable tables plus
// atomics: no allocation, no VFS, no IOKit, no sleeping and no unbounded logging.
class PatchProfile
{
public:
    // NRPT v1 layout constants (docs/PatchProfile-Spec.md sections 2-7).
    static constexpr size_t kPageSize         = 0x1000U;
    static constexpr size_t kMaxProfileSize   = 65536U;
    static constexpr UInt32 kHeaderSize       = 64U;
    static constexpr UInt32 kPageRecordSize   = 24U;
    static constexpr UInt32 kSiteRecordSize   = 40U;
    static constexpr UInt32 kMaxPages         = 256U;
    static constexpr UInt32 kMaxSites         = 1024U;
    static constexpr UInt32 kMaxSitesPerPage  = 64U;
    static constexpr UInt32 kMaxBuildLength   = 15U;
    static constexpr UInt32 kMaxSitePatchSize = 16U;
    static constexpr UInt32 kApuMaskKnown     = 0x3FU;

    // Header flags (specification section 3.3).
    static constexpr UInt32 kHeaderFlagRequireDeviceID = 1U << 0;
    static constexpr UInt32 kHeaderFlagsKnown          = kHeaderFlagRequireDeviceID;

    // Page `matchFlags` (specification section 4.2).
    static constexpr UInt16 kMatchRequireOffset = 1U << 0;
    static constexpr UInt16 kMatchRequireHash   = 1U << 1;
    static constexpr UInt16 kMatchRequireSites  = 1U << 2;
    static constexpr UInt16 kMatchKnownFlags    = kMatchRequireOffset | kMatchRequireHash | kMatchRequireSites;
    static constexpr UInt16 kMatchRequiredFlags = kMatchRequireHash | kMatchRequireSites;

    // Feature state.  `kNoOp` is the fail-closed state: the plugin stays loaded, nothing is written.
    enum class State : UInt8 {
        kIdle   = 0,
        kLoaded = 1,
        kNoOp   = 2,
    };

    // Why the profile is not active.  Every one of these is a fail-closed no-op.
    enum class Reason : UInt8 {
        kNone = 0,
        kProfileAbsent,
        kProfileInvalid,
        kBuildUnavailable,
        kBuildMismatch,
        kApuUnavailable,
        kApuMismatch,
        kDeviceMismatch,
    };

    static PatchProfile& singleton();

    // Validates and copies the complete NRPT profile.  Returns true only when every structural rule
    // of the specification (header, sizes, counts, checksums, page/site tables, canonical layout)
    // passed; the input `OSData` bytes are not referenced after this call returns.  The profile is
    // not active until both identity gates below also pass.
    bool loadFromData(const void* data, size_t size);

    // Reports the authoritative running build (`kern.osversion` as read by the plugin) together with
    // the optional `NRedSystemBuild` injection sanity hint.  `injectedBuild` never overrides
    // `actualBuild`: the profile must equal the actual running build.
    bool setRunningBuild(const char* actualBuild, const char* injectedBuild);

    // Reports the detected running APU family mask and the iGPU PCI device ID.  A zero mask means
    // "detection failed/unknown" and is a fail-closed condition, never a wildcard.
    bool setRunningApu(UInt32 runningMask, UInt16 runningDeviceID);

    // Acquire gate used by the hooks: true only after the profile parsed and all identity gates
    // passed.  Once true the tables are immutable for the rest of the boot.
    bool loaded() const;

    // Patches every complete 4 KiB chunk in [data, data + size) whose chunk base is `chunkBase`.
    // Called from the code-signing hooks only.
    void applyChunk(const UInt8* data, size_t size, UInt64 chunkBase);

    // Records that no profile property was injected.  Fail-closed `NoOp` (there is no fallback).
    void noteAbsentProfile();

    State       state() const;
    Reason      reason() const;
    const char* stateName() const;
    const char* reasonName() const;
    static const char* stateName(State state);
    static const char* reasonName(Reason reason);
    const char* errorCode() const;
    const char* errorContext() const;
    const char* build() const;
    UInt32      apuMask() const;
    UInt32      deviceID() const;
    UInt32      pageCount() const;
    UInt32      siteCount() const;
    bool        parsed() const;

    // Runtime counters (monotonic, atomics; safe to read from any context).
    UInt32 appliedPages() const;
    UInt32 findMismatches() const;
    UInt32 matchedPages() const;
    UInt32 chunkCalls() const;
    UInt32 writeFailures() const;

    // Candidate APU family mask for a PCI device ID (specification section 3.2).
    static UInt32 apuMaskForDeviceID(UInt16 deviceID);
    // Valid `kern.osversion` shape (specification section 3.1 alphabet, 1...15 bytes).
    static bool isValidBuildString(const char* build);

private:
    // One validated page record: the wire fields that matter at runtime.  `firstSite`/`siteCount`
    // index the static site array.
    struct Page
    {
        UInt64 pageFileOffset;
        UInt64 pageHash;
        UInt32 firstSite;
        UInt16 siteCount;
        UInt16 matchFlags;
    };

    // One validated site record.  `find`/`replace` are copied out of the profile, so the source
    // `OSData` may go away after loadFromData().
    struct Site
    {
        UInt16 siteInPage;
        UInt8  size;
        UInt8  find[kMaxSitePatchSize];
        UInt8  replace[kMaxSitePatchSize];
    };

    PatchProfile()  = default;
    ~PatchProfile() = default;
    PatchProfile(const PatchProfile&) = delete;
    PatchProfile& operator=(const PatchProfile&) = delete;
    PatchProfile(PatchProfile&&) = delete;
    PatchProfile& operator=(PatchProfile&&) = delete;

    bool loadHeader(const UInt8* data, size_t size, UInt32& pageCount, UInt32& siteCount, UInt32& headerFlags);
    bool loadPageTable(const UInt8* table, UInt32 pageCount, UInt32 siteCount);
    bool loadSiteTable(const UInt8* table, UInt32 siteCount, UInt32 pageCount);
    void evaluateIdentity();
    bool fail(Reason reason, const char* code, const char* context);
    void identityFailure(Reason reason, const char* context);
    bool takeLogBudget();
    void applyPage(const UInt8* page, UInt64 chunkBase);
    static bool parseBuildField(const UInt8* field, char* out, size_t outSize);

    State  state_{State::kIdle};
    Reason reason_{Reason::kNone};

    // Last structural rejection (stable E0xx code and a short static context string).
    const char* errorCode_{nullptr};
    const char* errorContext_{nullptr};

    // Header identity, copied from the profile.
    char   build_[kMaxBuildLength + 1]{};
    UInt32 apuMask_{0};
    UInt32 deviceID_{0};
    UInt32 headerFlags_{0};
    UInt16 pageCount_{0};
    UInt16 siteCount_{0};
    bool   profileParsed_{false};
    bool   loadAttempted_{false};

    // Running-system identity.
    char   actualBuild_[kMaxBuildLength + 1]{};
    UInt32 runningApuMask_{0};
    UInt16 runningDeviceID_{0};
    bool   buildKnown_{false};
    bool   apuKnown_{false};
    bool   identityEvaluated_{false};

    // Published with release semantics once the parsed tables and both identity gates are final;
    // the validation hooks use an acquire load.  The tables below are never modified afterwards.
    volatile UInt8 loadedFlag_{0};

    Page pages_[kMaxPages]{};
    Site sites_[kMaxSites]{};

    // One applied bit per page record: a record is applied at most once per boot.
    static constexpr UInt32 kAppliedWordCount = (kMaxPages + 63U) / 64U;
    volatile UInt64 appliedBits_[kAppliedWordCount]{};

    volatile UInt32 appliedPageCount_{0};
    volatile UInt32 findMismatchCount_{0};
    volatile UInt32 matchedPageCount_{0};
    volatile UInt32 chunkCallCount_{0};
    volatile UInt32 writeFailureCount_{0};

    // Shared budget for debug logging from the hook path.  Bounded, never refilled.
    static constexpr UInt32 kHookLogBudget = 32U;
    volatile UInt32 hookLogBudget_{kHookLogBudget};
};
