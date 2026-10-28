source /opt/hiddify-manager/scripts/common/package_manager.sh

# telemt 安装包解压后即得可执行文件，装完删除压缩包。
download_package telemt telemt.tar.gz "" "" telemt
# 返回 0 表示本次执行了下载，或二进制本身缺失，都需要重新解压安装。
if [ "$?" == "0"  ] || ! is_installed ./telemt; then
    tar -xf telemt.tar.gz || exit 1
    rm -rf telemt.tar.gz
    set_installed_version telemt
fi
