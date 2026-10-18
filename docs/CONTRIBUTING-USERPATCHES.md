# Contributing to UserPatches

This document is for contributors working on the Chromium/Electron dual-source corruption fix that
lives in `NootedRed/UserPatches.{hpp,cpp}`. It covers the architecture, how to add a macOS build or an
APU family, how to generate patch data, and the safety rules that keep a bad page image from corrupting
an unrelated process.

The normal kext build and coding conventions are in `AGENTS.md`; read that first.

## Status and branches

- `master`: the validated conditional gate/setz fix for macOS 15.8.1 / Renoir. It is the production
  baseline.
- `feature/multi-os-multi-apu`: version- and family-aware `PatchSet` table, APU masks, and the
  `tools/gen_patch_data.py` generator. Only 15.8.1 data is included; other builds must be generated.
- `research/patch-resolver`: opt-in masked-context resolver prototype. Exact page images remain the
  primary path.

Do not assume a branch's data applies to another macOS build. A mismatched page image is a no-op by
design, not a fallback.

## Architecture

### `PagePatch`

One patch site in one user-space Mach-O page.

```cpp
struct PagePatch {
    UserPatcher::FileSegment segment; // Lilu backend only
    const UInt8* page;                // exact 4 KiB page image for native backend
    const UInt8* find;
    const UInt8* replace;
    size_t size;
    size_t skip;
    size_t count;
};
```

The native backend only patches after the complete page image matches, and only after the page passed
code-signing validation. A failed match means no patch.

### `PatchSet`

```cpp
struct PatchSet {
    const char* name;
    PenguinWizardry::KernelVersion minVersion; // Darwin major.minor
    PenguinWizardry::KernelVersion maxVersion;
    ApuMask apus;
    const PagePatch* patches;
    size_t count;
    const SignaturePatch* signatures; // resolver, optional
    size_t signatureCount;
};
```

Selection is first-match on Darwin version and APU mask. An unknown APU (mask 0) only matches a
generic `kApuAll` fallback.

### Backends

- macOS 11+: `_cs_validate_page` for file-backed bundles (the GL driver), and `_cs_validate_range` for
  shared-cache pages (the Metal driver).
- macOS 10.15 and older: Lilu's user patcher. This path is not used by the current fix.

### Boot arguments

- `-NRedGLFix` enables the feature (default off).
- `-NRedGLFixOff` forces it off.
- `-NRedGLFixResolve` additionally enables the resolver fallback when an exact page image does not
  match. It does nothing without `-NRedGLFix`.

## Current patch sites (15.8.1 only)

These are known for macOS 15.8.1 / `AMDRadeonX5000GLDriver` 7.0.25 / build 24H32. Treat them as a
reference, not as offsets for another build.

| Target | Page | Page offset | Find | Replace | Notes |
| --- | --- | --- | --- | --- | --- |
| GL HwInfo (A1) | file `0xE000` | `0x81` | `C7 47 78 04 00 00 00` | `C7 47 78 01 00 00 00` | Renoir `numShaderEngines 4 -> 1` |
| GL dual-quad (A2) | file `0x8000` | `0x160` | `83 E0 FE` | `83 C8 01` | second occurrence in the vanilla page (`skip = 1`) |
| Metal gate | cache VA `0x7ffb087b3000` | `0x164` | `75 0B` | `EB 0B` | open `HwInfo+0xa0` capability gate |
| Metal allow | same cache page | `0x198` | `0F 94 C0` | `31 C0 90` | force `allowRBPlus` for the conditional path |

The two Metal sites are the validated workaround. Do not replace them with the source-level
`0x4D -> 0x4F` HwInfo patch: that enables RB+ register programming whose tiling tables do not model
Renoir, and produces black tiles/missing thumbnails.

## Adding a macOS build

### 1. Use a pristine driver

Generate data from the target build's **unmodified** driver and dyld shared cache. If a driver page was
already patched (for example by an earlier experiment), `gen_patch_data.py` will correctly fail its
`skip`/`count` validation. Restore a clean copy first.

### 2. Locate the sites

- GL driver is a file-backed bundle; `file_offset` is the file offset of the 4 KiB page.
- Metal driver is in the dyld shared cache; the spec uses the page VA and the cache file plus its base.
- Confirm the surrounding instructions in a disassembler. A repeated byte pattern is not enough; the
  context must identify the intended function/branch.

### 3. Write a spec and generate

```json
{
  "name": "15.8.1 / gfx9 APU",
  "darwin": [24, 6],
  "gl_driver": "/System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver",
  "cache_base": "0x7ffb00000000",
  "gl_pages": [
    {
      "name": "GLHwInfoPage",
      "file_offset": "0xe000",
      "find": "c7477804000000",
      "replace": "c7477801000000",
      "skip": 0,
      "count": 1
    }
  ],
  "cache_pages": [
    {
      "name": "MTLGatePage",
      "cache_file": "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_x86_64h.03",
      "va": "0x7ffb087b3000",
      "find": "750b",
      "replace": "eb0b",
      "skip": 0,
      "count": 1
    }
  ]
}
```

```sh
python3 tools/gen_patch_data.py spec.json --out /tmp/new-set.cpp
```

The generator validates every find in the extracted page and emits:

- 4 KiB page image arrays;
- find/replace arrays;
- a `PagePatch` table;
- a `PatchSet` entry.

Review the emitted offsets by hand; do not paste generated data without checking it.

### 4. Integrate

Add the generated arrays and tables to `NootedRed/UserPatches.cpp`, then add the `PatchSet` entry to
`kGLDriverPatchSets` with the correct Darwin `major.minor` and APU mask. Keep exact `minVersion` and
`maxVersion` for the first validated build; widen only after testing.

### 5. Build and test

```sh
xmake f -m release -y
xmake -y
python3 tools/test_patchset_selection.py
```

Then install the kext, reboot, and check:

- boot log contains `Selected patch set "<name>"` with the expected Darwin/APU mask;
- GL dual-source output is correct;
- Metal normal pipeline has `DISABLE_DUAL_QUAD=0`, dual-source pipeline has `1`;
- no `Kernel_*.gpuRestart` appears.

## Adding an APU family

1. Add a bit to `UserPatches::ApuMask` if the family is not covered.
2. Map device IDs/attributes in `UserPatches::currentApuMask()`.
3. Add or update a `PatchSet` entry for that family. If the page data is shared, reuse the existing
   tables; if not, generate a family-specific set.
4. Add cases to `tools/test_patchset_selection.py`.
5. Test on the real hardware. A code-level mask is not a claim of hardware validation.

Base Raven is special: `NRed` intentionally leaves `Attributes` empty for `0x15DD`, so
`currentApuMask()` maps that device ID to `kApuRaven` explicitly.

## Resolver prototype

The resolver is an opt-in fallback for builds whose page image is not known. It is a short masked
context around the patch site:

```cpp
struct SignaturePatch {
    const UInt8* context;
    const UInt8* mask;       // 0xFF must match, 0x00 wildcard
    size_t contextSize;
    size_t patchOffset;      // relative to context start
    const UInt8* replace;
    size_t replaceSize;
    size_t skip;
    size_t count;
    UInt64 pageOffset;       // ~0 = any page
};
```

Rules:

- exact page images are tried first;
- resolver runs only with `-NRedGLFixResolve`;
- a miss is a no-op;
- the current 15.8.1 signatures are 32-byte contexts generated from the same page images;
- MTL signatures currently have no module filter; do not treat them as safe for arbitrary pages.

Before relying on the resolver for a new macOS build, extract the signatures on that build and verify
the hit site, the resulting instructions, and the runtime behaviour. A matching context is not proof of
semantic correctness.

## Safety rules

- Never patch a page that failed code-signing validation.
- Prefer exact page images; use the resolver only for explicitly tested builds.
- Do not combine this with BFixup or another user-space GL/Metal patcher.
- Do not apply APU data to a Vega dGPU: the HwInfo model and RB+ support differ.
- Do not write to `/System/Library/Extensions` or the dyld shared cache; all patches are in-memory.
- Keep the feature opt-in. A failed or missing match must be a no-op, not a panic.
- Keep the `-NRedGLFixOff` override working.

## Commit conventions

- Keep patch data, selection logic, and docs in focused commits.
- Use a clear prefix such as `UserPatches:`, `tools:`, or `docs:`.
- Do not add AI/assistant attribution to files or commits; the project license forbids AI use.
- Preserve the ChefKiss Open Knowledge License header on source files.

## Known limitations

- The framework can select versions/families, but only 15.8.1 page data is present.
- Multi-APU family entries share 15.8.1 data; only Renoir has been validated.
- The resolver is a prototype; its 32-byte contexts are still per-build data.
- Full RB+ enablement is not safe on Renoir with isolated HwInfo/golden patches; keep the conditional
  gate/setz path.
