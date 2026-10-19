# VDA Hardware Decode — Deployment and Validation Runbook

Status: the kernel bridge and the 15.8.1 user-space patch pipeline are implemented in
`feature/vda-hardware-decode`. Everything is opt-in and default-off; a normal boot without `-NRedVDA` is
unchanged. This runbook is for the first hardware bring-up on a Renoir `0x1638` test machine
(macOS 15.8.1 / Darwin 24.6).

> **Safety first:** keep a bootable EFI backup and know how to remove `-NRedVDA` from the OpenCore
> config/NVRAM before booting with the new kext. If the accelerator hangs during boot, boot with the
> backup EFI (or `-NRedOff`) and restore the previous kext.

## 1. Build

Use the CommandLineTools toolchain while the default Xcode select is broken on this machine:

```sh
cd /Volumes/WorkSpace/Projects/Hackintosh/NootedRed
DEVELOPER_DIR=/Library/Developer/CommandLineTools xmake f -m release -y
DEVELOPER_DIR=/Library/Developer/CommandLineTools xmake -y
```

Artifact: `build/branches/<branch>/macosx/x86_64/release/NootedRed.kext`
(zip: `.../NootedRed-0.9.0-RELEASE.zip`). The supported build wrapper is `tools/build-branch.sh`;
see [Build-Artifacts.md](Build-Artifacts.md). `tools/deploy_vda.sh` locates the current branch artifact
automatically (it also accepts the old `build/macosx/...` layout).

Before deploying, run the read-only preflight; it verifies the OS/Darwin, iGPU, dGPU/X6000 state, kernel
collection, generated data and build artifact:

```sh
tools/vda_preflight.sh
```

## 2. Back up the working EFI kext

```sh
# adapt the ESP mount point if needed
sudo mount -t msdos /dev/diskXsY /Volumes/EFI
sudo ditto /Volumes/EFI/EFI/OC/Kexts/NootedRed.kext \
            "build/efi-backup/NootedRed-preVDA.kext"
shasum -a 256 /Volumes/EFI/EFI/OC/Kexts/NootedRed.kext/Contents/MacOS/NootedRed
```

## 3. Install the new kext

```sh
sudo rm -rf /Volumes/EFI/EFI/OC/Kexts/NootedRed.kext
sudo ditto build/macosx/x86_64/release/NootedRed.kext \
            /Volumes/EFI/EFI/OC/Kexts/NootedRed.kext
shasum -a 256 /Volumes/EFI/EFI/OC/Kexts/NootedRed.kext/Contents/MacOS/NootedRed
```

## 4. Enable the opt-in boot argument

Add `-NRedVDA` to the OpenCore `NVRAM/Add/7C436110-AB2A-4BBB-A880-FE41995C9F82/boot-args` value (keep the
existing arguments, e.g. `-NRedGLFix` if used). Do **not** add `-NRedNoAccel` at the same time.

The helper script backs up and lint-checks the config before/after the change:

```sh
tools/set_vda_bootarg.sh --show     # current state
tools/set_vda_bootarg.sh --add      # add -NRedVDA (backup in build/efi-backup/)
tools/set_vda_bootarg.sh --remove   # rollback the boot argument
```

For the first experiment, leave `-NRedVDA` out and boot once to confirm the graphics path is unchanged and
there are no VCN logs beyond the disabled message. Then add `-NRedVDA` and boot again.

## 5. Post-boot validation (read-only)

Run [`tools/vda_selftest.sh`](../tools/vda_selftest.sh) after boot (basic diagnostics), then
[`tools/vda_hwtest.sh`](../tools/vda_hwtest.sh) for the automated decode comparison. They collect:

- `uname -r`, `sw_vers`, boot args;
- `ioreg -l -w0 -r -n IGPU | grep -E 'NRed(VDA|VCN)'` (requested / native load / ABI validated / engine
  allocated / last hardware init / user patch diagnostics);
- `log show --last boot --info --debug --predicate 'eventMessage CONTAINS "VCN" OR eventMessage CONTAINS "VDA" OR eventMessage CONTAINS "UserPatch"'`;
- `ffmpeg -hwaccels` (if ffmpeg is installed);
- recent `.gpuRestart`/WindowServer watchdog reports.

Expected progression on a successful boot with `-NRedVDA`:

```text
VCN: X5000 VCN entry points prepared
VCN: X6000 native load status=0x0 prepared5=1 prepared6=1
VCN: X6000 VCN bridge prepared (N call-site patches)
VCN: X6000 initHardware channel=... result=1        # when a decoder is created
X5000: VCN0 media engine enabled from the device profile
```

`NRedVCNX5000Seen=1`, `NRedVCNX6000Seen=1`, `NRedVCNAccelStartSeen=1` show that the kext-load/start hooks
ran at all; `NRedVCNX5000ABIValidated=1`, `NRedVCNX6000ABIValidated=1`, `NRedVCNNativeLoadReady=1`,
`NRedVCNEngineAllocated=1` in ioreg are the kernel-side success markers. `NRedVCNUserApplied` counts VDA user-space page write events (VA/AppleGVA); it only increases once the
bridge is ready. It is a diagnostic, not a count of distinct live pages, and pages already patched in the
shared-cache page cache stay patched until reboot.

## 6. Decode test

`tools/vda_hwtest.sh` generates small H.264 (720p and the known-adverse 64x64) and HEVC clips, decodes them
with both VideoToolbox and software, compares the raw output and checks the VDA logs/reset reports. The
manual equivalent is:

```sh
ffmpeg -hwaccel videotoolbox -i sample_h264.mp4 -f null -
ffmpeg -hwaccel videotoolbox -i sample_hevc.mp4 -f null -
ffmpeg -i sample_h264.mp4 -f null -            # software reference
```

Also test a real application path (Safari/Apple TV/Chromium video) and a 64×64 H.264 stream (a known
adverse case from the community fork). Watch for:

- decoder creation but no frames (VCN0Dec stall);
- WindowServer watchdog / desktop freeze;
- `Kernel_*.gpuRestart` reports;
- system network/audio panics (reported by the fork for Apple TV DRM).

## 7. Validated results (2026-10-19)

The target passed the real-hardware runs on 2026-10-19 (latest loaded kext SHA-256
`3495df006ca54f4d9cfd4899e23126efeb1009c9a0ea51660b4bf3c27a9121ba`):

- `NRedVCNStage=11`, both ABI guards `=1`, X6000 native load ready, engine allocated, VCN
  `initHardware=1`; VA/AppleGVA patches applied and `h264_videotoolbox`/`hevc_videotoolbox` encode works;
- H.264 720p, 64x64 H.264 and HEVC 720p VideoToolbox decodes matched the software output;
- 5 repeated 1080p H.264 + 5 repeated 1080p HEVC decodes matched and produced no `.gpuRestart`;
- ffmpeg exposes `videotoolbox_vld` for H.264; AppleGVA logs for HEVC show
  `useHighPerformanceDecode = 1` and disposed physical/virtual accelerators.

Remaining acceptance: default-off boot of this build, Chromium/real-app playback, DRM/Apple TV, 10-bit HEVC,
long-duration playback, Hackintool create/destroy and other APUs.

## 8. Failure handling / rollback

1. Boot the backup EFI (or add `-NRedOff` to boot-args) so NootedRed does not load.
2. Remove `-NRedVDA` from the OpenCore config/NVRAM.
3. Restore `build/efi-backup/NootedRed-preVDA.kext` over the ESP kext.
4. Optionally boot with only the graphics fix (`-NRedGLFix`) to confirm the baseline.

The new kernel code has no panic path: ABI mismatch, failed X6000 load, failed engine allocation and
failed user-space page matching all return safely and stop installing new VDA patches. The user-space
VA/AppleGVA pages, however, are written into the shared-cache page cache after code-signing validation:
once applied they are system-wide for the rest of the boot and cannot be reliably rolled back. A failure
after that point disables further patching but does not make already-patched clients stock again; reboot
to return to a clean cache. A hang, if any, would be inside Apple's native VCN2 engine/power path, which
is exactly what the staged validation above is meant to isolate. Keep the backup EFI and rollback steps
ready.
