#!/bin/bash
# 教程里写的每条部署路径，逐条离线重放一遍。
#
# 覆盖（教程出处 → 场景）：
#   D1  一键部署（docs/deploy/onekey.md）              bash <(curl "$OK") install
#   D2  一键装到已存在的非 git 目录                     必须拒绝并提示 switch
#   D3  一键装到已是 git 检出的目录                     必须自动转成 update
#   D4  服务器手动部署（docs/deploy/manual.md）         git clone + install.sh --no-gui
#   D5  git 拉取开发（docs/deploy/git-checkout.md）     --recurse-submodules + make build + 面板切分支
#   D6  压缩包/release 安装（scripts/common/download.sh） tag 分派 / 失败不留半成品 / 废弃入口
#   D7  Docker（docs/deploy/docker.md）                docker-installer.sh beta / develop / 目录已存在
#   D8  cloud-init（docs/cloud-init.yml）              runcmd 形式（先 curl -o 再 bash，不用 <( )）
#   D9  switch（docs/ops/server-update.md §4）         release 安装 → 本 fork 检出，且可重复执行
#   D10 教程自检                                        文档里写的命令必须是脚本真支持的参数
#
# 全离线：远端一律是 /tmp 下的本地裸仓库（--fork 指向它，所以连"真实 clone"也是离线的）；
# 需要联网的外部命令（curl / wget / docker）用 PATH 前置的 stub 顶替，只断言生成物。
#
# 用法：bash scripts/tests/smoke_deploy_paths.sh [轮数]
set -u

ITERATIONS="${1:-10}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=/tmp/hdp
ORIGIN="$WORK/manager.git"
PANEL_ORIGIN="$WORK/panel.git"
UF_ORIGIN="$WORK/userfront.git"
BIN="$WORK/bin"
BRANCH=dev-custom

pass_count=0
fail_count=0
assert_total=0
failed_iterations=""

log() { echo -e "\033[1;34m==>\033[0m $*"; }
ok() { echo -e "    \033[1;32mPASS\033[0m $*"; assert_total=$((assert_total + 1)); }
bad() { echo -e "    \033[1;31mFAIL\033[0m $*"; fail_count=$((fail_count + 1)); }
skip() { echo -e "    \033[1;33mSKIP\033[0m $*"; }

prepare_env() {
    rm -rf "$WORK"
    mkdir -p "$WORK" "$BIN"
    git config --global protocol.file.allow always
    git config --global init.defaultBranch dev-custom
    git config --global user.email smoke@t
    git config --global user.name smoke
}

# ------------------------------------------------------------------ 夹具 -------
build_panel_fixture() {
    git init -q --bare "$UF_ORIGIN"
    local uf="$WORK/userfront"
    git init -q "$uf"
    echo "userfront v1" > "$uf/VERSION"
    git -C "$uf" add -A
    git -C "$uf" commit -qm "userfront v1"
    git -C "$uf" push -q "$UF_ORIGIN" HEAD:refs/heads/dev-custom
    git -C "$UF_ORIGIN" symbolic-ref HEAD refs/heads/dev-custom

    git init -q --bare "$PANEL_ORIGIN"
    local p="$WORK/panel"
    git init -q "$p"
    mkdir -p "$p/hiddifypanel"
    echo "panel v1" > "$p/VERSION"
    git -C "$p" add -A
    git -C "$p" commit -qm "panel v1"
    git -C "$p" submodule add -q "$UF_ORIGIN" hiddifypanel/user_front
    git -C "$p" commit -qm "panel: add user_front submodule"
    git -C "$p" push -q "$PANEL_ORIGIN" HEAD:refs/heads/dev-custom
    git -C "$PANEL_ORIGIN" symbolic-ref HEAD refs/heads/dev-custom
}

# 夹具里的"服务器代码"：真实 onekey.sh + 假的 install/update/backup/make
build_manager_fixture() {
    git init -q --bare "$ORIGIN"
    local w="$WORK/manager"
    git init -q "$w"
    mkdir -p "$w/scripts/common" "$w/services/panel"
    cp "$REPO/scripts/onekey.sh" "$w/scripts/onekey.sh"
    cp "$REPO/scripts/common/utils.sh" "$w/scripts/common/utils.sh" 2>/dev/null
    # Docker 路径需要仓库根上的 compose 文件（docker-installer.sh 就是去取的它们）
    cp "$REPO/docker-compose.yml" "$w/docker-compose.yml" 2>/dev/null
    cp "$REPO/docker-compose.bridge.yml" "$w/docker-compose.bridge.yml" 2>/dev/null
    cp "$REPO/docker.env" "$w/docker.env" 2>/dev/null
    cat > "$w/scripts/install.sh" <<'EOF'
#!/bin/bash
echo "FAKE INSTALL"
echo installed > "$(dirname "$0")/../install-was-run"
EOF
    cat > "$w/scripts/update.sh" <<'EOF'
#!/bin/bash
echo "FAKE UPDATE"
EOF
    cat > "$w/services/panel/backup.sh" <<'EOF'
#!/bin/bash
echo "FAKE BACKUP"
EOF
    chmod +x "$w/scripts/install.sh" "$w/scripts/update.sh" "$w/services/panel/backup.sh"
    printf 'build:\n\t@echo "FAKE BUILD"\n' > "$w/Makefile"
    build_panel_fixture
    git -C "$w" submodule add -q "$PANEL_ORIGIN" services/panel/src
    echo "manager v1" > "$w/VERSION"
    git -C "$w" add -A
    git -C "$w" commit -qm "manager v1"
    git -C "$w" tag v-smoke-1
    git -C "$w" push -q "$ORIGIN" HEAD:refs/heads/dev-custom
    git -C "$w" push -q "$ORIGIN" v-smoke-1
}

# 外部命令 stub：只记录调用、产出可控文件，绝不联网
build_stubs() {
    mkdir -p "$BIN"
    cat > "$BIN/curl" <<EOF
#!/bin/bash
echo "curl \$*" >> "$WORK/curl.log"
[ -n "\${CURL_FAIL:-}" ] && exit 1
out=""
prev=""
for a in "\$@"; do
    [ "\$prev" = "-o" ] && out="\$a"
    prev="\$a"
done
if [ -n "\$out" ]; then
    cat > "\$out" <<'INNER'
#!/bin/bash
echo "FAKE INSTALLER $*"
INNER
fi
exit 0
EOF
    cat > "$BIN/wget" <<EOF
#!/bin/bash
echo "wget \$*" >> "$WORK/curl.log"
for a in "\$@"; do
    case "\$a" in
        *docker-compose.yml) cp "$REPO/docker-compose.yml" ./docker-compose.yml ;;
        *docker.env) cp "$REPO/docker.env" ./docker.env ;;
    esac
done
exit 0
EOF
    cat > "$BIN/docker" <<EOF
#!/bin/bash
echo "docker \$*" >> "$WORK/docker.log"
exit 0
EOF
    cat > "$BIN/git" <<EOF
#!/bin/bash
# develop 分支的 Docker 安装会 clone GitHub；离线下把 URL 换成本地夹具
if [ "\$1" = "clone" ]; then
    args=()
    for a in "\$@"; do
        case "\$a" in https://github.com/*) a="$ORIGIN" ;; esac
        args+=("\$a")
    done
    exec /usr/bin/git "\${args[@]}"
fi
exec /usr/bin/git "\$@"
EOF
    chmod +x "$BIN"/curl "$BIN"/wget "$BIN"/docker "$BIN"/git
}

# ------------------------------------------------------------------ 断言 -------
file_has() { # $1 文件 $2 正则 $3 说明
    if grep -Eq "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3（$1 里没匹配到 /$2/）"; fi
}

file_hasnt() { # $1 文件 $2 正则 $3 说明
    if grep -Eq "$2" "$1" 2>/dev/null; then bad "$3"; else ok "$3"; fi
}

is_checkout() { [ -e "$1/.git" ] && git -C "$1" rev-parse --git-dir >/dev/null 2>&1; }

run_onekey() { # 其余参数原样透传，统一带上 --dir/--fork/-y
    bash "$REPO/scripts/onekey.sh" "$@" --fork "$ORIGIN" --branch "$BRANCH" -y 2>&1
}

# --------------------------------------------------------------- D1 一键全新 ---
scenario_d1_onekey_fresh_install() {
    log "D1: 一键部署（onekey.md）：全新目录 → clone + install"
    local root="$WORK/root-d1" out
    rm -rf "$root"
    out=$(run_onekey install --dir "$root")
    echo "$out" | sed 's/^/    | /'

    is_checkout "$root" && ok "D1 目录已成为 git 检出" || bad "D1 不是 git 检出"
    [ "$(git -C "$root" config --get remote.origin.url 2>/dev/null)" = "$ORIGIN" ] &&
        ok "D1 origin 指向 --fork 给的仓库" || bad "D1 origin 不对"
    [ -f "$root/install-was-run" ] && ok "D1 install.sh 被执行" || bad "D1 没跑 install.sh"
    # 子模块（含嵌套）必须一起到位：面板起不来多半就是这一层没初始化
    git -C "$root/services/panel/src" rev-parse --show-toplevel >/dev/null 2>&1 &&
        ok "D1 面板子模块已初始化" || bad "D1 面板子模块没初始化"
    git -C "$root/services/panel/src/hiddifypanel/user_front" rev-parse --show-toplevel >/dev/null 2>&1 &&
        ok "D1 嵌套子模块 user_front 已初始化" || bad "D1 嵌套子模块没初始化"
    # 顶层与面板都要登记 safe.directory：属主校验是按目录生效、不递归的
    git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$root" &&
        ok "D1 已登记 \$ROOT 的 safe.directory" || bad "D1 没登记 \$ROOT"
    git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "$root/services/panel/src" &&
        ok "D1 已登记面板子模块的 safe.directory" || bad "D1 没登记面板子模块"
}

# ------------------------------------------------- D2 撞上非 git（zip）目录 ---
scenario_d2_install_on_zip_layout() {
    log "D2: 已存在且不是 git 检出（官方 zip 安装）→ 必须拒绝并提示 switch"
    local root="$WORK/root-d2" out rc
    rm -rf "$root"
    mkdir -p "$root/services/panel/src" "$root/data"
    echo "release" > "$root/VERSION"
    echo "keep" > "$root/data/keep.txt"
    out=$(run_onekey install --dir "$root"); rc=$?
    echo "$out" | sed 's/^/    | /'

    [ "$rc" != "0" ] && ok "D2 以非 0 退出（拒绝覆盖）" || bad "D2 竟然装成功了"
    echo "$out" | grep -q "switch" && ok "D2 提示改用 switch" || bad "D2 没提示 switch"
    [ -f "$root/VERSION" ] && [ "$(cat "$root/VERSION")" = "release" ] &&
        ok "D2 原有文件未被清空" || bad "D2 把原目录清掉了"
    [ ! -e "$root/.git" ] && ok "D2 没有半途 git init" || bad "D2 留下了 .git"
}

# ------------------------------------------------------- D3 撞上 git 检出 -----
scenario_d3_install_on_checkout() {
    log "D3: 已是 git 检出 → 必须自动转成 update，不重复 clone"
    local root="$WORK/root-d3" out rc
    rm -rf "$root"
    git clone -q -b "$BRANCH" "$ORIGIN" "$root"
    git -C "$root" submodule update --init --recursive -q 2>/dev/null
    out=$(run_onekey install --dir "$root"); rc=$?
    echo "$out" | sed 's/^/    | /'

    echo "$out" | grep -q "改用 update" && ok "D3 打印了改用 update" || bad "D3 没转 update"
    echo "$out" | grep -q "FAKE UPDATE" && ok "D3 真的走了 update.sh" || bad "D3 没跑 update.sh"
    [ "$rc" = "0" ] && ok "D3 退出码 0" || bad "D3 退出码 $rc"
    [ "$(git -C "$root" config --get remote.origin.url 2>/dev/null)" = "$ORIGIN" ] &&
        ok "D3 没有重新 clone（origin 未变）" || bad "D3 origin 被改了"
}

# ------------------------------------------------------------- D4 手动部署 ----
scenario_d4_manual_deploy() {
    log "D4: 手动部署（manual.md）：git clone + install.sh --no-gui"
    local root="$WORK/root-d4" out
    rm -rf "$root"
    git clone -q --recurse-submodules -b "$BRANCH" "$ORIGIN" "$root" 2>&1 | sed 's/^/    | /'
    out=$(cd "$root" && bash scripts/install.sh --no-gui 2>&1)
    echo "$out" | sed 's/^/    | /'

    echo "$out" | grep -q "FAKE INSTALL" && ok "D4 install.sh --no-gui 跑通" || bad "D4 install.sh 没跑"
    git -C "$root/services/panel/src" rev-parse --show-toplevel >/dev/null 2>&1 &&
        ok "D4 --recurse-submodules 带出了面板" || bad "D4 面板子模块缺失"
    git -C "$root/services/panel/src/hiddifypanel/user_front" rev-parse --show-toplevel >/dev/null 2>&1 &&
        ok "D4 嵌套子模块也带出来了" || bad "D4 嵌套子模块缺失"
    [ "$(git -C "$root" rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] &&
        ok "D4 落在 $BRANCH 分支" || bad "D4 分支不对"
}

# --------------------------------------------------------- D5 git 拉取开发 ----
scenario_d5_git_checkout_dev() {
    log "D5: git 拉取开发（git-checkout.md）：make build + 面板切到 dev-custom"
    local root="$WORK/root-d5" out
    rm -rf "$root"
    git clone -q --recurse-submodules -b "$BRANCH" "$ORIGIN" "$root" 2>&1 | sed 's/^/    | /'
    out=$(cd "$root" && make build 2>&1)
    echo "$out" | sed 's/^/    | /'
    echo "$out" | grep -q "FAKE BUILD" && ok "D5 make build 跑通" || bad "D5 make build 失败"

    git -C "$root/services/panel/src" checkout -q "$BRANCH" 2>&1 | sed 's/^/    | /'
    [ "$(git -C "$root/services/panel/src" rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] &&
        ok "D5 面板已切到 $BRANCH 分支（不再 detached）" || bad "D5 面板仍在 detached"
    # 教程的提交顺序要求：先推子模块再推外层指针；这里验证外层指针确实等于面板 HEAD
    local want have
    want=$(git -C "$root" ls-tree HEAD services/panel/src | awk '{print $3}')
    have=$(git -C "$root/services/panel/src" rev-parse HEAD)
    [ "$want" = "$have" ] && ok "D5 外层指针与面板 HEAD 一致" ||
        bad "D5 指针与面板不一致（want=$want have=$have）"
}

# ------------------------------------------------------ D6 压缩包/release -----
scenario_d6_download_sh() {
    log "D6: 压缩包/release 安装（common/download.sh）：tag 分派 / 失败不留半成品"
    local out url rc scratch="$WORK/d6"
    rm -rf "$scratch" "$WORK/curl.log"; mkdir -p "$scratch"

    # v9~v12 的远古布局：脚本在仓库根，不在 scripts/ 下
    out=$(cd "$scratch" && PATH="$BIN:$PATH" bash "$REPO/scripts/common/download.sh" v10.0.0 --no-gui 2>&1)
    echo "$out" | sed 's/^/    | /'
    echo "$out" | grep -q "FAKE INSTALLER" && ok "D6 v10 拿到了安装器" || bad "D6 v10 没拿到安装器"
    url=$(grep -o 'https://raw[^ ]*' "$WORK/curl.log" 2>/dev/null | head -n 1)
    case "$url" in
        */refs/tags/v10.0.0/*) ok "D6 v10 走远古布局 refs/tags/v10.0.0/（$url）" ;;
        *) bad "D6 v10 的 URL 不对：$url" ;;
    esac
    echo "$url" | grep -q "/scripts/" && bad "D6 v10 不该再加 /scripts 前缀" ||
        ok "D6 v10 没有多加 /scripts 前缀"

    rm -f "$WORK/curl.log"
    out=$(cd "$scratch" && PATH="$BIN:$PATH" bash "$REPO/scripts/common/download.sh" v14.2.4 --no-gui 2>&1)
    echo "$out" | sed 's/^/    | /'
    grep -q 'refs/tags/v14\.2\.4/scripts' "$WORK/curl.log" 2>/dev/null &&
        ok "D6 v14 走 refs/tags/v14.2.4/scripts" || bad "D6 v14 的 URL 不对"

    rm -f "$WORK/curl.log"
    out=$(cd "$scratch" && PATH="$BIN:$PATH" bash "$REPO/scripts/common/download.sh" release --no-gui 2>&1)
    echo "$out" | sed 's/^/    | /'
    grep -q "refs/heads/$BRANCH/scripts" "$WORK/curl.log" 2>/dev/null &&
        ok "D6 release 走定制分支 refs/heads/$BRANCH/scripts" || bad "D6 release 的 URL 不对"

    # -f 的语义：404/502 的响应体不能被当成安装器下载下来
    rm -f "$WORK/curl.log"
    out=$(cd "$scratch" && CURL_FAIL=1 PATH="$BIN:$PATH" bash "$REPO/scripts/common/download.sh" v14.2.4 --no-gui 2>&1); rc=$?
    echo "$out" | sed 's/^/    | /'
    [ "$rc" != "0" ] && ok "D6 下载失败时以非 0 退出" || bad "D6 下载失败却成功了"
    [ ! -s /tmp/hiddify/hiddify_installer.sh ] && ok "D6 失败后没有留下半成品安装器" ||
        bad "D6 留下了半成品安装器"

    # 废弃入口：curl … | bash 这种老写法要提示改命令，而不是默默跑
    out=$(bash -s v14.2.4 < "$REPO/scripts/common/download.sh" 2>&1); rc=$?
    echo "$out" | sed 's/^/    | /'
    echo "$out" | grep -q "已废弃" && ok "D6 老入口提示已废弃" || bad "D6 老入口没提示"
    [ "$rc" != "0" ] && ok "D6 老入口拒绝执行" || bad "D6 老入口竟然执行了"
}

# ------------------------------------------------------------------ D7 Docker --
scenario_d7_docker_installer() {
    log "D7: Docker（docker.md）：beta / develop / 目录已存在"
    local scratch="$WORK/d7" out rc
    rm -rf "$scratch" "$WORK/docker.log" "$WORK/curl.log"; mkdir -p "$scratch"

    # 7a：当前目录已有 hiddify-manager → 必须报错退出，别覆盖已有栈
    mkdir -p "$scratch/hiddify-manager"
    out=$(cd "$scratch" && PATH="$BIN:$PATH" bash "$REPO/scripts/common/docker-installer.sh" beta 2>&1); rc=$?
    echo "$out" | sed 's/^/    | /'
    [ "$rc" != "0" ] && ok "D7 目录已存在时拒绝安装" || bad "D7 目录已存在却装了"
    echo "$out" | grep -q "已存在" && ok "D7 给出了已存在的提示" || bad "D7 没提示原因"
    rm -rf "$scratch/hiddify-manager"

    # 7b：beta → 拉已发布镜像，镜像必须钉到本 fork 的 tag，且密码与连接串一致
    out=$(cd "$scratch" && PATH="$BIN:$PATH" bash "$REPO/scripts/common/docker-installer.sh" beta 2>&1); rc=$?
    echo "$out" | sed 's/^/    | /'
    [ "$rc" = "0" ] && ok "D7 beta 安装退出码 0" || bad "D7 beta 退出码 $rc"
    [ -d "$scratch/hiddify-manager" ] && ok "D7 beta 创建了 hiddify-manager 目录" ||
        bad "D7 beta 没创建目录"
    file_has "$scratch/hiddify-manager/docker-compose.yml" \
        '^[[:space:]]*image:[[:space:]]*ghcr\.io/xgs87762gh/hiddify-manager:beta' \
        "D7 beta 镜像钉到 ghcr.io/xgs87762gh/hiddify-manager:beta"
    file_hasnt "$scratch/hiddify-manager/docker-compose.yml" \
        '^[[:space:]]*image:.*ghcr\.io.*:latest' "D7 beta 把 ghcr 镜像钉到了 beta（不是 latest）"
    grep -q "compose pull" "$WORK/docker.log" 2>/dev/null && ok "D7 beta 执行了 compose pull" ||
        bad "D7 beta 没 pull"
    grep -q "compose up -d" "$WORK/docker.log" 2>/dev/null && ok "D7 beta 执行了 compose up -d" ||
        bad "D7 beta 没 up"

    # 密码一致性：只改 *_PASSWORD 而漏改 URI 会让面板连不上库（docker.env 的注释就是这条）
    local env_file="$scratch/hiddify-manager/docker.env" mysqlpwd redispwd
    mysqlpwd=$(sed -n 's/^MYSQL_PASSWORD=//p' "$env_file" 2>/dev/null | head -n 1)
    redispwd=$(sed -n 's/^REDIS_PASSWORD=//p' "$env_file" 2>/dev/null | head -n 1)
    [ -n "$mysqlpwd" ] && ok "D7 生成了 MYSQL_PASSWORD" || bad "D7 没生成 MYSQL_PASSWORD"
    [ -n "$redispwd" ] && ok "D7 生成了 REDIS_PASSWORD" || bad "D7 没生成 REDIS_PASSWORD"
    file_has "$env_file" "SQLALCHEMY_DATABASE_URI=.*${mysqlpwd}" "D7 数据库连接串用的是新 MySQL 密码"
    file_has "$env_file" "REDIS_URI_MAIN=.*${redispwd}" "D7 Redis 连接串用的是新 Redis 密码"
    file_hasnt "$env_file" "mysql-strong-password" "D7 没有残留占位密码 mysql-strong-password"
    file_hasnt "$env_file" "redis-strong-password" "D7 没有残留占位密码 redis-strong-password"

    # 7c：develop → 本地源码构建，image 行必须被注释掉并改成 build: .
    rm -rf "$scratch"; mkdir -p "$scratch"
    out=$(cd "$scratch" && PATH="$BIN:$PATH" bash "$REPO/scripts/common/docker-installer.sh" develop 2>&1); rc=$?
    echo "$out" | sed 's/^/    | /'
    [ "$rc" = "0" ] && ok "D7 develop 退出码 0" || bad "D7 develop 退出码 $rc"
    file_has "$scratch/hiddify-manager/docker-compose.yml" '^[[:space:]]*build:[[:space:]]*\.' \
        "D7 develop 改成 build: ."
    file_has "$scratch/hiddify-manager/docker-compose.yml" '^[[:space:]]*#.*image:[[:space:]]*ghcr' \
        "D7 develop 把 image 行注释掉"
    grep -q "compose.*build" "$WORK/docker.log" 2>/dev/null && ok "D7 develop 执行了 compose build" ||
        bad "D7 develop 没 build"

    # 7d：两个 profile 都得在仓库里（docker.md 第 2 节）
    file_has "$REPO/docker-compose.yml" 'network_mode:[[:space:]]*host' "D7 host profile 用 host 网络"
    [ -f "$REPO/docker-compose.bridge.yml" ] && ok "D7 bridge profile 文件存在" ||
        bad "D7 缺 docker-compose.bridge.yml"
    file_has "$REPO/docker-compose.bridge.yml" '"?443:443"?' "D7 bridge profile 发布 443/TCP"
    file_has "$REPO/docker-compose.bridge.yml" '"?443:443/udp"?' "D7 bridge profile 发布 443/UDP"
    file_hasnt "$REPO/docker-compose.bridge.yml" 'network_mode:[[:space:]]*host' \
        "D7 bridge profile 不是 host 网络"
    [ -f "$REPO/docker-compose.external-db.yml" ] && ok "D7 external-db override 存在" ||
        bad "D7 缺 docker-compose.external-db.yml"
}

# --------------------------------------------------------------- D8 cloud-init -
scenario_d8_cloud_init() {
    log "D8: cloud-init（docs/cloud-init.yml）：runcmd 形式必须能在 /bin/sh 下跑"
    local ci="$REPO/docs/cloud-init.yml" root="$WORK/root-d8" out rc
    [ -f "$ci" ] || { bad "D8 找不到 docs/cloud-init.yml"; return; }

    file_has "$ci" 'curl -fsSL .*onekey\.sh -o /tmp/onekey\.sh' "D8 先把 onekey.sh 下载到 /tmp"
    file_has "$ci" 'bash /tmp/onekey\.sh install -y' "D8 用 bash /tmp/onekey.sh install -y"
    # cloud-init 的 runcmd 走 /bin/sh，没有 bash 的 <( ) 进程替换（注释里提到它不算）
    if grep -v '^[[:space:]]*#' "$ci" | grep -q '<('; then
        bad "D8 runcmd 用到了 bash 独有的 <( )"
    else
        ok "D8 runcmd 没有用到 bash 独有的 <( )"
    fi
    file_hasnt "$ci" 'i\.hiddify\.com' "D8 没有指向官方一键脚本"

    rm -rf "$root"
    cp "$REPO/scripts/onekey.sh" /tmp/onekey.sh
    out=$(sh -c "bash /tmp/onekey.sh install -y --dir $root --fork $ORIGIN --branch $BRANCH" 2>&1); rc=$?
    echo "$out" | sed 's/^/    | /'
    [ "$rc" = "0" ] && ok "D8 runcmd 等价形式跑通" || bad "D8 退出码 $rc"
    is_checkout "$root" && ok "D8 装出了 git 检出" || bad "D8 没装出 git 检出"
    [ -f "$root/install-was-run" ] && ok "D8 install.sh 被执行" || bad "D8 没跑 install.sh"
}

# ------------------------------------------------------------------- D9 switch -
scenario_d9_switch_to_fork() {
    log "D9: switch（server-update.md §4）：release 安装 → 本 fork 检出，且幂等"
    local root="$WORK/root-d9" out rc bak
    rm -rf "$root" "$root".bak.*
    # release 形态：没有 .git，services/panel/src 是普通目录
    mkdir -p "$root/scripts" "$root/services/panel/src/hiddifypanel" "$root/data" "$root/generated"
    echo "release" > "$root/VERSION"
    echo "panel from release" > "$root/services/panel/src/hiddifypanel/VERSION"
    echo "keep" > "$root/data/keep.txt"
    echo "gen" > "$root/generated/marker"
    cp "$REPO/scripts/onekey.sh" "$root/scripts/onekey.sh"

    out=$(HIDDIFY_DIR="$root" HIDDIFY_UPSTREAM_URL="$ORIGIN" \
        bash "$REPO/scripts/switch_to_fork.sh" --branch "$BRANCH" --fork "$ORIGIN" -y 2>&1); rc=$?
    echo "$out" | sed 's/^/    | /'
    [ "$rc" = "0" ] && ok "D9 首次转换退出码 0" || bad "D9 首次转换退出码 $rc"
    is_checkout "$root" && ok "D9 已成为 git 检出" || bad "D9 没有变成 git 检出"
    [ "$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$BRANCH" ] &&
        ok "D9 落在 $BRANCH 分支" || bad "D9 分支不是 $BRANCH"
    [ "$(git -C "$root" config --get remote.origin.url 2>/dev/null)" = "$ORIGIN" ] &&
        ok "D9 origin 指向本 fork" || bad "D9 origin 不对"
    git -C "$root/services/panel/src" rev-parse --show-toplevel >/dev/null 2>&1 &&
        ok "D9 面板目录已变成子模块" || bad "D9 面板子模块不可用"
    # 坑 3：release 的普通目录会让位成 .release-backup*
    bak=$(ls -d "$root"/services/panel/src.release-backup* 2>/dev/null | head -n 1)
    [ -n "$bak" ] && ok "D9 旧面板目录已让位为 $(basename "$bak")" || bad "D9 没生成 .release-backup"
    [ -f "$root/data/keep.txt" ] && ok "D9 data/ 保留" || bad "D9 data/ 被删了"
    [ -f "$root/generated/marker" ] && ok "D9 generated/ 保留" || bad "D9 generated/ 被删了"
    ls -d "$root".bak.* >/dev/null 2>&1 && ok "D9 生成了全量快照 ${root}.bak.*" ||
        bad "D9 没有生成快照"

    # 第二次跑：已是检出 → 只做 git 更新，不得再转换一次
    out=$(HIDDIFY_DIR="$root" HIDDIFY_UPSTREAM_URL="$ORIGIN" \
        bash "$REPO/scripts/switch_to_fork.sh" --branch "$BRANCH" --fork "$ORIGIN" -y 2>&1); rc=$?
    echo "$out" | sed 's/^/    | /'
    echo "$out" | grep -q "已是 git 检出" && ok "D9 第二次识别为已检出" ||
        bad "D9 第二次没识别为已检出"
    [ "$rc" = "0" ] && ok "D9 重复执行退出码 0" || bad "D9 重复执行退出码 $rc"
    [ -f "$root/data/keep.txt" ] && ok "D9 重复执行后 data/ 仍在" || bad "D9 重复执行把 data/ 弄丢了"
}

# --------------------------------------------------------------- D10 教程自检 --
scenario_d10_docs_match_scripts() {
    log "D10: 教程自检：文档里的命令必须是脚本真支持的"
    local readme="$REPO/docs/deploy/README.md" onekey="$REPO/scripts/onekey.sh"
    file_has "$readme" 'bash <\(curl -fsSL "\$OK"\) install' "D10 README 有一条命令的 install"
    for c in update reinstall switch; do
        file_has "$readme" "bash <\\(curl -fsSL \"\\\$OK\"\\) $c" "D10 README 有 $c 的用法"
    done
    file_has "$readme" 'version v14\.2\.4 -y' "D10 README 有切指定版本的用法"
    file_has "$readme" 'i\.hiddify\.com' "D10 README 明确警告不要用官方一键脚本"
    # 脚本真的支持这些子命令
    for c in install update reinstall version switch; do
        grep -Eq "^[[:space:]]+$c\\)[[:space:]]+cmd_" "$onekey" && ok "D10 onekey.sh 支持 $c" ||
            bad "D10 onekey.sh 缺 $c"
    done
    grep -Eq -- '--dir\)' "$onekey" && ok "D10 onekey.sh 支持 --dir" || bad "D10 缺 --dir"
    grep -Eq -- '--fork\)' "$onekey" && ok "D10 onekey.sh 支持 --fork" || bad "D10 缺 --fork"
    grep -Eq -- '--branch\)' "$onekey" && ok "D10 onekey.sh 支持 --branch" || bad "D10 缺 --branch"
    file_has "$REPO/docs/deploy/docker.md" "ghcr\.io/xgs87762gh/hiddify-manager" \
        "D10 docker.md 用的是本 fork 镜像"
    file_has "$REPO/docs/deploy/manual.md" "install\.sh --no-gui" "D10 manual.md 用 install.sh --no-gui"
}

# -------------------------------------------------------------------- driver ---
run_once() {
    local i="$1"
    echo
    echo "================ iteration $i ================"
    prepare_env
    build_manager_fixture
    build_stubs

    local before=$fail_count
    scenario_d1_onekey_fresh_install
    scenario_d2_install_on_zip_layout
    scenario_d3_install_on_checkout
    scenario_d4_manual_deploy
    scenario_d5_git_checkout_dev
    scenario_d6_download_sh
    scenario_d7_docker_installer
    scenario_d8_cloud_init
    scenario_d9_switch_to_fork
    scenario_d10_docs_match_scripts
    if [ "$fail_count" = "$before" ]; then
        pass_count=$((pass_count + 1))
    else
        failed_iterations="$failed_iterations $i"
    fi
}

start_ts=$(date +%s)
for i in $(seq 1 "$ITERATIONS"); do
    run_once "$i"
done
end_ts=$(date +%s)

echo
echo "================ summary ================"
echo "iterations: $ITERATIONS   all-green: $pass_count   failed: $fail_count   assertions: $assert_total   elapsed: $((end_ts - start_ts))s"
[ -n "$failed_iterations" ] && echo "failed iterations:$failed_iterations"
[ "$fail_count" -eq 0 ] || exit 1
exit 0
