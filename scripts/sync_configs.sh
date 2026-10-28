#!/bin/bash
# 从面板重新生成服务端配置（不重启服务）。
cd /opt/hiddify-manager/services/panel
source /opt/hiddify-manager/scripts/common/utils.sh
ensure_hiddify_data_dirs
activate_python_venv

reload_all_configs >/dev/null
if [[ $? != 0 ]]; then
    error "读取面板配置失败"
    exit 4
fi

# 将模板中的变量替换为实际值
bash /opt/hiddify-manager/scripts/common/replace_variables.sh
