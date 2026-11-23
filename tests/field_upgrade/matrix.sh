#!/usr/bin/env bash
set -euo pipefail
rig=$(cd "$(dirname "$0")" && pwd)
cd "$rig/../.."
logs=${1:-field-upgrade-logs}
target=$(git rev-parse --verify --end-of-options "${2:-HEAD}^{commit}")
oses=(11 12 13)
if [[ -n ${3:-} ]]; then
    case $3 in 11|12|13) oses=("$3") ;; *) exit 2 ;; esac
fi
mkdir -p "$logs"
summary=$logs/summary.md
{
    printf '# Field upgrades to %s\n\n' "$target"
    printf '| Debian | Origin | Sudo | Expected first hop | Result | Onward hop |\n'
    printf '| --- | --- | --- | --- | --- | --- |\n'
} > "$summary"
failed=0
passed=0
for os in "${oses[@]}"; do
    if ! "$rig/build.sh" "$os" >"$logs/build-$os.log" 2>&1; then
        printf '| %s | All | | | Image build failed | |\n' "$os" >> "$summary"
        tail -n 25 "$logs/build-$os.log"
        failed=$((failed + 1))
        continue
    fi
    while IFS=$'\t' read -r start _ _ install supported expected _; do
        [[ $start == \#* ]] && continue
        [[ ,$supported, == *",$os,"* ]] || continue
        policies=(nopasswd password)
        [[ $install != image ]] || policies=(nopasswd)
        for policy in "${policies[@]}"; do
            log="$os-$start-$policy.log"
            if FIELD_UPGRADE_PREBUILT=1 "$rig/run.sh" --os "$os" --from "$start" \
                --target "$target" --sudo "$policy" >"$logs/$log" 2>&1; then
                result=PASS
                onward=$(sed -n 's/^ONWARD //p' "$logs/$log")
                passed=$((passed + 1))
            else
                result=FAIL
                onward='—'
                tail -n 20 "$logs/$log"
                failed=$((failed + 1))
            fi
            printf '| %s | %s | %s | %s | [%s](%s) | %s |\n' \
                "$os" "$start" "$policy" "$expected" "$result" "$log" "$onward" >> "$summary"
        done
    done < "$rig/expectations.tsv"
done
printf '\nMatrix: %d passed, %d failed\n' "$passed" "$failed" | tee -a "$summary"
((failed == 0))
