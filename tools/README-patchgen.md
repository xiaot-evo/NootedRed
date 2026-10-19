# Page-image patch data generator

`gen_patch_data.py` turns a JSON spec into the C++ page images and
`UserPatches::PagePatch`/`PatchSet` entries for one macOS build.

It does **not** guess offsets. The spec must supply the page offset/VA and the
exact find/replace bytes for that build.

## Requirements

- Run on the target macOS install, with the **unmodified** `AMDRadeonX5000GLDriver`
  bundle and dyld shared cache available.
- If the driver was already patched (for example by an earlier test), restore a
  pristine copy first; the generator will otherwise find already-patched bytes
  and correctly fail its `skip`/`count` validation.

## Spec format

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
      "name": "MTLControlPage",
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

`find`/`replace` are hex strings. The page image is always read as one 4 KiB page.

## Usage

```sh
python3 tools/gen_patch_data.py spec.json --out /tmp/new-set.cpp
```

Add the generated arrays and `kGeneratedPatches` to `NootedRed/UserPatches.cpp`,
then add its `PatchSet` to `kGLDriverPatchSets` with the correct Darwin
`major.minor` and APU mask. See `analysis/multi-os-multi-apu.md`.

## Safety

- Each find is validated in the extracted page before output.
- A generated set is still gated by the runtime exact-page match; a mismatched
  build is a no-op.
- New APU families need testing; do not infer support only from a matching page.
