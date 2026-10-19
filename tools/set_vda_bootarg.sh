#!/bin/bash
# Safely show/add/remove the -NRedVDA token in the OpenCore NVRAM boot-args.
# Usage:
#   tools/set_vda_bootarg.sh --show
#   tools/set_vda_bootarg.sh --add
#   tools/set_vda_bootarg.sh --remove
#   tools/set_vda_bootarg.sh --esp "/Volumes/NO NAME" --show
# The config.plist is backed up to build/efi-backup/ before any change and lint-checked afterwards.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ESP="/Volumes/NO NAME"
CONFIG_KEY=":NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args"
ACTION="show"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --esp) ESP="${2:-}"; shift 2 ;;
        --add) ACTION="add"; shift ;;
        --remove) ACTION="remove"; shift ;;
        --show) ACTION="show"; shift ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

CONFIG="${ESP}/EFI/OC/config.plist"
if [[ ! -f "${CONFIG}" ]]; then
    echo "missing OpenCore config: ${CONFIG}" >&2
    exit 1
fi
if ! command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    echo "PlistBuddy not found" >&2
    exit 1
fi

SUDO=""
if [[ ! -w "${CONFIG}" ]]; then
    SUDO="sudo"
fi

CURRENT="$(${SUDO} /usr/libexec/PlistBuddy -c "Print ${CONFIG_KEY}" "${CONFIG}")"
echo "current boot-args: ${CURRENT}"

if [[ "${ACTION}" == "show" ]]; then
    if echo "${CURRENT}" | grep -q -- '-NRedVDA'; then
        echo "-NRedVDA: enabled in OpenCore config"
        exit 0
    fi
    echo "-NRedVDA: absent from OpenCore config"
    exit 1
fi

# Normalize the token list, preserving all other arguments and their order.
NEW="${CURRENT}"
if [[ "${ACTION}" == "add" ]]; then
    if echo "${NEW}" | grep -q -- '-NRedVDA'; then
        echo "-NRedVDA already present; nothing to do"
        exit 0
    fi
    NEW="${NEW} -NRedVDA"
else
    NEW="$(echo "${NEW}" | sed -E 's/(^| )-NRedVDA( |$)/ /g' | tr -s ' ' | sed 's/^ //; s/ $//')"
fi
NEW="$(echo "${NEW}" | sed 's/  */ /g; s/^ //; s/ $//')"

STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "${ROOT}/build/efi-backup"
BACKUP="${ROOT}/build/efi-backup/config-${STAMP}.plist"
suffix=1
while [[ -e "${BACKUP}" ]]; do
    BACKUP="${ROOT}/build/efi-backup/config-${STAMP}-${suffix}.plist"
    suffix=$((suffix + 1))
done
${SUDO} cp "${CONFIG}" "${BACKUP}"
echo "backup: ${BACKUP}"
echo "new boot-args: ${NEW}"

${SUDO} /usr/libexec/PlistBuddy -c "Set ${CONFIG_KEY} ${NEW}" "${CONFIG}"
plutil -lint "${CONFIG}" >/dev/null
VERIFY="$(${SUDO} /usr/libexec/PlistBuddy -c "Print ${CONFIG_KEY}" "${CONFIG}")"
if [[ "${VERIFY}" != "${NEW}" ]]; then
    echo "verification failed: ${VERIFY}" >&2
    echo "restore ${BACKUP} to ${CONFIG}" >&2
    exit 1
fi
echo "updated and verified; reboot for the change to take effect"
