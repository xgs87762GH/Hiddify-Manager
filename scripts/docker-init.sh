#!/bin/bash
set -e

mkdir -p /opt/hiddify-manager/data/cert /opt/hiddify-manager/data/log


# 容器内用轻量替代实现覆盖 systemctl / journalctl
chmod +x /opt/hiddify-manager/services/docker/systemctl /opt/hiddify-manager/services/docker/journalctl 
cp /opt/hiddify-manager/services/docker/systemctl /usr/bin/systemctl 
cp /opt/hiddify-manager/services/docker/journalctl /usr/bin/journalctl 


# 校验 REDIS_URI_MAIN 是否设置
if [ -z "$REDIS_URI_MAIN" ]; then
    echo "必须设置环境变量 REDIS_URI_MAIN"
    exit 1
 
fi


# 校验 SQLALCHEMY_DATABASE_URI 是否设置
if [ -z "$SQLALCHEMY_DATABASE_URI" ]; then
    echo "必须设置环境变量 SQLALCHEMY_DATABASE_URI"
    exit 1
 
fi

source .venv313/bin/activate
# 镜像里已包含构建好的面板前端；若用挂载的源码目录覆盖（docker-compose.override），
# 需要自备构建产物：请在宿主机上构建，容器内没有 Node.js。
if [ ! -f services/panel/src/hiddifypanel/static/admin-v2/index.html ] ||
   [ ! -f services/panel/src/hiddifypanel/static/user-front/manifest.json ]; then
    echo "警告：挂载的面板源码中没有构建好的前端。请在宿主机上执行："
    echo "    make ui"
    echo "  （或：cd services/panel/src && make build-ui）"
fi
uv pip install -e services/panel/src 

DO_NOT_INSTALL=true /opt/hiddify-manager/scripts/install.sh docker --no-gui $@
/opt/hiddify-manager/scripts/status.sh --no-gui

echo "Hiddify 已启动！5 秒后开始显示系统日志"
hiddify admin
sleep 5
tail -f /opt/hiddify-manager/data/log/*
