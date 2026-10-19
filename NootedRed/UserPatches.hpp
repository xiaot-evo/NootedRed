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
// Both backends are gated behind the `-NRedGLFix` boot argument (and `-NRedGLFixOff` to force them off
// even if the default is ever flipped) and log under the `UserPatch` tag.
class UserPatches
{
public:
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

    // User-space OpenGL driver this module exists to patch.
    static constexpr const char* kGLDriverPath =
        "/System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver";

    // Code signing page size used by both backends.
    static constexpr size_t kPageSize = 0x1000;

    static UserPatches& singleton();

    // Parses the boot arguments and registers the patcher load callback.  Must be called from
    // `NRed::init` so that the request is queued before Lilu starts processing them.
    void init();

    // Replaces the built-in GL driver patch table.  `patchTable` has to point to static storage, as it
    // is captured by pointer and used once the patcher becomes available.  May be called before or
    // after `init`, as long as both happen from `NRed::init`.
    void registerGLDriverFix(const PagePatch* patchTable, size_t count);

    // Adds the -NRedVDA user-space patch table (VA driver / AppleGVA).  Same storage/lifetime rules as
    // `registerGLDriverFix`.  Applied in addition to the GL patches.
    void registerVDAFix(const PagePatch* patchTable, size_t count);

    // Installs the native page patch backend.  Called from `NRed::processPatcher` once the device ID and
    // profile are known (it must run before user processes validate pages).
    void processPatcher(KernelPatcher& patcher);

private:
    // Longest supported replacement, in bytes.
    static constexpr size_t kMaxPatchSize = 32;

    // Amount of distinct pages and per-page sites the native backend supports.  The VDA tables patch pages
    // of two shared-cache images, so the limits are larger than the original GL-only backend.
    static constexpr size_t kMaxNativePages  = 12;
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
        NativeSite   sites[kMaxSitesPerPage]{};
        size_t       siteCount{0};
        bool         vda{false};
    };

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

    NativePage nativePages[kMaxNativePages]{};
    size_t     nativePageCount{0};
    UInt32     vdaAppliedCount{0};

    UserPatcher::BinaryModPatch liluPatches[kMaxLiluPatches]{};
    UserPatcher::BinaryModInfo  liluModInfo{};
    size_t                      liluPatchCount{0};

    mach_vm_address_t orgCsValidatePage{0};
    mach_vm_address_t orgCsValidateRange{0};

    auto installUserPatcher() -> bool;
    auto installNativePagePatcher(KernelPatcher& patcher) -> bool;
    auto buildNativePatches() -> bool;
    void patchNativePage(const void* data);

    static void      wrapCsValidatePage(void* vnode, void* pager, UInt64 pageOffset, const void* data, int* validated,
                                        int* tainted, int* nx);
    static boolean_t wrapCsValidateRange(void* vnode, void* pager, UInt64 pageOffset, const void* data, UInt64 dataSize,
                                         unsigned* tainted);
};
