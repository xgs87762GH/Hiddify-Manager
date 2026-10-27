#!/bin/bash

# Check if Docker is installed, if not, install it
command -v docker &>/dev/null || curl -fsSL https://get.docker.com | sh

# Set the default tag if not provided
TAG=${1:-latest}

# Check if the 'hiddify-manager' folder exists
if [ -d "hiddify-manager" ]; then
    echo 'Folder "hiddify-manager" already exists. Please change the directory to install with Docker.'
    exit 1
fi

# Download the docker-compose.yml file or clone the project if it's on dev
if [[ "$TAG" == "develop" || "$TAG" == "dev" ]]; then
    # Check if Git is installed, if not, install it
    command -v git &>/dev/null || (echo "Installing Git..."; sudo apt-get update && sudo apt-get install -y git)
    : "${HIDDIFY_MANAGER_REPO:=xgs87762GH/Hiddify-Manager}"
    : "${HIDDIFY_MANAGER_BRANCH:=dev-custom}"
    git clone -b "$HIDDIFY_MANAGER_BRANCH" "https://github.com/${HIDDIFY_MANAGER_REPO}.git" hiddify-manager
    cd hiddify-manager
    git submodule update --init --recursive
    # Local source build: compose ships with a published image line; switch to build.
    sed -i 's|^[[:space:]]*image: ghcr.io/xgs87762gh/hiddify-manager:.*|# &|; s|^[[:space:]]*#build: \.|    build: .|' docker-compose.yml
    docker compose -f docker-compose.yml build
else
  # Create the 'hiddify-manager' directory
  mkdir hiddify-manager
  cd hiddify-manager
  : "${HIDDIFY_MANAGER_REPO:=xgs87762GH/Hiddify-Manager}"
  : "${HIDDIFY_MANAGER_BRANCH:=dev-custom}"
  wget "https://raw.githubusercontent.com/${HIDDIFY_MANAGER_REPO}/refs/heads/${HIDDIFY_MANAGER_BRANCH}/docker-compose.yml"
  wget "https://raw.githubusercontent.com/${HIDDIFY_MANAGER_REPO}/refs/heads/${HIDDIFY_MANAGER_BRANCH}/docker.env"
  # Pin the published image to the requested tag (latest / beta / vX.Y.Z).
  sed -i "s|image: ghcr.io/xgs87762gh/hiddify-manager:.*|image: ghcr.io/xgs87762gh/hiddify-manager:$TAG|" docker-compose.yml
  docker compose pull
fi

# Generate random passwords for MySQL and Redis
mysqlpassword=$(< /dev/urandom tr -dc 'a-zA-Z0-9' | head -c49; echo)
redispassword=$(< /dev/urandom tr -dc 'a-zA-Z0-9' | head -c49; echo)

# Create an empty docker.env if not existing
touch docker.env

# Lookup variable name for redis password and update its value or append the whole line when required 
if grep -q "^REDIS_PASSWORD=" docker.env; then
    sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=$redispassword|" docker.env
else
    echo "REDIS_PASSWORD=$redispassword" >> docker.env
fi

# Lookup variable name for MySql password and update its value or append the whole line when required
if grep -q "^MYSQL_PASSWORD=" docker.env; then
    sed -i "s|^MYSQL_PASSWORD=.*|MYSQL_PASSWORD=$mysqlpassword|" docker.env
else
    echo "MYSQL_PASSWORD=$mysqlpassword" >> docker.env
fi

# Keep SQLAlchemy / Redis URIs in sync with the passwords above (docker.env ships
# placeholder passwords; only rewriting *_PASSWORD left the panel connecting with
# mysql-strong-password / redis-strong-password while MariaDB/Redis used the new ones).
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

# Start the containers using Docker Compose
docker compose up -d 

# Follow the logs from the containers
docker compose logs -f
