source /opt/hiddify-manager/scripts/common/utils.sh
source /opt/hiddify-manager/scripts/common/package_manager.sh
rm -rf configs/*.template

# latest= #$(get_release_version hiddify-hiddify-core)
version="" # 需要固定版本时在这里填写，留空则使用最新版本



download_package hiddify-core sb.tar.gz "$version" "" hiddify-core
# 返回 0 表示本次执行了下载，或二进制本身缺失，都需要重新解压安装。
if [ "$?" == "0"  ] || ! is_installed ./hiddify-core; then
    tar -xzf sb.tar.gz  || exit 1
    cp -rf hiddify-core-*/. . || exit 2  # -r：压缩包里还带 lib/ 目录
    # 压缩包约 29MB，装完即删；靠已安装版本记录（下方 set_installed_version）
    # 而不是压缩包文件本身来跳过下次下载。
    # （原先这里删除一个并不存在的 sb.zip，导致每次运行都失败：没建软链、没记录版本、没有 tor。）
    rm -rf sb.tar.gz hiddify-core-*/ || exit 3
    chown root:root hiddify-core || exit 4
    chmod +x hiddify-core || exit 5
    ln -sf /opt/hiddify-manager/services/hiddify-core/hiddify-core /usr/bin/hiddify-core || exit 6
    rm geosite.db 2>/dev/null 
    set_installed_version hiddify-core $version
fi

# hiddify-core 会自行启动该程序用于 Tor 出站。
install_package tor
systemctl disable --now tor 2>/dev/null || true