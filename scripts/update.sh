#!/bin/bash
cd /opt/hiddify-manager
source /opt/hiddify-manager/scripts/common/utils.sh

# 创建必要目录并定义常量

NAME="update"
LOG_FILE="$(log_file $NAME)"

# "下载 release" 兜底路径从哪个 GitHub 仓库取脚本。
# 默认使用你自己的 fork（utils.sh 中也有同样的默认值）；git 检出模式完全不会走这条
# 兜底路径（见下方 update_from_git）。需要时可覆盖：
#   export HIDDIFY_MANAGER_REPO="xgs87762GH/Hiddify-Manager"
: "${HIDDIFY_MANAGER_REPO:=xgs87762GH/Hiddify-Manager}"

# git 会拒绝属于其他用户的仓库（"dubious ownership"），而该例外按仓库目录生效、
# 不会递归：检出目录属主是 root 但也会被 hiddify-panel 写入，其下每个子模块同理。
# 子模块若没有自己的例外，就会报 "Unable to find current revision in submodule path"。
# 这两个函数通常来自上面 source 的 common/utils.sh。但 utils.sh 可能比本脚本旧
#（下面那段自我交接正是发生在它比 utils.sh 新的时候），而这时恰恰需要它们，
# 所以为本脚本自带一份，兼容尚未包含它们的 utils.sh。
if ! declare -F add_safe_directories >/dev/null; then
    function add_safe_directory() {
        local dir="${1%/}"
        [[ -n "$dir" ]] || return 0
        git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$dir" && return 0
        git config --global --add safe.directory "$dir" >/dev/null 2>&1
    }

    function add_safe_directories() {
        local d
        add_safe_directory "$HIDDIFY_DIR"
        add_safe_directory "$HIDDIFY_DIR/services/panel/src"
        while IFS= read -r d; do
            [[ -n "$d" ]] || continue
            add_safe_directory "$HIDDIFY_DIR/$d"
        done < <(
            git -C "$HIDDIFY_DIR" config --file .gitmodules --get-regexp '\.path$' 2>/dev/null | sed 's/^[^ ]* //'
            git -C "$HIDDIFY_DIR" submodule foreach --recursive --quiet 'echo "$sm_path"' 2>/dev/null
        )
    }
fi

# 本脚本是从 /tmp 中的副本运行的（见下方重新执行那段），因此"更新"本身无法改变
# 正在干活的这份代码：新提交里的修复只会在下次运行生效。这里改为取出分支上的
# 版本并交接给它，让本脚本仅凭面板上的"更新"按钮就能自我修复。
function hand_over_to_new_script() {
    local ref="$1"
    shift
    local script
    script=$(mktemp /tmp/hiddify-update-new.XXXXXX) || return 1
    if git -C "$HIDDIFY_DIR" show "$ref:scripts/update.sh" >"$script" 2>/dev/null &&
        [[ -s "$script" ]] && bash -n "$script" 2>/dev/null &&
        ! cmp -s "$script" "$0" && ! cmp -s "$script" "${_upd_tmp:-$script}"; then
        echo "scripts/update.sh 在 $ref 上已有变化，改用该版本继续"
        exec bash "$script" "$@"
    fi
    rm -f "$script"
}

# 就地更新一个 git 检出（你自己拥有的 fork），而不是下载 release。
# 可用 HIDDIFY_GIT_REMOTE / HIDDIFY_GIT_BRANCH 覆盖（默认：origin / 当前分支）。
function update_from_git() {
    local remote="${HIDDIFY_GIT_REMOTE:-origin}"
    local branch="${HIDDIFY_GIT_BRANCH:-$(git -C "$HIDDIFY_DIR" rev-parse --abbrev-ref HEAD)}"

    echo "正在从 $remote/$branch 更新 $HIDDIFY_DIR ……"
    add_safe_directories

    cd "$HIDDIFY_DIR" || return 1
    update_progress "Hiddify 更新器" "正在获取 $remote/$branch" 25
    git fetch --prune "$remote" "$branch" || { error "git fetch $remote/$branch 失败"; return 1; }

    local local_head remote_head
    local_head=$(git rev-parse HEAD)
    remote_head=$(git rev-parse "$remote/$branch" 2>/dev/null)
    if [[ -z "$remote_head" ]]; then
        error "分支 $remote/$branch 不存在"
        return 1
    fi

    # 使用分支上最新的 update.sh 继续，而不是启动时的那份。
    hand_over_to_new_script "$remote/$branch" --no-gui "$@"

    update_progress "Hiddify 更新器" "正在创建备份" 10
    (cd "$HIDDIFY_DIR" && ./services/panel/backup.sh) || { error "备份失败，已中止更新"; return 1; }
    cd "$HIDDIFY_DIR" || return 1
    if [[ "$local_head" == "$remote_head" ]]; then
        # 保留英文关键词：scripts/tests/smoke_update.sh 依赖它判断"无事可做"分支。
        echo "已是最新，无需更新（Already up to date: $local_head）"
    else
        # 只允许快进：绝不用 merge/rebase 覆盖本地改动
        git merge --ff-only "$remote/$branch" || {
            error "无法快进到 $remote/$branch。"
            error "请手动处理：cd $HIDDIFY_DIR && git status"
            return 1
        }
    fi

    # 子模块同步不在上面的分支里：某次运行若在合并后中断（子模块失败、Ctrl-C），
    # 面板会停在旧 commit 上，下次运行又报"已是最新"——所以必须照常同步。
    # 保留英文关键词：scripts/tests/smoke_update.sh 依赖它确认同步确实执行过。
    update_progress "Hiddify 更新器" "同步子模块（Syncing submodules）" 45
    add_safe_directories
    git submodule update --init --recursive || {
        # 这次调用新克隆出来的子模块是一个独立仓库，同样要过所有权检查：
        # 补加例外后再试一次。
        add_safe_directories
        git submodule update --init --recursive || { error "git submodule update 失败"; return 1; }
    }

    update_progress "Hiddify 更新器" "正在应用新代码" 60
    # 运行中的面板仍是旧代码，直到 install.sh 在最后重启它
    export HIDDIFY_NO_HTTP_API=true
    if command -v make >/dev/null 2>&1; then
        make build || return 1
    else
        bash scripts/install.sh --no-gui --no-log || return 1
    fi
    update_progress "Hiddify 更新器" "完成" 100
    return 0
}

# 安装过程会替换本文件，而我们可能还在读它。从私有副本重新执行，让运行中的 bash
# 持有稳定的脚本（避免 "Finished!" 之后出现 "syntax error near unexpected token fi"）。
if [[ -z "${HIDDIFY_UPDATE_COPIED:-}" && -f "$0" && "$0" == */scripts/update.sh ]]; then
    _upd_tmp=$(mktemp /tmp/hiddify-update.XXXXXX) || exit 1
    cp -a "$0" "$_upd_tmp"
    chmod 700 "$_upd_tmp"
    export HIDDIFY_UPDATE_COPIED=1
    exec bash "$_upd_tmp" "$@"
fi

function cleanup() {
    error "脚本被中断，正在退出……"
    # disable_ansii_modes
    #    reset
    remove_lock $NAME
    exit 1
}

trap cleanup SIGINT

function main() {
    if is_dev_checkout; then
        # git 检出（开发或自己的 fork）：从 git 更新，绝不用下载包覆盖
        update_from_git
        local rc=$?
        remove_lock $NAME
        # 这一行是面板判定日志结束的标记（apply_api.py 的 FINISHED_MARK、result.html 的同一标记），请勿翻译
        echo "---------------------Finished!------------------------"
        return $rc
    fi
    update_progress "Hiddify 更新器" "正在检查更新" 1
    echo "正在检查更新……"
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
    update_progress "Hiddify 更新器" "正在创建备份" 5
    echo "正在创建备份……"
    if ! ./services/panel/backup.sh; then
        error "备份失败；没有新备份时不允许更新"
        remove_lock $NAME
        return 1
    fi

    # 版本检查与安装脚本都来自你的 fork 的你的分支。
    : "${HIDDIFY_MANAGER_BRANCH:=dev-custom}"
    local update_script="https://raw.githubusercontent.com/${HIDDIFY_MANAGER_REPO}/refs/heads/${HIDDIFY_MANAGER_BRANCH}/scripts/common/download.sh"
    case "$package_mode" in
    dev|develop)
        # 使用 GitHub 上最新的提交
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
    echo "$package_mode 面板最新版本：$latest_panel 已安装：$current_panel_version 管理器最新版本：$latest_manager 已安装：$current_config_version"
    if [[ "$force" == "true" || $panel_update == 1 || $manager_update == 1 ]]; then
        # 运行中的面板在 install.sh 最后重启之前仍是旧代码：install.sh 必须用 CLI（新代码）
        # 读取并导出配置，而不是走面板的 HTTP API（reload_all_configs、dump_server_configs）。
        export HIDDIFY_NO_HTTP_API=true
        local installer
        installer="$(mktemp)"
        # -f：404/502 的响应体绝不能被当作脚本执行。
        if ! curl -fsSL "$update_script" -o "$installer"; then
            error "无法下载 $update_script"
            rm -f "$installer"
            remove_lock $NAME
            return 1
        fi
        bash "$installer" "$package_mode" "$force" "--no-gui" "--no-log"
        local install_rc=$?
        rm -f "$installer"
        if [[ $install_rc -ne 0 ]]; then
            error "安装脚本执行失败（退出码 $install_rc）"
            remove_lock $NAME
            return $install_rc
        fi
    else
        echo "没有可更新的内容"
    fi
    remove_lock $NAME
    # 同上：面板靠日志末尾的这个标记判定更新已结束，请勿翻译
    echo "---------------------Finished!------------------------"

}
if [[ "$HIDDIFY_DISABLE_UPDATE" == "1" || "$HIDDIFY_DISABLE_UPDATE" == "true" ]];then
    error "更新已被禁用，因为环境变量 HIDDIFY_DISABLE_UPDATE == $HIDDIFY_DISABLE_UPDATE"
    exit 9
elif [[ " $* " == *" --no-gui "* ]]; then
    set -- "${@/--no-gui/}"
    set_lock $NAME
    if [[ " $* " == *" --no-log "* ]]; then
        set -- "${@/--no-log/}"
        main "$@"
        error_code=$?
    else
        main "$@" |& tee "$LOG_FILE"
        error_code=${PIPESTATUS[0]} # 取 main 的退出码，而不是 tee 的
    fi
    remove_lock $NAME
else
    show_progress_window --subtitle "更新器" --log $LOG_FILE /opt/hiddify-manager/scripts/update.sh "$@" --no-gui --no-log
    error_code=$?
    if [[ $error_code != "0" ]]; then
        # echo less -r -P"Installation Failed! Press q to exit" +G "$log_file"
        msg_with_hiddify "更新失败！退出码=$error_code"
    else
        msg_with_hiddify "更新已成功完成。"
        check_hiddify_panel "$@" |& tee -a $LOG_FILE
    fi
fi
exit $error_code
