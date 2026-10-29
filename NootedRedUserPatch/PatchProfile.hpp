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
// Concurrency: loadFromData()/setProvisionalBuild()/confirmRunningBuild()/setRunningApu() are called
// from sleepable plugin contexts (IOService start, the Lilu patcher-load callback and a bounded
// identity-discovery retry thread) and are serialised by the plugin.
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
    static constexpr UInt32 kPageRecordSize   = 24U;    // NRPT v1 page record
    static constexpr UInt32 kPageRecordSizeV2 = 32U;    // NRPT v2 page record
    static constexpr UInt16 kVersionV1        = 1U;
    static constexpr UInt16 kVersionV2        = 2U;

    // NRPT v2 target-image metadata limits (vnode-name gate / offline tooling; see docs/PatchProfile-Spec.md).
    static constexpr UInt32 kMaxImages             = 16U;
    static constexpr UInt32 kMaxImagePathLength    = 200U;
    static constexpr UInt32 kImageEntryHeaderSize  = 20U;
    static constexpr UInt32 kMaxSegmentsPerImage   = 16U;
    static constexpr UInt32 kMaxSectionsPerImage   = 16U;
    static constexpr UInt32 kSegmentNameSize       = 16U;
    static constexpr UInt32 kSectionNameSize       = 16U;
    static constexpr UInt32 kMaxImageTableSize     = kMaxImages
                                                   * (kImageEntryHeaderSize + 204U
                                                      + kMaxSegmentsPerImage * kSegmentNameSize
                                                      + kMaxSectionsPerImage * kSectionNameSize);
    static constexpr UInt32 kMaxImageVmSize        = 0xFFFFF000U;
    static constexpr UInt8  kImageKindStandalone   = 0U;
    static constexpr UInt8  kImageKindSharedCache  = 1U;
    static constexpr UInt8  kImageFlagSuffixMatch  = 1U << 0;

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

    // Provisional identity for the window before the kernel publishes `kern.osversion`: the injected
    // `NRedSystemBuild` hint may unblock matching only when it is a valid build string AND exactly
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
    // Called from the code-signing hooks only.  `vnode` is the real vnode argument of the hook and is
    // used for the vnode-name gate (NRPT v2 profiles only) before any content comparison.
    void applyChunk(const UInt8* data, size_t size, UInt64 chunkBase, void* vnode);

    // Resolver for the hook's vnode argument (solved by the backend from the kernel).  Without it the
    // engine stays on the legacy pager-offset gate and never applies NRPT v2 pages that arrive at a
    // different offset (fail closed, no writes).
    using tVnodeGetName = const char* (*)(void* vnode);
    using tVnodePutName = void (*)(const char* name);
    void setVnodeResolver(tVnodeGetName getName, tVnodePutName putName);
    bool vnodeGateActive() const;

    // Hook-only matching diagnostics (no acceptance effect):
    //   vnodeRejectedPages  - pages whose content arrived under a vnode the name gate rejects;
    //   alreadyPatchedPages - pages recognised as already carrying all replace bytes (no write done);
    //   hashOnlyAppliedPages- pages applied on a content match even though the pager offset differed
    //                         (this is the case the legacy offset gate used to reject).
    UInt32 vnodeRejectedPages() const;
    UInt32 vnodeRejectedEvents() const;
    UInt32 alreadyPatchedPages() const;
    UInt32 hashOnlyAppliedPages() const;
    bool   vnodeRejected(UInt32 pageIndex) const;
    bool   alreadyPatched(UInt32 pageIndex) const;
    bool   hashOnlyApplied(UInt32 pageIndex) const;
    UInt64 vnodeRejectedMaskWord(UInt32 wordIndex) const;
    UInt64 alreadyPatchedMaskWord(UInt32 wordIndex) const;
    UInt64 hashOnlyAppliedMaskWord(UInt32 wordIndex) const;

    // Records that no profile property was injected.  Fail-closed `NoOp` (there is no fallback).
    void noteAbsentProfile();

    // NRPT version actually parsed (1 = legacy offset-gated profile, 2 = hook-only vnode-gated profile).
    UInt16 profileVersion() const;
    UInt32 imageCount() const;
    bool   directTargetsAvailable() const;

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

    // Per-page runtime diagnostics gathered in the hooks (acceptance is unaffected).  They answer
    // "why was record N never applied?" without another debug build:
    //   hashObserved  - the full-page hash matched record N at some delivered chunk (any offset);
    //   offsetMismatch- the hash matched but the record's REQUIRE_OFFSET gate rejected that chunk;
    //   offsetSeen    - a chunk with exactly the record's required pageFileOffset was delivered;
    //   firstObservedOffset - the first pager offset at which the record's content was observed.
    // Never presented: !hashObserved && !offsetSeen (for an offset-gated record).
    // Content mismatch: !hashObserved && offsetSeen.
    // Offset namespace mismatch: hashObserved && offsetMismatch.
    bool   hashObserved(UInt32 pageIndex) const;
    bool   offsetMismatch(UInt32 pageIndex) const;
    bool   offsetSeen(UInt32 pageIndex) const;
    bool   firstObservedOffset(UInt32 pageIndex, UInt64& offset) const;
    UInt64 observedHashMaskWord(UInt32 wordIndex) const;
    UInt64 offsetMismatchMaskWord(UInt32 wordIndex) const;
    UInt64 offsetSeenMaskWord(UInt32 wordIndex) const;
    UInt32 offsetMismatchEvents() const;
    UInt32 pendingObservations() const;
    bool   pageRequiresOffset(UInt32 pageIndex) const;

    // Hard bound on the diagnostics content-observation window: after this many delivered chunks the
    // engine stops hashing arbitrary chunks for diagnostics (acceptance hashing is unaffected).  This
    // bounds the cost when a profile record never appears at all.
    static constexpr UInt32 kDiagnosticsChunkBudget = 65536U;

    // Expected-offset content evidence (diagnostics only, no acceptance effect).  When a chunk arrives
    // at exactly a record's required pageFileOffset, the engine records the actual delivered
    // FNV-1a-64 and how many of that record's generated site find bytes matched, even when the
    // full-page hash differs.  This separates "the target page changed slightly" (site finds may still
    // match) from "an unrelated page at a colliding pager offset" (no finds match), and the actual
    // hashes can be searched offline for the source image.
    static constexpr UInt32 kExpectedOffsetHashSlots = 4U;
    UInt32 expectedOffsetHashCount(UInt32 pageIndex) const;
    bool   expectedOffsetHashEntry(UInt32 pageIndex, UInt32 slot, UInt64& hash, UInt32& sitesFound,
                                   UInt32& sitesTotal) const;
    bool   expectedOffsetSeen(UInt32 pageIndex) const;
    UInt64 expectedOffsetSeenMaskWord(UInt32 wordIndex) const;

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
        // NRPT v2 target-image metadata (zero for v1 profiles).
        UInt16 imageIndex;
        UInt32 pageVmOffset;
    };

    // One validated NRPT v2 target image (the segment/section name tables are validated and then
    // discarded: the runtime only needs the path, kind and geometry).
    struct Image
    {
        UInt8  kind;
        UInt8  flags;
        UInt8  segmentCount;
        UInt8  sectionCount;
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

    bool loadHeader(const UInt8* data, size_t size, UInt32& pageCount, UInt32& siteCount, UInt32& headerFlags,
                    UInt16& version, UInt16& imageCount, UInt32& imageTableSize, UInt32& pageRecordSize);
    bool loadImageTable(const UInt8* table, UInt32 imageCount, UInt32 imageTableSize);
    bool loadPageTable(const UInt8* table, UInt32 pageCount, UInt32 siteCount, UInt16 version);
    bool loadPageTableV1(const UInt8* table, UInt32 pageCount, UInt32 siteCount);
    bool loadPageTableV2(const UInt8* table, UInt32 pageCount, UInt32 siteCount);
    bool loadSiteTable(const UInt8* table, UInt32 siteCount, UInt32 pageCount);
    void evaluateIdentity();
    bool fail(Reason reason, const char* code, const char* context);
    void revokeBuild(Reason reason, const char* context);
    bool takeLogBudget();
    void applyPage(const UInt8* page, UInt64 chunkBase, void* vnode);
    bool vnodeGateAccepts(UInt32 pageIndex, const char* vnodeName) const;
    bool markAlreadyPatched(UInt32 pageIndex, const UInt8* page);
    void recordVnodeRejected(UInt32 pageIndex);
    void recordHashObservation(UInt32 pageIndex, UInt64 chunkBase);
    void recordExpectedOffsetEvidence(UInt32 pageIndex, UInt64 pageHash, const UInt8* page);
    void recordOffsetSeen(UInt32 pageIndex);
    void recordOffsetMismatch(UInt32 pageIndex);
    bool diagnosticsActive() const;
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
    UInt32 headerFlags_{0};
    UInt16 pageCount_{0};
    UInt16 siteCount_{0};
    UInt16 profileVersion_{0};
    UInt16 imageCount_{0};
    Image  images_[kMaxImages]{};
    bool   profileParsed_{false};

    // Hook-side vnode resolver (solved by the backend; may stay null, which keeps the legacy offset gate).
    tVnodeGetName vnodeGetName_{nullptr};
    tVnodePutName vnodePutName_{nullptr};

    // Hook-only matching diagnostics.
    volatile UInt64 vnodeRejectedBits_[kAppliedMaskWords]{};
    volatile UInt64 alreadyPatchedBits_[kAppliedMaskWords]{};
    volatile UInt64 hashOnlyAppliedBits_[kAppliedMaskWords]{};
    volatile UInt32 vnodeRejectedCount_{0};
    volatile UInt32 vnodeRejectedEventCount_{0};
    volatile UInt32 alreadyPatchedCount_{0};
    volatile UInt32 hashOnlyAppliedCount_{0};
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
    volatile UInt64 observedHashBits_[kAppliedMaskWords]{};
    volatile UInt64 offsetMismatchBits_[kAppliedMaskWords]{};
    volatile UInt64 offsetSeenBits_[kAppliedMaskWords]{};
    volatile UInt64 firstObservedOffsets_[kMaxPages]{};
    volatile UInt32 pendingObservationCount_{0};
    volatile UInt32 offsetMismatchEventCount_{0};
    volatile UInt64 expectedOffsetSeenBits_[kAppliedMaskWords]{};
    volatile UInt64 expectedOffsetHashes_[kMaxPages][kExpectedOffsetHashSlots]{};
    volatile UInt8  expectedOffsetSitesFound_[kMaxPages][kExpectedOffsetHashSlots]{};
    volatile UInt16 expectedOffsetSitesTotal_[kMaxPages][kExpectedOffsetHashSlots]{};
    volatile UInt32 expectedOffsetHashCounts_[kMaxPages]{};

    volatile UInt32 appliedPageCount_{0};
    volatile UInt32 findMismatchCount_{0};
    volatile UInt32 matchedPageCount_{0};
    volatile UInt32 chunkCallCount_{0};
    volatile UInt32 writeFailureCount_{0};

    // Shared budget for debug logging from the hook path.  Bounded, never refilled.
    static constexpr UInt32 kHookLogBudget = 32U;
    volatile UInt32 hookLogBudget_{kHookLogBudget};
};
