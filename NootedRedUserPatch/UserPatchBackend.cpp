// NootedRedUserPatch code-signing validation backend
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

#include <UserPatchBackend.hpp>

#include <Headers/kern_devinfo.hpp>
#include <Headers/kern_mach.hpp>
#include <PatchProfile.hpp>

namespace
{

    using tCsValidatePage = void (*)(void*, void*, UInt64, const void*, int*, int*, int*);
    using tCsValidateRange = boolean_t (*)(void*, void*, UInt64, const void*, UInt64, unsigned*);

    // Releases the Lilu DeviceInfo list on every return path.  Lilu's deleter is a deliberate no-op
    // for the global cached instance it owns, so this only frees a list this call created.
    struct DeviceInfoGuard
    {
        DeviceInfo* info{nullptr};

        ~DeviceInfoGuard()
        {
            if (this->info != nullptr) { DeviceInfo::deleter(this->info); }
        }
    };

}    // namespace

UserPatchBackend& UserPatchBackend::singleton()
{
    static UserPatchBackend instance;
    return instance;
}

void UserPatchBackend::install(KernelPatcher& patcher)
{
    if (this->installAttempted_) { return; }
    this->installAttempted_ = true;

    // Page validation path.  Intel/AMD user-space driver pages are delivered through this route.
    KernelPatcher::RouteRequest pageRequest{"_cs_validate_page", wrapCsValidatePage, this->orgCsValidatePage_};
    if (patcher.routeMultipleLong(KernelPatcher::KernelID, &pageRequest, 1)) {
        this->pageHookInstalled_ = true;
        SYSLOG("UserPatch", "installed _cs_validate_page route");
    }
    else {
        patcher.clearError();
        SYSLOG("UserPatch", "_cs_validate_page route unavailable; page path not covered");
    }

    // Range validation path.  dyld shared cache and Apple-protected pagers validate through this route.
    KernelPatcher::RouteRequest rangeRequest{"_cs_validate_range", wrapCsValidateRange, this->orgCsValidateRange_};
    if (patcher.routeMultipleLong(KernelPatcher::KernelID, &rangeRequest, 1)) {
        this->rangeHookInstalled_ = true;
        SYSLOG("UserPatch", "installed _cs_validate_range route");
    }
    else {
        patcher.clearError();
        SYSLOG("UserPatch", "_cs_validate_range route unavailable; shared-cache range path not covered");
    }
}

void UserPatchBackend::detectHardwareIdentity()
{
    auto& profile = PatchProfile::singleton();

    // DeviceInfo is populated by Lilu before the patcher-load callbacks run, and it contains the iGPU
    // entry the main kext uses.  A missing or unknown iGPU is a fail-closed condition, never a
    // wildcard: the profile engine requires a running APU family.
    const DeviceInfoGuard guard{DeviceInfo::create()};
    auto* const deviceInfo = guard.info;
    if (deviceInfo == nullptr || deviceInfo->videoBuiltin == nullptr) {
        SYSLOG("UserPatch", "no AMD iGPU detected; APU identity unavailable");
        profile.setRunningApu(0, 0);
        return;
    }

    UInt32 deviceID = 0;
    if (!WIOKit::getOSDataValue(deviceInfo->videoBuiltin, "device-id", deviceID)) {
        SYSLOG("UserPatch", "iGPU device-id property unavailable; APU identity unavailable");
        profile.setRunningApu(0, 0);
        return;
    }

    const UInt32 mask = PatchProfile::apuMaskForDeviceID(static_cast<UInt16>(deviceID & 0xFFFFU));
    if (mask == 0) {
        SYSLOG("UserPatch", "unsupported iGPU device ID 0x%X; APU identity unavailable",
               static_cast<unsigned>(deviceID));
        profile.setRunningApu(0, 0);
        return;
    }

    SYSLOG("UserPatch", "detected iGPU device 0x%04X apuMask 0x%X", static_cast<unsigned>(deviceID & 0xFFFFU),
           static_cast<unsigned>(mask));
    profile.setRunningApu(mask, static_cast<UInt16>(deviceID & 0xFFFFU));
}

void UserPatchBackend::wrapCsValidatePage(void* vnode, void* pager, UInt64 pageOffset, const void* data,
                                          int* validated, int* tainted, int* nx)
{
    (void) vnode;    // final hook-only consumer: mode routing + content identity, no vnode gate
    auto& self = singleton();

    // The original validator is always called first and its result is never modified.  Callers on
    // macOS 15 consume the three out-parameters, not the return value.
    auto original = reinterpret_cast<tCsValidatePage>(self.orgCsValidatePage_);
    FunctionCast(wrapCsValidatePage, reinterpret_cast<mach_vm_address_t>(original))(vnode, pager, pageOffset, data,
                                                                                    validated, tainted, nx);

    if (validated != nullptr && *validated != 0 && data != nullptr) {
        PatchProfile::singleton().applyChunk(static_cast<const UInt8*>(data), PatchProfile::kPageSize, pageOffset,
                                             PatchProfile::Mode::kPage);
    }
}

boolean_t UserPatchBackend::wrapCsValidateRange(void* vnode, void* pager, UInt64 rangeOffset, const void* data,
                                                UInt64 dataSize, unsigned* tainted)
{
    auto& self = singleton();

    auto original = reinterpret_cast<tCsValidateRange>(self.orgCsValidateRange_);
    const boolean_t result = FunctionCast(wrapCsValidateRange, reinterpret_cast<mach_vm_address_t>(original))(
        vnode, pager, rangeOffset, data, dataSize, tainted);

    // Patch only after the original validator accepted the range; its return value is not affected by
    // a patch failure.  A trailing partial page is never patched.
    if (result != FALSE && data != nullptr && dataSize >= PatchProfile::kPageSize) {
        PatchProfile::singleton().applyChunk(static_cast<const UInt8*>(data), static_cast<size_t>(dataSize),
                                             rangeOffset, PatchProfile::Mode::kDyld);
    }

    return result;
}

bool UserPatchBackend::pageHookInstalled() const { return this->pageHookInstalled_; }

bool UserPatchBackend::rangeHookInstalled() const { return this->rangeHookInstalled_; }
