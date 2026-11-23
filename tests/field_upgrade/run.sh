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
case "${start:-}" in
    1.3) revision=653acde ;;
    1.7) revision=e2c69ea ;;
    1.8-plain) revision=613476b ;;
    1.8-rollback) revision=1fefd13 ;;
    1.7.1) revision=0d02b65 ;;
    *) echo "Use --from 1.3|1.7|1.8-plain|1.8-rollback|1.7.1" >&2; exit 2 ;;
esac
case "${os:-}" in 11|12) ;; *) echo "Use --os 11|12" >&2; exit 2 ;; esac
case "$policy" in nopasswd|password) ;; *) echo "Use --sudo nopasswd|password" >&2; exit 2 ;; esac
target=$(git rev-parse --verify --end-of-options "${target:?Use --target COMMIT}^{commit}")
source=$(git rev-parse "${revision}^{commit}")
if ! docker image inspect "field-upgrade-rig:$os" >/dev/null 2>&1; then
    "$rig/build.sh" "$os"
fi
printf '%s\n' "$source" "$target" 61b7afa | git pack-objects --stdout --revs |
    docker run --rm -i --network none --pull never -v "$rig:/rig:ro" "field-upgrade-rig:$os" \
        /bin/bash /rig/device.sh "$revision" "$source" "$target" "$policy" "$os"
