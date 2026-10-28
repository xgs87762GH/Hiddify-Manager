#!/bin/bash

# 若未安装 Docker 则先安装
command -v docker &>/dev/null || curl -fsSL https://get.docker.com | sh

# 未指定 TAG 时默认 latest
TAG=${1:-latest}

# 检查 hiddify-manager 目录是否已存在
if [ -d "hiddify-manager" ]; then
    echo '目录 "hiddify-manager" 已存在。请切换到其他目录后再用 Docker 安装。'
    exit 1
fi

# 下载 docker-compose.yml；如果指定的是开发分支则直接克隆项目
if [[ "$TAG" == "develop" || "$TAG" == "dev" ]]; then
    # 若未安装 Git 则先安装
    command -v git &>/dev/null || (echo "正在安装 Git……"; sudo apt-get update && sudo apt-get install -y git)
    : "${HIDDIFY_MANAGER_REPO:=xgs87762GH/Hiddify-Manager}"
    : "${HIDDIFY_MANAGER_BRANCH:=dev-custom}"
    git clone -b "$HIDDIFY_MANAGER_BRANCH" "https://github.com/${HIDDIFY_MANAGER_REPO}.git" hiddify-manager
    cd hiddify-manager
    git submodule update --init --recursive
    # 本地源码构建：compose 文件里默认是拉取已发布镜像，这里改为本地 build。
    sed -i 's|^[[:space:]]*image: ghcr.io/xgs87762gh/hiddify-manager:.*|# &|; s|^[[:space:]]*#build: \.|    build: .|' docker-compose.yml
    docker compose -f docker-compose.yml build
else
  # 创建 hiddify-manager 目录
  mkdir hiddify-manager
  cd hiddify-manager
  : "${HIDDIFY_MANAGER_REPO:=xgs87762GH/Hiddify-Manager}"
  : "${HIDDIFY_MANAGER_BRANCH:=dev-custom}"
  wget "https://raw.githubusercontent.com/${HIDDIFY_MANAGER_REPO}/refs/heads/${HIDDIFY_MANAGER_BRANCH}/docker-compose.yml"
  wget "https://raw.githubusercontent.com/${HIDDIFY_MANAGER_REPO}/refs/heads/${HIDDIFY_MANAGER_BRANCH}/docker.env"
  # 将镜像固定到指定 tag（latest / beta / vX.Y.Z）
  sed -i "s|image: ghcr.io/xgs87762gh/hiddify-manager:.*|image: ghcr.io/xgs87762gh/hiddify-manager:$TAG|" docker-compose.yml
  docker compose pull
fi

# 为 MySQL 和 Redis 生成随机密码
mysqlpassword=$(< /dev/urandom tr -dc 'a-zA-Z0-9' | head -c49; echo)
redispassword=$(< /dev/urandom tr -dc 'a-zA-Z0-9' | head -c49; echo)

# docker.env 不存在时创建空文件
touch docker.env

# 更新或追加 Redis 密码
if grep -q "^REDIS_PASSWORD=" docker.env; then
    sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=$redispassword|" docker.env
else
    echo "REDIS_PASSWORD=$redispassword" >> docker.env
fi

# 更新或追加 MySQL 密码
if grep -q "^MYSQL_PASSWORD=" docker.env; then
    sed -i "s|^MYSQL_PASSWORD=.*|MYSQL_PASSWORD=$mysqlpassword|" docker.env
else
    echo "MYSQL_PASSWORD=$mysqlpassword" >> docker.env
fi

# SQLAlchemy / Redis 连接串必须与上面的密码保持一致
# （docker.env 里自带占位密码，只改 *_PASSWORD 会让面板仍用
# mysql-strong-password / redis-strong-password 去连接，而服务端已换成新密码）。
if grep -q "^SQLALCHEMY_DATABASE_URI=" docker.env; then
    sed -i "s|^SQLALCHEMY_DATABASE_URI=.*|SQLALCHEMY_DATABASE_URI=\"mysql+mysqldb://hiddifypanel:${mysqlpassword}@127.0.0.1:3306/hiddifypanel?charset=utf8mb4\"|" docker.env
else
    echo "SQLALCHEMY_DATABASE_URI=\"mysql+mysqldb://hiddifypanel:${mysqlpassword}@127.0.0.1:3306/hiddifypanel?charset=utf8mb4\"" >> docker.env
fi
if grep -q "^REDIS_URI_MAIN=" docker.env; then
    sed -i "s|^REDIS_URI_MAIN=.*|REDIS_URI_MAIN=\"redis://:${redispassword}@127.0.0.1:6379/1\"|" docker.env
else
    echo "REDIS_URI_MAIN=\"redis://:${redispassword}@127.0.0.1:6379/1\"" >> docker.env
fi

# 启动容器
docker compose up -d 

# 跟踪容器日志
docker compose logs -f
