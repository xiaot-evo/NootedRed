# User-Space Patch Runtime Analysis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the NRPT profile satellite with a small kext that parses the current macOS image at boot, resolves 5 default (GL/Metal) or 19 (with VDA) user-space patch sites from stable Mach-O symbols, function-local rules and a few shape variants, and applies them only in `_cs_validate_page` after the original validator accepts the page.

**Architecture:** A host-testable analyzer core (byte source → Mach-O parser → symbol/function resolver → rule resolver) is shared by a host test and the kext. The kext adds a VFS-backed byte source and a one-shot thread call; the validation hook only consumes the resolved `SiteSet` and never parses or allocates. The old profile/identity/warm/diagnostic layers are deleted.

**Tech Stack:** C++23 (no STL, no exceptions, no RTTI), Lilu KernelPatcher/FileIO, xmake + AppleForge, Python 3 host test driver, clean fixtures at `version-fixtures/15.8.2` and `version-fixtures/26.7.2`.

**Spec:** `docs/USERSPACE-PATCHING.md`

## Global Constraints

- ChefKiss Open Knowledge License v1 header on every source file; copyright year 2026; no AI or assistant attribution in files or commits.
- C++23; no STL containers, exceptions or RTTI; `auto f() -> T` trailing returns; PascalCase types; camelCase methods/locals/members; `k` constants.
- Hook path (`_cs_validate_page` wrapper): no allocation, sleeping, file I/O, IORegistry, vnode references, or unbounded logging. Only atomics, the immutable `SiteSet`, byte compares and the kernel write lock.
- Analysis runs in a sleepable, pre-allocated `thread_call`; it may use VFS/`FileIO` and bounded allocations, and must retry while the Cryptex/Data volume is not yet mounted.
- The original validator always runs first and its result is never changed. A site is written only when its complete `find`/`replace` bytes are inside the delivered chunk and `find` matches exactly.
- No runtime patch-data channel: no `NRedProfiles`, NVRAM, IORegistry or boot-arg-supplied patch bytes. The only boot-arg inputs are enable/disable switches (`-NRedUserPatchOff`, `-NRedUserPatchDry`, `-NRedUserPatchVDA`, `-NRedUserPatchDebug`).
- AMFI and SIP stay fully enabled; no boot-arg may be required to make the mechanism work.
- Rules carry a `familyMask` (VCN2 = `0x28`); VDA rules are enabled only with `-NRedUserPatchVDA`. There is no build string or per-profile identity; the only identity probe is the iGPU `device-id`.
- Shape variants are keyed by the function's byte shape, not by the macOS build. The MTL gate/allow variants are the only ones in v1; adding a variant is a code/data change, not a per-build profile.
- Every negative condition is fail-closed and logged once (bounded): unresolved rule, symbol missing, ambiguous local match, no matching variant, find mismatch, write failure.
- Host tests that need OS images read only the untracked local fixture tree. In this worktree it is a symlink: `version-fixtures -> <original checkout>/version-fixtures`; do not commit it.
- EFI writes, kext deployment and reboot validation require explicit authorization from the user in the current session. Do not deploy autonomously.
- Never delete `build/efi-backup/`, `build/revert-backup/`, `build/profile-24H232-v3/`, `build/profile-24H232-v4/`.

## Review Focus

- **Truncated/malformed cache and Mach-O data**: a short header, absurd `ncmds`, out-of-range `symoff`/`strx`, or a ULEB128 overrun must return false, never read out of bounds or loop forever. Pinned by the negative tests in Tasks 2–4.
- **Symbol collisions**: two symbols with the same name in different images must be disambiguated by the running image's text range; an ambiguous or out-of-image symbol must fail closed. Pinned by Task 3.
- **Ambiguous local match**: a local pattern that matches twice inside the function must not patch both silently; `unique` fails closed, `nth`/`all` must be explicit. Pinned by Task 5.
- **Variant selection**: if two shape variants could match the same function, table order decides and the result must be deterministic; a variant that matches structurally but whose `find` bytes do not match must not block the next variant. Pinned by the MTL variant tests in Task 5.
- **A target page validated before analysis completes**: the hook sees no resolved site and must not patch from a stale/partial table; log the first target delivery time relative to analysis completion. Pinned by the dry-run hardware check in Task 7.
- **UBC reclaim**: after eviction and re-read the page must be patched again on the next validation, with no per-page state. Pinned by the `--touch` verifier in Task 8.

---

### Task 1: Host-test skeleton and byte source

**Files:**
- Create: `NootedRedUserPatch/Analyzer/AnalyzerTypes.hpp`
- Create: `NootedRedUserPatch/Analyzer/ByteSource.hpp`
- Create: `test/support/FileByteSource.hpp`
- Create: `test/test_analyzer.py`
- Create: `test/test_analyzer.cpp`

**Interfaces:**
- Consumes: nothing.
- Produces: `NRedUserPatch::ByteSource { using ReadFn = bool (*)(void*, uint64_t, void*, size_t); ReadFn read; void* context; bool readAt(uint64_t, void*, size_t) const; }`; `test/support/FileByteSource.hpp` exposes `bool openFixtureFile(const char* path, FileSource& out)` where `FileSource` owns a `FILE*` and has a static `read` thunk.

- [ ] **Step 1: Write the failing host test**

`test/test_analyzer.py` compiles `test/test_analyzer.cpp` with `clang++ -std=c++23 -Wall -Wextra -Werror -I NootedRedUserPatch -I test/support`, passes the fixture root (`version-fixtures/15.8.2` by default), and runs it. The first test opens `System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver` and asserts the first four bytes are `cf fa ed fe`.

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/test_analyzer.py`
Expected: compile error/`openFixtureFile` undefined.

- [ ] **Step 3: Implement the types and file source**

`AnalyzerTypes.hpp`: fixed-width aliases only (`uint8_t/uint16_t/uint32_t/uint64_t/size_t`). `ByteSource.hpp`: the function-pointer source plus `bool readAt(...)`. `FileByteSource.hpp`: `FileSource { FILE* file; }`, `read` uses `fseeko`/`fread` and returns false on short read. Also add the rule/result enums (`ImageKind`, `AnchorKind`, `LocalKind`, `MatchPolicy`, `Rule`, `ResolvedSite`) here; Task 5 fills them in, but declare them now with the exact fields listed in Task 5.

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 test/test_analyzer.py`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add NootedRedUserPatch/Analyzer test/support test/test_analyzer.py test/test_analyzer.cpp
git commit -m "analyzer: add host-test skeleton and byte source"
```

---

### Task 2: Mach-O parser

**Files:**
- Create: `NootedRedUserPatch/Analyzer/MachO.hpp`
- Create: `NootedRedUserPatch/Analyzer/MachO.cpp`
- Modify: `test/test_analyzer.cpp`

**Interfaces:**
- Consumes: `ByteSource`.
- Produces:
  ```cpp
  struct MachOImage {
      uint64_t fileBase;              // file offset of the Mach-O header
      uint64_t loadAddress;           // unslid VA of the image (0 for standalone)
      uint64_t textVmAddr, textFileOffset, textSize;
      uint64_t imageVaEnd;            // loadAddress + textSize
      uint64_t linkeditFileOffset;
      uint32_t symoff, nsyms, stroff, strsize;
      uint32_t functionStartsOffset, functionStartsSize;
      uint32_t exportTrieOffset, exportTrieSize;
  };
  bool parseMachO(const ByteSource& source, uint64_t imageFileBase, uint64_t loadAddress,
                  uint64_t textSize, MachOImage& out);
  ```
  `parseMachO` returns false on any bounds error, non-`MH_MAGIC_64`, missing `__TEXT`, or `sizeofcmds` overrun. It accepts `LC_SEGMENT_64` (`__TEXT`, `__LINKEDIT`), `LC_SYMTAB`, `LC_FUNCTION_STARTS` (`0x26`), `LC_DYLD_EXPORTS_TRIE` (`0x80000033`) and `LC_DYLD_INFO_ONLY` (`0x80000022`, export fields).

- [ ] **Step 1: Write the failing test**

In `test/test_analyzer.cpp`, open the GL standalone file and the 15.8.2 MTL cache image (located by the cache locator in Task 4; for now use the known file offset `0x8757000` inside `dyld_shared_cache_x86_64h.03`). Assert:
- GL: `parseMachO(..., 0, 0x14d000)` succeeds; `nsyms == 8384`; `functionStartsOffset == 0x157bc0`.
- MTL: `parseMachO(..., 0x8757000, 0x7ffb08757000, 0x44fc11)` succeeds; `nsyms == 19870`; `functionStartsOffset == 0x23ba3918`.

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/test_analyzer.py`
Expected: FAIL, `parseMachO` undefined.

- [ ] **Step 3: Implement `parseMachO`**

Read the 32-byte header and the load-command array (cap `sizeofcmds` at 0x8000). Walk commands by `cmdsize`, validating `cmdsize >= 8` and staying inside `sizeofcmds`. Fill `MachOImage`; derive `imageVaEnd` from `loadAddress + textSize`. Do not allocate.

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 test/test_analyzer.py`
Expected: PASS for both images.

- [ ] **Step 5: Commit**

```bash
git add NootedRedUserPatch/Analyzer/MachO.* test/test_analyzer.cpp
git commit -m "analyzer: parse Mach-O load commands"
```

---

### Task 3: Symbol and function-start lookup

**Files:**
- Modify: `NootedRedUserPatch/Analyzer/MachO.hpp`
- Modify: `NootedRedUserPatch/Analyzer/MachO.cpp`
- Modify: `test/test_analyzer.cpp`

**Interfaces:**
- Consumes: `MachOImage`.
- Produces:
  ```cpp
  bool findSymbol(const ByteSource&, const MachOImage&, const char* name, uint64_t& outVa);
  bool functionRange(const ByteSource&, const MachOImage&, uint64_t va, uint64_t& start, uint64_t& end);
  ```
  `findSymbol` first parses the export trie; if absent, scans `nlist_64` entries whose `n_value` is inside `[loadAddress, imageVaEnd)`, reading each name from `stroff + strx` with a 256-byte bound. It returns false if zero or more than one in-image symbol matches.
  `functionRange` streams the `LC_FUNCTION_STARTS` ULEB128 deltas without storing the array: it tracks the greatest start `<= va` and the first start `> va`; `end` is the latter (or `imageVaEnd`).

- [ ] **Step 1: Write the failing test**

For the VADriver2 image in 15.8.2, assert `findSymbol("__ZN17VAAcceleratorInfo8identifyEjj")` returns the unslid VA whose image-relative offset is `0x9e0` (export trie says 2528), and `functionRange` brackets it. For the MTL image, assert `findSymbol("__Z19gfx9_HwInfoInitDataP14GFX9_HwInfoRecP24_sAMD_GET_HW_INFO_VALUESj")` returns the local symbol at image-relative `0x983dc`, which is not in the export trie. Repeat both for 26.7.2 and assert the symbol exists.

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/test_analyzer.py`
Expected: FAIL, `findSymbol` undefined.

- [ ] **Step 3: Implement the export-trie parser, nlist scan and ULEB128 stream**

Export trie: recursive walk with an explicit bound and depth cap; terminal node yields `flags` and `address`; the address is image-relative (`loadAddress + address` is the unslid VA). nlist scan: read entries in 4 KB chunks; for each in-range `n_value`, read the name via `readAt(stroff + strx, ...)` with a 256-byte cap and compare. `functionRange`: read `functionStartsSize` in 4 KB chunks, carry the ULEB128 state across chunk boundaries, and stop when the first start `> va` is found.

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 test/test_analyzer.py`
Expected: PASS for 15.8.2 and 26.7.2.

- [ ] **Step 5: Commit**

```bash
git add NootedRedUserPatch/Analyzer/MachO.* test/test_analyzer.cpp
git commit -m "analyzer: resolve symbols and function ranges"
```

---

### Task 4: Shared-cache image locator

**Files:**
- Create: `NootedRedUserPatch/Analyzer/CacheLocator.hpp`
- Create: `NootedRedUserPatch/Analyzer/CacheLocator.cpp`
- Modify: `test/test_analyzer.cpp`

**Interfaces:**
- Consumes: `ByteSource`.
- Produces:
  ```cpp
  using OpenCacheFn = bool (*)(void* context, const char* subcacheName, ByteSource& out);
  struct LocatedImage {
      char vnodeName[64];       // "dyld_shared_cache_x86_64h.NN"
      uint64_t fileOffset;      // __TEXT file offset inside the subcache
      uint64_t textSize;
      uint64_t loadAddress;
      uint64_t linkeditFileOffset;
  };
  bool locateCacheImage(const ByteSource& mainCache, OpenCacheFn open, void* openContext,
                        const char* imagePath, LocatedImage& out);
  ```
  The locator reads `imagesTextOffset/Count` at header `0x88/0x90`, matches `pathOffset` strings, then reads each subcache's mapping table (`mappingOffset`/`mappingCount` at `0x10/0x14`, 32-byte entries) to convert `loadAddress` to `(subcache, fileOffset)`. It also returns the image's `__LINKEDIT` file offset from its Mach-O header (via `parseMachO` in Task 2).

- [ ] **Step 1: Write the failing test**

Open `dyld_shared_cache_x86_64h` from 15.8.2 and locate:
- `/System/Library/Extensions/AMDRadeonX5000MTLDriver.bundle/Contents/MacOS/AMDRadeonX5000MTLDriver` → vnode `dyld_shared_cache_x86_64h.03`, file offset `0x8757000`, size `0x44fc11`, load `0x7ffb08757000`.
- `VADriver2` → same vnode, file offset `0x8606000`, size `0xb8268`.
- `AppleGVA` → vnode `.02`, file offset `0x6672000`, size `0xee2cf`.
Repeat for 26.7.2 and assert the known offsets `0x10c50000` / `0x10b00000` / `0xc57c000`.

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/test_analyzer.py`
Expected: FAIL, `locateCacheImage` undefined.

- [ ] **Step 3: Implement the locator**

All reads bounded; if `imagesTextCount > 65536` or a subcache mapping count is absurd, return false. Match path strings byte-for-byte with a 300-byte cap. Keep the host `OpenCacheFn` mapping to `<fixtures>/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/<name>`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 test/test_analyzer.py`
Expected: PASS for both versions.

- [ ] **Step 5: Commit**

```bash
git add NootedRedUserPatch/Analyzer/CacheLocator.* test/test_analyzer.cpp
git commit -m "analyzer: locate images in the dyld shared cache"
```

---

### Task 5: Rule table and resolver

**Files:**
- Create: `NootedRedUserPatch/Analyzer/RuleTable.hpp`
- Create: `NootedRedUserPatch/Analyzer/RuleTable.cpp`
- Create: `NootedRedUserPatch/Analyzer/RuleResolver.hpp`
- Create: `NootedRedUserPatch/Analyzer/RuleResolver.cpp`
- Modify: `test/test_analyzer.cpp`

**Interfaces:**
- Consumes: `parseMachO`, `findSymbol`, `functionRange`, `locateCacheImage`.
- Produces:
  ```cpp
  enum class ImageKind : uint8_t { kStandalone, kSharedCache };
  enum class AnchorKind : uint8_t { kSymbol, kFunctionFingerprint, kImageUnique };
  enum class LocalKind : uint8_t { kOffset, kPattern };
  enum class MatchPolicy : uint8_t { kUnique, kAll, kNth };

  struct RuleVariant {
      LocalKind localKind;
      uint32_t localOffset;
      const uint8_t* localPattern; uint8_t localPatternSize;  // '?' = wildcard
      const uint8_t* find; const uint8_t* replace; uint8_t patchSize;
  };

  struct Rule {
      uint16_t id;
      ImageKind imageKind;
      const char* imagePath;
      uint32_t familyMask;      // 0x28 = VCN2 Renoir/Cezanne/Green Sardine
      uint8_t flags;            // kRuleFlagVDA = enabled only with -NRedUserPatchVDA
      AnchorKind anchorKind;
      const char* symbol;
      const uint8_t* fingerprint; uint8_t fingerprintSize;
      const RuleVariant* variants; uint8_t variantCount;
      MatchPolicy policy;
      uint8_t localNth;
  };

  struct ResolvedSite {
      const char* vnodeName;   // static string owned by the rule table
      uint64_t fileOffset;
      const uint8_t* find;
      const uint8_t* replace;
      uint8_t size;
      uint16_t ruleId;
  };

  bool resolveRule(const ByteSource& mainCache, OpenCacheFn open, void* openContext,
                   const Rule& rule, bool vdaEnabled, uint32_t runningFamily,
                   ResolvedSite& out);
  ```
  `resolveRule` returns false if the family/VDA gate excludes the rule or if no variant matches; all resolution is host-testable and does not touch kernel APIs. The variant is tried in table order; the first variant with a unique (or policy-valid) match wins.

- [ ] **Step 1: Write the failing test**

The test iterates the rules and asserts:
- **Default mode** (`vdaEnabled=false`): 5 rules resolve on 15.8.2; golden offsets GL `0x8160,0xe081`, MTL `0x5c164,0x5c198,0x9851d`; the same 5 resolve on 26.7.2.
- **VDA mode** (`vdaEnabled=true`): 19 rules resolve on both fixtures; VADriver golden offsets `0xb96,0x2449,0x9987,0x9a49,0x9acb,0x9bd0,0x9c69,0x46af5,0x46b01,0x47f88,0x49626,0x4a82c,0x61c65,0x77770`.
- **Variant selection**: MTL site 2 resolves with `find=75 0B/replace=EB 0B` on 15.8.2 and `find=74 28/replace=EB 00` on 26.7.2; MTL site 3 with `find=0F 94 C0/replace=31 C0 90` on 15.8.2 and `find=0F 94 C1/replace=31 C9 90` on 26.7.2.
- **Family gate**: `runningFamily=0x10` (not VCN2) resolves zero rules; `runningFamily=0x28` resolves the expected set.
- Negative: a rule with `symbol="__missing__"` fails; a rule with `policy=kUnique` and a pattern that matches twice fails; a rule whose variant `find` is wrong fails; a rule with no matching variant fails closed.

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/test_analyzer.py`
Expected: FAIL, `resolveRule` undefined.

- [ ] **Step 3: Encode the rule table**

Use the anchors in `docs/USERSPACE-PATCHING.md` Appendix A. Encode **19 rules**: 5 default (GL 2, MTL 3) and 14 VDA (VADriver2). AppleGVA/site 19 is not included.

For each rule, derive the variant(s) from the clean 15.8.2 fixture:
- `kOffset` with the Appendix A function-relative offset; `find` is the site's original bytes.
- `kPattern` fallback with the ±12-byte context window; `?` wildcard for bytes that differ between 15.8.2 and 26.7.2 after alignment (these are the relative displacement/immediate bytes). Use `kUnique` unless the site intentionally patches multiple copies (`kAll`) or is the nth adjacent copy (`kNth`).
- MTL sites 2/3 get **two shape variants each**, in this order:
  - site 2: 15.8.2 shape `F6 80 A0 00 00 00 02 75 0B` -> `EB 0B`; 26.7.2 shape `F6 81 A0 00 00 00 02 74 28` -> `EB 00`.
  - site 3: 15.8.2 `0F 94 C0` -> `31 C0 90`; 26.7.2 `0F 94 C1` -> `31 C9 90`.
  The variant pattern includes the shape bytes; the patch offset is the last 2 bytes (site 2) or the 3-byte instruction (site 3). Scope every variant to the anchored function and require a unique match.

- [ ] **Step 4: Implement the resolver**

Order: locate image → `parseMachO` → anchor → function range → local rule → verify `find` at the resolved file offset. For `kPattern`, scan only `[functionStart, functionEnd)` in 4 KB chunks with a 4 KB overlap equal to the pattern length; count matches; enforce the policy. Return false on any ambiguity or mismatch. Never scan outside the function for a symbol anchor.

- [ ] **Step 5: Run the test to verify it passes**

Run: `python3 test/test_analyzer.py`
Expected: PASS 5/5 default and 19/19 VDA on both fixtures; the MTL variants select correctly; negatives fail closed.

- [ ] **Step 6: Commit**

```bash
git add NootedRedUserPatch/Analyzer/RuleTable.* NootedRedUserPatch/Analyzer/RuleResolver.* test/test_analyzer.cpp
git commit -m "analyzer: resolve the user-space patch rules and shape variants"
```

---

### Task 6: Kernel adapter and analyzer thread

**Files:**
- Create: `NootedRedUserPatch/KernelFileSource.hpp`
- Create: `NootedRedUserPatch/AnalyzerRuntime.hpp`
- Create: `NootedRedUserPatch/AnalyzerRuntime.cpp`
- Modify: `NootedRedUserPatch/Plugin.cpp`
- Modify: `NootedRedUserPatch/Info.plist` (remove `NRedProfiles` documentation; keep the main-kext dependency)
- Modify: `xmake.lua` (remove `LILU_CUSTOM_IOKIT_INIT` if no service start remains)

**Interfaces:**
- Consumes: `ByteSource`, `locateCacheImage`, `resolveRule`, `RuleTable`.
- Produces:
  ```cpp
  class AnalyzerRuntime {
  public:
      static AnalyzerRuntime& singleton();
      void start(KernelPatcher& patcher);   // patcher-load: install hook, submit thread call
      void stop();
      bool ready() const;                   // SiteSet is published
  private:
      static void callback(thread_call_param_t, thread_call_param_t);
      void process();
  };
  ```
  `KernelFileSource` opens a vnode with `vnode_lookup(path, 0, &vp, vfs_context_current())` and reads a range with `FileIO::readFileData(buffer, offset, size, vp, ctxt)`; it closes with `vnode_put` and `vfs_context_rele`. The analysis thread uses the live roots `kLiveCacheDir` and `kSystemCacheDir`, retries `thread_call_enter_delayed` up to 10 times at 500 ms, and on success calls `SiteSet::publish(...)`.

- [ ] **Step 1: Write the failing test**

There is no host test for the VFS adapter. The test is a compile + dry-run log check:
- Build: `xmake f -m debug -y && xmake build --project=. -y NootedRedUserPatch`
Expected: build succeeds; no references to `PatchProfile`/`NRedProfiles` remain in `NootedRedUserPatch/`.

- [ ] **Step 2: Implement the adapter and thread**

`KernelFileSource` holds one open vnode per file; the analyzer opens the main cache, each needed subcache, and the standalone GL driver, reads the iGPU `device-id` via Lilu `DeviceInfo` to compute `runningFamily` (VCN2 = `0x28`), resolves the enabled rules (5 default, 19 with `-NRedUserPatchVDA`), logs `resolved N/5` or `N/19`, and publishes the `SiteSet` with release semantics. A failed rule logs its ID, variant and reason. Do not install `_cs_validate_range`.

- [ ] **Step 3: Build and verify the binary**

Run: `xmake f -m debug -y && xmake build --project=. -y NootedRedUserPatch`
Expected: PASS. Then `nm` or `strings` the binary to confirm the rule anchor names and no `NRedProfiles` string.

- [ ] **Step 4: Commit**

```bash
git add NootedRedUserPatch/KernelFileSource.hpp NootedRedUserPatch/AnalyzerRuntime.* NootedRedUserPatch/Plugin.cpp NootedRedUserPatch/Info.plist xmake.lua
git commit -m "satellite: analyze live images at boot"
```

---

### Task 7: SiteSet and validation hook

**Files:**
- Create: `NootedRedUserPatch/SiteSet.hpp`
- Create: `NootedRedUserPatch/SiteSet.cpp`
- Create: `NootedRedUserPatch/ValidationHook.hpp`
- Create: `NootedRedUserPatch/ValidationHook.cpp`
- Delete: `NootedRedUserPatch/PatchProfile.hpp`, `NootedRedUserPatch/PatchProfile.cpp`
- Modify: `NootedRedUserPatch/Plugin.cpp`
- Create: `test/test_site_set.cpp`; create `test/test_site_set.py`

**Interfaces:**
- Consumes: `ResolvedSite`, `PatchPolicy::siteFitsChunk`.
- Produces:
  ```cpp
  class SiteSet {
  public:
      static SiteSet& singleton();
      void publish(const ResolvedSite* sites, uint32_t count);  // release store of ready flag
      bool ready() const;
      // Hook path: original validator already ran and accepted. No allocation/sleep/log flood.
      uint32_t apply(const char* vnodeName, uint64_t chunkOffset, const uint8_t* data, size_t size);
  };
  ```
  `apply` matches `vnodeName` exactly, requires `siteFitsChunk(offset, size, chunkOffset, chunkSize)`, skips if `replace` already present, skips if `find` absent (counts a foreign byte), and writes all clean sites under one `MachInfo::setKernelWriting` window, then verifies the readback.
- `ValidationHook` installs `_cs_validate_page` and resolves `_vnode_getname`/`_vnode_putname`/`_vn_getpath`; the wrapper calls the original first and only on `*validated != 0` calls `SiteSet::apply` with the vnode name.

- [ ] **Step 1: Write the failing test**

`test_site_set.cpp` is a pure host test: publish two sites with known `find`/`replace` in one 4 KB buffer; assert apply writes both, is idempotent, skips foreign bytes, and does not write a site split across two chunks. `test_site_set.py` compiles and runs it (no fixtures).

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/test_site_set.py`
Expected: FAIL, `SiteSet` undefined.

- [ ] **Step 3: Implement SiteSet and the hook wrapper**

The hook's name resolution is the only VFS-adjacent call; `vnode_getname` returns a const string that must be released with `vnode_putname`. If no resolver is available, the hook matches nothing (fail closed). Keep the wrapper's original result untouched.

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 test/test_site_set.py`
Expected: PASS.

- [ ] **Step 5: Build and dry-run on hardware (requires authorization)**

Build debug; deploy only after the user authorizes EFI writes and a reboot; boot with `-NRedUserPatchDebug -liludbgall liludump=60` and `-NRedUserPatchDry` first. Confirm the log shows 5/5 default (or 19/19 with `-NRedUserPatchVDA`) resolved and no writes.

- [ ] **Step 6: Commit**

```bash
git add NootedRedUserPatch/SiteSet.* NootedRedUserPatch/ValidationHook.* NootedRedUserPatch/Plugin.cpp test/test_site_set.cpp test/test_site_set.py
git rm NootedRedUserPatch/PatchProfile.hpp NootedRedUserPatch/PatchProfile.cpp
git commit -m "satellite: apply resolved sites in the page validation hook"
```

---

### Task 8: Delete legacy, update docs, hardware validation

**Files:**
- Delete: `NootedRedUserPatch/UserPatchBackend.hpp`, `NootedRedUserPatch/UserPatchBackend.cpp`
- Delete: `test/inject_profile.py`, `test/test_inject_profile.py`, `test/nrpt_validator.py`, `test/test_nrpt_validator.py`
- Replace: `NootedRedUserPatch/README.md` with a short pointer to `docs/USERSPACE-PATCHING.md`
- Modify: `docs/INSTALLATION.md` if it documents `NRedProfiles`
- Modify: `README.md` if it describes the profile pipeline
- Keep: `test/test_patch_policy.cpp`, `test/test_patch_policy.py` (or move `PatchPolicy.hpp` under `Analyzer/` if the test includes it)

**Interfaces:**
- Consumes: all previous tasks.
- Produces: a branch with no NRPT/profile/identity/warm code and a passing host test suite.

- [ ] **Step 1: Write the regression test first**

Extend `test/test_analyzer.py` to fail if any of these strings still appear under `NootedRedUserPatch/`: `NRedProfiles`, `PatchProfile`, `kVersionV3`, `warmCallback`, `identityRetry`.

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 test/test_analyzer.py`
Expected: FAIL with the offending file list.

- [ ] **Step 3: Delete and rewrite**

Delete the files above; remove the profile/profile-selection/warm/boot-arg code from `Plugin.cpp`; keep the minimal `device-id` family probe; update the README/installation text; keep the main-kext dependency and the boot args `-NRedUserPatchOff`, `-NRedUserPatchDry`, `-NRedUserPatchDebug`, `-NRedUserPatchVDA`.

- [ ] **Step 4: Run all host tests**

Run:

```sh
python3 test/test_analyzer.py
python3 test/test_site_set.py
python3 test/test_patch_policy.py
```

Expected: all PASS.

- [ ] **Step 5: Hardware validation (requires authorization)**

Deploy debug; boot with SIP + AMFI fully enabled. Verify:
1. Log: analyzer 5/5 default (19/19 with `-NRedUserPatchVDA`), no unresolved rules.
2. `-NRedUserPatchDry` first: planned writes only.
3. Normal boot: 5 writes default; 19 with VDA; GL/Metal work; VDA decode/encode per `docs/VDA-TESTING.md` under `-NRedUserPatchVDA`.
4. `--touch` page readback shows `replace`; after UBC pressure/reclaim, another touch shows the hook rewrote it.
5. `-NRedUserPatchOff` leaves the system unpatched and stable.
6. 26.7.2 (if the machine can boot it): analyzer resolves 5/5 default (19/19 with VDA); same functional checks, including the two MTL shape variants.

- [ ] **Step 6: Commit**

```bash
git add -A NootedRedUserPatch test docs README.md xmake.lua
git commit -m "userpatch: remove NRPT and validate runtime analysis"
```

---

## Self-Review Notes

- Spec coverage: section 2 (core hook) → Tasks 7; section 5 (image/Mach-O parsing) → Tasks 2–4; section 6 (rules/anchors/local rules) → Task 5; section 7 (write path/analysis timing) → Tasks 6–7; section 8 (cross-version) → Tasks 3–5; section 9 (performance) → Task 7; section 10 (security/fail-closed) → Tasks 2–7; section 11 (migration) → Task 8; section 12 (decisions) → encoded by the tasks.
- The rule table contents (the 19 anchors, local patterns and two MTL shape variants) are the one place the plan deliberately leaves data to the builder; Task 5 names the exact fixture, expected offsets/variants and negative tests that make a wrong table fail loudly.
- Hardware deployment and reboot steps are marked as requiring authorization per the repository rules.
