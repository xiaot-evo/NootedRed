#!/usr/bin/env bash
# NRPT v1 offline validation runner for NootedRedUserPatch profiles.
#
# 1. Runs the synthetic unit-test suite (no Apple binaries; deterministic fixtures).
# 2. If an NRPT profile is supplied, applies it to the CLEAN host fixture exactly like the
#    kext (offset gate + full 4 KiB FNV-1a-64 + all site finds + replace writes), reports
#    per-page/per-site results, rejects false positives, and writes a JSON report.
#
# The host's Apple binaries are read in place and never copied or committed.
#
# Usage:
#   test/run-validation.sh [profile.nrpt]
#
# Environment:
#   NRPT_PROFILE         profile path (alternative to $1); NRPT v1 and v2 are auto-detected
#                        (v2 profiles additionally need FIXTURES pointing at the clean fixture tree)
#   FIXTURES             fixture root (default: /)
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
FIXTURES="${FIXTURES:-/}"
REPORT="${NRPT_REPORT:-${ROOT}/build/validation-report.json}"
EXPECTED_BUILD="${NRPT_EXPECTED_BUILD:-}"
DEVICE_ID="${NRPT_DEVICE_ID:-}"

if [[ -z "${EXPECTED_BUILD}" ]] && command -v sw_vers >/dev/null 2>&1; then
    EXPECTED_BUILD="$(sw_vers -buildVersion 2>/dev/null || true)"
fi

echo "== NRPT validator unit tests =="
"${PYTHON}" "${ROOT}/test/test_nrpt_validator.py"

if [[ -z "${PROFILE}" ]]; then
    echo
    echo "No profile supplied: unit tests only."
    echo "Pass a profile path (or NRPT_PROFILE=...) to validate it against a clean fixture."
    exit 0
fi

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
