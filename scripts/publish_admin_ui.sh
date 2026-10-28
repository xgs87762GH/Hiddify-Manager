#!/usr/bin/env bash
# 为当前面板 commit 发布 admin UI 构建产物。
#
# 服务器因此不必再跑 npm：build_panel_admin_ui 会到
# scripts/admin-ui-prebuilt.tsv 里查对应的 commit，从 `prebuilt` 分支下载 tarball，
# 校验 sha256 后再解压。
#
#   bash scripts/publish_admin_ui.sh [--panel-src DIR] [--no-build] [--no-push]
#
# 请在面板的普通分支检出中运行（detached HEAD 只会告警，子模块仍可用，
# 但无法在那里创建 manifest commit）。
set -euo pipefail

# 帮助文本写在函数里，而不是用 sed -n '2,11p' "$0" 截取文件头：
# 后者硬编码行号，头注释一增删就会截断或把代码行打印出来。
usage() {
    cat <<'EOF'
为当前面板 commit 发布 admin UI 构建产物。

  bash scripts/publish_admin_ui.sh [--panel-src DIR] [--no-build] [--no-push]

--panel-src DIR   使用指定的面板源码目录（默认 services/panel/src）
--no-build        跳过 npm 构建，直接复用已有的静态产物
--no-push         只创建本地 manifest commit，不推送到远端
EOF
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/services/panel/src"
BRANCH="prebuilt"
KEEP_ARTIFACTS=6
DO_BUILD=1
DO_PUSH=1

while [ $# -gt 0 ]; do
    case "$1" in
        --panel-src) SRC="$2"; shift 2 ;;
        --no-build) DO_BUILD=0; shift ;;
        --no-push) DO_PUSH=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

SRC="${SRC%/}"
[ -f "$SRC/hiddifypanel/admin_v2/package.json" ] || { echo "不是面板源码目录：$SRC" >&2; exit 1; }

REMOTE="$(git -C "$SRC" remote get-url origin)"
SLUG="$(printf '%s' "$REMOTE" | sed -E 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
[ -n "$SLUG" ] || { echo "无法从 $REMOTE 解析出 owner/repo" >&2; exit 1; }

REV="$(git -C "$SRC" rev-parse HEAD)"
SHORT="$(git -C "$SRC" rev-parse --short=12 HEAD)"
STATIC="$SRC/hiddifypanel/static"
UI="$SRC/hiddifypanel/admin_v2"

if [ "$DO_BUILD" = 1 ]; then
    echo "正在为 $SHORT 构建 admin UI"
    if [ ! -d "$UI/node_modules" ]; then
        ( cd "$UI" && npm ci --no-audit --no-fund --loglevel=error )
    fi
    ( cd "$UI" && npm run build )
fi
[ -f "$STATIC/admin-v2/index.html" ] || { echo "$STATIC/admin-v2 中没有构建产物" >&2; exit 1; }

WORK="$(mktemp -d /var/tmp/hiddify-publish-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
ARTIFACT="admin-v2-$SHORT.tar.gz"
tar -czf "$WORK/$ARTIFACT" -C "$STATIC" admin-v2
SUM="$(sha256sum "$WORK/$ARTIFACT" | cut -d' ' -f1)"
SIZE="$(du -h "$WORK/$ARTIFACT" | cut -f1)"
echo "产物：$ARTIFACT（$SIZE）sha256=$SUM"

# 把产物推到专用分支，只保留最近几个，让服务器上的浅克隆保持较小体积。
REPO="$WORK/repo"
if git clone --depth 1 --branch "$BRANCH" --single-branch --quiet "$REMOTE" "$REPO" 2>/dev/null; then
    :
else
    git init --quiet -b "$BRANCH" "$REPO"
    git -C "$REPO" remote add origin "$REMOTE"
fi
cp "$WORK/$ARTIFACT" "$REPO/$ARTIFACT"
# 清理最旧的产物。没有匹配文件时 `ls` 会以 2 退出，在
# `set -euo pipefail` 下会让整个发布在推送前中止，因此刻意丢弃其状态。
( cd "$REPO" && ls -t admin-v2-*.tar.gz 2>/dev/null | tail -n +$((KEEP_ARTIFACTS + 1)) | xargs -r rm -f ) || true
git -C "$REPO" add -A
if git -C "$REPO" diff --cached --quiet; then
    echo "产物已发布过，分支保持不变"
else
    git -C "$REPO" -c user.name="admin-ui bot" -c user.email="bot@localhost" commit --quiet -m "admin-v2 $SHORT"
    if [ "$DO_PUSH" = 1 ]; then
        git -C "$REPO" push --quiet origin "$BRANCH"
        echo "已推送 $BRANCH -> $SLUG"
    else
        echo "--no-push：产物仅本地提交于 $REPO（临时目录）"
    fi
fi

# 校验和记录在 manager 侧，紧挨着它所属的子模块指针：
# 若提交到面板仓库，会把面板 HEAD 推到产物之后。
MANIFEST="$ROOT/scripts/admin-ui-prebuilt.tsv"
[ -f "$MANIFEST" ] || printf '# <panel commit>  <artifact>  <sha256>\n' > "$MANIFEST"
tmpm="$(mktemp)"
awk -v r="$REV" '$1 != r' "$MANIFEST" > "$tmpm"
printf '%s  %s  %s\n' "$REV" "$ARTIFACT" "$SUM" >> "$tmpm"
mv "$tmpm" "$MANIFEST"
echo "已更新 $MANIFEST"

MGR_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
if [ "$MGR_BRANCH" = "HEAD" ]; then
    echo "manager 处于 detached HEAD，请自行提交 manifest 与子模块指针"
    exit 0
fi
git -C "$ROOT" add -- scripts/admin-ui-prebuilt.tsv services/panel/src
if git -C "$ROOT" diff --cached --quiet; then
    echo "manifest 与子模块指针已是最新"
    exit 0
fi
git -C "$ROOT" -c user.name="admin-ui bot" -c user.email="bot@localhost" commit --quiet -m "chore: publish admin UI artifact for panel $SHORT"
if [ "$DO_PUSH" = 1 ]; then
    git -C "$ROOT" push --quiet origin "$MGR_BRANCH"
    echo "已推送 $MGR_BRANCH 到 manager 远端"
fi
