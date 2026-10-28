#!/bin/bash
cd $(dirname -- "$0")
source ./utils.sh
if [ "$(id -u)" -ne 0 ]; then
    echo '本脚本必须以 root 身份运行' >&2
    exit 1
fi


checkOS




export DEBIAN_FRONTEND=noninteractive
NAME="installer"
LOG_FILE="$(log_file $NAME)"
export USE_VENV=true

if [ ! -f /opt/hiddify-manager/common/install.sh ] && [ ! -f /opt/hiddify-manager/scripts/install.sh ]; then
    rm -rf /opt/hiddify-manager
fi



if [ ! -d "/opt/hiddify-manager/" ] && [ -d "/opt/hiddify-config/" ]; then
    mv /opt/hiddify-config /opt/hiddify-manager
    ln -s /opt/hiddify-manager /opt/hiddify-config
fi
if [ ! -d "/opt/hiddify-manager/" ] && [ -d "/opt/hiddify-server/" ]; then
    mv /opt/hiddify-config /opt/hiddify-manager
    ln -s /opt/hiddify-manager /opt/hiddify-server
fi

function install_panel() {
    local force=${2:-true}
    local package_mode=${1:-release}
    if [ "$package_mode" == "false" ]; then
        package_mode="release"
    fi
    local update=0
    local panel_update=0
    update_progress "正在升级……" "正在升级系统软件包以提升安全性……" 5
    apt-get update
    #apt upgrade -y
    # apt -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" --only-upgrade upgrade
    # apt dist-upgrade -y
    
    if ! is_installed hiddifypanel; then
        hiddify_bashrc_install_menu
    fi

    

    install_package curl clang libev-dev libevdev2 default-libmysqlclient-dev build-essential git ca-certificates pkg-config   jq wireguard  pkg-config #安装 uv 与 hiddifypanel 所需依赖

    update_panel "$package_mode" "$force"
    panel_update=$?
    # 这里降级 marshmallow，因为 api_flask 不支持 v4
    #/opt/hiddify-manager/.venv/bin/pip install "marshmallow<=3.26.1"
    
    update_config "$package_mode" "$force"
    config_update=$?
    post_update_tasks  "$panel_update" "$config_update" "$package_mode"
    
    if is_installed hiddifypanel && [[ -z "$package_mode" || ($package_mode == "develop" || $package_mode == "beta" || $package_mode == "release") ]]; then
        hiddify-panel-cli set-setting -k package_mode -v $1
    fi

}

function update_panel() {
    update_progress "正在检查更新……" "Hiddify 面板" 5
    local package_mode=$1
    local force=$2
    local current_panel_version=$(get_installed_panel_version)
    # 根据包模式判断并更新面板版本；
    # 若本次确实执行了更新，则把 panel_update 置为 1。
    
    case "$package_mode" in
        docker)
            activate_python_venv
            # install_python310
            # uv pip install -U --no-deps --force-reinstall hiddify-panel/src
            # Dockerfile 的 panel-ui 阶段已提供构建好的前端；镜像里没有 Node.js。
            if [ ! -f /opt/hiddify-manager/services/panel/src/hiddifypanel/static/admin-v2/index.html ]; then
                error "缺少管理端 UI 构建产物：请用 Dockerfile（panel-ui 阶段）构建镜像"
                exit 1
            fi
            uv pip install /opt/hiddify-manager/services/panel/src 
            # pip install -U hiddifypanel
        ;;
        v*)
            update_progress "正在更新……" "正在把 Hiddify 面板从 $current_panel_version 更新到 $latest" 10
            panel_path=$(hiddifypanel_path)
            disable_panel_services
            if [ ! -z "$USE_VENV" ]; then
                activate_python_venv
                if [ "$USE_VENV" == "310" ];then
                    install_python310
                    install_panel_from_git "${package_mode}" pip || return 1
                else
                    install_panel_from_git "${package_mode}" "uv pip" || return 1
                fi
            else 
               install_python310
               install_panel_from_git "${package_mode}" pip3 || return 1
            fi
            update_progress "更新完成" "Hiddify 面板已更新到 ${package_mode}" 50
            return 0
        ;;
        develop|dev)
            # 使用你自己定制面板分支上的最新提交
            : "${HIDDIFY_PANEL_BRANCH:=dev-custom}"
            latest=$(get_commit_version Hiddify-Panel)
            activate_python_venv
            echo "开发版：hiddify 面板版本 当前=$current_panel_version 最新=$latest"
            if [[ "$current_panel_version" != "$latest" ]]; then
                echo "检测到更新的开发版面板，正在更新……"
            fi
            if [[ $force == "true" || "$latest" != "$current_panel_version" ]]; then
                update_progress "正在更新……" "正在把 Hiddify 面板从 $current_panel_version 更新到 $latest" 10
                
                disable_panel_services
                
                install_panel_from_git "$HIDDIFY_PANEL_BRANCH" "uv pip" || return 1
                panel_path=$(hiddifypanel_path)
                if [ -n "$latest" ]; then
                    echo "正在把 $latest 写入 $panel_path/VERSION"
                    echo $latest > $panel_path/VERSION
                    sed -i "s/__version__='[^']*'/__version__='$latest'/" $panel_path/VERSION.py
                else
                    warning "无法从 GitHub 读取最新面板提交：VERSION 保持原值"
                fi
                update_progress "更新完成" "Hiddify 面板已更新到 $latest" 50
                return 0
            fi
        ;;
        beta)
            activate_python_venv
            latest=$(get_pre_release_version hiddify-panel)
            echo "预发布版：hiddify 面板版本 当前=$current_panel_version 最新=$latest"
            if [[ "$current_panel_version" != "$latest" ]]; then
                echo "检测到更新的预发布版面板，正在更新……"
            fi
            if [[ $force == "true" || "$current_panel_version" != "$latest" ]]; then
                update_progress "正在更新……" "正在把 Hiddify 面板从 $current_panel_version 更新到 $latest" 10
                # 绝不安装官方 PyPI 包：面板来自你自己的 fork
                # 克隆预发布 tag（get_* 会去掉开头的 v，git 需要把它加回来）。
                disable_panel_services
                install_panel_from_git "v${latest#v}" "uv pip" || return 1
                update_progress "更新完成" "Hiddify 面板已更新到 $latest" 50
                return 0
            fi
        ;;
        release) 
            #TODO release 应切换到 3.13
            #install_python310
            activate_python_venv
            # error "you can not install release version 8 using this script"
            # exit 1
            latest=$(get_release_version hiddify-panel)
            echo "稳定版：hiddify 面板版本 当前=$current_panel_version 最新=$latest"
            if [[ "$current_panel_version" != "$latest" ]]; then
                echo "检测到更新的稳定版面板，正在更新……"
            fi
            if [[ $force == "true" || "$current_panel_version" != "$latest" ]]; then
                update_progress "正在更新……" "正在把 Hiddify 面板从 $current_panel_version 更新到 $latest" 10
                # 绝不安装官方 PyPI 包：面板来自你自己的 fork
                disable_panel_services
                uv pip install -U wheel
                install_panel_from_git "v${latest#v}" "uv pip" || return 1
                update_progress "更新完成" "Hiddify 面板已更新到 $latest" 50
                return 0
            fi
        ;;
        *)
            echo "未知的包模式：$package_mode"
            exit 1
        ;;
    esac
    
    return 1
}

function update_config() {
    update_progress "正在检查更新……" "Hiddify 配置" 55
    local package_mode=$1
    local force=$2
    local current_config_version=$(get_installed_config_version)
    # 所有下载都来自你自己的 fork（HIDDIFY_MANAGER_REPO 的默认值在 utils.sh 中）；
    # HIDDIFY_MANAGER_BRANCH 是你定制的分支，绝不是与上游同步的 main/dev。
    : "${HIDDIFY_MANAGER_BRANCH:=dev-custom}"

    case "$package_mode" in
        docker)
            echo "正在以 docker 模式安装"
            DO_NOT_RUN=true bash /opt/hiddify-manager/scripts/install.sh docker --no-gui --no-log
            echo "docker 模式安装完成"
        ;;
        v*)
            update_progress "正在更新……" "正在把 Hiddify 配置从 $current_config_version 更新到 $latest" 60
            export HIDDIFY_DISABLE_UPDATE=true
            #update_from_github "hiddify-manager.tar.gz" "https://github.com/${HIDDIFY_MANAGER_REPO}/archive/refs/tags/${package_mode}.tar.gz" $latest
            update_from_github "hiddify-manager.zip" "https://github.com/${HIDDIFY_MANAGER_REPO}/releases/download/${package_mode}/hiddify-manager.zip" $latest
            local update_code=$?
            [[ $update_code == 0 ]] || return $update_code
            update_progress "更新完成" "Hiddify 配置已更新到 $latest" 100
            return 0
        ;;
        develop|dev)
            local latest=$(get_commit_version hiddify-manager)
            # GitHub 不可读时保留已安装版本，而不是写入空的 VERSION
            [ -n "$latest" ] || latest="$current_config_version"
            echo "开发版：当前配置版本=$current_config_version -- 最新=$latest"
            if [[ "$force" == "true" || "$latest" != "$current_config_version" ]]; then
                update_progress "正在更新……" "正在把 Hiddify 配置从 $current_config_version 更新到 $latest" 60
                update_from_github "hiddify-manager.tar.gz" "https://github.com/${HIDDIFY_MANAGER_REPO}/archive/refs/heads/${HIDDIFY_MANAGER_BRANCH}.tar.gz" $latest
                local update_code=$?
                [[ $update_code == 0 ]] || return $update_code
                update_progress "更新完成" "Hiddify 配置已更新到 $latest" 100
                return 0
            fi
        ;;
        beta)
            local latest=$(get_pre_release_version hiddify-manager)
            echo "预发布版：当前配置版本=$current_config_version -- 最新=$latest"
            if [[ "$force" == "true" || "$latest" != "$current_config_version" ]]; then
                update_progress "正在更新……" "正在把 Hiddify 配置从 $current_config_version 更新到 $latest" 60
                update_from_github "hiddify-manager.zip" "https://github.com/${HIDDIFY_MANAGER_REPO}/releases/download/v$latest/hiddify-manager.zip"
                local update_code=$?
                [[ $update_code == 0 ]] || return $update_code
                update_progress "更新完成" "Hiddify 配置已更新到 $latest" 100
                return 0
            fi
        ;;
        release)
            # error "you can not install release version 8 using this script"
            # exit 1
            local latest=$(get_release_version hiddify-manager)
            echo "稳定版：当前配置版本=$current_config_version -- 最新=$latest"
            if [[ "$force" == "true" || "$latest" != "$current_config_version" ]]; then
                update_progress "正在更新……" "正在把 Hiddify 配置从 $current_config_version 更新到 $latest" 60
                update_from_github "hiddify-manager.zip" "https://github.com/${HIDDIFY_MANAGER_REPO}/releases/latest/download/hiddify-manager.zip"
                local update_code=$?
                [[ $update_code == 0 ]] || return $update_code
                update_progress "更新完成" "Hiddify 配置已更新到 $latest" 100
                return 0
            fi

        ;;
        *)
            echo "未知的包模式：$package_mode"
            exit 1
        ;;
    esac
    
    return 1
}

function post_update_tasks() {
    local panel_update=$1
    local config_update=$2
    local package_mode=$3
    
    if [[ $config_update != 0 ]]; then
        # 这一行是面板判定日志结束的标记（apply_api.py 的 FINISHED_MARK、result.html 的同一标记），请勿翻译
        echo "---------------------Finished!------------------------"
    fi
    remove_lock $NAME

    if [ "$package_mode" != "docker" ];then
      if [[ $panel_update == 0 && $config_update != 0 ]]; then
          hiddify apply || bash /opt/hiddify-manager/scripts/apply_configs.sh --no-gui --no-log
      elif [[ $panel_update == 0 ]]; then
          restart_hiddify_panel restart
      else
          restart_hiddify_panel start
      fi
      if [ "$CREATE_EASYSETUP_LINK" == "true" ];then
          hiddify-panel-cli set-setting --key create_easysetup_link --val True
      fi

      case "$package_mode" in
          release|beta)
              hiddify-panel-cli set-setting --key package_mode --val $package_mode
          ;;
          dev|develop)
              hiddify-panel-cli set-setting --key package_mode --val develop
          ;;
      esac
    fi
}

function update_from_github() {
    if [ -e /opt/hiddify-manager/.git ]; then
        echo "/opt/hiddify-manager 是 git 检出（开发模式），不覆盖它。请改用 git pull --recurse-submodules && make build"
        return 0
    fi
    local file_name=$1
    local url=$2
    local override_version=$3
    
    local file_type=${file_name##*.}
    mkdir -p /opt/hiddify-manager
    cd /opt/hiddify-manager || return 1

    # 先下载解压到旁路目录：404 / 运营商劫持页 / 断流都不会碰到已安装的目录树，
    # 且只有新文件就位后才写 VERSION（否则 update.sh 会误以为已经更新完毕）。
    local work
    work=$(mktemp -d) || return 1
    if ! curl -fsSL --retry 2 --connect-timeout 20 -o "$work/$file_name" "$url"; then
        echo "错误：无法下载 $url" >&2
        rm -rf "$work"
        return 1
    fi
    mkdir -p "$work/tree"
    case "$file_type" in
    zip)
        install_package unzip
        unzip -tq "$work/$file_name" >/dev/null && unzip -q -o "$work/$file_name" -d "$work/tree"
        ;;
    gz)
        gzip -t "$work/$file_name" && tar xzf "$work/$file_name" --strip-components=1 -C "$work/tree"
        ;;
    *)
        echo "不支持的文件类型：$file_type" >&2
        false
        ;;
    esac
    if [ $? -ne 0 ] || [ -z "$(ls -A "$work/tree")" ]; then
        echo "错误：下载的 $file_name 不是有效压缩包；未做任何改动" >&2
        rm -rf "$work"
        return 1
    fi
    # rsync 先写临时文件名再重命名。直接用 `cp -a` 会原地截断，
    # 仍在运行的 update.sh（同一 inode）会读到错位的字节，并在 "完成！" 之后
    # 报出 "syntax error near unexpected token fi"。
    install_package rsync
    rsync -a "$work/tree/" /opt/hiddify-manager/ || {
        rm -rf "$work"
        return 1
    }
    rm -rf "$work"
    if [[ -n "$override_version" ]]; then
        echo "$override_version" >VERSION
    fi

    # v12 及更早的 tag 把 install.sh 放在仓库根目录
    local install_script=scripts/install.sh
    [ -f "$install_script" ] || install_script=install.sh
    bash "$install_script" --no-gui --no-log
    local install_code=$?
    if [[ $install_code != 0 ]]; then
        echo "错误：$install_script 退出码 $install_code（配置文件已更新但未应用）" >&2
    fi
    return $install_code
}

function custom_version_installer(){
    # 只列出你自己 fork 上的 tag；绝不查询官方组织或 PyPI。
    TAGS=$(curl -s "https://api.github.com/repos/${HIDDIFY_MANAGER_REPO}/tags?per_page=100" | jq -r '.[].name' | sed 's/^v//' | sort -V -r)
    version_gt() {
        [ "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1" ]
    }
    FILTERED_TAGS=("release" "稳定版（推荐）" "beta" "预发布版" "dev" "开发版")
    for tag in $TAGS; do
        if [[ ! $tag =~ dev ]] && version_gt "$tag" "10.0.0"; then
            FILTERED_TAGS+=("v$tag" "")
        fi
    done
    TAG_LIST=$(printf "%s " "${FILTERED_TAGS[@]}")
    SELECTED_TAG=$(whiptail --title "自定义版本安装器" --menu "请选择版本！注意：不支持降级！" 20 70 12 "${FILTERED_TAGS[@]}" 3>&1 1>&2 2>&3)
    if [ $? -eq 0 ]; then
        echo "你选择了：$SELECTED_TAG"
        $0 $SELECTED_TAG
    else
        echo "未选择任何版本。"
        exit 1
    fi
}

if [[ " $@ " == *" custom "* ]];then
    custom_version_installer
    exit $?
fi


export USE_VENV=313
if [[ " $@ " == *" dev "* || " $@ " == *" docker "* || " $@ " == *" develop "* || " $@ " == *" beta "* ]];then
    export USE_VENV=313
fi

# 运行主函数并记录输出
if [[ " $@ " == *" --no-gui "* || "$(get_installed_panel_version) " == "8."* || "$NO_UI" == "true" ]]; then
    set -- "${@/--no-gui/}"
    set_lock $NAME
    if [[ " $@ " == *" --no-log "* ]]; then
        set -- "${@/--no-log/}"
        install_panel "$@"
        error_code=$?
    else
        install_panel "$@" |& tee $LOG_FILE
        error_code="${PIPESTATUS[0]}"
    fi
    
    remove_lock $NAME
else
    
    show_progress_window --subtitle "安装器" --log $LOG_FILE $0 $@ --no-gui --no-log
    
    error_code=$?
    if [[ $error_code != "0" ]]; then
        # echo less -r -P"Installation Failed! Press q to exit" +G "$log_file"
        msg_with_hiddify "安装失败！退出码=$error_code"
    else
        msg_with_hiddify "安装已成功完成。"
        check_hiddify_panel $@ |& tee -a $LOG_FILE
        read -p "按任意键进入菜单" -n 1 key
    fi
    if [ -f /opt/hiddify-manager/scripts/hiddify ]; then
        bash /opt/hiddify-manager/scripts/hiddify
    else
        # v12 及更早的目录结构
        bash /opt/hiddify-manager/menu.sh
    fi
fi
exit $error_code
