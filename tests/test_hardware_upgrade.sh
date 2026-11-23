#!/bin/bash
# Run inside the disposable Linux unit job as root.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tool=$here/hardware/upgrade_matrix/bench.sh
shellcheck "$tool" "$0"
[[ $EUID == 0 ]] || { echo "Run this test in a disposable root container."; exit 2; }

unitdir=/etc/systemd/system/receive_messages.service.d
[[ ! -e $unitdir && ! -L $unitdir ]] || { echo "A real service drop-in directory exists."; exit 2; }
fixture=$(mktemp -d)
sudoers=/etc/sudoers.d/bench-upgrade-fixture
[[ ! -e $sudoers && ! -L $sudoers ]] || exit 2
trap 'rm -rf "$fixture" "$unitdir"; rm -f "$sudoers"' EXIT
install -m 0440 /dev/null "$sudoers"
echo 'nobody ALL=(root) NOPASSWD: ALL' > "$sudoers"
home=$fixture/home
original=$home/live
kit=$fixture/kit
origin=$home/fwtest/origin.git
dropin=$unitdir/90-fwtest.conf
mkdir -p "$original" "$home/archive" "$home/fwtest" "$kit/hardware/upgrade_matrix" "$kit/field_upgrade"
cp "$tool" "$kit/hardware/upgrade_matrix/"
tool=$kit/hardware/upgrade_matrix/bench.sh

git init -qb main "$fixture/source"
git -C "$fixture/source" config user.name Fixture
git -C "$fixture/source" config user.email fixture@example.invalid
touch "$fixture/source/requirements.txt" "$fixture/source/ReceiveMessages.py"
git -C "$fixture/source" add .
git -C "$fixture/source" commit -qm initial
start=$(git -C "$fixture/source" rev-parse HEAD)
git -C "$fixture/source" commit --allow-empty -qm target
target=$(git -C "$fixture/source" rev-parse HEAD)
git clone --quiet --bare "$fixture/source" "$origin"
printf '1.7\t%s\t1.7\tgit\t12\tauto\tFixture\t-\n1.9-image\t%s\t1.9\timage\t12\treflash\tFixture\t-\n' \
    "$start" "$start" > "$kit/field_upgrade/expectations.tsv"

printf 'WorkingDirectory=%s\n' "$original" > "$fixture/unit"
echo "$original" > "$fixture/live"
echo '{}' > "$original/config.json"
echo archive > "$home/archive/keep"
printf -v dev 'HostName=%s;DeviceId=%s;SharedAccessKey=%s' fixture-dev.example.invalid fixture Zml4dHVyZQ==
printf -v prod 'HostName=%s;DeviceId=%s;SharedAccessKey=%s' fixture.example.invalid fixture Zml4dHVyZQ==
printf 'IOT_CONNECTION_STRING="%s"\n' "$dev" > "$original/.env.dev"
ln -s .env.dev "$original/.env"
printf 'PATH=/fixture/.venv/bin "IOT_CONNECTION_STRING=%s"\n' "$dev" > "$fixture/environment"
cat > "$fixture/standins" <<'STUB'
sudo() {
    [[ $1 == -n ]] || return 1
    if [[ $2 == systemctl ]]; then
        shift 2
        systemctl "$@"
    else
        command sudo "$@"
    fi
}
systemctl() {
    case "$1" in
        show)
            case "$2" in
                --property=User) echo nobody ;;
                --property=FragmentPath) echo "$FIXTURE/unit" ;;
                --property=WorkingDirectory) cat "$FIXTURE/live" ;;
                --property=Environment) cat "$FIXTURE/environment" ;;
                --property=EnvironmentFiles|--property=PassEnvironment|--property=UnsetEnvironment) ;;
                --property=DropInPaths) if sudo -n test -f "$DROPIN"; then echo "$DROPIN"; fi ;;
                --property=ActiveState) echo active ;;
                --property=InvocationID) echo 11111111111111111111111111111111 ;;
                *) return 1 ;;
            esac ;;
        daemon-reload)
            if sudo -n test -f "$DROPIN"; then
                sudo -n sed -n 's/^WorkingDirectory=//p' "$DROPIN" > "$FIXTURE/live"
            else
                sed -n 's/^WorkingDirectory=//p' "$FIXTURE/unit" > "$FIXTURE/live"
            fi ;;
        restart)
            echo restart >> "$FIXTURE/events"
            [[ ! -e $FIXTURE/restart-fails ]] ;;
        is-active) ;;
        *) return 1 ;;
    esac
}
journalctl() {
    echo 'INFO Running with version: 1.7'
    cat "$FIXTURE/environment"
}
STUB
chown -R nobody "$fixture"
bench() {
    runuser -u nobody -- env HOME="$home" FIXTURE="$fixture" DROPIN="$dropin" \
        BASH_ENV="$fixture/standins" "$tool" "$@"
}
reject() {
    local message=$1
    shift
    if bench "$@" > "$fixture/output" 2>&1; then
        printf 'Unexpected success: %s\n' "$*" >&2
        exit 1
    fi
    grep -Fq "$message" "$fixture/output" || { cat "$fixture/output"; exit 1; }
    if grep -Eq 'HostName=|SharedAccessKey=' "$fixture/output"; then exit 1; fi
}

bench list | grep -q '1.9-image'
reject 'requires --yes' publish "$start"
bench --yes publish "$start"
bench prepare 1.7
checkout=$home/fwtest/run/1.7
[[ $(git -c safe.directory="$checkout" -C "$checkout" rev-parse HEAD) == "$start" ]]
cmp "$checkout/.env" "$original/.env"
cmp "$checkout/config.json" "$original/config.json"
[[ ! -L $checkout/.env ]]
reject 'requires --yes' prepare 1.7
bench --yes prepare 1.7
bench use 1.7
[[ $(cat "$fixture/live") == "$checkout" ]]
[[ $(stat -c '%u:%a' "$unitdir") == 0:755 ]]
[[ $(stat -c '%u:%a' "$dropin") == 0:644 ]]
if grep -Eq 'HostName=|SharedAccessKey=' "$dropin"; then exit 1; fi
reject 'active case' --yes prepare 1.7
bench publish "$target"
bench publish "$start" release/fixture
[[ $(git -c safe.directory="$origin" --git-dir="$origin" rev-parse main) == "$target" ]]
[[ $(git -c safe.directory="$origin" --git-dir="$origin" rev-parse release/fixture) == "$start" ]]
bench status > "$fixture/output"
grep -Fx "Directory: $checkout" "$fixture/output"
grep -Fx 'State: active' "$fixture/output"
grep -Fx 'Invocation: 11111111111111111111111111111111' "$fixture/output"
grep -Fx "Checkout commit: $start" "$fixture/output"
grep -Fx 'Running version: 1.7' "$fixture/output"
if grep -Eq 'HostName=|SharedAccessKey=' "$fixture/output"; then exit 1; fi
restore_case() {
    local label=$1 before
    before=$(wc -l < "$fixture/events")
    echo "Restore case: $label"
    bench restore
    [[ ! -e $dropin && $(cat "$fixture/live") == "$original" ]]
    [[ $(wc -l < "$fixture/events") == $((before + 1)) ]]
}

chmod 0700 "$unitdir"
chmod 0600 "$dropin"
[[ -f $dropin ]]
runuser -u nobody -- test ! -e "$dropin"
restore_case 'legacy root-only drop-in'
[[ ! -e $unitdir ]]

mkdir -m 0700 "$unitdir"
touch "$unitdir/unrelated.conf"
restore_case 'drop-in absent, unrelated file present'
[[ -f $unitdir/unrelated.conf ]]
rm "$unitdir/unrelated.conf"

restore_case 'drop-in directory empty'
[[ ! -e $unitdir ]]

restore_case 'drop-in directory absent'
[[ ! -e $unitdir ]]
bench prepare 1.9-image
image=$home/fwtest/run/1.9-image
[[ ! -e $image/.git ]]
bench use 1.9-image
bench status | grep -F 'no Git metadata'
bench restore

printf 'IOT_CONNECTION_STRING=%s\n' "$prod" > "$fixture/environment"
reject 'DEV hub' prepare 1.7
reject 'DEV hub' use 1.7
reject 'DEV hub' publish "$target"
printf 'PATH=/fixture/.venv/bin "IOT_CONNECTION_STRING=%s"\n' "$dev" > "$fixture/environment"
printf 'IOT_CONNECTION_STRING=%s\n' "$prod" > "$checkout/.env"
reject 'DEV hub' use 1.7
cp "$original/.env" "$checkout/.env"
printf 'IOT_CONNECTION_STRING=%s\n' "$prod" > "$original/.env.dev"
reject 'DEV hub' prepare 1.7
reject 'DEV hub' use 1.7
printf 'IOT_CONNECTION_STRING=%s\n' "$dev" > "$original/.env.dev"

reject 'Invalid case' --yes prepare ../../archive
reject 'Expected main or release' publish "$target" ../../archive
mv "$image" "$image.saved"
ln -s "$home/archive" "$image"
reject 'Unsafe directory' --yes prepare 1.9-image
reject 'Unsafe directory' use 1.9-image
mv "$home/fwtest/run" "$home/fwtest/run.saved"
ln -s "$home/archive" "$home/fwtest/run"
reject 'Unsafe directory' --yes prepare 1.7
rm "$home/fwtest/run"
mv "$home/fwtest/run.saved" "$home/fwtest/run"
mv "$origin" "$origin.saved"
ln -s "$home/archive" "$origin"
reject 'Unsafe directory' publish "$target"
rm "$origin"
mv "$origin.saved" "$origin"
ln -s "$home/archive" "$origin/refs/heads/outside"
reject 'Unsafe symlink' publish "$target"
rm "$origin/refs/heads/outside"

mkdir -m 0700 "$unitdir"
ln -s "$home/archive/keep" "$dropin"
reject 'Unsafe systemd drop-in' use 1.7
reject 'Unsafe systemd drop-in' restore
rm "$dropin"
echo unrelated > "$dropin"
reject 'already in use' use 1.7
reject 'already in use' restore
[[ $(cat "$dropin") == unrelated ]]
rm "$dropin"
rmdir "$unitdir"
touch "$fixture/restart-fails"
if bench use 1.7; then
    echo 'Unexpected successful restart' >&2
    exit 1
fi
rm "$fixture/restart-fails"
# Restoring remains possible even if the failed fixture has changed identity.
printf 'IOT_CONNECTION_STRING=%s\n' "$prod" > "$checkout/.env"
bench restore
bench restore
[[ ! -e $dropin && $(cat "$fixture/live") == "$original" ]]
[[ $(cat "$home/archive/keep") == archive ]]
echo 'Bench tooling fixture passed'
