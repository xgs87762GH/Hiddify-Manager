#!/bin/bash
# 一条命令完成 Hiddify-Manager（本 fork）的安装、更新、重装、指定版本。
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/dev-custom/scripts/onekey.sh) install
#
# 子命令：
#   install          全新安装（目录不存在就 git clone，然后装全部服务）
#   update           升级已有安装（备份 → ff-only 快进 → 子模块 → 重建）
#   reinstall        按当前代码重装全部服务（不重新拉代码）
#   version <tag>    切换到指定发布版本，如 v14.1.0b3（仅非 git 安装；git 检出见提示）
#   switch           官方安装 → 本 fork 检出（等价于 switch_to_fork.sh）
#
# 选项：
#   --dir <path>     安装目录（默认 /opt/hiddify-manager，$HIDDIFY_DIR）
#   --branch <name>  跟踪的分支（默认 dev-custom，$HIDDIFY_FORK_BRANCH）
#   --fork <url>     fork 地址（默认 $HIDDIFY_FORK_URL）
#   -y, --yes        不再询问确认
#   -h, --help       显示本帮助
#
# 本脚本是自包含的：通过 curl 直接执行时 /opt 下还没有任何文件，
# 所以它不 source utils.sh，也不依赖工作目录。

set -uo pipefail

ROOT="${HIDDIFY_DIR:-/opt/hiddify-manager}"
BRANCH="${HIDDIFY_FORK_BRANCH:-dev-custom}"
FORK_URL="${HIDDIFY_FORK_URL:-https://github.com/xgs87762GH/Hiddify-Manager.git}"
# 下载脚本（download.sh / switch_to_fork.sh）时用的仓库与分支
REPO="${HIDDIFY_MANAGER_REPO:-xgs87762GH/Hiddify-Manager}"
ASSUME_YES=0
CMD=""
ARG=""

log()  { echo -e "\033[1;34m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m警告：\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m错误：\033[0m $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
用法：bash <(curl -fsSL <本脚本地址>) <子命令> [选项]

子命令：
  install          全新安装（目录不存在就 git clone，然后装全部服务）
  update           升级已有安装（备份 → ff-only 快进 → 子模块 → 重建）
  reinstall        按当前代码重装全部服务（不重新拉代码）
  version <tag>    切换到指定发布版本，如 v14.1.0b3（git 检出：强制换代码留数据；zip 安装：下载该版本覆盖）
  switch           官方安装 → 本 fork 检出（等价于 switch_to_fork.sh）

选项：
  --dir <path>     安装目录（默认 /opt/hiddify-manager）
  --branch <name>  跟踪的分支（默认 dev-custom）
  --fork <url>     fork 地址
  -y, --yes        不再询问确认
  -h, --help       显示本帮助

例子（把 URL 存成变量更短：OK=https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/dev-custom/scripts/onekey.sh）：
  bash <(curl -fsSL "$OK") install             # 全新安装
  bash <(curl -fsSL "$OK") update              # 升级（会先备份）
  bash <(curl -fsSL "$OK") reinstall           # 按当前代码重装服务
  bash <(curl -fsSL "$OK") version v14.2.4 -y  # 切到指定版本（git 检出也能用：强制换代码留数据）
  bash <(curl -fsSL "$OK") switch              # 官方安装 → 本 fork 检出
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)    ROOT="${2:-}"; [ -n "$ROOT" ] || die "--dir 需要一个值"; shift 2 ;;
        --branch) BRANCH="${2:-}"; [ -n "$BRANCH" ] || die "--branch 需要一个值"; shift 2 ;;
        --fork)   FORK_URL="${2:-}"; [ -n "$FORK_URL" ] || die "--fork 需要一个值"; shift 2 ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "未知选项：$1（用 -h 看用法）" ;;
        *)
            if [ -z "$CMD" ]; then
                CMD="$1"
            elif [ -z "$ARG" ]; then
                ARG="$1"
            else
                die "多余的参数：$1"
            fi
            shift ;;
    esac
done

need_root() {
    [ "$(id -u)" = "0" ] || die "请以 root 身份运行（sudo -i）"
}

need_git() {
    command -v git >/dev/null 2>&1 && return 0
    log "正在安装 git"
    apt-get update -qq && apt-get install -y git || die "无法安装 git"
}

confirm() {
    [ "$ASSUME_YES" = "1" ] && return 0
    local a
    read -r -p "$1 [y/N] " a
    case "$a" in y|Y|yes) return 0 ;; *) die "已取消" ;; esac
}

# git 会拒绝属于其他用户的仓库（dubious ownership），该例外按目录生效、不递归：
# $ROOT 会被 root 和 hiddify-panel 同时写入，面板子模块及它内部嵌套的仓库
# （services/panel/src/hiddifypanel/user_front）各自都是独立仓库，需各自加例外，
# 否则切版本会停在 "Unable to find current revision in submodule path"。
# 与 scripts/common/utils.sh、scripts/switch_to_fork.sh 保持同一实现（$HIDDIFY_DIR→$ROOT、
# warning→warn）；那两处由 scripts/tests/smoke_update.sh 回归。改动时三处同步。
add_safe_directory() {
    local dir="${1%/}"
    [ -n "$dir" ] || return 0
    # 全局（当前用户）与系统（root）配置都尽力注册；任一不可写就跳过，真正的兜底是
    # add_safe_directories 导出的 GIT_CONFIG_*，它不依赖配置文件、随进程树继承。
    git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$dir" || \
        git config --global --add safe.directory "$dir" 2>/dev/null
    git config --system --get-all safe.directory 2>/dev/null | grep -Fxq "$dir" || \
        git config --system --add safe.directory "$dir" 2>/dev/null
}

add_safe_directories() {
    local d dirs=()
    # 先标记 manager 与面板子模块：submodule foreach 本身可能因属主问题失败。
    dirs+=("$ROOT" "$ROOT/services/panel/src")
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        # 相对路径（.gitmodules）补 $ROOT；foreach 给的是绝对路径，直接用。
        case "$d" in
            /*) dirs+=("$d") ;;
            *) dirs+=("$ROOT/$d") ;;
        esac
    done < <(
        # 已声明的子模块（相对 $ROOT）：任何子模块初始化前就能读到
        git -C "$ROOT" config --file .gitmodules --get-regexp '\.path$' 2>/dev/null | sed 's/^[^ ]* //'
        # 已检出的子模块（含嵌套）：必须输出绝对路径 —— 嵌套层的 $sm_path 是相对父模块的
        # （如 hiddifypanel/user_front），直接拼 $ROOT 会得到不存在的路径。
        git -C "$ROOT" submodule foreach --recursive --quiet 'pwd -P' 2>/dev/null
    )
    for d in "${dirs[@]}"; do
        add_safe_directory "$d"
    done
    # 兜底：环境变量方式，即使 $HOME 不可写、无论 root 还是 hiddify-panel 都立即生效。
    local i=${GIT_CONFIG_COUNT:-0}
    for d in "${dirs[@]}"; do
        export "GIT_CONFIG_KEY_$i=safe.directory"
        export "GIT_CONFIG_VALUE_$i=${d%/}"
        i=$((i + 1))
    done
    [[ $i -gt 0 ]] && export GIT_CONFIG_COUNT=$i
}

# release 安装留下的子模块可能是"半残"的：目录里 .git 是指针文件，但指向的 gitdir
# 已经不存在（手动删过 .git/modules，或用 zip 覆盖过）。此时 submodule update 直接失败：
#   fatal: not a git repository: /.../.git/modules/...
#   fatal: Unable to find current revision in submodule path '...'
# 现象和 "dubious ownership" 几乎一样，但根因不同 —— 这类目录必须移开，--init 才能重克隆。
#
# 两个要点：
#   1) 不能只扫顶层 .gitmodules：嵌套子模块（面板里的 hiddifypanel/user_front）同样会半残；
#   2) 判定"半残"只看 .git 指针指向的 gitdir 是否存在，不用 `git rev-parse` 探测 ——
#      后者在"属主不是当前用户"时也会失败，会把好仓库误判成坏的挪走。
is_valid_submodule() {
    local path="$1" top
    [ -e "$path/.git" ] || return 1
    top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || return 1
    [ "$top" = "$path" ]
}

# 递归读 .gitmodules 收集全部已声明子模块（含嵌套），不依赖 git 能否打开子仓库
collect_submodule_paths() {
    local base="$1" p
    [ -f "$base/.gitmodules" ] || return 0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        echo "${base%/}/$p"
        collect_submodule_paths "${base%/}/$p"
    done < <(git config --file "$base/.gitmodules" --get-regexp '\.path$' 2>/dev/null | sed 's/^[^ ]* //')
}

# 半残判定：.git 是指针文件，且它指向的 gitdir 不存在
is_broken_submodule() {
    local path="$1" gd
    [ -f "$path/.git" ] || return 1
    gd=$(sed -n 's/^gitdir:[[:space:]]*//p' "$path/.git" 2>/dev/null | head -n 1)
    [ -n "$gd" ] || return 1
    case "$gd" in
        /*) ;;
        *) gd="$path/$gd" ;;
    esac
    [ -e "$gd" ] && return 1
    return 0
}

fixup_broken_submodules() {
    local path dest
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        [ -d "$path" ] || continue
        is_broken_submodule "$path" || continue
        warn "移开半残子模块 ${path#"$ROOT"/}"
        dest="${path}.release-backup"
        [ -e "$dest" ] && dest="${dest}.$(date +%s)"
        mv "$path" "$dest"
        echo "    一切正常后可删除：rm -rf $dest"
    done < <(collect_submodule_paths "$ROOT")
}

is_git_checkout() {
    [ -e "$ROOT/.git" ]
}

# 下载本 fork 里的一个脚本到临时文件，避免 curl 直接 bash 时读不到 $0
fetch_script() {
    local rel=$1 out
    out=$(mktemp) || die "无法创建临时文件"
    curl -fsSL -o "$out" "https://raw.githubusercontent.com/${REPO}/${BRANCH}/${rel}" ||
        { rm -f "$out"; die "无法下载 ${rel}（仓库 ${REPO}，分支 ${BRANCH}）"; }
    echo "$out"
}

cmd_install() {
    need_root
    if is_git_checkout; then
        log "$ROOT 已是 git 检出，改用 update"
        cmd_update
        return $?
    fi
    if [ -e "$ROOT" ] && [ -n "$(ls -A "$ROOT" 2>/dev/null)" ]; then
        die "$ROOT 已存在且不是 git 检出（像是官方 zip 安装）。
请改用：bash <(curl -fsSL https://raw.githubusercontent.com/${REPO}/${BRANCH}/scripts/onekey.sh) switch"
    fi
    need_git
    log "正在克隆 ${FORK_URL}（分支 ${BRANCH}）到 ${ROOT}"
    mkdir -p "$(dirname "$ROOT")"
    git clone --recurse-submodules -b "$BRANCH" "$FORK_URL" "$ROOT" || die "git clone 失败"
    add_safe_directories
    log "开始安装（通常 10-30 分钟）"
    bash "$ROOT/scripts/install.sh" --no-gui --no-log ||
        die "安装失败，详见 /opt/hiddify-manager/log/*"
    log "安装完成"
}

# v14.2.4 及更早版本把 .j2 的渲染产物（如 services/warp/wireguard/install.sh）也提交了进来，
# 装完/跑完它们必然被改脏；此后 ff-only 更新和 `git checkout <新 tag>` 都会被 git 直接拒绝
# （"Your local changes ... would be overwritten"），升级就卡死了。
# 服务器检出里被改动的跟踪文件只可能是这类生成物，所以更新/切版本前先把它们还原。
# 只还原"旁边存在同名 .j2 模板"的文件，避免误伤人为改动。
restore_rendered_files() {
    is_git_checkout || return 0
    local f n=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -f "$ROOT/${f}.j2" ] || [ -f "$ROOT/${f%.j2}.j2" ]; then
            git -C "$ROOT" checkout -- "$f" 2>/dev/null && n=$((n + 1))
        fi
    done < <(git -C "$ROOT" diff --name-only 2>/dev/null)
    [ "$n" -gt 0 ] && log "已还原 $n 个被渲染改写的跟踪文件（.j2 产物）"
    return 0
}

cmd_update() {
    need_root
    [ -f "$ROOT/scripts/update.sh" ] ||
        die "未找到 $ROOT/scripts/update.sh；全新机器请先用 install"
    restore_rendered_files
    log "正在更新 ${ROOT}"
    bash "$ROOT/scripts/update.sh" --no-gui --no-log || die "更新失败"
    log "更新完成"
}

cmd_reinstall() {
    need_root
    [ -f "$ROOT/scripts/install.sh" ] ||
        die "未找到 $ROOT/scripts/install.sh；全新机器请先用 install"
    log "正在按当前代码重装 ${ROOT}（不会拉取新代码）"
    bash "$ROOT/scripts/install.sh" --no-gui --no-log || die "重装失败"
    log "重装完成"
}

cmd_version() {
    need_root
    [ -n "$ARG" ] || die "用法：onekey.sh version v14.1.0b3"
    case "$ARG" in
        v*) ;;
        *) die "版本号必须以 v 开头，例如 v14.1.0b3（收到：$ARG）" ;;
    esac
    if is_git_checkout; then
        # 官方的 update_from_github() 遇到 .git 就直接 return，不给覆盖；这里自己实现
        # 等价的"换代码留数据"：强制切到该 tag 的代码，data/、generated/、虚拟环境全部留着。
        warn "$ARG 会在 $ROOT 上整包换掉代码（保留 data/、generated/ 与虚拟环境）"
        warn "数据库迁移不可逆：降级到比当前更旧的大版本前，先准备好对应版本的数据库备份"
        confirm "确认切换到 $ARG ？"
        need_git
        git -C "$ROOT" fetch -q --tags origin || die "无法获取 tag（git fetch --tags 失败）"
        git -C "$ROOT" rev-parse -q --verify "refs/tags/$ARG" >/dev/null ||
            die "找不到 tag $ARG（先在 $ROOT 里 git fetch --tags 看看有哪些版本）"
        restore_rendered_files
        log "正在把 $ROOT 的代码切换到 $ARG"
        git -C "$ROOT" checkout -f "$ARG" || die "切换失败"
        # 与 update.sh 同序：登记全部子模块（含嵌套 user_front）→ 移开半残子模块 →
        # 同步；失败后补登记再重试一次（刚克隆出来的子模块也是独立仓库，同样要过校验）。
        add_safe_directories
        fixup_broken_submodules
        git -C "$ROOT" submodule update --init --recursive --force || {
            add_safe_directories
            git -C "$ROOT" submodule update --init --recursive --force || die "子模块同步失败"
        }
        # 不带 -x（不删被 ignore 的运行时文件），并显式排除数据与虚拟环境：
        # 裸跑 git clean -fdx 会把 data/ 一起删掉，等于把面板数据清空。
        git -C "$ROOT" clean -fd \
            -e data -e generated -e .venv313 -e .venv -e 'services/panel/src/.venv*' 2>/dev/null
        bash "$ROOT/scripts/install.sh" --no-gui --no-log || die "安装 $ARG 失败"
        log "已切换到 $ARG（detached HEAD；回到主线：git -C $ROOT checkout $BRANCH）"
        return 0
    fi
    warn "$ARG 会覆盖 $ROOT 中被跟踪的文件，且不支持从更高版本降级"
    confirm "确认安装 $ARG ？"
    local dl
    dl=$(fetch_script "scripts/common/download.sh") || exit 1
    bash "$dl" "$ARG" --no-gui || { rm -f "$dl"; die "安装 $ARG 失败"; }
    rm -f "$dl"
    log "已安装 $ARG"
}

cmd_switch() {
    need_root
    [ -d "$ROOT" ] ||
        die "$ROOT 不存在；全新机器请用 install"
    log "正在把 ${ROOT} 转成 ${FORK_URL}（分支 ${BRANCH}）的 git 检出"
    local sf
    sf=$(fetch_script "scripts/switch_to_fork.sh") || exit 1
    HIDDIFY_DIR="$ROOT" HIDDIFY_FORK_BRANCH="$BRANCH" HIDDIFY_FORK_URL="$FORK_URL" \
        bash "$sf" --branch "$BRANCH" --fork "$FORK_URL" -y
    local rc=$?
    rm -f "$sf"
    [ "$rc" = "0" ] || die "转换失败（退出码 $rc）"
    log "转换完成"
}

case "$CMD" in
    install)          cmd_install ;;
    update)           cmd_update ;;
    reinstall)        cmd_reinstall ;;
    version)          cmd_version ;;
    switch)           cmd_switch ;;
    "")               usage; exit 1 ;;
    *)                usage; die "未知子命令：$CMD" ;;
esac
