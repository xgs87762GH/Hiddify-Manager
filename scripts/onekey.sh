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
  version <tag>    切换到指定发布版本，如 v14.1.0b3（仅非 git 安装）
  switch           官方安装 → 本 fork 检出（等价于 switch_to_fork.sh）

选项：
  --dir <path>     安装目录（默认 /opt/hiddify-manager）
  --branch <name>  跟踪的分支（默认 dev-custom）
  --fork <url>     fork 地址
  -y, --yes        不再询问确认
  -h, --help       显示本帮助

例子：
  bash <(curl -fsSL https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/dev-custom/scripts/onekey.sh) install
  bash <(curl -fsSL https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/dev-custom/scripts/onekey.sh) update
  bash <(curl -fsSL https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/dev-custom/scripts/onekey.sh) version v14.1.0b3
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

# git 会拒绝属于其他用户的仓库（dubious ownership），该例外按目录生效、不递归，
# 而 $ROOT 及其子模块会被 root 和 hiddify-panel 同时写入。
add_safe_directory() {
    local dir="${1%/}"
    [ -n "$dir" ] || return 0
    git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$dir" || \
        git config --global --add safe.directory "$dir" 2>/dev/null
    git config --system --get-all safe.directory 2>/dev/null | grep -Fxq "$dir" || \
        git config --system --add safe.directory "$dir" 2>/dev/null
}

add_safe_directories() {
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
        die "$ROOT 是 git 检出，不要用 zip 覆盖它。请改用：
  cd $ROOT && git fetch --tags origin && git checkout $ARG && bash scripts/install.sh --no-gui --no-log
（这会进入 detached HEAD；回到主线：git checkout $BRANCH）
若 git 报 \"Your local changes ... would be overwritten\"：那是 .j2 渲染产物被安装改写，
先执行 bash <(curl -fsSL .../onekey.sh) update 让它自动还原，或手动 git checkout -- 。"
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
