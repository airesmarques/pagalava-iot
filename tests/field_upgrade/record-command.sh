#!/bin/bash
set -eu
printf 'STAND-IN %s %s\n' "$0" "$*" >&2
if [[ ${0##*/} != sudo ]]; then
    exit 0
fi
if [[ $RIG_SUDO_POLICY == password ]]; then
    echo 'sudo: a password is required (no TTY)' >&2
    exit 1
fi
if [[ ${1:-} == -n && ${2:-} == -l ]]; then
    test -x "$3"
    exit
fi
exec "$@"
