#!/usr/bin/env bash
set -euo pipefail
rig=$(cd "$(dirname "$0")" && pwd)
cd "$rig/../.."
case "${1:-}" in
    11) debian=bullseye ;;
    12) debian=bookworm ;;
    13) debian=trixie ;;
    *) echo "Usage: $0 11|12|13" >&2; exit 2 ;;
esac
context=$(mktemp -d "$PWD/.field-upgrade-build.XXXXXX")
trap 'rm -rf "$context"' EXIT
mkdir "$context/rig"
cp "$rig/Dockerfile" "$context/"
cp "$rig/"{device.sh,probe.py,observe-git.sh,record-command.sh} "$context/rig/"
while read -r label revision _; do
    [[ $label == \#* ]] && continue
    blob=$(git rev-parse "$revision:requirements.txt")
    git show "$blob" > "$context/requirements-$blob"
done < "$rig/expectations.tsv"
docker build -t "field-upgrade-rig:$1" --build-arg "DEBIAN=$debian" "$context"
