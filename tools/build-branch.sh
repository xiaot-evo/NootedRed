#!/bin/sh
# Build the kext into a per-branch artifact directory.
#
# Usage: tools/build-branch.sh [xmake args...]
# Example: tools/build-branch.sh -y
#          tools/build-branch.sh -m debug -y
#
# The branch name comes from NRED_BUILD_BRANCH, or git. A detached HEAD uses
# detached-<short-sha>. Artifacts land under:
#   build/branches/<branch>/<platform>/<arch>/<mode>/
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ -n "${NRED_BUILD_BRANCH:-}" ]; then
    BRANCH=$NRED_BUILD_BRANCH
else
    BRANCH=$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
        BRANCH=detached-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
    fi
fi

# Match the sanitization in xmake.lua.
BRANCH=$(printf '%s' "$BRANCH" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')
[ -n "$BRANCH" ] || BRANCH=unknown
export NRED_BUILD_BRANCH=$BRANCH

echo "branch: $BRANCH"
echo "artifacts: $ROOT/build/branches/$BRANCH"
exec xmake -P "$ROOT" "$@"
