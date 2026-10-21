# Root patch pipeline (Plane B)

Status: design specification for the companion user-space patcher. No code is implemented yet. See
[ARCHITECTURE.md](ARCHITECTURE.md) for the decision and migration plan.

## 1. Goal

Provide a supported, reversible way to apply NootedRed's Apple user-space driver changes
(GLFIX: GL/MTL driver; VDA: AMDRadeonVADriver2/AppleGVA) on macOS Big Sur and newer, without a kext
rewriting code-signing page caches.

The design follows OpenCore Legacy Patcher's root-patch model:

- versioned payloads selected by exact OS build and hardware;
- explicit installer/revert with APFS snapshots;
- kernel-collection/cache rebuild through Apple tools (`kmutil`, KDK) where required;
- state tracking so OS updates cannot silently leave a half-patched system.

## 2. Layout

Proposed repository/packaging layout (names may change during implementation):

```
compat/
  manifests/
    15.8.1-24H32/glfix.json
    15.8.1-24H32/vda.json
    14.8.9-23J631/...            # only after validation
  payloads/
    15.8.1-24H32/glfix/…         # patched files or patch recipes + hashes
    15.8.1-24H32/vda/…
  schemas/manifest.schema.json

rootpatch/
  install.py / revert.py / status.py
  volume/        # APFS mount + snapshot helpers
  caches/        # KDK merge, kmutil, dyld/preboot handling
  verify/        # manifest, hash, OS/APU, SIP/AMFI/LV checks
  state/         # installed payloads + hashes
  gui/           # optional
```

The kext (`NootedRed.kext`) is not part of the root patch payload; it keeps its own kernel-only release.

## 3. Manifest

The manifest is the only contract between payload generation and installation. It is versioned and
immutable after validation.

```json
{
  "schema": 2,
  "payload_id": "nred-vda-15.8.1-20261020",
  "feature": "VDA",
  "level": "validated",
  "os": { "product": "15.8.1", "build": "24H32", "darwin": [24, 6] },
  "apu": { "families": ["Renoir/Green Sardine"], "device_ids": [1638], "min_vcn": "2.2" },
  "requirements": {
    "sip": "disabled-or-unsupported-files-only",
    "amfi": "off-or-exempt",
    "library_validation": "patch-required",
    "kdk": "required-for-kext-merge",
    "recovery_install": "recommended"
  },
  "files": [
    {
      "path": "/System/Library/Extensions/AMDRadeonVADriver2.bundle/Contents/MacOS/AMDRadeonVADriver2",
      "container": "dyld-shared-cache",
      "source_uuid": "662187E4-9F38-375B-9BF6-CCAC3F60979A",
      "source_sha256": "…",
      "output_sha256": "…",
      "action": "replace-image",
      "patches": [{ "name": "family-5-identify", "offset": "0x…", "find": "…", "replace": "…" }]
    }
  ],
  "post_install": ["rebuild-kernel-collection", "update-preboot", "refresh-dyld-cache-if-required"],
  "revert": { "strategy": "apfs-last-sealed-snapshot", "remove_state": true },
  "evidence": ["analysis/vda-1581-va-data.md", "analysis/vda-1581-hardware-validation.md"]
}
```

Rules:

- `source_uuid`/`source_sha256` are mandatory for every touched file;
- `output_sha256` lets the installer and a later `status` call detect drift;
- `container` distinguishes file-backed bundles from dyld-shared-cache images;
- no manifest may reference a binary from another OS build;
- `level` is one of `validated`, `experimental`, `unsupported`; `unsupported` is useful as a negative
  manifest for diagnostics.

## 4. Payload generation

Two payload forms are allowed:

1. **Patched file replacement** (preferred for file-backed bundles and kexts): the generator applies the
   byte patches to a copy of the stock binary, fixes permissions/ownership, and records source/output
   hashes. The installer copies the resulting file/bundle.
2. **Patch recipe** (small, auditable, and only for files where shipping a full binary is impractical):
   the generator emits `offset/find/replace` records with masks and the expected source hash. The
   installer verifies the source and applies them to a temporary copy.

Generation remains in `tools/gen_*_data.py` (extended) so the same evidence and `--check` culture stays:

- read stock binary from the target build (pristine boot or reconstructed vanilla pages);
- apply the exact patch records;
- write output into `compat/payloads/<build>/<feature>/`;
- emit a manifest with hashes;
- CI compares manifests to stored binaries and fails on drift.

For **dyld-shared-cache images** (MTL, VA, AppleGVA), a simple file copy is not enough. This is the
feasibility gate from the architecture document:

- Option 1: replace the on-disk bundle/image and rebuild/refresh the shared cache with an OS-supported
  mechanism; validate that the stock cache does not shadow the replacement.
- Option 2: use an OS-supported cache override/split strategy; validate on each macOS generation.
- Option 3: if neither is safe, narrow the feature to file-backed bundles and/or use a strictly bounded
  data-only in-memory patch (Plane C), never a general code patcher.

No payload may ship until the chosen strategy passes install → boot → feature test → revert → update test.

## 5. Installer flow

The installer must work both from a normal administrator session and, preferably, from a supported
installer/recovery environment for setup-assistant-time patches.

```
1. Preflight
   - read OS product/build and Darwin version
   - detect APU/device ID, VCN generation, external GPU
   - read /System volume state, SIP/AMFI, library validation
   - select manifest; verify sha256 of manifest and all payload files
   - verify every target file's source UUID/hash
   - refuse if any check fails; print a specific reason and support level

2. Consent and prerequisites
   - explain root patch, SIP/AMFI/library-validation requirements, reboot and revert
   - require explicit user confirmation
   - ensure a bootable backup/snapshot path exists

3. Mount and patch
   - mount APFS root volume read/write (nobrowse)
   - install files into the mounted System volume (not the live root where inappropriate)
   - merge KDK if the payload includes kext/kernel changes
   - run kmutil/preboot/cache steps required by the manifest
   - create a new APFS snapshot and bless it

4. Record state
   - write installed payload ID(s), output hashes, snapshot identifier and timestamp
   - state file lives on the data volume with root-only permissions

5. Reboot prompt
```

Ordering and commands will follow the target OS generation; OCLP's `sys_patch.py` is the reference for
mount/kernel-cache/snapshot ordering, and the implementation must be tested on each supported macOS
generation rather than assumed portable.

### Revert

```
1. boot normally or into recovery (whichever is required by the OS state)
2. verify installed payload state/snapshot
3. revert to the last sealed APFS snapshot (bless --last-sealed-snapshot)
4. remove state, restored files are covered by the snapshot
5. reboot
```

Revert must be tested before a payload is marked `validated`; a payload without a working revert is not
released.

## 6. OS updates and state

- The tool records the OS build it patched.
- On a new build, `status.py` reports `stale` and offers:
  - revert to stock snapshot (if the platform allows), or
  - apply the new build's payload (if present), or
  - leave the system unpatched with a clear explanation.
- A background helper (optional, OCLP-style) may check after login, but it must never patch silently.
- Kernel cache/dyld cache state consistency is part of the payload contract: if the OS update invalidates
  a cache, the patch must be reapplied through the same pipeline.

## 7. Security prerequisites

Root patching modifies the sealed system volume and Apple-signed frameworks, so it cannot run with the
same security configuration as a kext-only setup. The requirements are **per payload**, recorded in the
manifest, and the installer must refuse to run when they are not met.

### 7.1 SIP

SIP must be **lowered** for root patching. The OCLP reference configuration is
`csr-active-config = 0x803`:

```
CSR_ALLOW_UNTRUSTED_KEXTS     0x001
CSR_ALLOW_UNRESTRICTED_FS     0x002
CSR_ALLOW_UNAUTHENTICATED_ROOT 0x800
```

That is the minimum for writing the APFS system volume and creating/blessing a new root snapshot. OCLP's
"full disable" option is `0xA03` (adds `CSR_ALLOW_UNAPPROVED_KEXTS`); do not disable AppleInternal, DTrace,
Debugging or NVRAM protections unless a specific payload requires them.

For comparison, a typical Hackintosh kext-only setup (including the current NootedRed machine) may run
with only `0x001` (Kext Signing disabled, Filesystem Protections enabled). **That is not enough for a root
patch**: filesystem protections and the unauthenticated-root bit must be lowered.

### 7.2 Secure Boot model

OCLP defaults to `SecureBootModel = Disabled` (`secure_status = False` in its security builder) for
root-patched systems. The new root snapshot is not Apple-signed in the way a stock sealed volume is, so
Secure Boot/SSV verification is part of the same tradeoff. The installer must check this setting and
require `Disabled` unless a future payload proves otherwise per OS build.

### 7.3 AMFI and Library Validation

The patched Apple user-space drivers/frameworks no longer carry Apple's platform signature. Loading them
into hardened processes trips Library Validation (and, depending on the payload, signature enforcement).

OCLP's preferred combination is kernel patches rather than turning AMFI fully off:

- `Disable Library Validation Enforcement` kernel patch;
- `Disable _csr_check() in _vnode_check_signature` kernel patch;
- `amfi=0x80` only when the LV/CSR patches are insufficient (OCLP notes the LV patch broke on Ventura,
  where it may fall back to AMFI off).

`amfi=0x80` disables signature enforcement **and** Library Validation, but per OCLP's own non-Metal guide it
also breaks TCC prompts (camera/microphone/etc.) and removes their entries from System Settings. It should
therefore be a last resort, not the default. The exact LV/AMFI requirement for GLFIX/VDA payloads must be
determined by the feasibility spike per macOS generation.

### 7.4 Payload classes

| Payload | SIP | SecureBootModel | Library Validation | AMFI |
| --- | --- | --- | --- | --- |
| Kernel-only NootedRed.kext | current Hackintosh setting can stay (e.g. `0x001`) | not changed by the kext | not applicable | not changed |
| Root patch: file-backed driver bundle | must lower (≥ `0x803`) | Disabled | kernel patch | only if LV patch is insufficient |
| Root patch: dyld-cache image | must lower; cache strategy must be proven first | Disabled | kernel patch | only if LV patch is insufficient |
| Root patch containing kexts | lower + kext-signing bits | Disabled | — | likely required (test per OS) |

The user must explicitly accept this security reduction. A root patch tool must never change SIP, Secure
Boot model or AMFI silently; it reports the current state, explains the required change, and aborts if the
state is not met.

Root patching is a deliberate security boundary change. The tool must:

- show what will be modified (files, hashes, kernel patches, SIP/AMFI/LV changes);
- never run from the kext or silently from a background daemon;
- keep payload files world-readable only if required (e.g. executable permissions), and state files
  root-only;
- verify every source and output hash before and after installation;
- keep the APFS snapshot until the user confirms the new boot works;
- provide a documented recovery path (backup EFI, last sealed snapshot, boot args).

## 8. CI and validation

Offline (every change):

- manifest schema validation;
- source/output hash verification against stored stock binaries;
- patch-record validation (offsets inside files, find bytes present, replace length equal, masks valid);
- cross-check that a manifest never references a binary from another build;
- static check that the kext contains no user-space page patcher in release builds (until Plane C is
  explicitly compiled in for research).

On hardware (per payload, before `validated`):

- clean install on the target OS build/APU;
- feature test (GLFIX: Chromium/Electron dual-source; VDA: H.264/HEVC decode/encode, 64×64, 720p, 1080p,
  repeat runs, idle-then-playback);
- root patch install, reboot, revert, reboot to stock;
- OS update then reapply/revert;
- no GPU reset, WindowServer watchdog, panic, or sleep/wake regression.

## 9. Open design questions

1. **dyld shared cache replacement**: what is the supported strategy on Big Sur/Ventura/Sonoma/Tahoe
   for MTL/VA/AppleGVA images? This must be prototyped before promising those features.
2. **File-backed GL driver**: can the GL driver bundle be replaced on disk and loaded by dyld without a
   cache rebuild? Prototype with a no-op patched copy first.
3. **Setup Assistant patches**: which root patches must be installed before the first login (login-screen
   Memoji/wallpaper cases)? The installer/recovery path must cover that, or the payload must be
   installable from the installer volume.
4. **Library Validation**: exact kernel patch/SIP requirements per OS generation; OCLP's
   `Disable Library Validation Enforcement` patch is the reference, but it must be validated here.
5. **Tool language/UI**: Python (OCLP-style) is the fastest reference; a signed app/CLI for release can
   follow.

## 10. References

- [OpenCore Legacy Patcher](https://github.com/dortania/OpenCore-Legacy-Patcher):
  `opencore_legacy_patcher/sys_patch/sys_patch.py`, `docs/PATCHEXPLAIN.md`, `docs/PROCESS.md`.
- [FeatureUnlock](https://github.com/acidanthera/FeatureUnlock): `kern_start.cpp` for the bounded
  in-memory fallback pattern.
- [Architecture](ARCHITECTURE.md).
