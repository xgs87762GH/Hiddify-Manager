#!/bin/bash

# 兼容旧调用方式：若设置了 VER，则把它作为第一个参数
if [[ "$VER" != "" ]];then
    set -- $VER  $@

fi

echo "$0 的输入参数为 $@"


if [[ " $@ " != *"--no-gui"* ]] &&  [[ "$0" == "bash" ]]; then
    echo "本脚本已废弃！请改用以下命令："
    echo ""
    echo "bash <(curl https://i.hiddify.com/$1)"
    echo ""
    exit 1
fi

echo "正在下载 '$@'"

# v8 是历史迁移路径：本 fork 无法提供远古的 hiddify-config 代码，
# 因此这里刻意仍指向官方旧仓库。不要用它来"更新"。
if [[ " $@ " == *" v8 "* ]]; then
    sudo bash -c "$(curl -sLfo- https://raw.githubusercontent.com/hiddify/hiddify-config/main/scripts/common/download_install.sh)"
    exit $?
fi


mkdir -p /tmp/hiddify/
chmod 600 /tmp/hiddify/
rm -rf /tmp/hiddify/*

# 所有下载都来自你自己的 fork、你自己的定制分支（绝不指向官方组织，
# 也不使用 fork 的 main/dev 等同步分支）。需要时可覆盖：
#   export HIDDIFY_MANAGER_REPO="xgs87762GH/Hiddify-Manager"
#   export HIDDIFY_MANAGER_BRANCH="dev-custom"
: "${HIDDIFY_MANAGER_REPO:=xgs87762GH/Hiddify-Manager}"
: "${HIDDIFY_MANAGER_BRANCH:=dev-custom}"

branch="${1:-release}"

if [[ "$branch" == v* ]]; then
    # 以 v 开头视为 tag（你 fork 上的发布标签）
    case "$branch" in
        v9*|v10*|v11*|v12*)
            base_url="https://raw.githubusercontent.com/${HIDDIFY_MANAGER_REPO}/refs/tags/$branch/"
            ;;
        *)
            base_url="https://raw.githubusercontent.com/${HIDDIFY_MANAGER_REPO}/refs/tags/$branch/scripts"
            ;;
    esac
else
    # release / beta / dev 等一律使用你的定制分支
    base_url="https://raw.githubusercontent.com/${HIDDIFY_MANAGER_REPO}/refs/heads/${HIDDIFY_MANAGER_BRANCH}/scripts"
fi
# -f：404/502 的响应体绝不能被当作安装器下载下来，也不能被 source 成 utils.sh。
curl -fsSL -o /tmp/hiddify/hiddify_installer.sh "$base_url/common/hiddify_installer.sh" || {
    echo "无法从 $base_url 下载 hiddify_installer.sh" >&2; exit 1; }
curl -fsSL -o /tmp/hiddify/utils.sh "$base_url/common/utils.sh" || {
    echo "无法从 $base_url 下载 utils.sh" >&2; exit 1; }
chmod 700 /tmp/hiddify/*

/tmp/hiddify/hiddify_installer.sh $@
