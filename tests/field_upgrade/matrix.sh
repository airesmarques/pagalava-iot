#!/usr/bin/env bash
set -euo pipefail
rig=$(cd "$(dirname "$0")" && pwd)
cd "$rig/../.."
logs=${1:-field-upgrade-logs}
mkdir -p "$logs"
failed=0
passed=0
for os in 11 12; do
    for start in 1.3 1.7 1.8-plain 1.8-rollback 1.7.1; do
        for target in 0d02b65 61b7afa; do
            for policy in nopasswd password; do
                log="$logs/$os-$start-$target-$policy.log"
                if "$rig/run.sh" --os "$os" --from "$start" --target "$target" --sudo "$policy" >"$log" 2>&1; then
                    printf 'PASS %s\n' "$log"
                    grep -E '^RESULT |^RESTART IMPORT ' "$log"
                    passed=$((passed + 1))
                else
                    printf 'FAIL %s\n' "$log"
                    tail -n 15 "$log"
                    failed=$((failed + 1))
                fi
            done
        done
    done
done
printf 'Matrix: %d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
