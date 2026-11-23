#!/usr/bin/env bash
set -euo pipefail
rig=$(cd "$(dirname "$0")" && pwd)
cd "$rig/../.."
policy=nopasswd
while (($#)); do
    if (($# < 2)); then
        echo "Missing value for $1" >&2
        exit 2
    fi
    case "$1" in
        --from) start=$2 ;;
        --target) target=$2 ;;
        --os) os=$2 ;;
        --sudo) policy=$2 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift 2
done
case "${os:-}" in 11|12|13) ;; *) echo "Use --os 11|12|13" >&2; exit 2 ;; esac
case "$policy" in nopasswd|password) ;; *) echo "Use --sudo nopasswd|password" >&2; exit 2 ;; esac
row=$(awk -v label="${start:?Use --from CASE}" '$1 == label {print}' "$rig/expectations.tsv")
[[ -n $row ]] || { echo "Unknown case: $start" >&2; exit 2; }
IFS=$'\t' read -r _ revision version install oses expected _ <<< "$row"
[[ ,$oses, == *",$os,"* ]] || { echo "Case $start does not cover Debian $os" >&2; exit 2; }
target=$(git rev-parse --verify --end-of-options "${target:?Use --target COMMIT}^{commit}")
source=$(git rev-parse --verify "${revision}^{commit}")
requirements=$(git rev-parse "$source:requirements.txt")
if [[ ${FIELD_UPGRADE_PREBUILT:-0} != 1 ]]; then
    "$rig/build.sh" "$os"
fi
printf '%s\n' "$source" "$target" 61b7afa | git pack-objects --stdout --revs |
    docker run --rm -i --network none --pull never "field-upgrade-rig:$os" \
        /bin/bash /rig/device.sh "$revision" "$source" "$target" "$policy" "$os" \
        "$version" "$install" "$expected" "$requirements"
