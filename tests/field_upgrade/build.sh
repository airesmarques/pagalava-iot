#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
case "${1:-}" in
    11) debian=bullseye ;;
    12) debian=bookworm ;;
    *) echo "Usage: $0 11|12" >&2; exit 2 ;;
esac
context=$(mktemp -d "$PWD/.field-upgrade-build.XXXXXX")
trap 'rm -rf "$context"' EXIT
cp tests/field_upgrade/Dockerfile "$context/"
for revision in 653acde e2c69ea 613476b 1fefd13 0d02b65; do
    git show "${revision}:requirements.txt" > "$context/requirements-$revision"
done
docker build -t "field-upgrade-rig:$1" --build-arg "DEBIAN=$debian" "$context"
