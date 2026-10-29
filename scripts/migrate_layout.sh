#!/bin/bash
# 用 unzip -o 把新 release 覆盖到 /opt/hiddify-manager 后，会残留 v10 的目录。
# 若 singbox/ 仍存在，说明还是旧布局：保留 MySQL/Redis 密码，并把残留目录移到 old/。
# 若 singbox/ 已不存在，说明是全新安装或已迁移过的目录。

set -euo pipefail

HIDDIFY_DIR="${HIDDIFY_DIR:-/opt/hiddify-manager}"
cd "$HIDDIFY_DIR"

SERVICES="$HIDDIFY_DIR/services"
SCRIPTS="$HIDDIFY_DIR/scripts"
DATA="$HIDDIFY_DIR/data"
OLD="$HIDDIFY_DIR/old"

log() { echo "[migrate-layout] $*"; }

# 注意：这里刻意不创建 $DATA/mysql/db（真正的数据目录）——
# mysql/utils.sh 的 migrate_mysql_datadir 需要该路径不存在或已就绪才能做原子 mv；
# 详见该文件。
mkdir -p "$SERVICES/mysql" "$SERVICES/redis" \
    "$DATA/ssl" "$DATA/log/system" "$DATA/mysql" "$DATA/redis" \
    "$DATA/hiddify-panel" "$HIDDIFY_DIR/generated"

install_hiddify_cli() {
    chmod +x "$SCRIPTS/hiddify" 2>/dev/null || true
    if [ -f "$SCRIPTS/hiddify" ]; then
        ln -sf "$SCRIPTS/hiddify" /usr/bin/hiddify
        mkdir -p /etc/bash_completion.d /etc/profile.d
        if [ -f "$SCRIPTS/hiddify-completion.bash" ]; then
            ln -sf "$SCRIPTS/hiddify-completion.bash" /etc/bash_completion.d/hiddify
            # set -u：面板更新/systemd 场景下 HOME 可能未导出，不能直接解引用。
            if [ -n "${HOME:-}" ] && [ -f "$HOME/.bashrc" ] && ! grep -qF 'hiddify-completion.bash' "$HOME/.bashrc"; then
                echo '[ -f /opt/hiddify-manager/scripts/hiddify-completion.bash ] && . /opt/hiddify-manager/scripts/hiddify-completion.bash' >>"$HOME/.bashrc"
            fi
        fi
        if [ -f "$SCRIPTS/hiddify-profile.sh" ]; then
            ln -sf "$SCRIPTS/hiddify-profile.sh" /etc/profile.d/hiddify.sh
        fi
        log "已安装 hiddify 命令行 -> /usr/bin/hiddify"
    fi
}
disable_all_services() {
    find /opt/hiddify-manager/ -type d -name "services" -prune -o -type d -name "old" -prune -o -type f -name "*.service" -print |
    xargs -r -n1 basename |
    tee /dev/stderr |
    xargs -r -I{} systemctl disable --now {}
}
# 停止单元并确认其进程真的消失。单元文件一旦被删除，systemd 就无法再加载（或停止）它，
# 遗留进程会继续占用端口，导致需要这些端口的新布局服务起不来（旧 sing-box 占着 2000 端口）。
stop_unit_and_confirm() {
    local unit="$1" pid cmd i
    systemctl disable --now "$unit" >/dev/null 2>&1 || systemctl stop "$unit" >/dev/null 2>&1 || true
    pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || echo 0)"
    case "$pid" in ''|*[!0-9]*|0*) return 0 ;; esac
    cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
    case "$cmd" in
        *hiddify*|*xray*|*sing-box*|*haproxy*|*nginx*) ;;
        *) log "不结束进程 $pid（$cmd）：它看起来不是 hiddify 的进程"
           return 0 ;;
    esac
    log "$unit 未能停止，正在结束其遗留进程 $pid"
    kill -TERM "$pid" 2>/dev/null || true
    for i in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    kill -KILL "$pid" 2>/dev/null || true
}
stop_old_units() {
    local link unit target
    local services_real hid_dir_real removed=0
    services_real="$(readlink -m "$SERVICES")"
    hid_dir_real="$(readlink -m "$HIDDIFY_DIR")"
    for link in /etc/systemd/system/*.service; do
        [ -L "$link" ] || continue
        unit="$(basename "$link")"
        # -m 也能规范化目标已不存在的悬空链接
        target="$(readlink -m "$link" 2>/dev/null || true)"
        case "$target" in
            "$services_real"/*) continue ;; # 当前布局的单元：不要动
            "$hid_dir_real"/*|/opt/hiddify-server/*|/opt/hiddify-config/*) ;;
            *) continue ;;                  # 不是 hiddify 管理的
        esac
        # 要在单元还能被解析时停止：一旦其文件/目标消失，systemd 就无法加载它，
        # 旧进程会继续运行（并占着端口）直到下次重启。
        log "正在停止遗留单元 $unit"
        stop_unit_and_confirm "$unit"
        rm -f "/etc/systemd/system/multi-user.target.wants/$unit" "$link"
        removed=1
    done
    # 单元文件已消失、但启用链接仍残留的情况
    for link in /etc/systemd/system/multi-user.target.wants/*.service; do
        [ -L "$link" ] || continue
        target="$(readlink -m "$link" 2>/dev/null || true)"
        case "$target" in
            "$services_real"/*) ;;
            "$hid_dir_real"/*|/opt/hiddify-server/*|/opt/hiddify-config/*)
                log "正在删除残留的启用链接 $(basename "$link")"
                rm -f "$link"
                removed=1
                ;;
        esac
    done
    if [ "$removed" = 1 ]; then
        systemctl daemon-reload 2>/dev/null || true # 让 systemd 忘掉刚删除的单元
    fi
}

rename_singbox_unit() {
    if [ -e /etc/systemd/system/hiddify-singbox.service ] || [ -L /etc/systemd/system/hiddify-singbox.service ]; then
        log "正在用 hiddify-core.service 替换 hiddify-singbox.service"
        stop_unit_and_confirm hiddify-singbox.service
        rm -f /etc/systemd/system/hiddify-singbox.service
    fi
    if [ -f "$SERVICES/hiddify-core/hiddify-core.service" ]; then
        ln -sf "$SERVICES/hiddify-core/hiddify-core.service" /etc/systemd/system/hiddify-core.service
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable hiddify-core.service 2>/dev/null || true
    fi
}

move_to_old() {
    local path="$1"
    local name
    name="$(basename "$path")"
    if [ -L "$path" ]; then
        log "正在删除残留的软链 $path"
        rm -f "$path"
        return 0
    fi
    if [ ! -e "$path" ]; then
        return 0
    fi
    mkdir -p "$OLD"
    local dest="$OLD/$name"
    if [ -e "$dest" ]; then
        dest="$OLD/${name}.$(date +%Y%m%d%H%M%S)"
    fi
    log "移动 $path -> $dest"
    mv "$path" "$dest"
}

# 在目录被移走之前先停掉旧布局的残留服务；否则它们的单元文件会变成悬空软链，
# systemd 再也无法加载，旧进程会继续运行并占用端口（从而阻塞新布局的服务启动）。
stop_old_units

# 全新安装或已迁移：没有残留的 singbox/ 目录。
if [ ! -d "$HIDDIFY_DIR/singbox" ] || [ -L "$HIDDIFY_DIR/singbox" ]; then
    disable_all_services

    if [ -L "$HIDDIFY_DIR/singbox" ]; then
        log "正在删除残留的 singbox 软链"
        rm -f "$HIDDIFY_DIR/singbox"
    fi
    # acme.sh --upgrade 可能在迁移后重建旧工作目录。
    move_to_old "$HIDDIFY_DIR/acme.sh"
    
    rename_singbox_unit
    install_hiddify_cli
    exit 0
fi

log "检测到 singbox/，正在把残留的旧布局目录迁移到 old/"

# 可用时复用服务辅助函数（data/ 下同样的一次性生成路径）
if [ -f "$SCRIPTS/common/utils.sh" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPTS/common/utils.sh"
fi
if [ -f "$SERVICES/mysql/utils.sh" ]; then
    # shellcheck source=/dev/null
    source "$SERVICES/mysql/utils.sh"
fi
if [ -f "$SERVICES/redis/utils.sh" ]; then
    # shellcheck source=/dev/null
    source "$SERVICES/redis/utils.sh"
fi

preserve_mysql_pass() {
    local dest="${HIDDIFY_MYSQL_PASS_FILE:-${HIDDIFY_DATA:-$DATA}/mysql/mysql_pass}"
    local src
    mkdir -p "$(dirname "$dest")"
    if [ -f "$dest" ]; then
        return 0
    fi
    for src in \
        "$SERVICES/mysql/mysql_pass" \
        "$HIDDIFY_DIR/other/mysql/mysql_pass" \
        "$HIDDIFY_DIR/mysql/mysql_pass"
    do
        if [ -f "$src" ]; then
            cp -a "$src" "$dest"
            chmod 600 "$dest"
            log "已从 $src 保留 MySQL 密码 -> $dest"
            return 0
        fi
    done
}

preserve_redis_pass() {
    local dest_pass="${HIDDIFY_REDIS_PASS_FILE:-${HIDDIFY_DATA:-$DATA}/redis/redis_pass}"
    local src pass=""
    mkdir -p "$(dirname "$dest_pass")"
    if [ -f "$dest_pass" ]; then
        return 0
    fi
    for src in \
        "${HIDDIFY_REDIS_LIVE_CONF:-${HIDDIFY_DATA:-$DATA}/redis/redis.conf}" \
        "$SERVICES/redis/redis.conf" \
        "$HIDDIFY_DIR/other/redis/redis.conf" \
        "$HIDDIFY_DIR/redis/redis.conf"
    do
        if type redis_pass_from_conf >/dev/null 2>&1; then
            pass="$(redis_pass_from_conf "$src" || true)"
        else
            pass="$(grep '^requirepass ' "$src" 2>/dev/null | awk '{print $2}' | tail -n1 || true)"
        fi
        if [ -n "$pass" ]; then
            log "已从 $src 保留 Redis 密码"
            break
        fi
    done
    [ -n "$pass" ] || return 0
    echo "$pass" >"$dest_pass"
    chmod 600 "$dest_pass"
    if type ensure_redis_data >/dev/null 2>&1; then
        ensure_redis_data --sync "$SERVICES/redis/redis.conf"
    fi
}

preserve_mysql_pass
preserve_redis_pass

for name in nginx haproxy singbox xray hiddify-panel acme.sh other ssl log mysql redis; do
    move_to_old "$HIDDIFY_DIR/$name"
done

# v10 的 common/ 是残留物；仅在存在打包的 download.sh 兼容层时保留它。
if [ -d "$HIDDIFY_DIR/common" ] && [ ! -L "$HIDDIFY_DIR/common" ]; then
    if [ -f "$HIDDIFY_DIR/common/utils.sh" ] || [ -f "$HIDDIFY_DIR/common/install.sh" ]; then
        shim=""
        if [ -f "$HIDDIFY_DIR/common/download.sh" ]; then
            shim="$(mktemp)"
            cp "$HIDDIFY_DIR/common/download.sh" "$shim"
        fi
        move_to_old "$HIDDIFY_DIR/common"
        if [ -n "$shim" ]; then
            mkdir -p "$HIDDIFY_DIR/common"
            mv "$shim" "$HIDDIFY_DIR/common/download.sh"
        fi
    fi
fi

for f in apply_configs.sh docker-init.sh install.sh menu.sh restart.sh status.sh uninstall.sh update.sh current.json; do
    move_to_old "$HIDDIFY_DIR/$f"
done

rename_singbox_unit
install_hiddify_cli


