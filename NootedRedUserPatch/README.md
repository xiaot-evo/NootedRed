# NootedRedUserPatch

Runtime analyzer for the user-space AMD drivers.  At boot the kext parses the live Mach-O images,
resolves the compiled rule table through symbols, function starts and a few function-shape variants,
and applies the resulting sites in `_cs_validate_page` after the original validator accepts the page.
There is no profile, no injection step and no runtime patch-data channel.

- Rules: `Analyzer/RuleTable.cpp` — 5 default GL/Metal sites plus 14 VADriver sites enabled with
  `-NRedUserPatchVDA`.
- Analyzer: `Analyzer/` (dyld cache, Mach-O, symbols, rule resolver) and `AnalyzerRuntime.cpp`
  (one-shot sleepable kernel thread created with `kernel_thread_start`; VFS/namei is not allowed in
  a `thread_call` context).
- Write path: `ValidationHook.cpp` and `SiteSet.cpp`.
- Design: [`../docs/USERSPACE-PATCHING.md`](../docs/USERSPACE-PATCHING.md).

Boot arguments: `-NRedUserPatchOff`, `-NRedUserPatchVDA`, `-NRedUserPatchDebug`.

Build (needs a sibling AppleForge checkout or `$AppleForgePath`):

```sh
xmake f -P . -m debug && xmake build --project=. NootedRedUserPatch
```

Host tests:

```sh
python3 test/test_analyzer.py    # 19 rules against the 15.8.2/26.7.2 fixtures
python3 test/test_site_set.py    # hook write/idempotence semantics
python3 test/test_block_reader.py    # 16 KiB block-cache cross-block regression
python3 test/test_fixture_probe.py   # 13/14/15/26 slots; missing fixtures are reserved
```
