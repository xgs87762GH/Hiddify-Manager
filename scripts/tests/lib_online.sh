#!/usr/bin/env bash
# 在线冒烟公共库（由 smoke_subscription / smoke_api_admin / smoke_proxy_matrix /
# smoke_backup_restore source）。与 scripts/tests 里那些纯离线套件不同，这里需要一台
# 正在运行的 Hiddify-Manager；检测不到实例时打印 SKIP 并退出 0，保证离线 CI 不被破坏。
#
# 全部凭证从本机数据库/环境变量发现，库里不写任何主机、UUID 或口令。
# 可用环境变量：
#   HIDDIFY_ROOT        安装根目录         默认 /opt/hiddify-manager
#   HIDDIFY_BASE        面板监听地址       默认 http://127.0.0.1:9000
#   HIDDIFY_PYTHON      JSON 解析用 python 默认 python3
#   HIDDIFY_HTTP_TIMEOUT 单次请求超时      默认 30
#   HIDDIFY_PROXY_PATH / _ADMIN_UUID / _USER_UUID / _DB_VERSION  手工覆盖凭证发现
set -uo pipefail

HIDDIFY_ROOT=${HIDDIFY_ROOT:-/opt/hiddify-manager}
HIDDIFY_BASE=${HIDDIFY_BASE:-http://127.0.0.1:9000}
HIDDIFY_PYTHON=${HIDDIFY_PYTHON:-python3}
HIDDIFY_TMP=${HIDDIFY_TMP:-$(mktemp -d /tmp/hiddify-smoke.XXXXXX)}
mkdir -p "$HIDDIFY_TMP"

SMOKE_PASS=0
SMOKE_FAIL=0
SMOKE_SKIP=0
SMOKE_FAILED=()

ok() { printf '  PASS  %s\n' "$*"; SMOKE_PASS=$((SMOKE_PASS + 1)); }
bad() {
    printf '  FAIL  %s\n' "$*"
    SMOKE_FAIL=$((SMOKE_FAIL + 1))
    SMOKE_FAILED+=("$*")
}
skip() { printf '  SKIP  %s\n' "$*"; SMOKE_SKIP=$((SMOKE_SKIP + 1)); }
section() { printf '\n== %s ==\n' "$*"; }
summary() {
    printf '\nSUMMARY pass=%d fail=%d skip=%d\n' "$SMOKE_PASS" "$SMOKE_FAIL" "$SMOKE_SKIP"
    if [ "$SMOKE_FAIL" -gt 0 ]; then
        printf 'FAILED CASES:\n'
        printf '  - %s\n' "${SMOKE_FAILED[@]}"
        return 1
    fi
    return 0
}

# root 命令：root 直接跑；非 root 时先试免密 sudo，若调用方通过 SUDO_PASS 提供了
# 口令则用 -S（库里不写死任何主机口令）。复合命令必须走 bash -c，直接传字符串会被
# sudo 当成可执行文件名而静默失败。
_root_sh() {
    local script=$1
    if [ "$(id -u)" -eq 0 ]; then
        bash -c "$script"
    elif [ -n "${SUDO_PASS:-}" ]; then
        printf '%s\n' "$SUDO_PASS" | sudo -S bash -c "$script" 2>/dev/null
    else
        sudo -n bash -c "$script"
    fi
}
dbq() { _root_sh "mysql -uroot -N -B -e $(printf '%q' "$1")" 2>/dev/null; }
root_run() { _root_sh "$1"; }

# 凭证发现：面板把「空密码 Basic」的用户名当 uuid 查（auth.py）
discover() {
    PROXY_PATH=${HIDDIFY_PROXY_PATH:-$(dbq "select value from hiddifypanel.str_config where \`key\`='proxy_path' limit 1")}
    ADMIN_UUID=${HIDDIFY_ADMIN_UUID:-$(dbq "select uuid from hiddifypanel.admin_user order by id limit 1")}
    USER_UUID=${HIDDIFY_USER_UUID:-$(dbq "select uuid from hiddifypanel.user where deleted=0 order by id limit 1")}
    DB_VERSION=${HIDDIFY_DB_VERSION:-$(dbq "select value from hiddifypanel.str_config where \`key\`='db_version' limit 1")}
    if [ -z "${PROXY_PATH:-}" ] || [ -z "${ADMIN_UUID:-}" ]; then
        echo "SKIP online smoke: no running instance at $HIDDIFY_ROOT"
        echo "     override with HIDDIFY_PROXY_PATH / HIDDIFY_ADMIN_UUID / HIDDIFY_USER_UUID / HIDDIFY_BASE"
        exit 0
    fi
    printf 'instance: base=%s db_version=%s admin=%s… user=%s…\n' \
        "$HIDDIFY_BASE" "${DB_VERSION:-?}" "${ADMIN_UUID:0:8}" "${USER_UUID:0:8}"
}
admin_auth() { printf 'Basic %s' "$(printf '%s:' "$ADMIN_UUID" | base64 -w0)"; }
user_auth() { printf 'Basic %s' "$(printf '%s:' "$USER_UUID" | base64 -w0)"; }

# http_code <outfile> <url> [curl 额外参数...] -> 打印状态码；curl 自身失败记 000
http_code() {
    local out=$1 url=$2 code
    shift 2
    code=$(curl -sS -o "$out" -w '%{http_code}' --max-time "${HIDDIFY_HTTP_TIMEOUT:-30}" "$@" "$url" 2>/dev/null) || code=000
    printf '%s' "${code:-000}"
}
# 同 http_code，但额外把响应头写到 <outfile>.hdr
http_hdr() {
    local out=$1 url=$2 code
    shift 2
    code=$(curl -sS -D "$out.hdr" -o "$out" -w '%{http_code}' --max-time "${HIDDIFY_HTTP_TIMEOUT:-30}" "$@" "$url" 2>/dev/null) || code=000
    printf '%s' "${code:-000}"
}
expect_code() {
    local name=$1 want=$2 got=$3
    if [ "$got" = "$want" ]; then ok "$name (HTTP $got)"; else bad "$name (want $want got $got)"; fi
}
# 负例的判据是「不得 5xx / 不得连接不上」，具体 4xx 由产品决定
expect_not5xx() {
    local name=$1 got=$2
    case "$got" in
        5*|000) bad "$name (got $got)" ;;
        *) ok "$name (HTTP $got)" ;;
    esac
}
# json_get <file> <dot.path>  —— 不依赖 jq
json_get() {
    "$HIDDIFY_PYTHON" - "$1" "$2" <<'PY' 2>/dev/null
import json
import sys

data = json.load(open(sys.argv[1]))
for part in sys.argv[2].split('.'):
    data = data[int(part)] if isinstance(data, list) and part.isdigit() else data[part]
print(data)
PY
}
# body_has <file> <grep 扩展正则> <说明> —— 节点/标志位断言
body_has() {
    local file=$1 pattern=$2 label=$3
    if grep -qiE "$pattern" "$file" 2>/dev/null; then ok "$label"; else bad "$label (pattern not found)"; fi
}
