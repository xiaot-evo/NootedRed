# Synthetic cross-engine vectors (NRPT v1)

These files are synthetic (no Apple bytes; both pages are deterministic byte patterns). They were
produced by `kext-engineer`'s independent C++ harness (`/tmp/pptest/gen_golden.py` + `test_main.cpp`,
which compiles the real `NootedRedUserPatch/PatchProfile.cpp` against stubs and ran **56 scenarios, 0
failures**), and are committed here as a cross-implementation conformance check for the independent
Python validator.

| File | Meaning |
| --- | --- |
| `golden.nrpt` | 232-byte NRPT v1 profile, 2 pages / 3 sites, build `24H232`, apuMask `0x20` (Green Sardine), deviceID `0x1638` + `REQUIRE_DEVICE_ID` |
| `golden.page0.bin` | clean 4 KiB page 0 (`pageFileOffset 0x8000`, `matchFlags 0x0007`) |
| `golden.page1.bin` | clean 4 KiB page 1 (`pageFileOffset 0x9000`, `matchFlags 0x0006`, hash-only) |
| `golden.page0.patched.bin` / `golden.page1.patched.bin` | the exact engine output after applying the profile to those pages |

The Python validator must:

1. decode `golden.nrpt` to the same model as the reference `ProfileCodec`,
2. apply page 0 and page 1 through the spec §8 algorithm and reproduce
   `golden.pageN.patched.bin` **byte for byte**,
3. return `alreadyApplied` on a repeat delivery and write nothing.

Page 1 has no `REQUIRE_OFFSET`; the recorded `pageFileOffset` must not be used as an identity gate
there. Page 0 is offset-gated. This covers both identity modes.
