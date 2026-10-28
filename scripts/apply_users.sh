#!/bin/bash
# 重新生成随用户列表变化的配置，然后重载对应服务。
# $1: "domain"（域名有变化：telemt 需重启）或 "users"（仅用户变化：xray 会从面板实时获取）。
# 输出与错误写入日志目录：apply-users.out.log 和 apply-users.err.log。
cd /opt/hiddify-manager
source /opt/hiddify-manager/scripts/common/utils.sh

if [ "$(id -u)" -ne 0 ]; then
    echo "本脚本必须以 root 身份运行" >&2
    exit 1
fi

apply_users() {
    ensure_generated_permissions
    echo "正在导出用户配置到 $HIDDIFY_GENERATED"
    dump_server_configs "xray,hiddify-core,wireguard,telemt" || {
        echo "导出用户配置到 $HIDDIFY_GENERATED 失败" >&2
        return 1
    }
    echo "正在重载服务"
    ensure_generated_permissions
    local pids=() rc=0 pid
    for svc in xray hiddify-core wireguard telegram/telemt; do 
        echo "正在重载 $svc"
        run_timed "$svc" bash "$HIDDIFY_SERVICES/$svc/reload.sh" "$1" &
        pids+=("$!")
    done
    echo "等待服务重载完成"
    # 直接 `wait` 即使有重载失败也会返回 0：逐个等待并记录最差结果。
    for pid in "${pids[@]}"; do
        wait "$pid" || rc=1
    done
    if [ "$rc" -ne 0 ]; then
        echo "部分服务重载失败；磁盘上的配置比正在运行的更新" >&2
        return 1
    fi
    echo "服务已重载完成"
}

# 与 install/update 共用同一把锁：并发执行会同时改写 generated/ 并重启服务。
with_lock apply-users run_logged apply-users apply_users "$1"
