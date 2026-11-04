#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

cd /opt/hiddify-manager
source /opt/hiddify-manager/scripts/common/utils.sh
# 动作可通过 HIDDIFY_SYSTEMCTL_ACTION 指定为 start/stop，默认 restart
ACTION="${HIDDIFY_SYSTEMCTL_ACTION:-restart}"
LOG_NAME="restart"
case "$ACTION" in
start) LOG_NAME="run" ;;
stop) LOG_NAME="stop" ;;
esac
function restart_service() {
    local s=$1
    if systemctl is-enabled $s >/dev/null 2>&1 ; then
        before_stat=$(get_pretty_service_status $s 2>&1)
        systemctl "$ACTION" $s &
        sleep 2
        # 最多等 10 秒，直到状态符合预期
        for i in {1..10};do
            new_status=$(get_pretty_service_status $s 2>&1)
            if [ "$ACTION" = "stop" ]; then
                [[ "$new_status" != *active* ]] && break
            else
                [[ "$new_status" == *active* ]] && break
            fi
            sleep 1
        done
        printf "%-30s %-20s ---> %+19s \n" $s $before_stat  $new_status
    fi
}
function main() {
    # 安装/更新/应用配置正在跑的时候重启服务，会把半成品状态踩坏（配置还没生成、
    # 二进制还在替换、数据库正在迁移）。面板的 apply_api.check_can_start 只拦
    # apply/install/update，不拦 restart/status，所以这里自己兜住。
    local u
    for u in hiddify-install hiddify-update hiddify-apply; do
        if systemctl is-active --quiet "$u" 2>/dev/null; then
            error "安装/更新/应用配置正在进行（$u），请等它结束再重启服务。"
            # 拒绝分支也要写结束标记：面板只认日志尾部这一行（apply_api 的 FINISHED_MARK），
            # 不写的话"上次运行"永远显示未完成，页面只能靠"日志安静 6 秒"猜结束。
            echo "---------------------Finished!------------------------"
            return 12
        fi
    done

    echo -e "\n----------------------------------------------------------------"
    warning "$(printf "%-30s %-20s %s \n" "服务" "原状态" "新状态")"

    # 重启所有服务并输出状态（hiddify-panel 稍后单独处理）
    for ss in $(hiddify_service_units); do
        case "$ss" in
            *hiddify-panel*|*hiddify-cli*)
                continue
                ;;
            wg-quick@warp)
                # WARP 关闭时跳过
                [ "$(hconfig warp_mode)" == "disable" ] && continue
                ;;
        esac
        restart_service $ss &
    done
    wait
    # hiddify-panel 放在最后单独重启，避免面板重启导致前面的输出中断。
    # 由面板的“重启服务”按钮触发时，本脚本就跑在 hiddify-panel 的 cgroup 里：
    # 直接 systemctl restart hiddify-panel 会给该 cgroup 里每个进程（包括本脚本和
    # 写日志的 tee）发 SIGTERM，日志被截断、结尾标记永远写不进去，面板只能靠
    # “日志安静 6 秒”猜它结束了。这里把重启交给 systemd 在 1 秒后执行——独立
    # timer/独立 cgroup，不受面板停止影响——本脚本先把状态与结束标记打完再退出。
    if systemctl is-enabled hiddify-panel >/dev/null 2>&1; then
        local before_stat
        before_stat=$(get_pretty_service_status hiddify-panel 2>&1)
        if command -v systemd-run >/dev/null 2>&1 &&
            systemd-run --collect --unit=hiddify-panel-restart --on-active=1 --no-block \
                systemctl "$ACTION" hiddify-panel >/dev/null 2>&1; then
            printf "%-30s %-20s ---> %+19s \n" hiddify-panel "$before_stat" "scheduled(+1s)"
        else
            restart_service hiddify-panel &
            wait
        fi
    fi

    echo -e "----------------------------------------------------------------\n"
    # 面板靠日志末尾这一行判定本次运行结束（apply_api.py 的 FINISHED_MARK），请勿翻译
    echo "---------------------Finished!------------------------"
}
mkdir -p /opt/hiddify-manager/data/log/
# 管道的退出码取自 tee（永远是 0），而守卫分支的 return 12 会被这样吞掉，调用方
# 就以为"重启成功"了。显式取 main 的退出码，与 install.sh 的 ${PIPESTATUS[0]} 保持一致。
main "$@"|& tee /opt/hiddify-manager/data/log/${LOG_NAME}.log
exit_code=${PIPESTATUS[0]}
exit "$exit_code"
