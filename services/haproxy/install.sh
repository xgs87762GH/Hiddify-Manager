source /opt/hiddify-manager/scripts/common/utils.sh
rm -rf *.template
# 若旧版 sniproxy 仍在运行，先停用并移除。
if is_installed sniproxy; then
    # systemctl kill hiddify-sniproxy > /dev/null 2>&1
    systemctl stop hiddify-sniproxy >/dev/null 2>&1
    systemctl disable hiddify-sniproxy >/dev/null 2>&1
    pkill -9 sniproxy >/dev/null 2>&1
fi

# Series 3.4 from haproxy.com (AWS-LC). Need >= 3.4.6 for the mux_quic RESET_STREAM
# crash fix (#5576 / upstream #3505); pin the floor to the current patch in that series.
HAPROXY_SERIES=3.4
HAPROXY_MIN_VERSION=3.4.7
installed_ver=$(dpkg-query -W -f='${Version}' haproxy-awslc 2>/dev/null || true)
need_install=0
if [ -z "$installed_ver" ]; then
    need_install=1
elif ! dpkg --compare-versions "$installed_ver" ge "$HAPROXY_MIN_VERSION"; then
    echo "haproxy-awslc $installed_ver 低于 $HAPROXY_MIN_VERSION（QUIC 崩溃修复）；正在升级"
    need_install=1
fi

if [ "$need_install" = 1 ]; then
    CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
    REPO_TAG="ha${HAPROXY_SERIES//./}"

    echo "为 ${CODENAME} 添加 HAProxy 软件源（haproxy-${HAPROXY_SERIES}）"
    install -d -m 0755 /usr/share/keyrings
    wget -qO /usr/share/keyrings/HAPROXY-key-community.asc https://pks.haproxy.com/linux/community/RPM-GPG-KEY-HAProxy
    echo "deb [signed-by=/usr/share/keyrings/HAPROXY-key-community.asc] https://www.haproxy.com/download/haproxy/performance/ubuntu/${REPO_TAG} ${CODENAME} main" >/etc/apt/sources.list.d/haproxy.list
    apt-get update -qq
    echo "正在安装 haproxy-awslc（>= ${HAPROXY_MIN_VERSION}）"
    install_package "haproxy-awslc"
else
    echo "haproxy-awslc $installed_ver 已安装（>= ${HAPROXY_MIN_VERSION}）"
fi
# 停用发行版自带的 haproxy 服务，改由 hiddify-haproxy 接管。
systemctl kill haproxy >/dev/null 2>&1
systemctl stop haproxy >/dev/null 2>&1
systemctl disable haproxy >/dev/null 2>&1

ln -sf $(pwd)/hiddify-haproxy.service /etc/systemd/system/hiddify-haproxy.service
systemctl enable hiddify-haproxy.service
