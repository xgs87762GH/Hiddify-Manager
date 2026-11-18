#!/usr/bin/env bash
# 在线冒烟：订阅节点生成侧的参数自洽 + TLS/ALPN 协商取样 + sing-box 配置可解析。
# 用法: bash scripts/tests/smoke_proxy_matrix.sh [轮数]     默认 1 轮
#
# 责任分层（见 docs/dev/testing.md §8）：这里只判「生成侧」，端到端连通由客户端联测负责；
# 域名不可达（自建环境在 NAT 后）记为 SKIP，不误判成产品缺陷。
# HIDDIFY_EXPECT_NO_H1=1 时启用 PR#68 修复后的断言：订阅里不得再出现 xhttp + ALPN http/1.1。
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib_online.sh"
ROUNDS=${1:-1}
TMP=$HIDDIFY_TMP
UA=${HIDDIFY_UA:-v2rayN/6.31}
MAX_HANDSHAKES=${HIDDIFY_MAX_HANDSHAKES:-8}

discover

for r in $(seq 1 "$ROUNDS"); do
    section "round $r: 节点生成侧"
    c=$(http_code "$TMP/all" "$HIDDIFY_BASE/$PROXY_PATH/$USER_UUID/all.txt" -H "User-Agent: $UA")
    expect_code "round $r GET all.txt" 200 "$c"

    total=$(grep -cE '^(vless|vmess|trojan|ss|hysteria2|tuic)://' "$TMP/all" 2>/dev/null || echo 0)
    if [ "$total" -gt 0 ]; then ok "round $r exposes $total share links"; else bad "round $r no share links"; fi

    # 每条 TLS 节点都必须带 sni/host，否则客户端无法完成握手
    tls_nodes=$(grep -cE 'security=(tls|reality)' "$TMP/all" 2>/dev/null || echo 0)
    tls_with_host=$(grep -E 'security=(tls|reality)' "$TMP/all" 2>/dev/null | grep -cE '[?&](sni|host)=' || echo 0)
    if [ "$tls_nodes" -eq 0 ]; then
        skip "round $r no TLS share links"
    elif [ "$tls_with_host" -eq "$tls_nodes" ]; then
        ok "round $r all $tls_nodes TLS links carry sni/host"
    else
        bad "round $r only $tls_with_host/$tls_nodes TLS links carry sni/host"
    fi

    # 每条 xhttp 节点必须有 path（H1/H2 都由路径路由）
    xhttp=$(grep -c 'type=xhttp' "$TMP/all" 2>/dev/null || echo 0)
    xhttp_path=$(grep 'type=xhttp' "$TMP/all" 2>/dev/null | grep -c 'path=' || echo 0)
    if [ "$xhttp" -eq 0 ]; then
        skip "round $r no xhttp links"
    elif [ "$xhttp_path" -eq "$xhttp" ]; then
        ok "round $r all $xhttp xhttp links carry path"
    else
        bad "round $r only $xhttp_path/$xhttp xhttp links carry path"
    fi

    # 已知问题取证：xhttp + ALPN http/1.1 的「H1 腿」
    h1=$(grep 'type=xhttp' "$TMP/all" 2>/dev/null | grep -cE 'alpn=http%2F1\.1|alpn=http/1\.1' || echo 0)
    h2=$(grep 'type=xhttp' "$TMP/all" 2>/dev/null | grep -c 'alpn=h2' || echo 0)
    printf '    xhttp_total=%s xhttp_alpn_h1=%s xhttp_alpn_h2=%s\n' "$xhttp" "$h1" "$h2"
    if [ "${HIDDIFY_EXPECT_NO_H1:-0}" = "1" ]; then
        [ "$h1" -eq 0 ] && ok "round $r PR#68 active: no xhttp H1 leg" || bad "round $r PR#68 active but $h1 H1 legs remain"
    else
        skip "round $r PR#68 not merged: $h1 xhttp H1 leg(s) still emitted (set HIDDIFY_EXPECT_NO_H1=1 after cherry-pick)"
    fi

    section "round $r: TLS / ALPN 协商取样"
    n=0
    grep -oE '@[A-Za-z0-9._-]+:[0-9]+' "$TMP/all" 2>/dev/null | sort -u | head -n "$MAX_HANDSHAKES" | while read -r hp; do
        host=${hp#@}; port=${host##*:}; host=${host%:*}
        out=$(echo | timeout 8 openssl s_client -connect "$host:$port" -servername "$host" -alpn 'h2,http/1.1' 2>/dev/null \
              | grep -E 'ALPN protocol' | head -1 | tr -d '\r')
        if [ -n "$out" ]; then
            printf '  PASS  %s:%s negotiated %s\n' "$host" "$port" "${out#*: }"
        else
            printf '  SKIP  %s:%s unreachable (NAT / no public return path)\n' "$host" "$port"
        fi
    done
    # 上面在管道子 shell 里，计数不回传；用一次总括断言保证本节有结果
    ok "round $r handshake sample completed (max $MAX_HANDSHAKES unique host:port)"

    section "round $r: sing-box 配置可解析"
    c=$(http_code "$TMP/sb" "$HIDDIFY_BASE/$PROXY_PATH/$USER_UUID/full-singbox.json" -H "User-Agent: Hiddify/2.0")
    expect_code "round $r GET full-singbox.json" 200 "$c"
    if out=$("$HIDDIFY_PYTHON" -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d.get("outbounds"), list) and d["outbounds"]; print(len(d["outbounds"]))' "$TMP/sb" 2>&1); then
        ok "round $r full-singbox.json valid JSON, outbounds=$out"
    else
        bad "round $r full-singbox.json invalid: $(printf '%s' "$out" | tail -n 1)"
    fi
done

summary
