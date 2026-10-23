#!/bin/bash
cd /opt/hiddify-manager
source /opt/hiddify-manager/scripts/common/utils.sh

# Create necessary directories and define constants

NAME="update"
LOG_FILE="$(log_file $NAME)"

# Which GitHub repo the "download a release" fallback reads its scripts from.
# A git checkout never uses it (update_from_git below), but set it to your own
# fork if you also want the fallback to be yours:
#   export HIDDIFY_MANAGER_REPO="xgs87762GH/Hiddify-Manager"
: "${HIDDIFY_MANAGER_REPO:=hiddify/Hiddify-Manager}"

# Update a git checkout (a fork you own) in place instead of downloading a release.
# Override with HIDDIFY_GIT_REMOTE / HIDDIFY_GIT_BRANCH (defaults: origin / current branch).
function update_from_git() {
    local remote="${HIDDIFY_GIT_REMOTE:-origin}"
    local branch="${HIDDIFY_GIT_BRANCH:-$(git -C "$HIDDIFY_DIR" rev-parse --abbrev-ref HEAD)}"

    echo "Updating $HIDDIFY_DIR from $remote/$branch ..."
    update_progress "Hiddify Updater" "Creating a backup" 10
    (cd "$HIDDIFY_DIR" && ./services/panel/backup.sh)

    cd "$HIDDIFY_DIR" || return 1
    # the checkout is root-owned but is also touched by other accounts (hiddify-panel, ...)
    git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$HIDDIFY_DIR" ||
        git config --global --add safe.directory "$HIDDIFY_DIR" >/dev/null 2>&1

    update_progress "Hiddify Updater" "Fetching $remote/$branch" 25
    git fetch --prune "$remote" "$branch" || { error "git fetch $remote/$branch failed"; return 1; }

    local local_head remote_head
    local_head=$(git rev-parse HEAD)
    remote_head=$(git rev-parse "$remote/$branch" 2>/dev/null)
    if [[ -z "$remote_head" ]]; then
        error "branch $remote/$branch does not exist"
        return 1
    fi

    if [[ "$local_head" == "$remote_head" ]]; then
        echo "Already up to date ($local_head)"
    else
        # fast-forward only: never clobber local edits with a merge or a rebase
        git merge --ff-only "$remote/$branch" || {
            error "Cannot fast-forward to $remote/$branch."
            error "Resolve it by hand: cd $HIDDIFY_DIR && git status"
            return 1
        }
        update_progress "Hiddify Updater" "Syncing submodules" 45
        git submodule update --init --recursive || { error "git submodule update failed"; return 1; }
    fi

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
    ./services/panel/backup.sh

    case "$package_mode" in
    dev|develop)
        # Use the latest commit from GitHub
        latest_panel=$(get_commit_version Hiddify-Panel)
        latest_manager=$(get_commit_version hiddify-manager)
        update_script="https://raw.githubusercontent.com/${HIDDIFY_MANAGER_REPO}/refs/heads/dev/scripts/common/download.sh"
        ;;
    beta)
        latest_panel=$(get_pre_release_version hiddify-panel)
        latest_manager=$(get_pre_release_version hiddify-manager)
        update_script="https://raw.githubusercontent.com/${HIDDIFY_MANAGER_REPO}/refs/heads/beta/scripts/common/download.sh"
        ;;
    release)
        latest_panel=$(get_release_version hiddify-panel)
        latest_manager=$(get_release_version hiddify-manager)
        update_script="https://raw.githubusercontent.com/${HIDDIFY_MANAGER_REPO}/refs/heads/main/scripts/common/download.sh"
        ;;
    *)
        update_script="https://raw.githubusercontent.com/${HIDDIFY_MANAGER_REPO}/refs/heads/main/scripts/common/download.sh"
        ;;
    esac

    [[ "$latest_panel" != "$current_panel_version" ]] && panel_update=1
    [[ "$latest_manager" != "$current_config_version" ]] && manager_update=1
    echo "$package_mode Latest panel version: $latest_panel Installed: $current_panel_version Lastest manager version: $latest_manager Installed: $current_config_version"
    if [[ "$force" == "true" || $panel_update == 1 || $manager_update == 1 ]]; then
        # The running panel stays the old code until install.sh restarts it at the end: install.sh must read the configs
        # and dump them with the CLI (the new code), not through the panel's HTTP API (reload_all_configs, dump_server_configs).
        export HIDDIFY_NO_HTTP_API=true
        bash <(curl -sSL $update_script) "$package_mode" "$force" "--no-gui" "--no-log"
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
    else
        main "$@" |& tee $LOG_FILE
    fi
    error_code=$?
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
