// NootedRedUserPatch plugin entry point
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

#include <Headers/kern_api.hpp>
#include <Headers/kern_util.hpp>
#include <Headers/plugin_start.hpp>

#include <AnalyzerRuntime.hpp>
#include <SiteSet.hpp>
#include <ValidationHook.hpp>

static const char* bootargOff   = "-NRedUserPatchOff";
static const char* bootargDebug = "-NRedUserPatchDebug";
static const char* bootargBeta  = "-NRedUserPatchBeta";
static const char* bootargDry   = "-NRedUserPatchDry";

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
    []() {
        SYSLOG("init", "NootedRedUserPatch %s starting (runtime analyzer)", xStringify(MODULE_VERSION));

        lilu.onPatcherLoadForce(
            [](void* const, KernelPatcher& patcher)
            {
                NRedUserPatch::SiteSet::singleton().setDryRun(checkKernelArgument(bootargDry));
                NRedUserPatch::ValidationHook::singleton().install(patcher);
                NRedUserPatch::AnalyzerRuntime::singleton().start(patcher);
            },
            nullptr);
    },
};
