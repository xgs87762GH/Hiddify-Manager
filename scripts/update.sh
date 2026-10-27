#!/bin/bash
cd /opt/hiddify-manager
source /opt/hiddify-manager/scripts/common/utils.sh

# Create necessary directories and define constants

NAME="update"
LOG_FILE="$(log_file $NAME)"

# Which GitHub repo the "download a release" fallback reads its scripts from.
# Defaults to YOUR fork (also defined in utils.sh); a git checkout never uses this
# fallback at all (update_from_git below). Override if needed:
#   export HIDDIFY_MANAGER_REPO="xgs87762GH/Hiddify-Manager"
: "${HIDDIFY_MANAGER_REPO:=xgs87762GH/Hiddify-Manager}"

# git refuses a repository owned by another user ("dubious ownership"), and the
# exception is per repository directory, never recursive: the checkout is
# root-owned but is also touched by hiddify-panel, and every submodule below it
# is the same. Without its own exception the panel submodule fails with
# "Unable to find current revision in submodule path".
function add_safe_directory() {
    local dir="$1"
    git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$dir" ||
        git config --global --add safe.directory "$dir" >/dev/null 2>&1
}

function add_safe_directories() {
    local d
    add_safe_directory "$HIDDIFY_DIR"
    {
        # declared submodules, read before any of them is initialized
        git -C "$HIDDIFY_DIR" config --file .gitmodules --get-regexp '\.path$' 2>/dev/null | sed 's/^[^ ]* //'
        # nested ones, only visible once their parent is checked out
        git -C "$HIDDIFY_DIR" submodule foreach --recursive --quiet 'echo "$sm_path"' 2>/dev/null
    } | while read -r d; do
        [[ -n "$d" ]] || continue
        add_safe_directory "$HIDDIFY_DIR/$d"
    done
}

# This script runs from a copy in /tmp (see the re-exec below), so an update by
# itself cannot change the code that is doing the work: the fixes shipped in the
# new commit would only reach the next run. Take the branch's version instead
# and hand over to it, so this script can repair itself with nothing but the
# panel's "update" button.
function hand_over_to_new_script() {
    local ref="$1"
    shift
    local script
    script=$(mktemp /tmp/hiddify-update-new.XXXXXX) || return 1
    if git -C "$HIDDIFY_DIR" show "$ref:scripts/update.sh" >"$script" 2>/dev/null &&
        [[ -s "$script" ]] && bash -n "$script" 2>/dev/null &&
        ! cmp -s "$script" "$0" && ! cmp -s "$script" "${_upd_tmp:-$script}"; then
        echo "scripts/update.sh changed on $ref, continuing with that version"
        exec bash "$script" "$@"
    fi
    rm -f "$script"
}

# Update a git checkout (a fork you own) in place instead of downloading a release.
# Override with HIDDIFY_GIT_REMOTE / HIDDIFY_GIT_BRANCH (defaults: origin / current branch).
function update_from_git() {
    local remote="${HIDDIFY_GIT_REMOTE:-origin}"
    local branch="${HIDDIFY_GIT_BRANCH:-$(git -C "$HIDDIFY_DIR" rev-parse --abbrev-ref HEAD)}"

    echo "Updating $HIDDIFY_DIR from $remote/$branch ..."
    add_safe_directories

    cd "$HIDDIFY_DIR" || return 1
    update_progress "Hiddify Updater" "Fetching $remote/$branch" 25
    git fetch --prune "$remote" "$branch" || { error "git fetch $remote/$branch failed"; return 1; }

    local local_head remote_head
    local_head=$(git rev-parse HEAD)
    remote_head=$(git rev-parse "$remote/$branch" 2>/dev/null)
    if [[ -z "$remote_head" ]]; then
        error "branch $remote/$branch does not exist"
        return 1
    fi

    # Run the newest update.sh from the branch, not the one we started with.
    hand_over_to_new_script "$remote/$branch" --no-gui "$@"

    update_progress "Hiddify Updater" "Creating a backup" 10
    (cd "$HIDDIFY_DIR" && ./services/panel/backup.sh) || { error "backup failed, refusing to update"; return 1; }
    cd "$HIDDIFY_DIR" || return 1
    if [[ "$local_head" == "$remote_head" ]]; then
        echo "Already up to date ($local_head)"
    else
        # fast-forward only: never clobber local edits with a merge or a rebase
        git merge --ff-only "$remote/$branch" || {
            error "Cannot fast-forward to $remote/$branch."
            error "Resolve it by hand: cd $HIDDIFY_DIR && git status"
            return 1
        }
    fi

    # Syncing is not part of the branch above: a run that stopped after the
    # merge (submodule failure, Ctrl-C) left the panel on its old commit, and
    # the next run reports "Already up to date" — it must still sync.
    update_progress "Hiddify Updater" "Syncing submodules" 45
    add_safe_directories
    git submodule update --init --recursive || {
        # A submodule cloned by that call is a repository of its own and
        # gets the same ownership check: add it and try once more.
        add_safe_directories
        git submodule update --init --recursive || { error "git submodule update failed"; return 1; }
    }

    update_progress "Hiddify Updater" "Applying the new code" 60
    # the running panel stays the old code until install.sh restarts it at the end
    export HIDDIFY_NO_HTTP_API=true
    if command -v make >/dev/null 2>&1; then
        make build || return 1
    else
        bash scripts/install.sh --no-gui --no-log || return 1
    fi
    update_progress "Hiddify Updater" "Finished" 100
    return 0
}

# Install may replace this file while we are still reading it. Re-exec from a private copy so the
# running bash keeps a stable script (avoids "syntax error near unexpected token fi" after Finished!).
if [[ -z "${HIDDIFY_UPDATE_COPIED:-}" && -f "$0" && "$0" == */scripts/update.sh ]]; then
    _upd_tmp=$(mktemp /tmp/hiddify-update.XXXXXX) || exit 1
    cp -a "$0" "$_upd_tmp"
    chmod 700 "$_upd_tmp"
    export HIDDIFY_UPDATE_COPIED=1
    exec bash "$_upd_tmp" "$@"
fi

function cleanup() {
    error "Script interrupted. Exiting..."
    # disable_ansii_modes
    #    reset
    remove_lock $NAME
    exit 1
}

trap cleanup SIGINT

function main() {
    if is_dev_checkout; then
        # A git checkout (development / own fork): update from git, never overwrite it with a download.
        update_from_git
        local rc=$?
        remove_lock $NAME
        echo "---------------------Finished!------------------------"
        return $rc
    fi
    update_progress "Hiddify Updater" "Checking for update" 1
    echo "Checking for update..."
    local force=false
    local manager_update=0
    local panel_update=0

    if [[ -n "$1" ]]; then
        local package_mode=$1
        force=true
    else
        local package_mode=$(get_package_mode)
    fi
    local current_config_version=$(get_installed_config_version)
    local current_panel_version=$(get_installed_panel_version)

    # if [[ $package_mode == "release" ]] && [[ $current_config_version == *"dev"* || ! $current_panel_version == 10* || ! $current_panel_version == 9* ]]; then
    #     bash common/downgrade.sh
    #     return 0
    # fi

    rm -rf sniproxy caddy
    update_progress "Hiddify Updater" "Creating a backup" 5
    echo "Creating a backup ..."
    if ! ./services/panel/backup.sh; then
        error "backup failed; refusing to update without a fresh backup"
        remove_lock $NAME
        return 1
    fi

    # Version checks and the installer script both come from YOUR fork on YOUR branch.
    : "${HIDDIFY_MANAGER_BRANCH:=dev-custom}"
    local update_script="https://raw.githubusercontent.com/${HIDDIFY_MANAGER_REPO}/refs/heads/${HIDDIFY_MANAGER_BRANCH}/scripts/common/download.sh"
    case "$package_mode" in
    dev|develop)
        # Use the latest commit from GitHub
        latest_panel=$(get_commit_version Hiddify-Panel)
        latest_manager=$(get_commit_version hiddify-manager)
        ;;
    beta)
        latest_panel=$(get_pre_release_version hiddify-panel)
        latest_manager=$(get_pre_release_version hiddify-manager)
        ;;
    release)
        latest_panel=$(get_release_version hiddify-panel)
        latest_manager=$(get_release_version hiddify-manager)
        ;;
    esac

    [[ "$latest_panel" != "$current_panel_version" ]] && panel_update=1
    [[ "$latest_manager" != "$current_config_version" ]] && manager_update=1
    echo "$package_mode Latest panel version: $latest_panel Installed: $current_panel_version Lastest manager version: $latest_manager Installed: $current_config_version"
    if [[ "$force" == "true" || $panel_update == 1 || $manager_update == 1 ]]; then
        # The running panel stays the old code until install.sh restarts it at the end: install.sh must read the configs
        # and dump them with the CLI (the new code), not through the panel's HTTP API (reload_all_configs, dump_server_configs).
        export HIDDIFY_NO_HTTP_API=true
        local installer
        installer="$(mktemp)"
        # -f: a 404/502 body must never be executed as a script.
        if ! curl -fsSL "$update_script" -o "$installer"; then
            error "could not download $update_script"
            rm -f "$installer"
            remove_lock $NAME
            return 1
        fi
        bash "$installer" "$package_mode" "$force" "--no-gui" "--no-log"
        local install_rc=$?
        rm -f "$installer"
        if [[ $install_rc -ne 0 ]]; then
            error "installer failed (exit $install_rc)"
            remove_lock $NAME
            return $install_rc
        fi
    else
        echo "Nothing to update"
    fi
    remove_lock $NAME
    echo "---------------------Finished!------------------------"

}
if [[ "$HIDDIFY_DISABLE_UPDATE" == "1" || "$HIDDIFY_DISABLE_UPDATE" == "true" ]];then
    error "Updating is disabled because env variable HIDDIFY_DISABLE_UPDATE == $HIDDIFY_DISABLE_UPDATE"
    exit 9
elif [[ " $@ " == *" --no-gui "* ]]; then
    set -- "${@/--no-gui/}"
    set_lock $NAME
    if [[ " $@ " == *" --no-log "* ]]; then
        set -- "${@/--no-log/}"
        main "$@"
        error_code=$?
    else
        main "$@" |& tee "$LOG_FILE"
        error_code=${PIPESTATUS[0]} # main's, not tee's
    fi
    remove_lock $NAME
else
    show_progress_window --subtitle "Updater" --log $LOG_FILE /opt/hiddify-manager/scripts/update.sh $@ --no-gui --no-log
    error_code=$?
    if [[ $error_code != "0" ]]; then
        # echo less -r -P"Installation Failed! Press q to exit" +G "$log_file"
        msg_with_hiddify "Installation Failed! code=$error_code"
    else
        msg_with_hiddify "The update has successfully completed."
        check_hiddify_panel $@ |& tee -a $LOG_FILE
    fi
fi
exit $error_code
