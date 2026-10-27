# Production adaptation info

`tools/adaptation_info.py` is the current production-facing compatibility report. It replaces the
archived `collect_target_data.py`: it does not collect Apple binaries and does not patch anything.

Run it on the target machine from the repository root:

```sh
python3 tools/adaptation_info.py
python3 tools/adaptation_info.py --json
python3 tools/adaptation_info.py --json --out /tmp/nred-adaptation.json
```

It reports:

- macOS product/build, Darwin, model;
- AMD iGPU device ID, APU family, expected satellite `apuMask`, VCN2 media capability;
- loaded `NootedRed` / `NootedRedUserPatch` kexts;
- available embedded `PatchData` builds, exact-build presence, table kinds (GL/Metal/VDA/AppleGVA),
  page/site counts and APU-mask match;
- main kext `NRedVCN*` properties and `NRedVCNBridgeReady`;
- satellite state/build/data source/APU/pages/sites/VDA readiness;
- current boot arguments and what each supported argument means.

No root, no kext install, no reboot, no GPU draw calls.

Current supported boot arguments are listed in the script and below:

| Argument | Effect |
| --- | --- |
| `-NRedVDA` | main kext: enable the VCN/VDA kernel bridge; required for satellite VDA pages |
| `-NRedUserPatchOff` | satellite: disable all user-space page patching |
| `-NRedUserPatchDebug` | satellite: verbose Lilu logging |
| `-NRedUserPatchBeta` | satellite: allow non-release kernels |
| `-NRedOff` | main kext: disable NootedRed |
| `-NRedDebug` | main kext: verbose logging |
| `-NRedBeta` | main kext: allow non-release kernels |
| `-NRedNoAccel` | main kext: FB-only debug mode |

For collecting raw driver/platform data to add a new build, use
[`collect_platform_data.py`](README-collect-platform-data.md); the resulting patch data is derived
with the pinned-master/PatchData pipeline and embedded with `tools/embed_patchdata.py`.
