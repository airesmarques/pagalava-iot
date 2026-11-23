#!/bin/bash
# Probe the actual Bash script descriptor at the moment Git replaces the path.
set -euo pipefail
git=/usr/bin/git.real
if [[ ${1:-} != reset || ${2:-} != --hard || ${3:-} != origin/main ]]; then
    exec "$git" "$@"
fi

script=update_pagalava.sh
fd=/proc/$PPID/fd/255
[[ $fd -ef $script ]]
offset=$(/bin/sed -n 's/^pos:[[:space:]]*//p' "/proc/$PPID/fdinfo/255")
old=$("$git" hash-object "$fd")
expected_old=$("$git" rev-parse "HEAD:$script")
[[ $old == "$expected_old" ]]

"$git" "$@"

opened=$("$git" hash-object "$fd")
installed=$("$git" hash-object "$script")
expected_new=$("$git" rev-parse "HEAD:$script")
if [[ $expected_old != "$expected_new" ]]; then
    [[ ! $fd -ef $script && $opened == "$old" && $installed == "$expected_new" ]]
    printf 'SCRIPT FD offset=%s open_inode=%s path_inode=%s open_blob=%s installed_blob=%s\n' \
        "$offset" "$(/usr/bin/stat -Lc %i "$fd")" "$(/usr/bin/stat -c %i "$script")" \
        "$opened" "$installed" >&2
fi
