#!/usr/bin/env bash
# NRPT v3 offline validation runner for NootedRedUserPatch profiles and NRedProfiles bundles.
#
# 1. Runs the synthetic unit-test suite (no Apple binaries; deterministic fixtures).
# 2. If an NRPT v3 profile (or NRedProfiles bundle) is supplied, selects/decodes it, applies it
#    to the clean fixture exactly like the hook engine (PAGE route / DYLD range route, optional
#    vnode gate, full-page FNV-1a-64 + all site finds identity, no offset identity, applied-once,
#    already-patched pass), re-resolves the image metadata, reports per-page/per-site results,
#    rejects false positives, and writes a JSON report.
#
# The host's Apple binaries are read in place and never copied or committed.
#
# Usage:
#   test/run-validation.sh [profile.nrpt]
#
# Environment:
#   NRPT_PROFILE         profile path (alternative to $1); NRPT v3 only
#   NRPT_BUNDLE          NRedProfiles bundle plist path (alternative to a single profile)
#   FIXTURES             clean fixture root (required for an extracted fixture tree; default: /)
#   NRPT_REPORT          JSON report path (default: <repo>/build/validation-report.json)
#   NRPT_EXPECTED_BUILD  expected build string (default: sw_vers -buildVersion)
#   NRPT_DEVICE_ID       running iGPU PCI device ID, e.g. 0x1638 (optional but recommended)
#   NRPT_EXTRA_IMAGES    space-separated extra candidate image paths (optional)
#
# Exit code: 0 = all checks PASS; nonzero = failure (see output).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="${PYTHON:-python3}"

PROFILE="${1:-${NRPT_PROFILE:-}}"
BUNDLE="${NRPT_BUNDLE:-}"
FIXTURES="${FIXTURES:-/}"
REPORT="${NRPT_REPORT:-${ROOT}/build/validation-report.json}"
EXPECTED_BUILD="${NRPT_EXPECTED_BUILD:-}"
DEVICE_ID="${NRPT_DEVICE_ID:-}"

if [[ -z "${EXPECTED_BUILD}" ]] && command -v sw_vers >/dev/null 2>&1; then
    EXPECTED_BUILD="$(sw_vers -buildVersion 2>/dev/null || true)"
fi

echo "== NRPT validator unit tests =="
"${PYTHON}" "${ROOT}/test/test_nrpt_validator.py"

if [[ -z "${PROFILE}" && -z "${BUNDLE}" ]]; then
    echo
    echo "No profile supplied: unit tests only."
    echo "Pass a v3 profile path (or NRPT_PROFILE=...), or NRPT_BUNDLE=<plist>, to validate."
    exit 0
fi

if [[ -n "${BUNDLE}" ]]; then
    if [[ ! -f "${BUNDLE}" ]]; then
        echo "error: bundle not found: ${BUNDLE}" >&2
        exit 2
    fi
    ARGS=(
        --bundle-plist "${BUNDLE}"
        --fixtures "${FIXTURES}"
        --report "${REPORT}"
        --mutation-sweep
    )
else
    if [[ ! -f "${PROFILE}" ]]; then
        echo "error: profile not found: ${PROFILE}" >&2
        exit 2
    fi
    ARGS=(
        --profile "${PROFILE}"
        --fixtures "${FIXTURES}"
        --report "${REPORT}"
        --mutation-sweep
    )
fi
if [[ -n "${EXPECTED_BUILD}" ]]; then
    ARGS+=(--expected-build "${EXPECTED_BUILD}")
fi
if [[ -n "${DEVICE_ID}" ]]; then
    ARGS+=(--device-id "${DEVICE_ID}")
fi
if [[ -n "${NRPT_EXTRA_IMAGES:-}" ]]; then
    # shellcheck disable=SC2206  # intentional word splitting of the explicit list
    for extra in ${NRPT_EXTRA_IMAGES}; do
        ARGS+=(--image "${extra}")
    done
fi

echo
echo "== NRPT offline validation against clean fixture (${FIXTURES}) =="
"${PYTHON}" "${ROOT}/test/nrpt_validator.py" "${ARGS[@]}"
