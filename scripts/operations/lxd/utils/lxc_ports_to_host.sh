#!/usr/bin/env bash

DIR_PATH=$(dirname "${BASH_SOURCE[0]}")/
MODE="advanced" # 运行模式（可选 'basic' 或 'advanced'）
LXC_CONTAINER_NAME="Hiddify-on-LXC"
CSV_FILE="hiddify_service_ports_in_use.csv"

set -e
# 用户未提供 CSV 时，自动从容器导出端口列表
if [ ! -f "${DIR_PATH}${CSV_FILE}" ]; then
    USER_CREATED_CSV="0"
    bash ${DIR_PATH}hiddify_ports_to_csv.sh
fi

# 为 CSV 中的每个端口在宿主机上建立映射
fetch_services_from_csv() {
    NEW_DEVICE_QUEUE=()

    # 用文件描述符 3 读取 CSV，避免与循环内的 read 冲突
    exec 3< "${DIR_PATH}${CSV_FILE}"

    while IFS="," read -u 3 -r PROTOCOL_DOMAIN PROTOCOL_NAME PROTOCOL_PORT ; do
        echo "$PROTOCOL_DOMAIN $PROTOCOL_NAME $PROTOCOL_PORT"
        if [[ "$MODE" == "advanced" ]]; then
            PROMPT_MESSAGE="请为 \"${PROTOCOL_DOMAIN:+$PROTOCOL_DOMAIN }$PROTOCOL_NAME\" 指定绑定到宿主机的端口 [默认=$PROTOCOL_PORT]？"
            DEFAULT_PORT=$PROTOCOL_PORT
            read -p "$PROMPT_MESSAGE" -r USER_INPUT
            USER_PORT=${USER_INPUT:-$DEFAULT_PORT}
        else
            USER_PORT=$PROTOCOL_PORT
        fi

        # 判断 TCP/UDP
        PROTOCOL="tcp"
        if [[ "$PROTOCOL_NAME" == "hysteria" || "$PROTOCOL_NAME" == "tuic" || "$PROTOCOL_DOMAIN" == "wireguard" ]]; then
            PROTOCOL="udp"
        fi

        NEW_DEVICE_QUEUE+=("lxc config device add $LXC_CONTAINER_NAME ${PROTOCOL_DOMAIN:+$PROTOCOL_DOMAIN_}${PROTOCOL_NAME} proxy listen=$PROTOCOL:0.0.0.0:$USER_PORT connect=$PROTOCOL:127.0.0.1:$PROTOCOL_PORT")
    done
}

remove_old_services() {
    for i in $(lxc config device list $LXC_CONTAINER_NAME); do
         lxc config device remove $LXC_CONTAINER_NAME "$i"
    done
}
add_new_services() {
    for job in "${NEW_DEVICE_QUEUE[@]}"; do
         eval "$job"
    done
}


fetch_services_from_csv
trap '' SIGINT		# 禁止用户中途取消，避免端口映射处于半完成状态
remove_old_services
add_new_services

# 若 CSV 是脚本自动生成的，用完即删
if [ "$USER_CREATED_CSV" == "0" ]; then
    rm ${DIR_PATH}${CSV_FILE}
fi
