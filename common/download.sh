#!/bin/bash
# for backward compatibility: v12 servers fetch <branch>/common/download.sh with the
# package mode (release/beta/dev) as the first argument. On this fork, always forward
# to YOUR customized branch — never the official org or the fork's upstream-synced
# main/dev (those would drop the fork install-source patches).
: "${HIDDIFY_MANAGER_REPO:=xgs87762GH/Hiddify-Manager}"
: "${HIDDIFY_MANAGER_BRANCH:=dev-custom}"
url="https://raw.githubusercontent.com/${HIDDIFY_MANAGER_REPO}/refs/heads/${HIDDIFY_MANAGER_BRANCH}/scripts/common/download.sh"
tmp=$(mktemp)
if ! curl -sLf -o "$tmp" "$url"; then
    echo "Failed to download $url" >&2
    rm -f "$tmp"
    exit 1
fi
# Run from a file (not bash -c) so $0 is not "bash", which download.sh treats as deprecated usage.
bash "$tmp" "$@"
code=$?
rm -f "$tmp"
exit $code
