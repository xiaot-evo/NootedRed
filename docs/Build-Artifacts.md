# Per-Branch Build Artifacts

Builds are separated by git branch so switching branches cannot overwrite another branch's kext or zip.

## Usage

```sh
tools/build-branch.sh -y
```

The script detects the current branch, sanitizes it, and invokes xmake with
`NRED_BUILD_BRANCH`. The main kext and the satellite kext land in sibling directories:

```text
build/branches/<branch>/<platform>/<arch>/<mode>/                 # NootedRed.kext
build/branches/<branch>/<platform>/<arch>/userpatch/<mode>/       # NootedRedUserPatch.kext
```

For example:

```text
build/branches/research-satellite-userpatch/macosx/x86_64/release/NootedRed.kext
build/branches/research-satellite-userpatch/macosx/x86_64/release/NootedRed-0.9.1-RELEASE-20261025-215000.zip
build/branches/research-satellite-userpatch/macosx/x86_64/userpatch/release/NootedRedUserPatch.kext
build/branches/research-satellite-userpatch/macosx/x86_64/userpatch/release/NootedRedUserPatch-0.9.1-RELEASE-20261025-215000.zip
```

CI (`.github/workflows/main.yml`) and the wrapper both glob the two locations; a single
`build/branches/*/*/*/*/*.zip` pattern would silently drop the satellite archive.

A detached HEAD uses `detached-<short-sha>`. To override:

```sh
NRED_BUILD_BRANCH=my-test tools/build-branch.sh -y
```

The wrapper appends the local build time to both archive names (`...-YYYYMMDD-HHMMSS.zip`), so repeated
default builds never silently overwrite each other. Direct `xmake -y` (without the wrapper) uses
`build/branches/shared/...` and keeps AppleForge's canonical archive name; the wrapper is the supported
interface for per-branch, timestamped output.

## Why

The kext and zip are versioned by branch (for example the 15.8.1 build and experiment branches).
Keeping them under one branch-specific directory avoids accidentally installing or sharing a kext
from another branch.
