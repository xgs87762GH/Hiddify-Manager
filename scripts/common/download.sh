#!/bin/bash

if [[ "$VER" != "" ]];then
    set -- $VER  $@

fi

echo "$0 input params are $@"


if [[ " $@ " != *"--no-gui"* ]] &&  [[ "$0" == "bash" ]]; then
    echo "This script is deprecated! Please use the following command"
    echo ""
    echo "bash <(curl https://i.hiddify.com/$1)"
    echo ""
    exit 1
fi

echo "Downloading '$@'"

# v8 is a legacy migration path: the fork cannot serve the ancient hiddify-config code,
# so it intentionally still points at the official legacy repo. Do NOT use it to "update".
if [[ " $@ " == *" v8 "* ]]; then
    sudo bash -c "$(curl -sLfo- https://raw.githubusercontent.com/hiddify/hiddify-config/main/scripts/common/download_install.sh)"
    exit $?
fi


mkdir -p /tmp/hiddify/
chmod 600 /tmp/hiddify/
rm -rf /tmp/hiddify/*

# All downloads come from YOUR fork, on YOUR customized branch (never the official
# org, and never the fork's upstream-synced main/dev branches). Override if needed:
#   export HIDDIFY_MANAGER_REPO="xgs87762GH/Hiddify-Manager"
#   export HIDDIFY_MANAGER_BRANCH="dev-custom"
: "${HIDDIFY_MANAGER_REPO:=xgs87762GH/Hiddify-Manager}"
: "${HIDDIFY_MANAGER_BRANCH:=dev-custom}"

branch="${1:-release}"

if [[ "$branch" == v* ]]; then
    # If input starts with 'v', treat it as a tag (your fork's release tags)
    case "$branch" in
        v9*|v10*|v11*|v12*)
            base_url="https://raw.githubusercontent.com/${HIDDIFY_MANAGER_REPO}/refs/tags/$branch/"
            ;;
        *)
            base_url="https://raw.githubusercontent.com/${HIDDIFY_MANAGER_REPO}/refs/tags/$branch/scripts"
            ;;
    esac
else
    # release / beta / dev / anything else: always your customized branch
    base_url="https://raw.githubusercontent.com/${HIDDIFY_MANAGER_REPO}/refs/heads/${HIDDIFY_MANAGER_BRANCH}/scripts"
fi
# -f: a 404/502 body must never be installed as the installer, nor sourced as utils.sh.
curl -fsSL -o /tmp/hiddify/hiddify_installer.sh "$base_url/common/hiddify_installer.sh" || {
    echo "could not download hiddify_installer.sh from $base_url" >&2; exit 1; }
curl -fsSL -o /tmp/hiddify/utils.sh "$base_url/common/utils.sh" || {
    echo "could not download utils.sh from $base_url" >&2; exit 1; }
chmod 700 /tmp/hiddify/*

/tmp/hiddify/hiddify_installer.sh $@
