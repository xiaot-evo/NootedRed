# Per-Branch Build Artifacts

Builds are separated by git branch so switching branches cannot overwrite another branch's kext or zip.

## Usage

```sh
tools/build-branch.sh -y
```

The script detects the current branch, sanitizes it, and invokes xmake with
`NRED_BUILD_BRANCH`. Artifacts land under:

```text
build/branches/<branch>/<platform>/<arch>/<mode>/
```

For example:

```text
build/branches/feature-tahoe-26.7.1/macosx/x86_64/release/NootedRed.kext
build/branches/feature-tahoe-26.7.1/macosx/x86_64/release/NootedRed-0.9.0-RELEASE.zip
```

A detached HEAD uses `detached-<short-sha>`. To override:

```sh
NRED_BUILD_BRANCH=my-test tools/build-branch.sh -y
```

Direct `xmake -y` (without the wrapper) uses `build/branches/shared/...`; the wrapper is the supported
interface for per-branch output.

## Why

The kext and zip are versioned by branch (for example the stable 15.8.1 build and the experimental
26.7.1/VDA builds). Keeping them under one branch-specific directory avoids accidentally installing or
sharing a kext from another branch.
