#!/bin/bash
cd /opt/hiddify-manager
source /opt/hiddify-manager/scripts/common/utils.sh
ensure_hiddify_data_dirs
if [ -f /opt/hiddify-manager/scripts/migrate_layout.sh ]; then
    bash /opt/hiddify-manager/scripts/migrate_layout.sh
fi
NAME="0-install"
LOG_FILE="$(log_file $NAME)"
# 修正安装目录
if [ ! -d "/opt/hiddify-manager/" ] && [ -d "/opt/hiddify-server/" ]; then
    mv /opt/hiddify-server /opt/hiddify-manager
    ln -s /opt/hiddify-manager /opt/hiddify-server
fi
if [ ! -d "/opt/hiddify-manager/" ] && [ -d "/opt/hiddify-config/" ]; then
    mv /opt/hiddify-config/ /opt/hiddify-manager/
    ln -s /opt/hiddify-manager /opt/hiddify-config
fi

export DEBIAN_FRONTEND=noninteractive
if [ "$(id -u)" -ne 0 ]; then
    echo '本脚本必须以 root 身份运行' >&2
    exit 1
fi
# ---------------------------------------------------------------------------------------------
# 并行执行各步骤，并如实反映进度。
#
#   add_task [-n 单元数] "标签" 命令 参数...   排队一个步骤（单元数：该步骤总共会调用多少次
#                                             progress_tick，默认 1；命令返回时还会为它计一次）
#   run_parallel 起始百分比 结束百分比 "分组"   一次性运行所有已排队的步骤；每结束一个步骤，
#                                             进度条从 起始 推进到 结束 一个单元
#   progress_tick "标签"                       完成一个单元（用于由多部分组成的步骤）
# ---------------------------------------------------------------------------------------------
declare -a _TASK_LABELS=() _TASK_CMDS=() _TASK_UNITS=()
# 任意一次 run_parallel 中失败的步骤：安装最后会以错误结束（但会先跑完其余步骤）
declare -a FAILED_STEPS=()

function add_task() {
    local units=1
    if [ "$1" == "-n" ]; then units=$2; shift 2; fi
    local label="$1"; shift
    _TASK_LABELS+=("$label")
    _TASK_UNITS+=("$units")
    _TASK_CMDS+=("$(printf '%q ' "$@")")
}

function progress_tick() {
    (
        flock 9
        local finished=$(( $(<"$PROGRESS_DIR/finished") + 1 ))
        echo "$finished" >"$PROGRESS_DIR/finished"
        local percent=$(( PROGRESS_FROM + (PROGRESS_TO - PROGRESS_FROM) * finished / PROGRESS_TOTAL ))
        update_progress "${PROGRESS_GROUP}" "$1 ($finished/$PROGRESS_TOTAL)" "$percent"
    ) 9>"$PROGRESS_DIR/lock"
}

function run_parallel() {
    local total=0 units i
    for units in "${_TASK_UNITS[@]}"; do total=$((total + units)); done
    if [ "$total" -eq 0 ]; then return 0; fi

    export PROGRESS_FROM=$1 PROGRESS_TO=$2 PROGRESS_GROUP="$3" PROGRESS_TOTAL=$total
    export PROGRESS_DIR="$(mktemp -d)"
    echo 0 >"$PROGRESS_DIR/finished"
    : >"$PROGRESS_DIR/failed"
    update_progress "${PROGRESS_GROUP}" "并行启动 ${#_TASK_LABELS[@]} 个步骤" "$PROGRESS_FROM"

    for i in "${!_TASK_LABELS[@]}"; do
        (
            eval "${_TASK_CMDS[$i]}"
            local rc=$?
            [ "$rc" != 0 ] && echo "${_TASK_LABELS[$i]}" >>"$PROGRESS_DIR/failed"
            progress_tick "${_TASK_LABELS[$i]}"
        ) &
    done
    wait

    if [ -s "$PROGRESS_DIR/failed" ]; then
        error "以下步骤报告了错误：$(paste -sd, "$PROGRESS_DIR/failed")"
        mapfile -t -O "${#FAILED_STEPS[@]}" FAILED_STEPS <"$PROGRESS_DIR/failed"
    fi
    rm -rf "$PROGRESS_DIR"
    _TASK_LABELS=() _TASK_CMDS=() _TASK_UNITS=()
}

# 证书：面板负责申请（先 Let's Encrypt，再 ZeroSSL；HAProxy 负责应答验证）并自行续期。
# 安装/重装（含快速安装）会在这里等待所有需要正式证书的域名——不只是第一个——
# 这样在"完成"之前所有管理员链接都能用 HTTPS。签发的证书会立即保存并加载进 HAProxy，
# 核心通过 apply-users 重建；失败的域名保持自签，域名页面会继续重试。
function wait_for_certificates() {
    update_progress "${PROGRESS_ACTION}" "正在申请证书（Let's Encrypt / ZeroSSL）" 98
    # 不加 --first：一旦已有域名持有正式证书，它会跳过整轮，导致新快速安装的域名永远拿不到证书。
    # 不加参数时，只处理仍待签发的域名，已有效的域名保持不动。
    local out rc=0
    # stdout 是 RenewSummary JSON；ACME 日志走 stderr，仍会出现在安装日志里
    out=$(hiddify-panel-cli issue-certificates) || rc=$?
    echo "$out"
    if [ "$rc" == 3 ]; then
        # 退出码 3 = 至少一张证书发生变化（已写入 HAProxy 并触发 apply-users）。
        # 再走一遍安装路径刷新生成的配置和 hiddify-core，避免安装中途的竞争留下旧配置。
        bash scripts/common/replace_variables.sh
        DO_NOT_INSTALL=true install_run services/hiddify-core
        rc=0
    fi
    if [ "$rc" != 0 ]; then
        warning "当前无法签发证书；面板会继续尝试（见域名页面）"
        return
    fi
    # 部分 ACME 失败仍会返回 0（有签发成功时返回 3）：把失败数暴露出来，让日志更清楚。
    local failed
    failed=$(echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(d.get("failed") or 0))' 2>/dev/null) || failed=0
    if [ "${failed:-0}" -gt 0 ]; then
        warning "$failed 个域名的证书当前无法签发；在域名页面重试之前它们保持自签"
    fi
}

function main() {
    update_progress "请稍候……" "即将开始安装 Hiddify……" 0
    export ERROR=0
    
    export PROGRESS_ACTION="正在安装……"
    if [ "$MODE" == "apply_users" ];then
        export DO_NOT_INSTALL="true"
    elif [ -d "/hiddify-data-default/" ] && [ -z "$(ls -A /hiddify-data/ 2>/dev/null)" ]; then
        cp -r /hiddify-data-default/* /hiddify-data/
    fi
    if [ "$DO_NOT_INSTALL" == "true" ];then
        PROGRESS_ACTION="正在应用……"
    fi

    export USE_VENV=313

    install_python
    activate_python_venv
    
    if [ "$MODE" != "apply_users" ]; then
        clean_files

        # 1) Common tools, redis and mysql (independent of each other). A service is
        #    skipped when the panel is configured to use an external server for it:
        #    SQLALCHEMY_DATABASE_URI / REDIS_URI_MAIN (env), or the HIDDIFY_EXTERNAL_*
        #    markers run.sh persisted in the panel's app.cfg on a previous run.
        add_task "常用工具与依赖" runsh install.sh scripts/common
        if [ "$DOCKER_MODE" != "true" ]; then
            if is_panel_redis_external; then
                echo "External Redis configured (REDIS_URI_MAIN): skipping the local Redis install"
            else
                add_task "Redis" install_run services/redis
            fi
            if is_panel_db_external; then
                echo "External database configured (SQLALCHEMY_DATABASE_URI): skipping the local MySQL install"
            else
                add_task "MySQL" install_run services/mysql
            fi
        fi
        run_parallel 2 6 "常用工具与依赖"

        if [ "$DOCKER_MODE" != "true" ] && ! is_panel_db_external; then
            install_run services/mysql # make sure mysql is running
        fi
        # The panel needs them all (it generates the reality pair, ...)
        update_progress "${PROGRESS_ACTION}" "Hiddify 面板" 7
        install_run services/panel
    fi

    # 2) 读取面板中的配置
    if [ "$DO_NOT_RUN" != "true" ]; then
        update_progress "Hiddify 面板" "正在从面板读取配置……" 9
        set_config_from_hpanel

        update_progress "正在应用配置" "……" 11
        bash scripts/common/replace_variables.sh
    fi

    # 3) 所有服务并行安装；每完成一个，进度条前进一次
    if [ "$MODE" != "apply_users" ]; then
        bash ./services/deprecated/remove_deprecated.sh
        add_task "系统设置" runsh run.sh scripts/common
        add_task "防火墙" install_run services/firewall
        add_task "Rpxy L4（流量分流）" install_run services/rust-rpxy-l4
        add_task "HAProxy" install_run services/haproxy
        add_task "个人测速" install_run services/speedtest "$(hconfig "speed_test")"
        add_task "DNS 代理" install_run services/dns_proxy "$(hconfig "dnstt_enable")"
        # telemt 同时提供 MTProxy FakeTLS（telegram_enable）和 Telegram Web 代理（telegram_webproxy_enable）
        telegram_on=false
        [ "$(hconfig telegram_enable)" = "true" ] || [ "$(hconfig telegram_webproxy_enable)" = "true" ] && telegram_on=true
        add_task "Telegram 代理" install_run services/telegram "$telegram_on"
        add_task "FakeTLS 代理" install_run services/ssfaketls "$(hconfig "ssfaketls_enable")"
        add_task "WARP" install_run services/warp 1
        add_task "Xray" install_run services/xray 1
    fi
    add_task "WireGuard" install_run services/wireguard "$(hconfig "wireguard_enable")"
    add_task "Hiddify Core" install_run services/hiddify-core
    add_task "Clash Meta" install_run services/clash
    run_parallel 11 98 "${PROGRESS_ACTION}"
    if [ "$MODE" != "apply_users" ] && [ "$DO_NOT_RUN" != "true" ]; then
        wait_for_certificates
    fi

    update_progress "${PROGRESS_ACTION}" "即将完成" 98
    # 这一行是面板判定日志结束的标记（apply_api.py 的 FINISHED_MARK、result.html 的同一标记），请勿翻译
    echo "---------------------Finished!------------------------"
    remove_lock $NAME
    update_progress "${PROGRESS_ACTION}" "完成" 100
    # 只有面板代码被（重新）安装（安装/更新）时才重启面板。应用配置或应用用户不会改变面板：
    # 它直接从数据库读取新设置（设置变化时会清理缓存）。
    if [ "$DO_NOT_INSTALL" != "true" ]; then
        restart_hiddify_panel restart
    else
        restart_hiddify_panel start
    fi
    if [ ${#FAILED_STEPS[@]} -gt 0 ]; then
        error "完成，但以下步骤出错：$(IFS=,; echo "${FAILED_STEPS[*]}")（详见上方日志）"
        return 1
    fi
}

function clean_files() {
    rm -rf data/log/xray*
    # 旧 data/services 布局遗留的 jinja 产物
    rm -rf /opt/hiddify-manager/data/services/xray/json/*.json
    rm -rf /opt/hiddify-manager/data/services/hiddify-core/json/*.json
    rm -rf /opt/hiddify-manager/data/services/haproxy/*.cfg
    find /opt/hiddify-manager/services/xray/configs /opt/hiddify-manager/services/hiddify-core/configs \
        -type f -name '*.json' ! -name '*.j2' -delete 2>/dev/null || true
    # 目录内遗留文件（不是 generated/ 下的软链）
    rm -f /opt/hiddify-manager/services/rust-rpxy-l4/config.toml
    find ./ -type f -name "*.template" -exec rm -f {} \;
}

function cleanup() {
    error "脚本被中断，正在退出……"
    # disable_ansii_modes
    remove_lock $NAME
    exit 9
}

# 捕获 Ctrl+C 并调用清理函数
trap cleanup SIGINT

function set_config_from_hpanel() {
    reload_all_configs >/dev/null
    if [[ $? != 0 ]]; then
        error "Hiddify 面板出现异常，请把日志发送到 hiddify@gmail.com"
        exit 4
    fi
    
    export SERVER_IP=$(curl --connect-timeout 1 -s https://v4.ident.me/)
    # 内核关闭了 IPv6 时不做探测：不可能成功。
    export SERVER_IPv6=
    if [ -d /proc/sys/net/ipv6 ] && [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != 1 ]; then
        SERVER_IPv6=$(curl --connect-timeout 1 -s https://v6.ident.me/)
    fi
}

# 安装并运行一个服务；当它的 install.sh 或 run.sh 失败时返回非零（由 run_parallel 汇总报告）。
function install_run() {
    echo "======================$1====================================={"
    local start_time=$(date +%s) rc=0

    if [ "$DO_NOT_INSTALL" != "true" ];then
        if [ "$DOCKER_MODE" == "true" ]; then
            # Docker 在构建镜像时安装，此时设置还不存在：安装所有服务，由容器启动时决定启用哪些。
            runsh install.sh "$1" || rc=$?
        else
            runsh install.sh "$@" || rc=$?
        fi
        if [ "$MODE" != "apply_users" ] && [ "$DOCKER_MODE" != "true"  ]; then
            systemctl daemon-reload
        fi
    fi
    if [ "$DO_NOT_RUN" != "true" ];then
        runsh run.sh "$@" || rc=$?
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    [ "$rc" != 0 ] && error "$1 执行失败（退出码 $rc）"
    echo "}========================$1（耗时 ${duration}s）=============================="
    return $rc
}

# 运行服务的 install.sh / run.sh（对应设置为关闭时改跑 disable.sh）；返回其退出码。
function runsh() {
    local command=$1 rc=0
    if [[ $3 == "false" || $3 == "0" ]]; then
        command=disable.sh
    fi
    pushd "$2" >>/dev/null || return 1
    if [[ -f $command ]]; then
        echo "=== $command $2"
        bash "$command" || rc=$?
    fi
    popd >>/dev/null
    return $rc
}

if [[ " $* " == *" --no-gui "* ]]; then
    set -- "${@/--no-gui/}"
    export MODE="$1"
    set_lock $NAME
    if [[ " $* " == *" --no-log "* ]]; then
        set -- "${@/--no-log/}"
        main
        error_code=$?
    else
        main |& tee $LOG_FILE
        error_code=${PIPESTATUS[0]} # 取 main 的退出码，而不是 tee 的
    fi
    remove_lock $NAME
else
    show_progress_window --subtitle $(get_installed_config_version) --log $LOG_FILE /opt/hiddify-manager/scripts/install.sh "$@" --no-gui --no-log
    error_code=$?
    if [[ $error_code != "0" ]]; then
        # echo less -r -P"Installation Failed! Press q to exit" +G "$log_file"
        msg_with_hiddify "安装失败！退出码 $error_code"
    else
        msg_with_hiddify "安装已成功完成。"
        check_hiddify_panel "$@" |& tee -a $LOG_FILE
    fi
fi

exit $error_code
