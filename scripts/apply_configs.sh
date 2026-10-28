#!/bin/bash
# 仅重新生成配置文件，不做安装。
cd /opt/hiddify-manager
DO_NOT_INSTALL=true /opt/hiddify-manager/scripts/install.sh apply_configs "$@"
#DO_NOT_INSTALL=true /opt/hiddify-manager/scripts/install.sh
