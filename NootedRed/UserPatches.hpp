// User-Space Driver Patches
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
#include <Headers/kern_patcher.hpp>
#include <PenguinWizardry/KernelVersion.hpp>
#include <Headers/kern_user.hpp>
#include <libkern/OSTypes.h>

// Patches Apple's user-space OpenGL drivers, which is where the Chromium/GL corruption originates.
//
// Lilu's user patcher only operates on macOS 10.9 through 10.15; upstream Lilu hard-disables it on
// Big Sur and newer, and even where it is enabled it only wraps `_cs_validate_range`, while a
// vnode-backed bundle such as `AMDRadeonX5000GLDriver` is validated through `_cs_validate_page` on
// macOS 11 and newer.  This module therefore has two backends, selected by kernel version:
//
//  - macOS 10.15 and older: `lilu.onProcLoad` with `UserPatcher::BinaryModInfo`/`BinaryModPatch`
//    entries.  No process filter is registered on purpose, so that the patcher never injects the
//    `__RESTRICT` segment into user processes; page patches are global in Lilu and do not need one.
//  - macOS 11 and newer: a self-contained `_cs_validate_page`/`_cs_validate_range` hook.  A complete
//    `kPageSize` page image has to match byte for byte before `find` is replaced with `replace`, so a
//    patch can never hit an unrelated binary.  See analysis/lilu-userpatch.md for the details.
//
// The GL table is gated by `-NRedGLFix`/`-NRedGLFixOff`; the optional VA/AppleGVA tables are a separate
// `-NRedVDA` opt-in and only apply on the validated 0x1638 profile after the kernel VCN bridge is ready.
// Both log under the `UserPatch` tag.
class UserPatches
{
public:
    // APU families this module can target.  A patch set may be limited to a subset; `kApuAll` is used by
    // the shared page-image patches, which are safe for every supported gfx9 APU (the exact page image
    // still gates them, so an unsupported APU is a no-op).
    enum ApuMask : UInt8 {
        kApuRaven        = 1U << 0,
        kApuRaven2       = 1U << 1,
        kApuPicasso      = 1U << 2,
        kApuRenoir       = 1U << 3,
        kApuRenoirE      = 1U << 4,
        kApuGreenSardine = 1U << 5,
        kApuAll          = 0x3F,
    };

    struct PagePatch;

    // A patch set valid for a macOS version range and an APU-family subset.  The first matching set is
    // selected once per boot; page images remain the last line of defence, so a set whose images do not
    // match the running driver simply does nothing.
    struct PatchSet
    {
        const char*                     name;
        PenguinWizardry::KernelVersion  minVersion;
        PenguinWizardry::KernelVersion  maxVersion;
        ApuMask                         apus;
        const PagePatch*                patches;
        size_t                          count;
    };

    // Lookup-style patch for one user-space Mach-O image.
    struct PagePatch
    {
        // Mach segment/section containing the patch; only used by the Lilu backend.
        UserPatcher::FileSegment segment;

        // Exact `kPageSize` byte image of the file page that contains `find`, or `nullptr` when the
        // patch is only meant for the Lilu backend.  Required by the native backend.
        const UInt8* page;

        // Byte sequence to look for and the bytes written in its place (`size` bytes each).
        const UInt8* find;
        const UInt8* replace;

        // Number of bytes in `find` and `replace`.
        size_t size;

        // Number of occurrences of `find` to skip before patching each occurrence.
        size_t skip;

        // Number of occurrences of `find` to patch.
        size_t count;
    };

    // Semantic patch kinds.  The runtime verifies the instruction form before writing anything, so a
    // masked context that happens to match unrelated instructions cannot corrupt a page.
    enum SemanticKind : UInt8 {
        kSemanticGLHwInfo = 0,
        kSemanticGLDualQuad,
        kSemanticMTLGate,
        kSemanticMTLAllow,
        kSemanticMTLDirect,
    };

    // Instruction-context patch used by the generic (symbol/semantics based) backend.  A masked context
    // window identifies a site by the surrounding instruction semantics; `find` is then verified verbatim
    // at `siteOffset` and replaced with same-length `replace` bytes.  `group` 0 means a standalone site,
    // non-zero sites share a group and only apply when every site in that group matches the same page.
    struct SemanticPatch
    {
        const char*   name;
        const UInt8*  context;
        const UInt8*  mask;
        size_t        contextSize;
        size_t        siteOffset;
        const UInt8*  find;
        size_t        findSize;
        const UInt8*  replace;
        size_t        replaceSize;
        UInt8         group;
        bool          cachePage;
        SemanticKind  kind;
    };

    // User-space OpenGL driver this module exists to patch.
    static constexpr const char* kGLDriverPath =
        "/System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver";

    // Code signing page size used by both backends.
    static constexpr size_t kPageSize = 0x1000;

    static UserPatches& singleton();

    // Parses the boot arguments and records the enabled tables.  Must be called from `NRed::init`;
    // `processPatcher` installs the selected backend once the device profile is known.
    void init();

    // Replaces the built-in GL driver patch table.  `patchTable` has to point to static storage, as it
    // is captured by pointer and used once the patcher becomes available.  May be called before or
    // after `init`, as long as both happen from `NRed::init`.
    void registerGLDriverFix(const PagePatch* patchTable, size_t count);

    // Replaces the built-in version/family-aware patch-set table.  `sets` has to point to static storage.
    // May be called before or after `init`, as long as both happen from `NRed::init`.
    void registerPatchSets(const PatchSet* sets, size_t count);

    // Adds the -NRedVDA user-space patch table (VA driver / AppleGVA).  Same storage/lifetime rules as
    // `registerGLDriverFix`.  Applied in addition to the selected GL patch set.
    void registerVDAFix(const PagePatch* patchTable, size_t count);

    // Installs the native page patch backend.  Called from `NRed::processPatcher` once the device ID and
    // profile are known (it must run before user processes validate pages).
    void processPatcher(KernelPatcher& patcher);

private:
    // Longest supported replacement, in bytes.
    static constexpr size_t kMaxPatchSize = 32;

    // Amount of distinct pages and per-page sites the native backend supports.  The combined selected GL
    // set (3 pages), VA (8) and AppleGVA (1) tables currently use 12 pages; keep headroom so a new table
    // cannot be silently dropped by the page cap.  The backend refuses the whole table on overflow.
    static constexpr size_t kMaxNativePages  = 16;
    static constexpr size_t kMaxSitesPerPage = 16;

    // Maximum combined (GL + VDA) patch entries in the native backend.
    static constexpr size_t kMaxNativePatches = 64;

    // Amount of patches handed over to Lilu's user patcher.
    static constexpr size_t kMaxLiluPatches = 8;

    struct NativeSite
    {
        size_t       offset{0};
        const UInt8* find{nullptr};
        const UInt8* replace{nullptr};
        size_t       size{0};
    };

    struct NativePage
    {
        const UInt8* image{nullptr};
        UInt64       head{0};
        NativeSite   sites[kMaxSitesPerPage]{};
        size_t       siteCount{0};
        bool         vda{false};
    };

    const PatchSet* patchSets{nullptr};
    size_t          patchSetCount{0};

    // Generic semantic backend.  GL entries are enabled together with the GL fix and only patch the
    // vnode-backed AMDRadeonX5000GLDriver; Metal variants scan shared-cache pages and are opt-in because
    // that backend validates much more data per boot.
    const SemanticPatch* semanticPatches{nullptr};
    size_t               semanticPatchCount{0};
    bool                 semanticEnabled{false};
    bool                 semanticMTLEnabled{false};

    const PagePatch* patches{nullptr};
    size_t           patchCount{0};

    struct PatchTable
    {
        const PagePatch* table{nullptr};
        size_t           count{0};
    };

    PatchTable vdaTables[2]{};
    size_t     vdaTableCount{0};

    PagePatch nativePatches[kMaxNativePatches]{};
    bool      nativePatchIsVDA[kMaxNativePatches]{};
    size_t    nativePatchCount{0};
    bool      enabled{false};
    bool      vdaEnabled{false};

    void selectPatchSet();
    auto currentApuMask() const -> ApuMask;

    NativePage nativePages[kMaxNativePages]{};
    size_t     nativePageCount{0};
    SInt32     vdaAppliedCount{0};

    UserPatcher::BinaryModPatch liluPatches[kMaxLiluPatches]{};
    UserPatcher::BinaryModInfo  liluModInfo{};
    size_t                      liluPatchCount{0};

    mach_vm_address_t orgCsValidatePage{0};
    mach_vm_address_t orgCsValidateRange{0};

    auto installUserPatcher() -> bool;
    auto installNativePagePatcher(KernelPatcher& patcher) -> bool;
    auto buildNativePatches() -> bool;
    void patchNativePage(const void* data, void* vnode, bool cachePage);

    // Generic semantic backend: matches instruction-context windows instead of full page images.  Returns
    // true when at least one site was patched.  `vnode` is the code-signing vnode for file-backed pages and
    // nullptr for shared-cache ranges; GL entries are only applied when the vnode is the X5000 GL driver.
    auto patchSemanticPage(const void* data, void* vnode, bool cachePage) -> bool;
    auto isGLDriverVnode(void* vnode) const -> bool;

    // Returns true when `data` is an already-patched version of an exact native page.  This is the normal
    // state for a page after the first process validated it: the kernel keeps the patched bytes, so a later
    // validation must not scan the page again.
    auto isPatchedPage(const NativePage& page, const UInt8* data) const -> bool;

    static void      wrapCsValidatePage(void* vnode, void* pager, UInt64 pageOffset, const void* data, int* validated,
                                        int* tainted, int* nx);
    static boolean_t wrapCsValidateRange(void* vnode, void* pager, UInt64 pageOffset, const void* data, UInt64 dataSize,
                                         unsigned* tainted);
};
