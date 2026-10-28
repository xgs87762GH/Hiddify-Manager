export HIDDIFY_DIR="/opt/hiddify-manager"
export HIDDIFY_SCRIPTS="$HIDDIFY_DIR/scripts"
export HIDDIFY_SERVICES="$HIDDIFY_DIR/services"
export HIDDIFY_DATA="$HIDDIFY_DIR/data"
export HIDDIFY_GENERATED="$HIDDIFY_DIR/generated"
# 锁属于运行期状态：放在 tmpfs（/run），绝不能放 data/
#（会被备份、恢复、整机拷贝带走）。
export HIDDIFY_LOCKS="/run/hiddify/locks"
# 面板持久化配置的唯一来源——必须与 hiddifypanel/__init__.py 和 base.py 里的默认值一致。
export HIDDIFY_PANEL_CFG_PATH="$HIDDIFY_DATA/hiddify-panel/app.cfg"
export venv_path="/opt/hiddify-manager/.venv313"

# ---------------------------------------------------------------------------------
# External database: the panel normally uses the locally installed MariaDB and
# Redis, but it can point at a remote instance instead by defining the
# connection URIs (docker: docker.env; bare-metal: export in the shell that
# runs install.sh / updates):
#
#     SQLALCHEMY_DATABASE_URI="mysql+mysqldb://user:pass@db-host:3306/hiddifypanel?charset=utf8mb4"
#     REDIS_URI_MAIN="redis://:pass@redis-host:6379/0"
#
# services/panel/run.sh persists both URIs in app.cfg together with a
# HIDDIFY_EXTERNAL_* marker, so later installs/updates remember "external"
# even when the env vars are no longer set. Marker names must not start with
# "SQLALCHEMY_DATABASE_URI" / "REDIS_URI": run.sh deletes the config lines by
# those prefixes when it rewrites its config.
# See docs/EXTERNAL_DATABASE.md.
# ---------------------------------------------------------------------------------

# True when the panel is configured to use an external MySQL/MariaDB server
# (URI in the environment right now, or persisted by a previous run).
function is_panel_db_external() {
    [ -n "${SQLALCHEMY_DATABASE_URI:-}" ] && return 0
    [ -f "$HIDDIFY_PANEL_CFG_PATH" ] && grep -q '^HIDDIFY_EXTERNAL_DB=True' "$HIDDIFY_PANEL_CFG_PATH" && return 0
    return 1
}

# True when the panel is configured to use an external Redis server.
function is_panel_redis_external() {
    [ -n "${REDIS_URI_MAIN:-}" ] && return 0
    [ -f "$HIDDIFY_PANEL_CFG_PATH" ] && grep -q '^HIDDIFY_EXTERNAL_REDIS=True' "$HIDDIFY_PANEL_CFG_PATH" && return 0
    return 1
}

# 备份是完整数据库导出（含密钥、用户 ID）：属主为面板用户，且不可被其他人读取。
# hiddify-panel-cli backup 以 hiddify-panel 身份运行，因此 root 属主的目录
#（例如面板曾以 root 运行留下）会让每次备份都报 "Permission denied"。
function ensure_panel_backup_dir() {
    local dir="$HIDDIFY_DATA/backup"
    mkdir -p "$dir"
    if id -u hiddify-panel >/dev/null 2>&1; then
        chown -R hiddify-panel:hiddify-panel "$dir"
    fi
    chmod 750 "$dir"
    find "$dir" -type f -exec chmod 640 {} + 2>/dev/null || true
}

function ensure_service_group() {
    groupadd -f hiddify-common
    local user
    for user in root hiddify-panel dns_proxy hiddify-cli tgproxy; do
        id -u "$user" >/dev/null 2>&1 && usermod -aG hiddify-common "$user"
    done
}

# generated/ 的属主是 hiddify-panel，属组是 hiddify-common。
# 目录保持可进入（setgid 2770）；配置文件为 660，这样面板能改写，
# 同时组内各服务账号都能读取。
function ensure_generated_permissions() {
    ensure_service_group
    mkdir -p "$HIDDIFY_GENERATED/client" "$HIDDIFY_GENERATED/include"
    chown -R $USER:hiddify-common "$HIDDIFY_GENERATED"
    find "$HIDDIFY_GENERATED" -type d -exec chmod 2770 {} \;
    find "$HIDDIFY_GENERATED" -type f -exec chmod 660 {} \;
}

# data/cert：HAProxy 实际使用的证书。由面板根据数据库写入（hiddifypanel/acme/store.py）：
# 属主 hiddify-panel、属组 hiddify-common（setgid，新建文件自动继承），文件权限 640。
function ensure_cert_dir() {
    local dir="$HIDDIFY_DATA/cert"
    mkdir -p "$dir"
    ensure_service_group
    if id -u hiddify-panel >/dev/null 2>&1; then
        chown -R hiddify-panel:hiddify-common "$dir"
    fi
    chmod 2750 "$dir"
    find "$dir" -type f -exec chmod 640 {} + 2>/dev/null || true
}

# v14 之前的日志放在 data/log/system：把它们上移到 data/log。正在运行的服务在服务重启
#（新单元已指向 data/log）之前，会继续写自己那个已被移动的文件（同一文件系统）。
function migrate_log_dir() {
    local old="$HIDDIFY_DATA/log/system"
    [ -d "$old" ] && [ ! -L "$old" ] || return 0
    local entry
    for entry in "$old"/* "$old"/.[!.]*; do
        [ -e "$entry" ] || continue
        # mv 保持 inode 不变：持有该文件句柄的进程会继续写到它的新位置
        [ -e "$HIDDIFY_DATA/log/${entry##*/}" ] || mv "$entry" "$HIDDIFY_DATA/log/"
    done
    rm -rf "$old"
}

function ensure_hiddify_data_dirs() {
    # 只处理各服务共用的固定路径；各服务的私有数据目录由各自创建。
    mkdir -p \
        "$HIDDIFY_DATA/log" \
        "$HIDDIFY_GENERATED/client" \
        "$HIDDIFY_GENERATED/include"
    migrate_log_dir
    ensure_panel_backup_dir
    ensure_cert_dir
    ensure_generated_permissions
}

# 开机菜单就是 bashrc 里的一行。关闭它就是把该行注释掉（`# hiddify`）。
# 安装时必须保留这条注释，不能又追加一次 `hiddify`。

function hiddify_bashrc_menu_disabled() {
    local bashrc="${1:-$HOME/.bashrc}"
    [ -f "$bashrc" ] && grep -qE '^[[:space:]]*#[[:space:]]*hiddify[[:space:]]*$' "$bashrc"
}

function hiddify_bashrc_strip_legacy_menu() {
    local bashrc="${1:-$HOME/.bashrc}"
    [ -f "$bashrc" ] || return 0
    sed -i \
        -e 's|/opt/hiddify-config/menu.sh||g' \
        -e 's|/opt/hiddify-server/menu.sh||g' \
        -e 's|/opt/hiddify-manager/menu.sh||g' \
        -e 's|/opt/hiddify-manager/scripts/menu.sh||g' \
        -e 's|cd /opt/hiddify-manager/||g' \
        "$bashrc"
}

function hiddify_bashrc_disable_menu() {
    local bashrc="${1:-$HOME/.bashrc}"
    touch "$bashrc"
    hiddify_bashrc_strip_legacy_menu "$bashrc"
    if grep -qE '^[[:space:]]*hiddify[[:space:]]*$' "$bashrc"; then
        sed -i -E 's/^[[:space:]]*hiddify[[:space:]]*$/# hiddify/' "$bashrc"
    elif ! hiddify_bashrc_menu_disabled "$bashrc"; then
        echo "# hiddify" >>"$bashrc"
    fi
}

function hiddify_bashrc_enable_menu() {
    local bashrc="${1:-$HOME/.bashrc}"
    touch "$bashrc"
    hiddify_bashrc_strip_legacy_menu "$bashrc"
    if hiddify_bashrc_menu_disabled "$bashrc"; then
        sed -i -E 's/^[[:space:]]*#[[:space:]]*hiddify[[:space:]]*$/hiddify/' "$bashrc"
    fi
    if ! grep -qE '^[[:space:]]*hiddify[[:space:]]*$' "$bashrc"; then
        echo "hiddify" >>"$bashrc"
    fi
}

# 仅当用户没有把启动行注释掉时才追加。
function hiddify_bashrc_install_menu() {
    local bashrc="${1:-$HOME/.bashrc}"
    touch "$bashrc"
    hiddify_bashrc_strip_legacy_menu "$bashrc"
    if hiddify_bashrc_menu_disabled "$bashrc"; then
        return 0
    fi
    if ! grep -qE '^[[:space:]]*hiddify[[:space:]]*$' "$bashrc"; then
        echo "hiddify" >>"$bashrc"
    fi
}

# 用法：hiddify_random_password [长度]（默认 49）
function hiddify_random_password() {
    local len="${1:-49}"
    < /dev/urandom tr -dc 'a-zA-Z0-9' | head -c "$len"
    echo
}

# 所有版本查询与下载都指向你自己的 fork，绝不走官方组织。
# 需要时可覆盖：
#   export HIDDIFY_GITHUB_USER="yourname"
#   export HIDDIFY_MANAGER_REPO="yourname/Hiddify-Manager"
#   export HIDDIFY_PANEL_REPO="yourname/hiddifypanel"
: "${HIDDIFY_GITHUB_USER:=xgs87762GH}"
: "${HIDDIFY_MANAGER_REPO:=${HIDDIFY_GITHUB_USER}/Hiddify-Manager}"
: "${HIDDIFY_PANEL_REPO:=${HIDDIFY_GITHUB_USER}/hiddifypanel}"
# 开发版安装 / 提交日期探测使用的定制分支（绝不是与上游同步的 main/dev）。
: "${HIDDIFY_MANAGER_BRANCH:=dev-custom}"
: "${HIDDIFY_PANEL_BRANCH:=dev-custom}"

# git 会拒绝操作属于其他用户的仓库（"dubious ownership"），而该例外是按仓库目录
# 生效、不会递归：manager 检出会被 root 和 hiddify-panel 同时写入，面板子模块
#（以及它内部嵌套的仓库）各自都是独立仓库，需要各自加例外。任何可能触及子模块的
# git 命令之前都要调用本函数，否则更新会停在
# "Unable to find current revision in submodule path"。
function add_safe_directory() {
    local dir="${1%/}"
    [[ -n "$dir" ]] || return 0
    # 全局配置（当前用户，需要 $HOME 可写）与系统配置（需要 root，对所有用户生效）都尽力注册。
    # 任一处不可写（典型：面板以 hiddify-panel 身份运行、却带着 root 的 $HOME）就跳过——真正兜底的
    # 是 add_safe_directories 导出的 GIT_CONFIG_* 环境变量，它不依赖任何配置文件，谁跑都生效。
    git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$dir" || \
        git config --global --add safe.directory "$dir" 2>/dev/null
    git config --system --get-all safe.directory 2>/dev/null | grep -Fxq "$dir" || \
        git config --system --add safe.directory "$dir" 2>/dev/null
}

function add_safe_directories() {
    local d dirs=()
    # 先标记 manager 和面板子模块。以前用管道 + while 子 shell，一旦 submodule
    # foreach 本身因 dubious ownership 失败，这两项就会被跳过。
    dirs+=("$HIDDIFY_DIR" "$HIDDIFY_DIR/services/panel/src")
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        dirs+=("$HIDDIFY_DIR/$d")
    done < <(
        # 已声明的子模块：在任何一个被初始化之前就能读到
        git -C "$HIDDIFY_DIR" config --file .gitmodules --get-regexp '\.path$' 2>/dev/null | sed 's/^[^ ]* //'
        # 嵌套子模块：父模块检出后才可见
        git -C "$HIDDIFY_DIR" submodule foreach --recursive --quiet 'echo "$sm_path"' 2>/dev/null
    )

    # 尽量写进配置文件（持久、对后续独立进程也有效）。
    for d in "${dirs[@]}"; do
        add_safe_directory "$d"
    done

    # 兜底：导出的 GIT_CONFIG_* 环境变量随进程树继承，即使 $HOME 不可写、也无论以
    # root 还是 hiddify-panel 身份运行，本次更新里所有 git 子调用都能读到例外。
    local i=${GIT_CONFIG_COUNT:-0}
    for d in "${dirs[@]}"; do
        export "GIT_CONFIG_KEY_$i=safe.directory"
        export "GIT_CONFIG_VALUE_$i=${d%/}"
        i=$((i + 1))
    done
    [[ $i -gt 0 ]] && export GIT_CONFIG_COUNT=$i
}

# 把调用方使用的旧上游仓库名（hiddify-panel、Hiddify-Panel、hiddify-manager……）
# 映射到你 fork 的仓库，确保每次版本检查和下载都由 fork 提供，而不是 hiddify/*。
function fork_repo() {
    local name
    name=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$name" in
        *panel*) echo "$HIDDIFY_PANEL_REPO" ;;
        *manager*) echo "$HIDDIFY_MANAGER_REPO" ;;
        *) echo "$HIDDIFY_GITHUB_USER/$1" ;;
    esac
}

# 按仓库名（面板 / manager）返回默认的开发分支。
function fork_dev_branch() {
    local name
    name=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$name" in
        *panel*) echo "$HIDDIFY_PANEL_BRANCH" ;;
        *) echo "$HIDDIFY_MANAGER_BRANCH" ;;
    esac
}

# 开发版安装的版本号：分支上最新提交的日期，格式 MM-DDTHH:MM（UTC）。
# 默认使用你定制的分支（HIDDIFY_*_BRANCH），而不是与上游同步的 `dev`。
# GitHub 的 commits 页面改过 JSON 结构（提交被挪到 .payload.commitsRefRoute 下），
# 旧路径会解析出 "null" 和空 VERSION。因此依次尝试该页面、它的 Atom 源和 API，
# 且只从中取日期。
function get_commit_version() {
    local repo="$1" branch="${2:-$(fork_dev_branch "$1")}" date="" page fork
    fork=$(fork_repo "$repo")
    page=$(curl -sL -m 20 -H "Accept: application/json" "https://github.com/$fork/commits/$branch.atom")
    date=$(echo "$page" | jq -r '(.payload.commitsRefRoute.commitGroups // .payload.commitGroups // [])[0].commits[0].committedDate // empty' 2>/dev/null)
    if ! [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
        date=$(curl -sL -m 20 "https://github.com/$fork/commits/$branch.atom" | grep -m 1 -o '<updated>[^<]*</updated>' | sed -E 's#</?updated>##g')
    fi
    if ! [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
        date=$(curl -sL -m 20 "https://api.github.com/repos/$fork/commits/$branch" | jq -r '.commit.committer.date // empty' 2>/dev/null)
    fi
    if ! [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
        echo "无法从 GitHub 读取 $repo（$branch）的最新提交日期" >&2
        return 1
    fi
    # 统一转成 UTC：页面给出的是提交者时区偏移（+03:30），Atom 源和 API 给的是 Z；
    # update.sh 会拿它与已安装的 VERSION 比较，所以同一提交在各来源必须得到相同文本。
    local utc
    utc=$(date -u -d "$date" +%Y-%m-%dT%H:%M 2>/dev/null) && date="$utc"
    echo "${date:5:11}"
}

function get_pre_release_version() {
    # lastversion "$1" --pre --at github
    VERSION=$(curl -sL "https://api.github.com/repos/$(fork_repo "$1")/releases" | jq -r 'map(select(.prerelease == true or .draft == true)) | sort_by(.created_at) | last | .tag_name')
    VERSION=${VERSION/#v/}
    echo $VERSION
}

function get_release_version() {
    local fork
    fork=$(fork_repo "$1")
    VERSION=$(curl -sL "https://api.github.com/repos/$fork/releases" | jq -r 'map(select(.prerelease == false)) | sort_by(.created_at) | last | .tag_name')
    if [ -z $VERSION ]; then
        # COMMIT_URL=https://api.github.com/repos/$fork/releases/latest
        # VERSION=$(curl -s --connect-timeout 1 $COMMIT_URL | jq -r .tag_name)
        location=$(curl -sI "https://github.com/$fork/releases/latest" | grep -i location | awk -F' ' '{print $2}' | tr -d '\r')
        if [[ $location == *"latest"* ]]; then
            location=$(curl -sI "$location" | grep -i location | awk -F' ' '{print $2}' | tr -d '\r')
        fi

        VERSION=$(echo $location | rev | awk -F/ '{print $1}' | rev)
        VERSION="${VERSION//$'\r'/}"
    fi
    VERSION=${VERSION/#v/}
    echo $VERSION
}

function hiddifypanel_path() {
    activate_python_venv
    timeout 15 /opt/hiddify-manager/.venv313/bin/python -c "import os,hiddifypanel;print(os.path.dirname(hiddifypanel.__file__),end='')" 2>&1 || echo "面板尚未安装。"
}
function get_installed_panel_version() {
    activate_python_venv
    version=$(cat "$(hiddifypanel_path)/VERSION" 2>/dev/null)
    if [ -z "$version" ]; then
        version="-"
    fi
    echo $version
}
function get_installed_config_version() {
    version=$(cat /opt/hiddify-manager/VERSION 2>/dev/null)

    if [ -z "$version" ]; then
        version="-"
    fi
    echo $version
}

function get_package_mode() {
    reload_all_configs | jq -r '.chconfigs["0"].package_mode'
}

function error() {
    echo -e "\033[91m$1\033[0m" >&2
}

function warning() {
    echo -e "\033[93m$1\033[0m" >&2
}

function success() {
    echo -e "\033[92m$1\033[0m" >&2
}

function get_pretty_service_status() {
    status=$(systemctl is-active $1)
    if [ $? == 0 ]; then
        success $status
	else
        error $status
	fi
}
function add_DNS_if_failed() {
    # 用于检测的域名
    DOMAIN="yahoo.com"

    # 用 dig 解析该域名
    dig +short $DOMAIN >/dev/null 2>&1

    # 检查 dig 的退出码
    if [ $? -ne 0 ]; then
        echo "dig 无法解析 $DOMAIN！正在向 /etc/resolv.conf 添加 nameserver 8.8.8.8……"
        # 先检查 8.8.8.8 是否已存在，避免重复追加
        grep -q "8.8.8.8" /etc/resolv.conf || echo "nameserver 8.8.8.8" | sudo tee -a /etc/resolv.conf
        # else
        # echo "dig 成功解析 $DOMAIN！"
    fi

}

function disable_ansii_modes() {
    echo -e "\033[?25l"
    echo -e "\e[?1003l"
    #echo -e '\033c'
    echo -e '\e[?25h'
    tput sgr0
    pkill -9 dialog
}

function update_progress() {
    title="${1^}"
    text="$2"
    percentage="$3"
    echo -e "####$percentage####$title####$text####"
}

function restart_hiddify_panel() {
    # 调用它之前必须先完成 apply/install 的工作（包括进度 100）。
    # ``systemctl kill`` / 阻塞式 restart 会给 hiddify-panel cgroup 里的每个进程
    # 发 SIGTERM。apply 必须在该 cgroup 之外运行（commander.py 用 systemd-run），
    # 而这里的 restart 必须带 --no-block。
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi
    local mode="${1:-restart}"
    if [ "$mode" = "start" ]; then
        systemctl start --no-block hiddify-panel
    else
        systemctl restart --no-block hiddify-panel
    fi
}

function is_installed_pypi_package() {
    activate_python_venv
    package_name="$1"
    if [ "$USE_VENV" == "310" ];then
        if pip list --format=freeze | grep -E "^$package_name" >/dev/null; then
            return 0
        else
            echo "Python 包 $package_name 未安装。"
            return 1
        fi
    else 
        if uv pip list --format=freeze | grep -E "^$package_name" >/dev/null; then
            return 0
        else
            echo "Python 包 $package_name 未安装。"
            return 1
        fi
    fi
}

function install_pypi_package() {
    activate_python_venv
    for package in "$@"; do
        if ! is_installed_pypi_package $package; then
            if [ "$USE_VENV" == "310" ];then
                pip install -U $package
            else
                uv pip install -U $package
            fi
        fi
    done
}
function is_installed_package() {
    package_spec="$1"

    # 从 "包名=版本" 形式的规格里拆出包名和版本
    package_name=$(echo "$1" | cut -d'=' -f1)
    version=$(echo "$1" | cut -s -d'=' -f2)
    if dpkg -l | grep -qE "^ii  $package_name *$version"; then
        return 0
    else
        echo "$package_name 版本 $version 未安装。"
        return 1
    fi
}
install_package() {
    # scripts/install.sh 会并行安装 scripts/common、services/redis 和
    # services/mysql，否则多个 apt 会同时启动，除一个之外全部因 dpkg 锁失败。
    # 随后的失败处理又会乱序修补它们，可能留下已解包但未配置的包，让它的
    # postinst 在该服务自己的安装脚本结束很久之后才运行 —— 对 mariadb-server
    # 来说，那个 postinst 会重新初始化 datadir，并清掉 services/mysql/install.sh
    # 刚创建的面板数据库用户。这把锁也覆盖"是否已安装"的检查，因此第二次运行
    # 不会决定去安装第一次正在安装的包。
    (
        flock 9
        local not_installed_packages=""
        local package

        for package in "$@"; do
            if ! is_installed_package "$package"; then
                # 该包未安装，加入待安装列表
                not_installed_packages+=" $package"
            fi
        done

        if [ -n "$not_installed_packages" ]; then
            # On a fresh server unattended-upgrades usually holds the dpkg lock
            # for minutes; wait for it instead of failing every retry on it.
            local apt_wait="-o DPkg::Lock::Timeout=900"
            apt-get $apt_wait install -y --no-install-recommends $not_installed_packages

            # 检查安装是否失败
            if [ $? -ne 0 ]; then
                apt-get $apt_wait --fix-broken install -y
                apt-get $apt_wait update
                # 最多重试 3 次
                apt-get $apt_wait install -y $not_installed_packages ||apt-get $apt_wait install -y $not_installed_packages||apt-get $apt_wait install -y $not_installed_packages
            fi
        fi
    ) 9>"$(lock_file apt)"
}

function remove_package() {
    for package in "$@"; do
        if dpkg -l | grep -q "^ii  $package"; then
            with_lock apt apt-get remove -y --auto-remove "$package"
        fi
    done
}

# --- 管理端 V2 界面（Vue）----------------------------------------------------
# 构建后的界面（hiddifypanel/static/admin-v2/）不在 git 中。release/beta 的 wheel
# 由发布流程预先构建好并随包提供；从源码安装时则在这里构建。

# 面板仓库的默认值（你的 fork）定义在本文件开头：
#   : "${HIDDIFY_PANEL_REPO:=${HIDDIFY_GITHUB_USER}/hiddifypanel}"
HIDDIFY_PANEL_GIT_URL="https://github.com/${HIDDIFY_PANEL_REPO}"

function _node_major() {
    command -v node >/dev/null 2>&1 || { echo 0; return; }
    node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0
}


# 仅用于构建管理端界面的 Node.js。系统自带的 node 版本足够新时直接用它；
# 否则把官方预编译的 Node 装到私有目录（不用 apt 包：Ubuntu 22.04 的
# nodejs 12/libnode 与新版 node 包冲突）。
HIDDIFY_NODE_VERSION="${HIDDIFY_NODE_VERSION:-22.23.3}"
# 给这个私有 Node 用的 npm（比它自带的更新）；要求 node ^22.22.2。
HIDDIFY_NPM_VERSION="${HIDDIFY_NPM_VERSION:-12.1.0}"
HIDDIFY_NODE_MIRRORS="${HIDDIFY_NODE_MIRRORS:-https://nodejs.org/dist https://npmmirror.com/mirrors/node}"

function _node_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo x64 ;;
        aarch64 | arm64) echo arm64 ;;
        armv7l) echo armv7l ;;
        *) return 1 ;;
    esac
}

function _download_nodejs() {
    local arch dir name mirror tmp
    arch=$(_node_arch) || { error "没有适用于 CPU $(uname -m) 的预编译 Node.js" >&2; return 1; }
    name="node-v${HIDDIFY_NODE_VERSION}-linux-${arch}"
    dir="$HIDDIFY_DIR/.cache/nodejs/$name"
    if [ -x "$dir/bin/node" ]; then
        echo "$dir"
        return 0
    fi
    install_package curl xz-utils ca-certificates >/dev/null 2>&1
    tmp=$(mktemp -d /var/tmp/hiddify-node.XXXXXX) || return 1
    for mirror in $HIDDIFY_NODE_MIRRORS; do
        warning "正在从 ${mirror} 下载 Node.js v${HIDDIFY_NODE_VERSION}（仅用于构建管理端界面）……" >&2
        if curl -fsSL --retry 2 --connect-timeout 15 -o "$tmp/$name.tar.xz" "$mirror/v${HIDDIFY_NODE_VERSION}/$name.tar.xz" &&
            curl -fsSL --retry 2 --connect-timeout 15 -o "$tmp/SHASUMS256.txt" "$mirror/v${HIDDIFY_NODE_VERSION}/SHASUMS256.txt" &&
            (cd "$tmp" && grep " $name.tar.xz\$" SHASUMS256.txt | sha256sum -c --status); then
            mkdir -p "$(dirname "$dir")"
            rm -rf "$dir"
            if tar -xJf "$tmp/$name.tar.xz" -C "$(dirname "$dir")"; then
                rm -rf "$tmp"
                echo "$dir"
                return 0
            fi
        fi
        warning "从 ${mirror} 下载 Node.js 失败或校验未通过" >&2
        rm -f "$tmp/$name.tar.xz" "$tmp/SHASUMS256.txt"
    done
    rm -rf "$tmp"
    return 1
}

function ensure_nodejs() {
    # Docker 镜像里的界面来自 Dockerfile 的构建阶段，镜像中不应带 Node.js。
    if [ "${DOCKER_MODE:-}" = "true" ]; then
        error "Docker 模式不安装 Node.js：管理端界面在 Dockerfile 的 panel-ui 阶段构建"
        return 1
    fi
    # vite 需要 Node >= 18。
    if [ "$(_node_major)" -ge 18 ] && command -v npm >/dev/null 2>&1; then
        return 0
    fi
    local dir
    if ! dir=$(_download_nodejs); then
        error "无法获取 Node.js v${HIDDIFY_NODE_VERSION}（已尝试：${HIDDIFY_NODE_MIRRORS}）。请把 HIDDIFY_NODE_MIRRORS 设为可访问的镜像。"
        return 1
    fi
    # 只有当前 shell（安装脚本）能看到它，不会装到系统全局。
    export PATH="$dir/bin:$PATH"
    [ "$(_node_major)" -ge 18 ] && command -v npm >/dev/null 2>&1 || return 1
    # 只升级一次私有副本的 npm；`-g` 装进 $dir（Node 自己的前缀），不影响系统。
    if [ -n "$HIDDIFY_NPM_VERSION" ] && [ "$(npm -v 2>/dev/null)" != "$HIDDIFY_NPM_VERSION" ]; then
        warning "正在升级 npm $(npm -v) -> $HIDDIFY_NPM_VERSION（仅私有 Node）……" >&2
        if ! npm install -g --no-audit --no-fund --loglevel=error "npm@$HIDDIFY_NPM_VERSION"; then
            warning "npm 升级失败，改用现有 npm $(npm -v) 继续构建" >&2
        fi
    fi
    return 0
}

# 界面构建约需 1.2 GB 内存（Node 堆上限由 HIDDIFY_UI_BUILD_HEAP_MB 控制；低于
# 约 900 MB 就会失败）。小内存 VPS 上构建会被 OOM 杀掉，因此当可用内存 + swap
# 低于 HIDDIFY_UI_BUILD_MIN_MEM_MB 时，为构建临时加一个 swap 文件，构建完立即删除。
HIDDIFY_UI_BUILD_HEAP_MB="${HIDDIFY_UI_BUILD_HEAP_MB:-2048}"
HIDDIFY_UI_BUILD_MIN_MEM_MB="${HIDDIFY_UI_BUILD_MIN_MEM_MB:-1600}"
_HIDDIFY_UI_SWAPFILE="/var/tmp/hiddify-ui-build.swap"

function _mem_available_mb() {
    awk '/^(MemAvailable|SwapFree):/ {sum += $2} END {print int(sum / 1024)}' /proc/meminfo
}

function _add_build_swap() {
    local have need size_mb disk_mb
    have=$(_mem_available_mb)
    need=$HIDDIFY_UI_BUILD_MIN_MEM_MB
    [ "$have" -ge "$need" ] && return 0
    size_mb=$(( need - have ))
    [ "$size_mb" -lt 1024 ] && size_mb=1024
    [ "$size_mb" -gt 2048 ] && size_mb=2048
    disk_mb=$(df -Pm /var/tmp | awk 'NR==2 {print $4}')
    if [ "${disk_mb:-0}" -lt $(( size_mb + 512 )) ]; then
        warning "可用内存仅 ${have} MB，且磁盘空间不足以创建临时 swap；管理端界面构建可能失败"
        return 0
    fi
    warning "可用内存仅 ${have} MB：为构建管理端界面临时添加 ${size_mb} MB swap"
    swapoff "$_HIDDIFY_UI_SWAPFILE" >/dev/null 2>&1
    rm -f "$_HIDDIFY_UI_SWAPFILE"
    if ! { fallocate -l "${size_mb}M" "$_HIDDIFY_UI_SWAPFILE" 2>/dev/null || dd if=/dev/zero of="$_HIDDIFY_UI_SWAPFILE" bs=1M count="$size_mb" status=none; }; then
        rm -f "$_HIDDIFY_UI_SWAPFILE"
        return 0
    fi
    chmod 600 "$_HIDDIFY_UI_SWAPFILE"
    if ! { mkswap "$_HIDDIFY_UI_SWAPFILE" >/dev/null && swapon "$_HIDDIFY_UI_SWAPFILE"; }; then
        # 例如容器或不支持 swap 的文件系统：不使用 swap 直接构建
        rm -f "$_HIDDIFY_UI_SWAPFILE"
    fi
    return 0
}

function _remove_build_swap() {
    [ -f "$_HIDDIFY_UI_SWAPFILE" ] || return 0
    swapoff "$_HIDDIFY_UI_SWAPFILE" >/dev/null 2>&1
    rm -f "$_HIDDIFY_UI_SWAPFILE"
}

# 管理端界面的构建产物按提交发布在 `prebuilt` 分支上，这样 1 GB 内存的 VPS 无需
# 运行 npm。sha256 清单保存在本仓库（scripts/admin-ui-prebuilt.tsv，与子模块指针
# 一起更新），而不是放在面板里：改变面板 HEAD 的那个提交永远匹配不上它刚发布的
# 产物。清单缺项或校验不符时，就退回到源码编译。
HIDDIFY_ADMIN_UI_PREBUILT="${HIDDIFY_ADMIN_UI_PREBUILT:-1}"
HIDDIFY_ADMIN_UI_PREBUILT_REPO="${HIDDIFY_ADMIN_UI_PREBUILT_REPO:-xgs87762GH/hiddifypanel}"
HIDDIFY_ADMIN_UI_PREBUILT_BRANCH="${HIDDIFY_ADMIN_UI_PREBUILT_BRANCH:-prebuilt}"
HIDDIFY_ADMIN_UI_PREBUILT_BASE="${HIDDIFY_ADMIN_UI_PREBUILT_BASE:-https://raw.githubusercontent.com/$HIDDIFY_ADMIN_UI_PREBUILT_REPO/$HIDDIFY_ADMIN_UI_PREBUILT_BRANCH}"

function _panel_source_rev() {
    git -C "${1%/}" rev-parse HEAD 2>/dev/null || true
}

# 安装与当前提交精确对应的产物；返回非 0 表示"改为从源码编译"。
function _install_admin_ui_prebuilt() {
    local src="${1%/}"
    local manifest="${HIDDIFY_ADMIN_UI_PREBUILT_MANIFEST:-$HIDDIFY_DIR/scripts/admin-ui-prebuilt.tsv}"
    local static="$src/hiddifypanel/static"
    local rev file sum tmp
    [ "$HIDDIFY_ADMIN_UI_PREBUILT" = "1" ] || return 1
    [ -f "$manifest" ] || return 1
    rev=$(_panel_source_rev "$src")
    [ -n "$rev" ] || return 1
    read -r file sum < <(awk -v r="$rev" '$1 == r { print $2, $3; exit }' "$manifest" 2>/dev/null)
    if [ -z "${file:-}" ] || [ -z "${sum:-}" ]; then
        warning "面板 ${rev:0:12} 没有预构建的管理端界面；改为源码编译（在小 VPS 上较慢）"
        return 1
    fi
    tmp=$(mktemp /var/tmp/hiddify-admin-ui-XXXXXX.tar.gz) || return 1
    if ! curl -fsSL --connect-timeout 10 --max-time 600 "${HIDDIFY_ADMIN_UI_PREBUILT_BASE%/}/$file" -o "$tmp"; then
        warning "无法获取预构建的管理端界面（$file）；改为源码编译"
        rm -f "$tmp"
        return 1
    fi
    if ! { echo "$sum  $tmp" | sha256sum -c - >/dev/null 2>&1; }; then
        warning "预构建的管理端界面校验和不符合；改为源码编译"
        rm -f "$tmp"
        return 1
    fi
    rm -rf "$static/admin-v2"
    mkdir -p "$static"
    if ! tar -xzf "$tmp" -C "$static" 2>/dev/null; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    [ -f "$static/admin-v2/index.html" ] || return 1
    # 让它比下面新鲜度检查里的任何源文件都更新，下次运行就不会再重建。
    touch "$static/admin-v2/index.html"
    return 0
}

# build_panel_admin_ui <面板源码目录> [--force]
# 若 <目录>/hiddifypanel/static/admin-v2/ 缺失或比源码旧，则把管理端界面构建进去。
# 对于没有界面源码的代码树（例如 wheel）为空操作。
function build_panel_admin_ui() {
    local src="${1%/}" force="${2:-}"
    local ui="$src/hiddifypanel/admin_v2"
    local out="$src/hiddifypanel/static/admin-v2/index.html"
    if [ ! -f "$ui/package.json" ]; then
        return 0
    fi
    if [ "$force" != "--force" ] && [ -f "$out" ] &&
        [ -z "$(find "$ui/src" "$ui/index.html" "$ui/package-lock.json" "$ui/vite.config.ts" "$src/hiddifypanel/translations.i18n" -newer "$out" -print -quit 2>/dev/null)" ]; then
        return 0
    fi
    if [ "$force" != "--force" ] && _install_admin_ui_prebuilt "$src"; then
        success "管理端界面已用预构建产物安装（无需 npm 构建）"
        return 0
    fi
    update_progress "正在构建……" "Hiddify 面板管理端界面（可能需要几分钟）" 30
    ensure_nodejs || { error "构建管理端界面需要 Node.js >= 18"; return 1; }
    # 只清理我们自己创建的 node_modules：开发者自己的检出保留原样。
    local had_node_modules=0
    [ -d "$ui/node_modules" ] && had_node_modules=1
    _add_build_swap
    local rc=0
    (cd "$ui" && npm ci --no-audit --no-fund --loglevel=error &&
        NODE_OPTIONS="--max-old-space-size=$HIDDIFY_UI_BUILD_HEAP_MB ${NODE_OPTIONS:-}" npm run build) || rc=$?
    _remove_build_swap
    if [ "$rc" != 0 ]; then
        if [ "$rc" = 137 ] || dmesg 2>/dev/null | tail -n 20 | grep -qi "killed process.*node"; then
            error "构建管理端界面时内存不足（需要约 1.2 GB 可用内存或 swap）"
        else
            error "构建管理端界面失败（详见上面的 npm 输出）"
        fi
        return 1
    fi
    if [ "$had_node_modules" = 0 ] && [ -z "${HIDDIFY_KEEP_NODE_MODULES:-}" ]; then
        rm -rf "$ui/node_modules"
    fi
    success "管理端界面构建完成"
}

# build_panel_user_ui <面板源码目录> [--force]
# 把 user_front 构建到 <目录>/hiddifypanel/static/user-front/（与 admin_v2 同一模式）。
# 默认使用 gh-pages 上的预构建产物（在小 VPS 上更安全）。设 HIDDIFY_USER_FRONT_FROM_SOURCE=1 则从源码编译。
function build_panel_user_ui() {
    local src="${1%/}" force="${2:-}"
    local ui="$src/hiddifypanel/user_front"
    local out="$src/hiddifypanel/static/user-front/manifest.json"
    local build_sh="$ui/scripts/build.sh"
    local prebuilt_sh="$ui/scripts/install_prebuilt.sh"
    if [ ! -f "$ui/package.json" ]; then
        return 0
    fi
    if [ "$force" != "--force" ] && [ -f "$out" ] &&
        [ -z "$(find "$ui/src" "$ui/index.html" "$ui/package-lock.json" "$ui/vite.config.ts" "$ui/public" -newer "$out" -print -quit 2>/dev/null)" ]; then
        return 0
    fi
    update_progress "正在构建……" "Hiddify 面板用户端界面" 32
    local rc=0
    if [ "${HIDDIFY_USER_FRONT_FROM_SOURCE:-}" = "1" ] && [ -f "$build_sh" ]; then
        ensure_nodejs || { error "从源码构建用户端界面需要 Node.js >= 18"; return 1; }
        local had_node_modules=0
        [ -d "$ui/node_modules" ] && had_node_modules=1
        _add_build_swap
        NODE_OPTIONS="--max-old-space-size=${HIDDIFY_USER_FRONT_HEAP_MB:-1024} ${NODE_OPTIONS:-}" \
            bash "$build_sh" || rc=$?
        _remove_build_swap
        if [ "$had_node_modules" = 0 ] && [ -z "${HIDDIFY_KEEP_NODE_MODULES:-}" ]; then
            rm -rf "$ui/node_modules"
        fi
        # OOM / 编译失败 → 仍然用 gh-pages 的产物提供一个可用的界面。
        if [ "$rc" != 0 ] && [ -f "$prebuilt_sh" ]; then
            warning "user_front 源码构建失败；改为安装 gh-pages 上的预构建产物"
            bash "$prebuilt_sh" || rc=$?
        fi
    elif [ -f "$prebuilt_sh" ]; then
        bash "$prebuilt_sh" || rc=$?
    else
        return 0
    fi
    if [ "$rc" != 0 ]; then
        error "安装用户端界面失败（详见上面的输出）"
        return 1
    fi
    success "用户端界面已就绪"
}

# build_panel_ui <面板源码目录> [--force]
# 为面板源码树构建管理端 + 用户端界面（源码不存在时为空操作）。
function build_panel_ui() {
    build_panel_admin_ui "$@" || return $?
    build_panel_user_ui "$@" || return $?
}

# install_panel_from_git [ref] [pip 命令]
# 从 GitHub 安装面板（develop / tag）：克隆、构建界面、安装。
# 不能再用 `pip install git+...`：那样装出来的面板没有界面。
function install_panel_from_git() {
    local ref="${1:-}" pip_cmd="${2:-uv pip}"
    if is_dev_checkout; then
        warning "开发版检出：面板仍从 $HIDDIFY_DIR/services/panel/src 安装（更新请在该目录 git pull）"
        return 0
    fi
    install_package git
    # 故意放在 $HIDDIFY_DIR 之外：配置渲染器（scripts/common/jinja.py）会遍历
    # $HIDDIFY_DIR 下的 *.j2，并可能去渲染面板自己的模板。
    local dir
    dir=$(mktemp -d /var/tmp/hiddify-panel-src.XXXXXX) || return 1
    local rc=0
    if ! git clone --quiet --depth 1 --recurse-submodules ${ref:+--branch "$ref"} "$HIDDIFY_PANEL_GIT_URL" "$dir/src"; then
        error "无法下载面板源码（${ref:-默认分支}）"
        rc=1
    elif ! build_panel_ui "$dir/src" --force; then
        rc=1
    else
        { $pip_cmd install -U --no-deps --force-reinstall "$dir/src" && $pip_cmd install "$dir/src"; } || rc=$?
    fi
    # 无论下载或界面构建是否失败，都要清理。
    rm -rf "$dir"
    return $rc
}

function is_installed() {
    if ! command -v "$1" >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

function msg_with_hiddify() {
    text=$(
        cat <<END
                                  ▓▓▓
                                ▓▓▓▓▓
                           ▓▓▓       
                         ▓▓▓▓▓  ▓▓▓▓▓
                    ▓▓▓  ▓▓▓▓▓  ▓▓▓▓▓
                 ▓▓▓▓▓▓  ▓▓▓▓▓  ▓▓▓▓▓
                 ▓▓▓▓▓▓▓▓▓▓▓▓▓  ▓▓▓▓▓
                 ▓▓▓▓▓▓  ▓▓▓▓▓  ▓▓▓▓▓
END
    )
    msg "$text \n\n$1"

}
function center_text() {
    local text="$1"
    local screen_width="$(tput cols)"
    local longest_line_length="$(echo "$text" | awk '{ print length }' | sort -rn | head -1)"
    local padding_width="$(((screen_width - longest_line_length) / 2))"
    while IFS= read -r line; do
        printf "%*s%s\n" $padding_width "" "$line"
    done <<<"$text"
}

function msg() {
    install_package whiptail
    NEWT_COLORS='title=blue, textbox=blue, border=blue, button=black,blue' whiptail --title Hiddify --msgbox "$1" 0 60
    disable_ansii_modes
}


function install_python() {
    # USE_VENV 未设置或为空时的默认值
    if [ -z "${USE_VENV}" ]; then
        # echo "USE_VENV 变量未设置或为空，退出……"
        export USE_VENV=313
    fi
    
    # region 在系统范围安装 python3.10
    rm -rf /usr/lib/python3/dist-packages/blinker*
    

    # endregion

    # region 创建虚拟环境
    # 部分第三方包（如 grpcio-tools）与 python3.13 不兼容
    # 因此仍然使用 python3.10
    # 检查 USE_VENV 是否存在或为 true
    # if [ "${USE_VENV}" = true ]; then
        activate_python_venv
    # fi
    # endregion

}
function create_python_venv() {
    if [ "${USE_VENV}" = "310" ]; then
        export venv_path="/opt/hiddify-manager/.venv/"
        if [ ! -d "$venv_path" ]; then
            install_package python3.10-venv
            python3.10 -m venv "$venv_path"
        fi
    else 
        if ! is_installed ${venv_path}/bin/python3.13 ;then
            rm -rf ${venv_path}
            if ! is_installed uv ;then
                curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/bin/ UV_NO_MODIFY_PATH=1 UV_PYTHON_INSTALL_DIR=/usr/local/share/uv sh -s --
            fi
            UV_PYTHON_INSTALL_DIR=/usr/local/share/uv uv venv ${venv_path} --python=3.13
        fi
    fi
    
}
function activate_python_venv() {
    create_python_venv
    if [ -z "$VIRTUAL_ENV" ]; then
        if [ "${USE_VENV}" = "310" ]; then
            export venv_path="/opt/hiddify-manager/.venv"    
        fi
        source "${venv_path}/bin/activate"
    fi
}


function install_python310() {
    # USE_VENV 未设置或为空时的默认值
   # if [ -z "${USE_VENV}" ]; then
        # echo "USE_VENV 变量未设置或为空，退出……"
  #  fi
    export USE_VENV=310
    # region 在系统范围安装 python3.10
    rm -rf /usr/lib/python3/dist-packages/blinker*
    if ! is_installed /opt/hiddify-manager/.venv/bin/python3.10 ;then
        rm -rf /opt/hiddify-manager/.venv/
    fi
    if ! python3.10 --version &>/dev/null; then
        echo "尚未安装 Python 3.10。"
        install_package software-properties-common
        add-apt-repository -y ppa:deadsnakes/ppa
    #    sudo apt-get -y remove python*
    fi
    install_package python3.10-dev
    # ln -sf $(which python3.10) /usr/bin/python3
    ln -sf /usr/bin/python3 /usr/bin/python
    if ! pip --version>/dev/null; then
        curl https://bootstrap.pypa.io/get-pip.py | python3.10 -
        python3.10 -m pip install -U pip
    fi
    # endregion

    # region 创建虚拟环境
    # 部分第三方包（如 grpcio-tools）与 python3.13 不兼容
    # 因此仍然使用 python3.10
    # 检查 USE_VENV 是否存在或为 true
#    if [ "${USE_VENV}" = "310" ]; then
        activate_python_venv
 #   fi
    # endregion

}
# 面板链接的证书在浏览器眼里的状态：trusted（可信）、self_signed（自签名或其他不受信任）、
# insecure（http）。直接向本机自己发起检查，因此即使域名走 CDN 或尚未解析也能判断。
function link_cert_state() {
    local url="$1" host
    [[ "$url" == http://* ]] && { echo insecure; return; }
    # 向本机自己发起检查，因此即使域名走 CDN 或尚未解析也能判断。
    host="${url#https://}"
    host="${host%%/*}"
    [[ "$host" == \[* ]] || host="${host%%:*}"  # 去掉 :port，保留完整的 [IPv6]
    # openssl 会立刻发出 ClientHello；curl 要先加载整个 CA 证书库，在慢速设备上这比
    # rpxy-l4 为新连接等待 SNI 的 100ms 还久。这样探测会失败，一个完全有效的证书
    # 就被报成自签名。
    if timeout 8 openssl s_client -connect 127.0.0.1:443 -servername "$host" \
        -verify_return_error -verify_hostname "$host" </dev/null >/dev/null 2>&1; then
        echo trusted
    else
        echo self_signed
    fi
}

# 面板的各个链接，按打开时的安全程度分组：可信证书（绿色）、自签名（黄色：浏览器会警告）、
# 纯 http（红色）。在支持链接的终端里可点击。
function print_panel_links() {
    local -a trusted=() self_signed=() insecure=()
    local link
    while read -r link; do
        [ -n "$link" ] || continue
        case "$(link_cert_state "$link")" in
        trusted) trusted+=("$link") ;;
        self_signed) self_signed+=("$link") ;;
        *) insecure+=("$link") ;;
        esac
    done < <(jq -r '.panel_links[]' /opt/hiddify-manager/data/current.json | awk '!seen[$0]++')

    local reset=$'\e[0m' dim=$'\e[2m' bold=$'\e[1m'
    _panel_link_group() {  # 颜色 图标 标题 说明 链接...
        local color="$1" icon="$2" title="$3" note="$4"
        shift 4
        [ $# -gt 0 ] || return 0
        printf "%s%s %s%s%s  %s%s%s\n" "$color$bold" "$icon" "$title" "$reset" "" "$dim" "$note" "$reset"
        for link in "$@"; do
            printf "%s\e]8;;%s\e\\%s\e]8;;\e\\%s\n" "$color" "$link" "$link" "$reset"
        done
        echo
    }
    echo
    printf "  %s打开你的面板%s\n\n" "$bold" "$reset"
    # 最好的放在最后：紧挨着提示符，目光自然落在那里
    _panel_link_group $'\e[91m' "✖" "不安全" "未加密（http）：请勿使用" "${insecure[@]}"
    _panel_link_group $'\e[93m' "⚠" "自签名" "浏览器会警告；仅在安全链接打不开时才用这些" "${self_signed[@]}"
    _panel_link_group $'\e[92m' "✔" "安全" "证书受信任" "${trusted[@]}"
}

function check_hiddify_panel() {
    if [ "$MODE" != "apply_users" ]; then
        reload_all_configs >/dev/null
        
        if [[ $? != 0 ]]; then
            error "Hiddify 面板出现异常。请把日志发送到 hiddify@gmail.com"
            exit 4
        fi
        echo -e "\n\n"

        bash /opt/hiddify-manager/scripts/status.sh
        print_logo

        install_package qrencode
        center_text "$(qrencode -t utf8 -m 2 $(cat /opt/hiddify-manager/data/current.json | jq -r '.panel_links[]' | tail -n 1))"
        echo ""
        # "Finished!" 是面板 apply 流程判定日志结束的标记（apply_api.py: FINISHED_MARK），请勿翻译
        center_text $'\t\033[92mFinished! 感谢你为跨越网络过滤所做的贡献。\033[0m'
        
        echo -e "\n"
        print_panel_links

        # (cd hiddify-panel && python3 -m hiddifypanel admin-links)
        
        for s in hiddify-xray hiddify-core hiddify-haproxy hiddify-mysql; do
            [ $s == "hiddify-xray" ] && [ "$(hconfig 'core_type')" != "xray" ] && continue
            [ $s == "hiddify-mysql" ] && [ "$DOCKER_MODE" == "true" ] && continue
            s=${s##*/}
            s=${s%%.*}
            for i in $(seq 1 10); do
                if [[ "$(systemctl is-active "$s")" == "active" ]]; then
                    break
                else
                    if [ $i -eq 10 ]; then
                        error "重要服务 $s 在 10 秒内仍未启动"
                        error "安装失败！"
                        exit 32
                    fi
                    warning "重要服务 $s 尚未启动"
                    sleep 1
                fi
            done
            
        done
    fi
}


# Hiddify 的 logo：一张纯文本图形（进度窗口 cli_progress --logo 也用它）
export HIDDIFY_LOGO="$HIDDIFY_SCRIPTS/common/logo.ico"

# 居中显示、蓝色的 logo
function print_logo() {
    local LC_ALL=C.UTF-8 width longest=0 line
    width="$(tput cols 2>/dev/null || echo 80)"
    while IFS= read -r line; do
        [ "${#line}" -gt "$longest" ] && longest=${#line}  # 按字符数而非字节数（▓ 占 3 字节）
    done <"$HIDDIFY_LOGO"
    local pad=$(((width - longest) / 2))
    [ "$pad" -lt 0 ] && pad=0
    while IFS= read -r line; do
        printf "%*s\033[0;34m%s\033[0m\n" "$pad" "" "$line"
    done <"$HIDDIFY_LOGO"
}

function show_progress_window() {
    # 没有可用终端时（管道、cron、未加 -t 的 ssh），cli_progress 改为边产生边打印输出
    activate_python_venv
    uv pip install -q "cli-progress>=3.0.2"
    disable_ansii_modes
    # logo 与进度；输出在按 L 后显示（同时也总会写入 --log 指定的文件）
    python -m cli_progress --title "Hiddify Manager" --logo "$HIDDIFY_LOGO" "$@"
    exit_code=$?
    disable_ansii_modes
    return $exit_code
}

function log_dir() {
    LOG_DIR="/opt/hiddify-manager/data/log"
    mkdir -p "$LOG_DIR" >/dev/null 2>&1
    echo $LOG_DIR
}

function log_file() {
    echo "$(log_dir)/${1}.log"
}

# 日志超过 6000 行时，只保留最后 3000 行。
function trim_log() {
    if [ -f "$1" ] && [ "$(wc -l <"$1")" -gt 6000 ]; then
        tail -n 3000 "$1" >"$1.tmp" && mv "$1.tmp" "$1"
    fi
}

# 给从 stdin 读到的每一行加上时间前缀。
function add_time() {
    while IFS= read -r line; do echo "$(date +%T) $line"; done
}

# run_timed 标签 命令...：运行命令，并输出开始/结束信息（耗时秒数、退出码）；失败时同时写到 stderr。
function run_timed() {
    local label="$1" start=$SECONDS rc
    shift
    echo "$label：开始"
    "$@"
    rc=$?
    echo "$label：结束，用时 $((SECONDS - start))s（退出码 $rc）"
    [ "$rc" -eq 0 ] || echo "$label：失败（退出码 $rc）" >&2
    return $rc
}

# run_logged 名称 命令...：运行命令，把它打印的内容保存到 $(log_dir)/名称.out.log，错误保存到
# 名称.err.log（每次运行一行分隔头，随后是带时间的行）。同时也会打印出来。返回命令的退出码。
function run_logged() {
    local name="$1" out err tmp_out tmp_err rc
    shift
    out="$(log_file "$name.out")"
    err="$(log_file "$name.err")"
    trim_log "$out"
    trim_log "$err"
    tmp_out="$(mktemp)"
    tmp_err="$(mktemp)"
    "$@" >"$tmp_out" 2>"$tmp_err"
    rc=$?
    echo "===== $(date '+%F %T') $name：退出码 $rc =====" | tee -a "$out" >>"$err"
    add_time <"$tmp_out" | tee -a "$out"
    add_time <"$tmp_err" | tee -a "$err" >&2
    rm -f "$tmp_out" "$tmp_err"
    return $rc
}

# hiddify 里所有互斥都基于 $HIDDIFY_LOCKS 下某个文件的 flock。内核把锁绑定在已打开的
# 文件描述符上，所以持有锁的进程一消失，锁立即释放 —— 正常退出、kill -9、崩溃或
# 断电都一样。.lock 文件不承载任何状态，崩溃后留下的文件不会阻塞后续运行：
# 无需清理，也没有"过期时间"要调。
# 开发版检出：/opt/hiddify-manager 本身就是 git 克隆（见 DEVELOPMENT.md）。此时面板以
# 可编辑方式从 services/panel/src 安装，更新器不会覆盖这棵目录树（改用 git pull）。
function is_dev_checkout() {
    [ -d "$HIDDIFY_DIR/.git" ] || [ -f "$HIDDIFY_DIR/.git" ]
}

function lock_file() {
    # 755：面板（hiddify-panel）以只读方式打开它们，用来判断是否有安装正在运行（apply_api.py）
    mkdir -p -m 755 "$HIDDIFY_LOCKS" >/dev/null 2>&1
    echo "$HIDDIFY_LOCKS/${1}.lock"
}

# 在持有指定名称的锁的情况下运行命令，并等待锁释放。
# -o 防止命令把锁传给它的子进程。
function with_lock() {
    local name="$1"
    shift
    flock -o "$(lock_file "$name")" "$@"
}

# 为当前 shell 的整个生命周期持有指定名称的锁；锁已被占用时立即失败退出。
function set_lock() {
    exec {HIDDIFY_LOCK_FD}>"$(lock_file "$1")"
    if ! flock -n "$HIDDIFY_LOCK_FD"; then
        error "另一个安装正在进行…… 请等待它结束。"
        exit 12
    fi
}

function remove_lock() {
    [ -n "$HIDDIFY_LOCK_FD" ] || return 0
    # 关闭文件描述符即释放锁。
    exec {HIDDIFY_LOCK_FD}>&-
    unset HIDDIFY_LOCK_FD
}


function hconfig() {
    local json_file="/opt/hiddify-manager/data/current.json"
    [ ! -f "$json_file" ] && { error "找不到面板配置文件"; return 1; }

    local key=$1
    local essential_vars=$(jq -r '.chconfigs["0"] | to_entries[] | .key' "$json_file")
    for var in $essential_vars; do
        if [ "$key" == "$var" ]; then
            local value=$(jq -r --arg var "$var" '.chconfigs["0"][$var]' "$json_file")
            echo "$value"
            return 0  # 以成功状态退出函数
        fi
    done

    # 找不到该键时返回错误状态
    error "错误：未找到键 $key"
    return 1
}
#TODO: 检查不使用 venv 时的功能是否正常
# Hiddify 的 systemd 单元列表，每行一个名字（不含 ".service"）：services/ 下一层和两层的单元文件（不含
# services/deprecated；没有 globstar 时 ** 只匹配一层）、模板单元（hiddify-*@*）正在运行/已启用的实例，
# 以及 WireGuard 接口。供 stop / restart / status / uninstall 使用。
function hiddify_service_units() {
    (
        shopt -s nullglob # 仅在此子 shell 中生效
        local f name
        for f in "$HIDDIFY_SERVICES"/*/*.service "$HIDDIFY_SERVICES"/*/*/*.service; do
            [[ "$f" == "$HIDDIFY_SERVICES/deprecated/"* ]] && continue
            name=${f##*/}
            name=${name%.service}
            [[ "$name" == *@ ]] && continue # 模板单元：其实例由下面的 systemd 列表给出
            echo "$name"
        done
        systemctl list-units --all --plain --no-legend 'hiddify-*@*.service' 2>/dev/null | awk '{print $1}' | sed 's/\.service$//'
        echo wg-quick@warp
        echo wg-quick@hiddifywg
    ) | sort -u
}

# 在（重新）加载使用该配置的服务之前，先校验生成的配置。
# config_check_ok <标签> <配置文件> <校验命令...>
# 拒绝重载会保留上一份可用的配置继续运行，比陷入重启循环更安全。任何看起来是校验器
# 本身出问题的情况（二进制缺失、未知子命令、配置尚未生成）都绝不能阻止重载。
function config_check_ok() {
    local label="$1" config_file="$2"
    shift 2
    if [ ! -f "$config_file" ]; then
        echo "跳过 $label 的配置检查：$config_file does not exist yet（尚未生成）"
        return 0
    fi
    local output rc=0
    output=$("$@" 2>&1) || rc=$?
    if [ $rc -eq 0 ]; then
        return 0
    fi
    if [ $rc -eq 127 ] || echo "$output" | grep -qiE 'unknown command|invalid choice|flag provided but not defined|^usage:'; then
        echo "$label 的配置检查不可用（unavailable：校验器报用法错误或找不到），仍然继续重载"
        return 0
    fi
    echo "$label 配置有错误！不要重载（do not reload $label service）"
    if [ -n "$output" ]; then echo "$output"; fi
    return 1
}

function hiddify-panel-run() {
    local base_command="export HIDDIFY_CFG_PATH='$HIDDIFY_PANEL_CFG_PATH'; cd /opt/hiddify-manager/services/panel/; source ${venv_path}/bin/activate && $*"

    # 不用 eval：命令本身已经拼好，再次解析它会把某个参数里恰好包含的内容当作命令执行
    # （这条路径可以从面板经 sudo commander 触达）。
    if [ "$(whoami)" == "hiddify-panel" ]; then
        bash -c "$base_command"
    else
        su hiddify-panel -c "$base_command"
    fi
}

function hiddify-panel-cli() {
  hiddify-panel-run "python3 -m hiddifypanel $*"
}
# region 安装器工具函数
function checkOS() {
    # 支持的发行版列表
    #supported_distros=("Ubuntu" "Debian" "Fedora" "CentOS" "Arch")
    supported_distros=("Ubuntu")
    # 获取发行版名称与版本
    if [[ -f "/etc/os-release" ]]; then
        source "/etc/os-release"
        distro_name=$NAME
        distro_version=$VERSION_ID
    else
        echo "无法判断发行版。"
        exit 1
    fi
    # 检查该发行版是否受支持
    if [[ " ${supported_distros[*]} " =~ " ${distro_name} " ]]; then
        echo "你的 Linux 发行版是 ${distro_name} ${distro_version}"
        : # 空操作命令
    else
        # 用红色打印错误信息
        echo -e "\e[31m你当前的 Linux 发行版（${distro_name} ${distro_version}）暂不支持。\e[0m"
        exit 1
    fi
    
    # 本脚本仅支持 Ubuntu 22 及以上
    if [ "$(uname)" == "Linux" ]; then
        version_info=$(lsb_release -rs | cut -d '.' -f 1)
        # 检查是否为 Ubuntu 且版本低于 22
        if [ "$(lsb_release -is)" == "Ubuntu" ] && [ "$version_info" -lt 22 ]; then
            echo "本脚本仅支持 Ubuntu 22 及以上"
            exit
        fi
    fi
}
function disable_panel_services() {
    # rm /etc/cron.d/hiddify_usage_update
    # rm /etc/cron.d/hiddify_auto_backup
    # service cron reload >/dev/null 2>&1
    # kill -9 $(pgrep -f 'hiddifypanel update-usage')
    # systemctl restart hiddify-mysql
    echo ""
}

function vercomp () {
    if [[ $1 == $2 ]]
    then
        echo 0
        return 0
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    # 用 0 补齐 ver1 的空字段
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
    do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++))
    do
        if [[ -z ${ver2[i]} ]]
        then
            # 用 0 补齐 ver2 的空字段
            ver2[i]=0
        fi
        if ((10#${ver1[i]//[!0-9]/} > 10#${ver2[i]//[!0-9]/}))
        then
            echo 1
            return 1
        fi
        if ((10#${ver1[i]//[!0-9]/} < 10#${ver2[i]//[!0-9]/}))
        then
            echo 2
            return 2
        fi
    done
    echo 0
    return 0
}


function check_venv_compatibility() {
    package_mode=${1:-release}

    if [ "$package_mode" == "false" ]; then
        package_mode="release"
    fi

    first_release_compatible_venv_version=v10.30

    case "$package_mode" in
        v*)
            # 检查版本是否大于等于兼容该 venv 的首个正式版本
            
            if [ $(vercomp "$package_mode" "$first_release_compatible_venv_version") == 0 ] || [ $(vercomp "$package_mode" "$first_release_compatible_venv_version") == 1 ]; then
                USE_VENV=310
            fi
        ;;
        develop|dev)
            # develop 始终兼容 venv
            USE_VENV=313
        ;;
        beta)
            # beta 始终兼容 venv
            USE_VENV=313
        ;;
        release)
            # 取最新的正式版本
            USE_VENV=313
        ;;
        *)
            echo "未知的包模式：$package_mode"
            exit 1
        ;;
    esac
}

function hiddify-http-api(){
    api_path=$(jq -r '.api_path // empty' /opt/hiddify-manager/data/current.json 2>/dev/null)
    api_key=$(jq -r '.api_key // empty' /opt/hiddify-manager/data/current.json 2>/dev/null)
    

    if [ -z "$api_path" ] || [ -z "$api_key" ]; then
        echo "配置文件无效"
        return 1
    fi
    temp_file=$(mktemp)
    http_status=$(curl -s -o $temp_file -w "%{http_code}" http://localhost:9000/${api_path}/api/v2/$1 --header "Hiddify-API-Key: ${api_key}")
    cat $temp_file
    rm $temp_file
    if [ "$http_status" -ne 200 ];then
        echo "$http_status"
        # 以前写作 `return 1$http_status`，会被解读成 1404 -> 124：调用方无法区分这两种情况。
        return 1
    fi
    return 0
}

function is_valid_current_json() {
    jq -e '(.chconfigs["0"] | type == "object") and (.domains | type == "array")' "$1" >/dev/null 2>&1
}

function reload_all_configs(){
    # 先写入临时文件，只有结果有效时才替换 current.json：API 会从当前这份读取
    # 凭据，而每个服务脚本都依赖它。
    local cfg=/opt/hiddify-manager/data/current.json
    local tmp
    tmp=$(mktemp "$cfg.XXXXXX") || return 1
    # HIDDIFY_NO_HTTP_API：正在运行的面板还是旧的（升级只在最后才重启它），改为询问新代码。
    if [ "$HIDDIFY_NO_HTTP_API" = "true" ] || ! hiddify-http-api admin/all-configs/ >"$tmp" || ! is_valid_current_json "$tmp"; then
        if ! hiddify-panel-cli all-configs >"$tmp" || ! is_valid_current_json "$tmp"; then
            error "无法从 Hiddify 面板读取配置；保留原来的 $cfg"
            rm -f "$tmp"
            return 1
        fi
    fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$cfg" || { rm -f "$tmp"; return 1; }
    cat "$cfg"
}

# 把 xray/hiddify-core/haproxy/dns_proxy 的配置渲染到 $HIDDIFY_GENERATED。
# 优先用正在运行的面板的 HTTP API（不额外加载 Python/模块）；只有在面板不可达时
# 才退回 CLI（会启动自己的解释器）。
function dump_server_configs() {
    # 可选，逗号分隔的核心（xray,hiddify-core,wireguard,telemt）。为空表示全部。
    local cores="${1:-}"
    local query=""
    [ "$MODE" = "apply_users" ] && query="no_invalidate_cache=1"
    if [ -n "$cores" ]; then
        local enc
        enc=$(printf '%s' "$cores" | jq -sRr @uri)
        query="${query:+$query&}cores=${enc}"
    fi
    [ -n "$query" ] && query="?${query}"
    # HIDDIFY_NO_HTTP_API：正在运行的面板还是旧的（升级只在最后才重启它），改用新代码。
    if [ "$HIDDIFY_NO_HTTP_API" != "true" ] && hiddify-http-api "admin/dump-server-configs/${query}" >/dev/null; then
        return 0
    fi

    local flags=()
    [ "$MODE" = "apply_users" ] && flags+=(--no-invalidate-cache)
    [ -n "$cores" ] && flags+=(--cores "$cores")
    hiddify-panel-cli dump-server-configs "$HIDDIFY_GENERATED" "${flags[@]}"
}


set_files_in_folder_readable_to_hiddify_common_group() {
    # 确保含空格或特殊字符的路径也能被正确处理
    file=$1
    find "$file" -type d -exec chmod u+rx,g+rx,o-rwx {} \;  # 目录：属主 rwx，属组 rw-
    find "$file" -type f -exec chmod 640 {} \;  # 文件：属主和属组都是 rw-
    find "$file" -exec chown :hiddify-common {} \;
    # 处理父目录（当父目录不是 "hiddify-manager" 时）
    # 解析输入路径的绝对路径
    
    parent=$(realpath "$file")

    while [[ $(basename "$parent") != "hiddify-manager" && "$parent" != "/" ]]; do
        # echo "正在设置 $parent 的权限"
        chmod u+rx,g+rx "$parent"  # 设置父目录权限
        chown :hiddify-common "$parent"  # 把属组改为该组
        parent=$(dirname "$parent")  # 继续处理上一级目录
    done
}