source /opt/hiddify-manager/scripts/common/utils.sh
source /opt/hiddify-manager/services/redis/utils.sh
cd "$(dirname -- "$0")"

if ! is_installed redis-server; then
    add-apt-repository -y universe
    install_package redis-server
fi

# 先停掉系统自带的 redis，避免出现"无密码"的空窗期
systemctl disable --now redis-server >/dev/null 2>&1 || true
pkill -9 redis-server >/dev/null 2>&1 || true

ensure_redis_data_dirs

# 旧版本把 dump.rdb 放在服务目录，迁移到 data/ 下统一保管。
if [ -f dump.rdb ] && [ ! -f "$HIDDIFY_DATA/redis/dump.rdb" ]; then
    mv dump.rdb "$HIDDIFY_DATA/redis/dump.rdb"
    chown redis:redis "$HIDDIFY_DATA/redis/dump.rdb"
fi

# 密码与运行配置只生成一次；--sync 会修复 requirepass（仅安装阶段的改动）
ensure_redis_data --sync "$(pwd)/redis.conf"

ln -sf "$(pwd)/hiddify-redis.service" /etc/systemd/system/hiddify-redis.service >/dev/null 2>&1
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl enable hiddify-redis
