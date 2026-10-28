#!/bin/bash
# cd "$(dirname -- "$0")"
cd /opt/hiddify-manager/
source /opt/hiddify-manager/scripts/common/utils.sh

function hiddify_bashrc_has_autostart() {
    grep -qE '/opt/hiddify-(manager|config|server)/(scripts/)?menu\.sh|^[[:space:]]*hiddify[[:space:]]*$' ~/.bashrc 2>/dev/null
}

# .bashrc 里 `# hiddify` 被注释掉表示用户主动关闭了菜单，不要覆盖它。
if hiddify_bashrc_has_autostart && ! hiddify_bashrc_menu_disabled; then
    hiddify_bashrc_enable_menu
fi


if ! grep -rxq "PasswordAuthentication.*no" /etc/ssh/sshd*; then
    # 提示用户关闭密码登录：密码认证容易被暴力破解
    WARNING_MSG="当前服务器开启了 SSH 密码登录，存在被滥用的风险。建议改用密钥登录，并在 ssh 配置中关闭 PasswordAuthentication。"
    whiptail --title "警告" --msgbox "$WARNING_MSG" 10 78
fi
#PACKAGE_MODE=$(get_package_mode)
#LATEST_CONFIG_VERSION=$(get_release_version hiddify-manager)
#LATEST_PANEL_VERSION=$(get_release_version hiddifypanel)


# if [[ "$PACKAGE_MODE" == "develop" ]] || [[ "$CURRENT_CONFIG_VERSION" == "$LATEST_CONFIG_VERSION" && "$CURRENT_PANEL_VERSION" == "$LATEST_PANEL_VERSION" ]]; then
#     UPDATE_NEED=""
# else
#     UPDATE_NEED="*UPDATE AVAILABLE* Config=v$LATEST_CONFIG_VERSION Panel=v$LATEST_PANEL_VERSION"
# fi


export CURRENT_CONFIG_VERSION=$(get_installed_config_version)
export CURRENT_PANEL_VERSION=$(get_installed_panel_version)

function menu() {
    

    HEIGHT=20
    WIDTH=70
    CHOICE_HEIGHT=12
    BACKTITLE="Hiddify Manager (Config=v$CURRENT_CONFIG_VERSION Panel=v$CURRENT_PANEL_VERSION)   $UPDATE_NEED  "
    TITLE="Hiddify Manager $PACKAGE_MODE"
    MENU="请选择操作："

    # 左侧是 case 匹配用的键名，不要修改；右侧是可读描述。
    OPTIONS=(status "查看系统状态"
        admin "显示管理员链接"
        log "查看系统日志"
        restart "重启服务（不修改配置）"
        install "重新安装服务端"
        update "更新 $UPDATE_NEED"
        advanced "卸载、远程协助、降级……"
        Quit "退出"
    )

    CHOICE=$(whiptail --clear \
        --backtitle "$BACKTITLE" \
        --title "$TITLE" \
        --menu "$MENU" \
        $HEIGHT $WIDTH $CHOICE_HEIGHT \
        "${OPTIONS[@]}" \
        3>&1 1>&2 2>&3)

    if [[ $? != 0 ]]; then
        clear
        exit 1
    fi
    clear
    echo "Hiddify：执行命令 $CHOICE"
    echo "=========================================="
    NEED_KEY=1
    case $CHOICE in
    "") exit 1 ;;
    "Quit") exit 1 ;;
    'log')
        W=()
        while read -r line; do
            size=$(ls -lah data/log/"$line" | awk -F " " '{print $5}')
            W+=("$line" "$size")
        done < <(ls -1 data/log)
        LOG=$(whiptail --clear \
            --backtitle "$BACKTITLE" \
            --title "$TITLE" \
            --menu "$MENU" \
            $HEIGHT $WIDTH $CHOICE_HEIGHT \
            "${W[@]}" \
            3>&1 1>&2 2>&3)
        clear
        echo -e "\033[0m"
        if [[ $LOG != "" ]]; then
            less -r -P"按 q 退出" +G "data/log/$LOG"
        fi
        NEED_KEY=0
        ;;
    "advanced")
        OPTIONS=(
            warp "查看 WARP 状态"
            add_remote "为该服务器开启远程协助"
            remove_remote "移除该服务器的远程协助"
            enable "开机时显示本菜单"
            disable "关闭本菜单"
            uninstall "卸载 Hiddify :("
            purge "彻底卸载并删除数据库 :("
            Back "返回"
        )
        CHOICE=$(whiptail --clear --backtitle "$BACKTITLE" --title "$TITLE" --menu "$MENU" $HEIGHT $WIDTH $CHOICE_HEIGHT "${OPTIONS[@]}" 3>&1 1>&2 2>&3)
        case $CHOICE in
        "enable")
            hiddify_bashrc_enable_menu
            NEED_KEY=0
            ;;
        "disable")
            hiddify_bashrc_disable_menu
            NEED_KEY=0
            ;;
        "uninstall")
            bash /opt/hiddify-manager/scripts/uninstall.sh
            ;;
        "purge")
            bash /opt/hiddify-manager/scripts/uninstall.sh purge
            ;;
        "add_remote")
            bash scripts/common/add_remote_assistant.sh
            ;;
        "remove_remote")
            bash scripts/common/remove_remote_assistant.sh
            ;;
        "warp")
            (
                cd services/warp/
                bash status.sh | less -r -P"按 q 退出" +G
            )
            NEED_KEY=0
            ;;
        *) NEED_KEY=0 ;;
        esac
        ;;

    "update")
        OPTIONS=(default "按面板中的配置决定"
                release "稳定版（推荐）$UPDATE_NEED"
                beta "预发布版 —— 可能存在缺陷"
                Back "返回"
        )
        CHOICE=$(whiptail --clear --backtitle "$BACKTITLE" --title "$TITLE" --menu "$MENU" $HEIGHT $WIDTH $CHOICE_HEIGHT "${OPTIONS[@]}" 3>&1 1>&2 2>&3)
        case $CHOICE in
        "default")
            bash /opt/hiddify-manager/scripts/update.sh
            ;;
        "release")
            bash /opt/hiddify-manager/scripts/update.sh release
            ;;
        "beta")
            bash /opt/hiddify-manager/scripts/update.sh beta
            ;;
        *) NEED_KEY=0 ;;
        esac
        export CURRENT_CONFIG_VERSION=$(get_installed_config_version)
        export CURRENT_PANEL_VERSION=$(get_installed_panel_version)

        ;;
    "admin")
        source /opt/hiddify-manager/scripts/common/utils.sh
        check_hiddify_panel
        echo "提示：hiddify admin    |    hiddify reset-password"
        read -p "按 'r' 重置管理员密码，按其他任意键返回主菜单：" -n 1 key
        echo  # 换行，便于阅读后续输出
        if [[ "$key" == 'r' ]]; then
            echo "正在重置所有者密码……"
            hiddify-panel-cli reset-owner-password
        fi
        NEED_KEY=0
        ;;
    "status")
        bash /opt/hiddify-manager/scripts/status.sh | less -r -P"按 q 退出" +G
        NEED_KEY=0
        ;;
    *)
        bash "/opt/hiddify-manager/scripts/${CHOICE}.sh"
        ;;
    esac

    if [[ $NEED_KEY == 1 ]]; then
        read -p "按任意键返回菜单" -n 1 key
    fi

    menu
}
menu
