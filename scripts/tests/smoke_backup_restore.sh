#!/usr/bin/env bash
# 在线冒烟：MySQL 转储 + data/generated 打包 → 恢复 → 复验，默认 3 轮。
# 用法: bash scripts/tests/smoke_backup_restore.sh [轮数]
#
# 两个已踩过的坑写死在脚本里：
#   1) $ROOT/data 里含 MariaDB datadir（data/mysql），打包/解包都必须排除，
#      否则 datadir 变成 root 属主 → 表只读 → 面板 500；
#   2) dump 只导 --databases hiddifypanel（不是 --all-databases），SQL 自带
#      CREATE DATABASE / USE，不会再打到 mysql 系统库；加 --one-database 反而会让
#      带库名的语句被过滤掉、恢复失败。
# 备份目录默认在 /tmp，绝不能放进 $ROOT/data（否则自己打自己，体积会滚雪球）。
# 这是破坏性用例：会 DROP DATABASE 再恢复，请只在测试机上运行。
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib_online.sh"
ROUNDS=${1:-3}
DIR=${HIDDIFY_BACKUP_DIR:-/tmp/hiddify-backup-smoke}
mkdir -p "$DIR"

discover

counts() {
    dbq "select concat(
        (select count(*) from hiddifypanel.user where deleted=0),'/',
        (select count(*) from hiddifypanel.domain),'/',
        (select count(*) from hiddifypanel.admin_user),'/',
        (select count(*) from hiddifypanel.tag),'/',
        (select value from hiddifypanel.str_config where \`key\`='db_version'))"
}

wait_panel() {
    local i code
    for i in $(seq 1 25); do
        code=$(http_code "$DIR/wait" "$HIDDIFY_BASE/$PROXY_PATH/" -H "Authorization: $(admin_auth)")
        [ "$code" = "200" ] && return 0
        sleep 2
    done
    return 1
}

check_alive() {
    local tag=$1 u code
    for u in hiddify-panel hiddify-mysql hiddify-redis; do
        systemctl is-active --quiet "$u" && ok "$tag: $u active" || bad "$tag: $u inactive"
    done
    code=$(http_code "$DIR/panel" "$HIDDIFY_BASE/$PROXY_PATH/" -H "Authorization: $(admin_auth)")
    expect_not5xx "$tag: panel responds" "$code"
    code=$(http_code "$DIR/sub" "$HIDDIFY_BASE/$PROXY_PATH/$USER_UUID/auto/" -H "User-Agent: v2rayN/6.31")
    expect_code "$tag: subscription" 200 "$code"
}

BEFORE=$(counts)
printf 'before: %s (users/domains/admins/tags/db_version)\n' "$BEFORE"

for r in $(seq 1 "$ROUNDS"); do
    section "round $r: backup"
    if root_run "mysqldump --single-transaction --routines --triggers --databases hiddifypanel > '$DIR/db-r$r.sql'" &&
       root_run "tar -czf '$DIR/data-r$r.tar.gz' -C '$HIDDIFY_ROOT' --exclude=data/mysql --exclude=data/redis --exclude=data/cert data generated" &&
       [ -s "$DIR/db-r$r.sql" ] && [ -s "$DIR/data-r$r.tar.gz" ]; then
        ok "round $r snapshot written (db=$(stat -c%s "$DIR/db-r$r.sql")B data=$(stat -c%s "$DIR/data-r$r.tar.gz")B)"
    else
        bad "round $r snapshot failed"
        continue
    fi

    section "round $r: restore"
    root_run "systemctl stop hiddify-panel" >/dev/null 2>&1
    root_run "mysql -uroot -e 'DROP DATABASE IF EXISTS hiddifypanel'" >/dev/null 2>&1
    if root_run "mysql -uroot < '$DIR/db-r$r.sql'"; then
        ok "round $r db restored"
    else
        bad "round $r db restore failed"
    fi
    root_run "tar -xzf '$DIR/data-r$r.tar.gz' -C '$HIDDIFY_ROOT' --exclude=data/mysql --exclude=data/redis --exclude=data/cert" >/dev/null 2>&1
    root_run "chown -R hiddify-panel:hiddify-panel '$HIDDIFY_ROOT/data/hiddify-panel' '$HIDDIFY_ROOT/generated'" >/dev/null 2>&1
    root_run "systemctl start hiddify-panel" >/dev/null 2>&1
    root_run "redis-cli flushall" >/dev/null 2>&1
    root_run "bash '$HIDDIFY_ROOT/scripts/apply_configs.sh'" >/dev/null 2>&1
    if wait_panel; then ok "round $r panel back up"; else bad "round $r panel did not come back in 50s"; fi

    AFTER=$(counts)
    [ "$AFTER" = "$BEFORE" ] && ok "round $r counts identical ($AFTER)" || bad "round $r counts changed $BEFORE -> $AFTER"
    check_alive "round $r"

    # 恢复后 db_version / 凭证必须仍然可读，否则后面几轮会连锁失败
    if [ -z "$(dbq "select value from hiddifypanel.str_config where \`key\`='proxy_path' limit 1")" ]; then
        bad "round $r proxy_path lost after restore"
    else
        ok "round $r proxy_path intact"
    fi
done

section "final"
AFTER=$(counts)
[ "$AFTER" = "$BEFORE" ] && ok "final counts stable ($AFTER)" || bad "final counts $BEFORE -> $AFTER"
summary
