#!/bin/bash
# 把 /opt/hiddify-manager 从"下载的 release"变成你自己 fork 的 git 检出，然后应用配置。
# 可重复执行：已经是检出状态时只做 git 更新。
#
#   bash <(curl -sSL https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/refs/heads/dev-custom/scripts/switch_to_fork.sh)
#
# 选项（同时也都可以用环境变量指定）：
#   --branch <name>      跟踪的分支             （默认 dev-custom，$HIDDIFY_FORK_BRANCH）
#   --fork <url>         你的 Hiddify-Manager fork（默认 $HIDDIFY_FORK_URL）
#   --panel-repo <o/r>   覆盖面板子模块 URL（默认用 fork .gitmodules，已是本 fork 面板）
#   --base <branch>      对比用的上游分支        （默认 main）
#   --no-backup          跳过备份步骤（不推荐）
#   -y, --yes            不再询问确认
#
# 未跟踪的文件一律不动：data/（数据库配置、证书、备份）、
# generated/、.venv313/ 以及下载到 services/*/bin 下的所有内容。

ROOT="${HIDDIFY_DIR:-/opt/hiddify-manager}"
FORK_URL="${HIDDIFY_FORK_URL:-https://github.com/xgs87762GH/Hiddify-Manager.git}"
UPSTREAM_URL="${HIDDIFY_UPSTREAM_URL:-https://github.com/hiddify/Hiddify-Manager.git}"
BRANCH="${HIDDIFY_FORK_BRANCH:-dev-custom}"
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
            # 打印文件头部的注释块（直到第一行代码之前）
            awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
            exit 0 ;;
        *) echo "错误：未知参数：$1" >&2; exit 1 ;;
    esac
done

log()  { echo -e "\033[1;34m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m警告：\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m错误：\033[0m $*" >&2; exit 1; }

# 本脚本是独立下载执行的（curl … | bash），无法 source
# scripts/common/utils.sh，因此自带与 update.sh 相同的辅助函数。git 会拒绝
# 属于其他用户的仓库（"dubious ownership"），而该例外是按目录生效、不会递归：
# $ROOT 会被 root 和 hiddify-panel 写入，其下每个子模块都需要各自例外，
# 否则更新会因 "Unable to find current revision in submodule path" 失败。
function add_safe_directory() {
    local dir="${1%/}"
    [ -n "$dir" ] || return 0
    git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$dir" || \
        git config --global --add safe.directory "$dir" 2>/dev/null
    git config --system --get-all safe.directory 2>/dev/null | grep -Fxq "$dir" || \
        git config --system --add safe.directory "$dir" 2>/dev/null
}

function add_safe_directories() {
    local d dirs=()
    dirs+=("$ROOT" "$ROOT/services/panel/src")
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        dirs+=("$ROOT/$d")
    done < <(
        git -C "$ROOT" config --file .gitmodules --get-regexp '\.path$' 2>/dev/null | sed 's/^[^ ]* //'
        git -C "$ROOT" submodule foreach --recursive --quiet 'echo "$sm_path"' 2>/dev/null
    )
    for d in "${dirs[@]}"; do
        add_safe_directory "$d"
    done
    local i=${GIT_CONFIG_COUNT:-0}
    for d in "${dirs[@]}"; do
        export "GIT_CONFIG_KEY_$i=safe.directory"
        export "GIT_CONFIG_VALUE_$i=${d%/}"
        i=$((i + 1))
    done
    [[ $i -gt 0 ]] && export GIT_CONFIG_COUNT=$i
}

# release 安装的 services/*/src 可能是普通目录，或残留一个指向不存在 gitdir 的
# 半残 .git 指针（git submodule update 会报 "could not get a repository handle"）。
# 把这类"不是合法子模块工作树"的路径移开，让 update --init 重新克隆。
is_valid_submodule() {
    local path="$1" top
    [ -e "$path/.git" ] || return 1
    top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || return 1
    [ "$top" = "$path" ]
}

fixup_broken_submodules() {
    local sm path dest
    while IFS= read -r sm; do
        [ -n "$sm" ] || continue
        path="$ROOT/$sm"
        [ -e "$path" ] || continue
        is_valid_submodule "$path" && continue
        warn "移开非子模块路径 $sm"
        dest="${path}.release-backup"
        [ -e "$dest" ] && dest="${path}.release-backup.$(date +%s)"
        mv "$path" "$dest"
        echo "    一切正常后可删除：rm -rf $dest"
    done < <(git -C "$ROOT" config --file .gitmodules --get-regexp '\.path$' 2>/dev/null | sed 's/^[^ ]* //')
}

# --- 已经是 git 检出：直接从 git 更新 -------------------------------------------
update_from_git() {
    cd "$ROOT" || die "无法进入 $ROOT"
    add_safe_directories
    log "正在拉取 $BRANCH"
    git fetch --no-recurse-submodules --prune origin "$BRANCH" || die "git fetch 失败"
    git merge --ff-only "origin/$BRANCH" || die "无法快进合并，请手动处理：cd $ROOT && git status"
    add_safe_directories
    fixup_broken_submodules
    git submodule update --init --recursive || {
        # 上面克隆的子模块本身就是一个独立仓库：补加例外后重试
        add_safe_directories
        git submodule update --init --recursive || warn "子模块更新失败"
    }
    log "正在应用"
    export HIDDIFY_NO_HTTP_API=true
    if command -v make >/dev/null 2>&1; then
        make build
    else
        bash scripts/install.sh --no-gui --no-log
    fi
    return $?
}

# --- 首次：release 安装 -> git 检出 ---------------------------------------------
switch_to_fork() {
    log "这会把 $ROOT 变成 $FORK_URL（分支 $BRANCH）的 git 检出"
    echo "    保留    ：data/ generated/ .venv313/ services/*/bin（未跟踪文件）"
    echo "    替换    ：$BRANCH 中所有被跟踪的文件"
    if [ "$DO_BACKUP" = "1" ]; then
        echo "    备份至  ：${ROOT}.bak.<时间戳>"
    else
        warn "已通过 --no-backup 关闭备份"
    fi
    if [ "$ASSUME_YES" != "1" ]; then
        read -r -p "是否继续？[y/N] " answer
        case "$answer" in y|Y|yes) ;; *) die "已取消" ;; esac
    fi

    cd "$ROOT" || die "无法进入 $ROOT"

    if [ "$DO_BACKUP" = "1" ]; then
        local stamp
        stamp=$(date +%F-%H%M%S)
        log "面板备份"
        bash services/panel/backup.sh || warn "面板备份失败（面板是否在运行？）"
        log "完整快照到 ${ROOT}.bak.${stamp}"
        [ -e "${ROOT}.bak.${stamp}" ] || cp -a "$ROOT" "${ROOT}.bak.${stamp}" || die "快照失败"
        echo "    回滚方法：systemctl stop hiddify-panel; rm -rf $ROOT; mv ${ROOT}.bak.${stamp} $ROOT; systemctl start hiddify-panel"
    fi

    log "git init"
    git init -b "$BRANCH" >/dev/null 2>&1 || git init >/dev/null
    git remote add origin "$FORK_URL" 2>/dev/null || git remote set-url origin "$FORK_URL"
    git remote add upstream "$UPSTREAM_URL" 2>/dev/null || true
    add_safe_directories

    log "正在从你的 fork 拉取 $BRANCH"
    git fetch --no-recurse-submodules --prune origin "$BRANCH" || die "无法拉取 $FORK_URL（$BRANCH）"
    # 先记下来：后面拉取 upstream 会覆盖 FETCH_HEAD
    local fork_commit
    fork_commit=$(git rev-parse FETCH_HEAD)
    git fetch --no-recurse-submodules --prune upstream "$BASE" >/dev/null 2>&1 || warn "无法拉取上游 $BASE（将跳过差异对比）"

    log "检出 $BRANCH（仅跟踪的文件）"
    git reset --hard "$fork_commit" || die "检出失败"
    git branch -m "$BRANCH" >/dev/null 2>&1 || true
    git branch --set-upstream-to="origin/$BRANCH" "$BRANCH" >/dev/null 2>&1 || true

    # release 安装里的子模块路径可能是普通目录，或残留一个指向不存在 gitdir 的
    # 半残 .git 指针；git submodule update 会因此失败，先把它们移开。
    fixup_broken_submodules

    if [ -n "$PANEL_REPO" ]; then
        log "把面板子模块指向 ${PANEL_REPO}"
        # 兼容官方旧名 Hiddify-Panel、现行 hiddifypanel，以及本 fork 已写好的 URL。
        sed -i -E "s#url = https://github.com/[^/]+/(Hiddify-Panel|hiddifypanel)(\.git)?#url = https://github.com/${PANEL_REPO}.git#" .gitmodules
        git submodule sync --recursive
    fi

    log "子模块"
    add_safe_directories
    git submodule update --init --recursive || {
        # 上面克隆的子模块本身就是一个独立仓库：补加例外后重试
        add_safe_directories
        git submodule update --init --recursive || die "子模块更新失败"
    }

    log "与官方 $BASE 的差异如下："
    git --no-pager diff --stat "upstream/$BASE...HEAD" 2>/dev/null ||
        { git --no-pager log --oneline -3; echo "    （未拉取 upstream/$BASE，仅显示最近提交）"; }

    log "正在应用（会重装服务，需要几分钟）"
    export HIDDIFY_NO_HTTP_API=true
    if command -v make >/dev/null 2>&1; then
        make build
    else
        bash scripts/install.sh --no-gui --no-log
    fi
    return $?
}

# --- 主流程 ----------------------------------------------------------------------
[ "$(id -u)" = "0" ] || die "请以 root 身份运行（sudo -i）"
[ -d "$ROOT" ] || die "$ROOT 不存在"
command -v git >/dev/null 2>&1 || {
    log "正在安装 git"
    apt-get update -qq && apt-get install -y git || die "无法安装 git"
}

rc=0
if [ -e "$ROOT/.git" ]; then
    log "$ROOT 已是 git 检出，改为从 git 更新"
    update_from_git
    rc=$?
else
    switch_to_fork
    rc=$?
fi

echo
if [ "$rc" = "0" ]; then
    log "完成"
    systemctl is-active hiddify-panel >/dev/null 2>&1 &&
        log "hiddify-panel 正在运行" ||
        warn "hiddify-panel 未运行：systemctl status hiddify-panel"
    echo "今后更新请执行：  cd $ROOT && scripts/update.sh"
    echo "或一行命令：      bash $ROOT/scripts/switch_to_fork.sh"
else
    warn "执行出错（退出码 $rc），请查看上方日志"
fi
exit $rc
