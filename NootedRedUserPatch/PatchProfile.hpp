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

// Generic consumer for the NRPT v3 profile format (docs/PatchProfile-Spec.md).
//
// The class owns only generic engine state: the parsed and fully validated page/site records copied
// out of the selected `NRedProfiles` bundle profile, the running-system identity gates and the
// per-chunk matcher used by the code-signing hooks.  It contains no patch data of its own: every page
// offset, page hash, site offset and find/replace byte comes from the profile.
//
// The profile is authoritative and fail-closed: a profile that violates any structural rule in the
// specification is rejected as a whole, and a page is only written after the running build, the
// running APU family (and optionally the iGPU PCI device ID) passed and the full-page hash and every
// site find of the matched record passed.
//
// Concurrency: loadFromData()/setProvisionalBuild()/confirmRunningBuild()/setRunningApu() are called
// from sleepable plugin contexts (IOService start, the Lilu patcher-load callback and a bounded
// identity-discovery retry thread) and are serialised by the plugin.
// Once loaded() returns true the parsed tables are immutable for the rest of the boot.  applyChunk()
// runs inside the _cs_validate_page/_cs_validate_range hooks and only reads the immutable tables plus
// atomics: no allocation, no VFS, no IOKit, no sleeping and no unbounded logging.
class PatchProfile
{
public:
    // NRPT layout constants.  The parser currently accepts the interim v2 page/image tables; the final
    // v3 byte layout lands with the frozen v3 specification (task-24) and only the loader changes.
    static constexpr size_t kPageSize         = 0x1000U;
    static constexpr size_t kMaxProfileSize   = 65536U;
    static constexpr UInt32 kHeaderSize       = 64U;
    static constexpr UInt32 kPageRecordSize   = 32U;    // NRPT v3 page record
    static constexpr UInt16 kVersionV3        = 3U;

    // Target-image metadata limits (NRPT v3 image table: kind/path/unslid/vmSize only).
    static constexpr UInt32 kMaxImages            = 16U;
    static constexpr UInt32 kMaxImagePathLength   = 200U;
    static constexpr UInt32 kImageEntryHeaderSize = 16U;
    static constexpr UInt32 kMaxImageTableSize    = kMaxImages * (kImageEntryHeaderSize + 204U);
    static constexpr UInt32 kMaxImageVmSize       = 0xFFFFF000U;
    static constexpr UInt8  kImageKindStandalone  = 0U;
    static constexpr UInt8  kImageKindSharedCache = 1U;


    static constexpr UInt32 kSiteRecordSize   = 40U;
    static constexpr UInt32 kMaxPages         = 256U;
    static constexpr UInt32 kMaxSites         = 1024U;
    static constexpr UInt32 kMaxSitesPerPage  = 64U;
    static constexpr UInt32 kMaxBuildLength   = 15U;
    static constexpr UInt32 kMaxSitePatchSize = 16U;
    static constexpr UInt32 kApuMaskKnown     = 0x3FU;


    // Page mode (NRPT v3): the only route that may apply the page.  `PAGE` is served by
    // _cs_validate_page, `DYLD` by _cs_validate_range; `RESOLVER` is reserved and never accepted.
    enum class Mode : UInt8 {
        kPage     = 1,
        kDyld     = 2,
        kResolver = 3,
    };
    static const char* modeName(Mode mode);

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

    // Provisional identity for the window before the kernel publishes `kern.osversion`: the injected
    // provisional `NRedProfiles` candidate may unblock matching only when it is a valid build string AND exactly
    // equals the parsed profile build.  An invalid or mismatched hint is never stored or accepted.
    // Returns true when the engine accepted the provisional state (or a confirmed build is known).
    bool setProvisionalBuild(const char* injectedBuild);

    // Authoritative confirmation once the actual running build (`kern.osversion`) is readable.  Exact
    // equality with the profile build is required; a mismatch is a hard error that revokes the profile
    // (further writes stop; pages already written cannot be rolled back and are reported).  The
    // optional injected hint must also agree with the actual build.
    bool confirmRunningBuild(const char* actualBuild, const char* injectedBuild);

    // Discovery budget exhausted before the actual running build became readable: fail closed and stop
    // further writes.  A provisionally accepted build is never promoted to the final state.
    void failUnconfirmedBuild();

    // Reports the detected running APU family mask and the iGPU PCI device ID.  A zero mask means
    // "detection failed/unknown" and is a fail-closed condition, never a wildcard.
    bool setRunningApu(UInt32 runningMask, UInt16 runningDeviceID);

    // Acquire gate used by the hooks: true only while the profile is active and not revoked.  The
    // tables are immutable once published; revocation (hard identity error) only clears this flag.
    bool loaded() const;

    // Patches every complete 4 KiB chunk in [data, data + size) whose chunk base is `chunkBase`.
    // Called from the code-signing hooks only.  `route` is the hook's mode domain: a PAGE record is
    // only considered by the page hook and a DYLD record only by the range hook.
    void applyChunk(const UInt8* data, size_t size, UInt64 chunkBase, Mode route);

    // Pages recognised as already carrying all replace bytes (marked applied, never written).
    UInt32 alreadyPatchedPages() const;
    bool   alreadyPatched(UInt32 pageIndex) const;
    UInt64 alreadyPatchedMaskWord(UInt32 wordIndex) const;

    // Records that no profile property was injected.  Fail-closed `NoOp` (there is no fallback).
    void noteAbsentProfile();

    // Records a bundle-level selection/validation failure (NRedProfiles layer).  Fail-closed NoOp.
    void failBundleSelection(Reason reason, const char* code, const char* context);

    // NRPT version actually parsed (v3 only in this consumer).
    UInt16 profileVersion() const;
    UInt32 imageCount() const;

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

    // True while the build gate was accepted from the injected hint and has not been confirmed by the
    // actual running build yet.
    bool provisionalBuild() const;

    // Publishes the applied-once bit and counts a page exactly like the hook path.  A page already
    // marked applied is left untouched.
    void noteAppliedPage(UInt32 pageIndex);

    // Per-page applied diagnostics (read by the plugin's IORegistry publication, never in hooks).
    bool   pageApplied(UInt32 pageIndex) const;
    static constexpr UInt32 kAppliedMaskWords = (kMaxPages + 63U) / 64U;
    UInt64 appliedMaskWord(UInt32 wordIndex) const;

    // Per-mode diagnostics: how many profile pages belong to each route (PAGE/DYLD).
    UInt32 pageModeCount(Mode mode) const;

    // Running hardware identity (set once by the backend's DeviceInfo detection).
    UInt32 runningApuMask() const;
    UInt32 runningDeviceID() const;
    bool   runningApuKnown() const;

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
        UInt64 pageFileOffset;    // diagnostic only; never part of page identity
        UInt64 pageHash;
        UInt32 firstSite;
        UInt16 siteCount;
        UInt8  mode;              // Mode: which route may apply this page
        UInt8  flags;             // reserved (v3)
        UInt16 imageIndex;
        UInt32 pageVmOffset;      // evidence only
    };

    // One validated NRPT v2 target image (the segment/section name tables are validated and then
    // discarded: the runtime only needs the path, kind and geometry).
    struct Image
    {
        UInt8  kind;
        UInt8  reserved;
        UInt64 unslidVmaddr;
        UInt32 vmSize;
        char   path[kMaxImagePathLength + 1];
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

    bool loadHeader(const UInt8* data, size_t size, UInt32& pageCount, UInt32& siteCount, UInt16& version,
                    UInt16& imageCount, UInt32& imageTableSize, UInt32& pageRecordSize);
    bool loadImageTable(const UInt8* table, UInt32 imageCount, UInt32 imageTableSize);
    bool loadPageTable(const UInt8* table, UInt32 pageCount, UInt32 siteCount);
    bool loadSiteTable(const UInt8* table, UInt32 siteCount, UInt32 pageCount);
    void evaluateIdentity();
    bool fail(Reason reason, const char* code, const char* context);
    void revokeBuild(Reason reason, const char* context);
    bool takeLogBudget();
    void applyPage(const UInt8* page, UInt64 chunkBase, Mode route);
    bool markAlreadyPatched(UInt32 pageIndex, const UInt8* page);
    static bool maskBitSet(const volatile UInt64* bits, UInt32 pageIndex);
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
    UInt16 pageCount_{0};
    UInt16 siteCount_{0};
    UInt16 profileVersion_{0};
    UInt16 imageCount_{0};
    Image  images_[kMaxImages]{};
    bool   profileParsed_{false};

    // Hook-only matching diagnostics.
    volatile UInt64 alreadyPatchedBits_[kAppliedMaskWords]{};
    volatile UInt32 alreadyPatchedCount_{0};

    bool   loadAttempted_{false};

    // Running-system identity.
    char   actualBuild_[kMaxBuildLength + 1]{};
    UInt32 runningApuMask_{0};
    UInt16 runningDeviceID_{0};
    bool   buildKnown_{false};
    bool   buildProvisional_{false};
    bool   apuKnown_{false};
    bool   identityEvaluated_{false};

    // Published with release semantics once the parsed tables and both identity gates are final;
    // the validation hooks use an acquire load.  Cleared again if the build is revoked by a hard
    // identity error, which makes further writes a no-op without touching the immutable tables.
    volatile UInt8 activeFlag_{0};

    Page pages_[kMaxPages]{};
    Site sites_[kMaxSites]{};

    // One applied bit per page record: a record is applied at most once per boot.
    volatile UInt64 appliedBits_[kAppliedMaskWords]{};

    // Bounded per-page runtime diagnostics.  Hashing every delivered chunk is only needed until every
    // record has been observed; kDiagnosticsChunkBudget also bounds the cost for records that never appear.

    volatile UInt32 appliedPageCount_{0};
    volatile UInt32 findMismatchCount_{0};
    volatile UInt32 matchedPageCount_{0};
    volatile UInt32 chunkCallCount_{0};
    volatile UInt32 writeFailureCount_{0};

    // Shared budget for debug logging from the hook path.  Bounded, never refilled.
    static constexpr UInt32 kHookLogBudget = 32U;
    volatile UInt32 hookLogBudget_{kHookLogBudget};
};
