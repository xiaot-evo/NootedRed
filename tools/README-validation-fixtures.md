# Target-macOS validation fixture collector

`collect_validation_fixtures.py` runs **on the macOS version you want to test** and copies the
files needed by the two parsers:

- user-space parser: dyld shared cache, `.map`, and standalone AMD GL/Metal/VDA driver bundles;
- VCN runtime resolver: `SystemKernelExtensions.kc` containing X5000/X6000 symbols and vtables.

It does not load kexts, patch anything, or require root. The resulting directory contains a manifest
with macOS build, Darwin version, hardware ID, file sizes and SHA-256 hashes.

## Usage

```sh
python3 collect_validation_fixtures.py
python3 collect_validation_fixtures.py --out ~/Desktop/nred-validation --zip
python3 collect_validation_fixtures.py --map-only
python3 collect_validation_fixtures.py --no-drivers
```

- Default: kernel collection + full dyld cache + standalone AMD driver bundles.
- `--map-only`: only `dyld_shared_cache_x86_64h.map`; enough for symbol/offset inspection, not enough
  to validate the full user-space parser.
- `--no-drivers`: skip standalone `AMDRadeonX5000*` / `AMDRadeonX6000*` bundles.
- `--zip`: create a zip next to the output directory for transfer.

## What gets copied

```text
System/Library/CoreServices/SystemVersion.plist
System/Library/KernelCollections/*.kc
System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_x86_64h*
System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/...
System/Library/Extensions/AMDRadeonX5000MTLDriver.bundle/...
System/Library/Extensions/AMDRadeonX5000VADriver.bundle/...
System/Library/Extensions/AMDRadeonX5000.kext/...
System/Library/Extensions/AMDRadeonX6000.kext/...
System/Library/Extensions/AMDRadeonX6000Framebuffer.kext/...
manifest.json
```

The kernel collection can be several hundred MB and the dyld cache can be multiple GB. Use
`--map-only` when only the VCN/kernel metadata is needed.

## Validation mapping

| Fixture | Parser test |
| --- | --- |
| `SystemKernelExtensions.kc` | VCNRuntimeResolver: symbols, vtable slots, call boundaries |
| `dyld_shared_cache_x86_64h` + `.map` | user-space parser: image ranges and Mach-O extraction |
| `AMDRadeonX5000GLDriver.bundle` | GL driver Mach-O parse |
| `AMDRadeonX5000MTLDriver.bundle` | Metal driver page/symbol search |
| `SystemVersion.plist` | exact build/profile matching |

Do not commit the collected Apple binaries; the output directory/zip is for local analysis only.
