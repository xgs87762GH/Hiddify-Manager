source /opt/hiddify-manager/scripts/common/utils.sh
source /opt/hiddify-manager/scripts/common/package_manager.sh
# latest= #$(get_release_version hiddify-sing-box)
version="" # 需要固定版本时在这里填写，留空则使用最新版本
mkdir -p bin run



download_package xray sb.zip "$version" "" bin/xray
# 返回 0 表示本次执行了下载，或二进制本身缺失，都需要重新解压安装。
if [ "$?" == "0"  ] || ! is_installed ./bin/xray; then
    systemctl stop hiddify-xray.service > /dev/null 2>&1 
    rm -rf bin/*
    install_package unzip 
    unzip -o sb.zip -d bin/ > /dev/null || exit 1
    rm -r sb.zip 
    chown root:root bin/xray || exit 2
    chmod +x bin/xray || exit 3
    ln -sf /opt/hiddify-manager/services/xray/bin/xray /usr/bin/xray || exit 3
    set_installed_version xray $version
fi
