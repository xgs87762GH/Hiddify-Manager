source /opt/hiddify-manager/scripts/common/utils.sh
source /opt/hiddify-manager/scripts/common/package_manager.sh

mkdir -p bin 

download_package rpxy-l4 rpxy-l4.tar.gz "0.2.4" "" bin/rpxy-l4
# 返回 0 表示本次执行了下载，或二进制本身缺失/不可执行，都需要重新解压安装。
if [ "$?" == "0" ] || [ ! -x ./bin/rpxy-l4 ]; then
    systemctl stop hiddify-rpxy-l4.service >/dev/null 2>&1
    rm -rf bin/*
    tar -xzf rpxy-l4.tar.gz -C bin/ || exit 1
    # 压缩包内的文件带版本号后缀，统一重命名为固定名字。
    mv bin/rpxy-l4-* bin/rpxy-l4 2>/dev/null || true
    chown root:root bin/rpxy-l4 || exit 2
    chmod +x bin/rpxy-l4 || exit 3
    ln -sf /opt/hiddify-manager/services/rust-rpxy-l4/bin/rpxy-l4 /usr/bin/rpxy-l4 || exit 4
    rm -f rpxy-l4.tar.gz
    # 记录版本必须与上面下载的版本一致，否则每次都会判定版本不符而重复下载。
    set_installed_version rpxy-l4 "0.2.4"
fi
