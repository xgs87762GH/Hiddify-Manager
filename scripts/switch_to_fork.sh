#!/bin/bash
# Turn /opt/hiddify-manager from a downloaded release into a git checkout of your own fork,
# then apply it. Safe to re-run: when it is already a checkout it just updates from git.
#
#   bash <(curl -sSL https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/mine/scripts/switch_to_fork.sh)
#
# Options (each also has an environment variable):
#   --branch <name>      branch to track             (default: mine,   $HIDDIFY_FORK_BRANCH)
#   --fork <url>         your Hiddify-Manager fork   (default: $HIDDIFY_FORK_URL)
#   --panel-repo <o/r>   also track your panel fork  (default: keep official, $HIDDIFY_PANEL_REPO)
#   --base <branch>      upstream branch to diff against (default: main)
#   --no-backup          skip the backup step (not recommended)
#   -y, --yes            no confirmation prompt
#
# Untracked files are never touched: data/ (database config, certificates, backups),
# generated/, .venv313/ and everything downloaded into services/*/bin.

ROOT="${HIDDIFY_DIR:-/opt/hiddify-manager}"
FORK_URL="${HIDDIFY_FORK_URL:-https://github.com/xgs87762GH/Hiddify-Manager.git}"
UPSTREAM_URL="${HIDDIFY_UPSTREAM_URL:-https://github.com/hiddify/Hiddify-Manager.git}"
BRANCH="${HIDDIFY_FORK_BRANCH:-mine}"
PANEL_REPO="${HIDDIFY_PANEL_REPO:-}"
BASE="${HIDDIFY_UPSTREAM_BASE:-main}"
DO_BACKUP=1
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --branch)     BRANCH="$2"; shift 2 ;;
        --fork)       FORK_URL="$2"; shift 2 ;;
        --panel-repo) PANEL_REPO="$2"; shift 2 ;;
        --base)       BASE="$2"; shift 2 ;;
        --no-backup)  DO_BACKUP=0; shift ;;
        -y|--yes)     ASSUME_YES=1; shift ;;
        -h|--help)
            # print the header comment block (everything up to the first line of code)
            awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
            exit 0 ;;
        *) echo "error: unknown option: $1" >&2; exit 1 ;;
    esac
done

log()  { echo -e "\033[1;34m==>\033[0m $*"; }
warn() { echo -e "\033[1;33mwarning:\033[0m $*" >&2; }
die()  { echo -e "\033[1;31merror:\033[0m $*" >&2; exit 1; }

# --- already a git checkout: just update from git -------------------------------
update_from_git() {
    cd "$ROOT" || die "cannot enter $ROOT"
    git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$ROOT" ||
        git config --global --add safe.directory "$ROOT" >/dev/null 2>&1
    log "fetching $BRANCH"
    git fetch --prune origin "$BRANCH" || die "git fetch failed"
    git merge --ff-only "origin/$BRANCH" || die "cannot fast-forward, resolve by hand: cd $ROOT && git status"
    git submodule update --init --recursive || warn "submodule update failed"
    log "applying"
    make build
    return $?
}

# --- first time: release install -> git checkout --------------------------------
switch_to_fork() {
    log "this turns $ROOT into a git checkout of $FORK_URL (branch $BRANCH)"
    echo "    kept    : data/ generated/ .venv313/ services/*/bin (untracked files)"
    echo "    replaced: every file tracked in $BRANCH"
    if [ "$DO_BACKUP" = "1" ]; then
        echo "    backup  : ${ROOT}.bak.<timestamp>"
    else
        warn "backup disabled with --no-backup"
    fi
    if [ "$ASSUME_YES" != "1" ]; then
        read -r -p "continue? [y/N] " answer
        case "$answer" in y|Y|yes) ;; *) die "aborted" ;; esac
    fi

    cd "$ROOT" || die "cannot enter $ROOT"

    if [ "$DO_BACKUP" = "1" ]; then
        local stamp
        stamp=$(date +%F-%H%M%S)
        log "panel backup"
        bash services/panel/backup.sh || warn "panel backup failed (is the panel running?)"
        log "full snapshot to ${ROOT}.bak.${stamp}"
        [ -e "${ROOT}.bak.${stamp}" ] || cp -a "$ROOT" "${ROOT}.bak.${stamp}" || die "snapshot failed"
        echo "    rollback: systemctl stop hiddify-panel; rm -rf $ROOT; mv ${ROOT}.bak.${stamp} $ROOT; systemctl start hiddify-panel"
    fi

    log "git init"
    git init -b "$BRANCH" >/dev/null 2>&1 || git init >/dev/null
    git remote add origin "$FORK_URL" 2>/dev/null || git remote set-url origin "$FORK_URL"
    git remote add upstream "$UPSTREAM_URL" 2>/dev/null || true
    git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$ROOT" ||
        git config --global --add safe.directory "$ROOT" >/dev/null 2>&1

    log "fetching $BRANCH from your fork"
    git fetch --prune origin "$BRANCH" || die "could not fetch $FORK_URL ($BRANCH)"
    # keep it: fetching upstream below overwrites FETCH_HEAD
    local fork_commit
    fork_commit=$(git rev-parse FETCH_HEAD)
    git fetch --prune upstream "$BASE" >/dev/null 2>&1 || warn "could not fetch upstream $BASE (diff will be skipped)"

    log "checking out $BRANCH (tracked files only)"
    git reset --hard "$fork_commit" || die "checkout failed"
    git branch -m "$BRANCH" >/dev/null 2>&1 || true
    git branch --set-upstream-to="origin/$BRANCH" "$BRANCH" >/dev/null 2>&1 || true

    # a release install has services/panel/src as a plain directory, git wants a submodule there
    if [ -d services/panel/src ] && [ ! -e services/panel/src/.git ]; then
        warn "moving the release copy of services/panel/src aside"
        mv services/panel/src services/panel/src.release-backup
        echo "    you can delete it once everything works: rm -rf services/panel/src.release-backup"
    fi
    git branch -m "$BRANCH" >/dev/null 2>&1 || true
    git branch --set-upstream-to="origin/$BRANCH" "$BRANCH" >/dev/null 2>&1 || true

    if [ -n "$PANEL_REPO" ]; then
        log "pointing the panel submodule at ${PANEL_REPO}"
        sed -i "s#https://github.com/hiddify/Hiddify-Panel.git#https://github.com/${PANEL_REPO}.git#" .gitmodules
        git submodule sync --recursive
    fi

    log "submodules"
    git submodule update --init --recursive || die "submodule update failed"

    log "what differs from the official $BASE:"
    git --no-pager diff --stat "upstream/$BASE...HEAD" 2>/dev/null ||
        { git --no-pager log --oneline -3; echo "    (upstream/$BASE not fetched, showing recent commits only)"; }

    log "applying (reinstalls the services, takes a few minutes)"
    export HIDDIFY_NO_HTTP_API=true
    if command -v make >/dev/null 2>&1; then
        make build
    else
        bash scripts/install.sh --no-gui --no-log
    fi
    return $?
}

# --- main ------------------------------------------------------------------------
[ "$(id -u)" = "0" ] || die "run as root (sudo -i)"
[ -d "$ROOT" ] || die "$ROOT does not exist"
command -v git >/dev/null 2>&1 || {
    log "installing git"
    apt-get update -qq && apt-get install -y git || die "could not install git"
}

rc=0
if [ -e "$ROOT/.git" ]; then
    log "$ROOT is already a git checkout, updating from git"
    update_from_git
    rc=$?
else
    switch_to_fork
    rc=$?
fi

echo
if [ "$rc" = "0" ]; then
    log "done"
    systemctl is-active hiddify-panel >/dev/null 2>&1 &&
        log "hiddify-panel is running" ||
        warn "hiddify-panel is not running: systemctl status hiddify-panel"
    echo "from now on update with:  cd $ROOT && scripts/update.sh"
    echo "or one line:             bash $ROOT/scripts/switch_to_fork.sh"
else
    warn "finished with errors (exit $rc), check the log above"
fi
exit $rc
