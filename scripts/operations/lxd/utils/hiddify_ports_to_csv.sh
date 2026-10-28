#!/usr/bin/env bash

DIR_PATH=$(dirname "${BASH_SOURCE[0]}")/
LXC_CONTAINER_NAME="Hiddify-on-LXC"
INPUT_FILE="current.json"
OUTPUT_FILE="hiddify_service_ports_in_use.csv"
# 从 LXC 容器中取出面板生成的当前配置
lxc exec $LXC_CONTAINER_NAME -- bash -c "cat /opt/hiddify-manager/data/current.json" > ${DIR_PATH}${INPUT_FILE}

# 导出面板的对外端口（网关、服务与自定义代理），与防火墙放行的列表一致：",<名称> (<协议>),<端口>"
jq -r '
  .public_ports // {} | to_entries[] | .key as $proto | (.value // {}) | to_entries[] |
  ",\(.value) (\($proto)),\(.key)"
' ${DIR_PATH}${INPUT_FILE} >> ${DIR_PATH}${OUTPUT_FILE}

rm ${DIR_PATH}${INPUT_FILE}
