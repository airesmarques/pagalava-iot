#!/bin/bash
set +x
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

fail() { printf '%s\n' "$*" >&2; exit 2; }
usage() { fail "Usage: $0 [--yes] list | prepare CASE | use CASE | publish COMMIT [main|release/NAME] | status | restore"; }
here=$(cd -P -- "$(dirname -- "$0")" && pwd)
expectations=$here/../../field_upgrade/expectations.tsv
unit=receive_messages.service
dropdir=/etc/systemd/system/$unit.d
dropin=$dropdir/90-fwtest.conf
marker='# Managed by the bench firmware upgrade script'
confirm=false
if [[ ${1:-} == --yes ]]; then
    confirm=true
    shift
fi
action=${1:-}
[[ $# -gt 0 ]] || usage
shift

case "$action" in
    list|status|restore) [[ $# == 0 ]] || usage ;;
    prepare|use) [[ $# == 1 ]] || usage ;;
    publish) [[ $# == 1 || $# == 2 ]] || usage ;;
    *) usage ;;
esac

if [[ $action == list ]]; then
    cat "$expectations"
    exit
fi

[[ $EUID != 0 ]] || fail "Run as the service user."
home=$(cd -P -- "$HOME" && pwd)
[[ $home == "$HOME" && $home =~ ^/[a-zA-Z0-9_./-]+$ && -O $home ]] ||
    fail "Expected the service user's physical home directory."
root=$home/fwtest
runs=$root/run
origin=$root/origin.git
query() { systemctl show --property="$1" --value "$unit"; }
safe_dir() {
    [[ ! -L $1 && ( ! -e $1 || ( -d $1 && -O $1 ) ) ]] ||
        fail "Unsafe directory in fwtest."
}
managed_dropin() {
    [[ ! -L $dropdir && ! -L $dropin ]] || fail "Unsafe systemd drop-in path."
    if [[ -e $dropin ]]; then
        [[ -f $dropin && $(head -n 1 "$dropin") == "$marker" ]] ||
            fail "The drop-in path is already in use."
    fi
}
[[ $(query User) == "$(id -un)" ]] || fail "Run as the configured service user."
fragment=$(query FragmentPath)
[[ $fragment == /* && -f $fragment ]] || fail "Cannot locate the original unit."
original=$(sed -n 's/^WorkingDirectory=//p' "$fragment")
[[ $original == "$home/"* && $original != "$root" && $original != "$root/"* &&
    $original =~ ^/[a-zA-Z0-9_./-]+$ ]] || fail "Unsafe original checkout path."
[[ $(cd -P -- "$original" && pwd) == "$original" ]] || fail "Cannot resolve the original checkout."

restart_at() {
    sudo -n systemctl daemon-reload
    [[ $(query WorkingDirectory) == "$1" ]] || fail "Effective service directory did not change as expected."
    sudo -n systemctl restart "$unit"
    systemctl is-active --quiet "$unit" || fail "Service is not active."
}

if [[ $action == restore ]]; then
    managed_dropin
    if [[ -e $dropin ]]; then
        sudo -n rm -f -- "$dropin"
    fi
    restart_at "$original"
    printf 'Restored %s\n' "$original"
    exit
fi

# Accept the stock installer/firstboot format. Check both sources because
# historical versions differ in precedence. Keep all parser inputs off argv.
dev_identity() {
    local value=${1#\"}
    value=${value%\"}
    [[ $value =~ ^HostName=([a-zA-Z0-9.-]+)\;DeviceId=[a-zA-Z0-9_.:%+-]+\;SharedAccessKey=[a-zA-Z0-9+/=]+$ &&
        ${BASH_REMATCH[1],,} == *-dev* ]]
}
check_identity() {
    local directory=$1 unit_env file_env property value parent
    for property in EnvironmentFiles PassEnvironment UnsetEnvironment; do
        value=$(query "$property") || fail "Cannot inspect the service environment."
        [[ -z $value ]] || fail "Unsupported service environment configuration."
    done
    unit_env=$(query Environment | awk '
        /IOT_CONNECTION_STRING/ {
            for (i = 1; i <= NF; i++)
                if ($i ~ /^IOT_CONNECTION_STRING=/) {
                    count++
                    value = substr($i, length("IOT_CONNECTION_STRING=") + 1)
                } else if ($i ~ /IOT_CONNECTION_STRING/) invalid = 1
        }
        END { if (count > 1 || invalid) exit 1; print value }
    ') || fail "Cannot validate the service identity."
    if [[ -n $unit_env ]]; then
        dev_identity "$unit_env" || fail "A DEV hub identity is required."
    fi
    file_env=
    if [[ -e $directory/.env || -L $directory/.env ]]; then
        [[ -f $directory/.env ]] || fail "Cannot validate the checkout identity."
        file_env=$(awk '
            /^[[:space:]]*(#|$)/ { next }
            /^IOT_CONNECTION_STRING=/ { count++; value = substr($0, length("IOT_CONNECTION_STRING=") + 1); next }
            { invalid = 1 }
            END { if (count != 1 || invalid) exit 1; print value }
        ' "$directory/.env") || fail "Cannot validate the checkout identity."
        dev_identity "$file_env" || fail "A DEV hub identity is required."
    else
        parent=$(dirname -- "$directory")
        while [[ $parent != / ]]; do
            [[ ! -e $parent/.env && ! -L $parent/.env ]] ||
                fail "Cannot use a checkout that may inherit an ancestor .env."
            parent=$(dirname -- "$parent")
        done
        [[ ! -e /.env && ! -L /.env ]] || fail "Cannot use a checkout that may inherit an ancestor .env."
    fi
    [[ -n $unit_env || -n $file_env ]] || fail "A DEV hub identity is required."
    validated_identity=${file_env:-$unit_env}
}

if [[ $action == status ]]; then
    live=$(query WorkingDirectory)
    printf 'Directory: %s\nState: %s\n' "$live" "$(query ActiveState)"
    if [[ -d $live/.git && ! -L $live/.git ]]; then
        printf 'Checkout commit: %s\n' "$(git -C "$live" rev-parse --verify HEAD)"
    else
        printf 'Checkout commit: unavailable (no Git metadata)\n'
    fi
    invocation=$(query InvocationID)
    if [[ $invocation =~ ^[[:xdigit:]]{32}$ ]]; then
        version=$(journalctl --no-pager -o cat "_SYSTEMD_INVOCATION_ID=$invocation" 2>/dev/null |
            sed -nE 's/^.*Running with version: ([0-9]+(\.[0-9]+)+)$/\1/p' | tail -n 1) || version=
    fi
    printf 'Running version: %s\n' "${version:-unconfirmed}"
    exit
fi

live=$(query WorkingDirectory)
[[ $live == "$original" || ( $live == "$runs/"* && $live =~ ^/[a-zA-Z0-9_./-]+$ &&
    $(cd -P -- "$live" && pwd) == "$live" ) ]] || fail "Unexpected live checkout."
check_identity "$original"
[[ $live == "$original" ]] || check_identity "$live"
live_identity=$validated_identity
safe_dir "$root"
safe_dir "$runs"

# Keep Git and dependency installation scoped to the fixtures and their venvs.
for variable in $(git rev-parse --local-env-vars); do
    unset "$variable"
done
unset GIT_CONFIG_SYSTEM GIT_CONFIG_GLOBAL GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
local_git() { git -c core.hooksPath=/dev/null "$@"; }

if [[ $action == publish ]]; then
    branch=${2:-main}
    case "$branch" in main|release/*) ;; *) fail "Expected main or release/NAME." ;; esac
    local_git check-ref-format "refs/heads/$branch" || fail "Invalid branch."
fi
safe_dir "$origin"
[[ -d $origin && $(local_git --git-dir="$origin" rev-parse --is-bare-repository) == true ]] ||
    fail "Set up the local bare origin under fwtest first."
origin_link=$(find "$origin" -type l -print -quit)
[[ -z $origin_link ]] || fail "Unsafe symlink inside the local origin."

if [[ $action == publish ]]; then
    [[ $1 =~ ^[[:xdigit:]]{7,40}$ ]] || fail "Expected an abbreviated or full commit ID."
    commit=$(local_git --git-dir="$origin" rev-parse --verify "$1^{commit}") || fail "Commit unavailable."
    ref=refs/heads/$branch
    old=$(local_git --git-dir="$origin" rev-parse --verify "$ref" 2>/dev/null) || old=
    if [[ -n $old && $old != "$commit" ]] &&
        ! local_git --git-dir="$origin" merge-base --is-ancestor "$old" "$commit"; then
        "$confirm" || fail "Rewriting the fixture branch requires --yes."
    fi
    local_git --git-dir="$origin" update-ref --no-deref "$ref" "$commit" "${old:-0000000000000000000000000000000000000000}"
    printf 'Published %s to local %s\n' "$commit" "$branch"
    exit
fi

[[ $1 =~ ^[0-9]+(\.[0-9]+)+(-[a-z]+)?$ ]] || fail "Invalid case name."
row=$(awk -F '\t' -v label="$1" '$1 == label {print}' "$expectations")
[[ -n $row ]] || fail "Unknown case. See list."
IFS=$'\t' read -r _ revision _ install_type _ <<< "$row"
checkout=$runs/$1
safe_dir "$checkout"

if [[ $action == use ]]; then
    [[ -f $checkout/.fwtest-ready && ! -L $checkout/.fwtest-ready &&
        -x $checkout/.venv/bin/python ]] || fail "Prepare this case first."
    check_identity "$checkout"
    managed_dropin
    dropins=$(query DropInPaths) || fail "Cannot inspect the service drop-ins."
    [[ -z $dropins || $dropins == "$dropin" ]] || fail "Other service drop-ins are active."
    sudo -n mkdir -p -- "$dropdir"
    if ! printf '%s\n[Service]\nWorkingDirectory=%s\nExecStart=\nExecStart=%s/.venv/bin/python %s/ReceiveMessages.py\nEnvironment="PATH=%s/.venv/bin"\n' \
        "$marker" "$checkout" "$checkout" "$checkout" "$checkout" |
        sudo -n tee "$dropin" >/dev/null; then
        sudo -n rm -f -- "$dropin"
        fail "Could not write the service drop-in."
    fi
    restart_at "$checkout"
    exit
fi

[[ $live != "$checkout" ]] || fail "Restore or switch away before preparing the active case."
commit=$(local_git --git-dir="$origin" rev-parse --verify "$revision^{commit}") || fail "Starting commit unavailable."
[[ -f $live/config.json ]] || fail "The live checkout needs a config.json."
if [[ -e $checkout ]]; then
    "$confirm" || fail "Replacing this fixture requires --yes."
    rm -rf -- "$checkout"
fi
mkdir -p -- "$checkout"
if [[ $install_type == image ]]; then
    local_git --git-dir="$origin" archive "$commit" | tar -xf - -C "$checkout"
    [[ ! -e $checkout/.update-channel && ! -L $checkout/.update-channel ]] ||
        fail "Firmware tree contains a reserved fixture path."
    printf 'release/1.9\n' > "$checkout/.update-channel"
else
    local_git clone --quiet --no-local --no-checkout "$origin" "$checkout"
    local_git -C "$checkout" switch --quiet -C main "$commit"
fi
for name in .env config.json .venv .fwtest-ready; do
    [[ ! -e $checkout/$name && ! -L $checkout/$name ]] || fail "Firmware tree contains a reserved fixture path."
done
if [[ -f $live/.env ]]; then
    cp -L -- "$live/.env" "$checkout/.env"
else
    printf 'IOT_CONNECTION_STRING=%s\n' "$live_identity" > "$checkout/.env"
fi
chmod 600 -- "$checkout/.env"
cp -L -- "$live/config.json" "$checkout/config.json"
chmod 600 -- "$checkout/config.json"
check_identity "$checkout"
mkdir -- "$checkout/.build-tmp"
export TMPDIR=$checkout/.build-tmp
python3 -m venv "$checkout/.venv"
"$checkout/.venv/bin/python" -m pip --isolated --disable-pip-version-check install --no-cache-dir \
    -r "$checkout/requirements.txt" >/dev/null 2>&1 || fail "Could not install the case requirements."
: > "$checkout/.fwtest-ready"
printf 'Prepared %s at %s\n' "$1" "$commit"
