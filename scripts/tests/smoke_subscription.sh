#!/usr/bin/env bash
# 在线冒烟：全部订阅端点 + Subscription-Userinfo + 节点非空 + 负例不得 5xx。
# 用法: bash scripts/tests/smoke_subscription.sh [轮数]     默认 1 轮
# 检测不到运行中的实例会 SKIP 并退出 0（不会破坏纯离线 CI）。
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib_online.sh"
ROUNDS=${1:-1}
TMP=$HIDDIFY_TMP
UA=${HIDDIFY_UA:-v2rayN/6.31}

discover

ENDPOINTS=(/auto/ /all.txt /clash/all.yml /clash/proxies.yml /full-singbox.json /singbox.json)

for r in $(seq 1 "$ROUNDS"); do
    section "round $r: 订阅端点"
    for e in "${ENDPOINTS[@]}"; do
        url="$HIDDIFY_BASE/$PROXY_PATH/$USER_UUID$e"
        c=$(http_hdr "$TMP/sub" "$url" -H "User-Agent: $UA" -H "Authorization: $(user_auth)")
        size=$(stat -c%s "$TMP/sub" 2>/dev/null || echo 0)
        if [ "$c" = "200" ] && [ "$size" -gt 20 ]; then ok "round $r $e 200 (${size}B)"; else bad "round $r $e (HTTP $c, ${size}B)"; fi
        if grep -qi 'subscription-userinfo' "$TMP/sub.hdr" 2>/dev/null; then
            ok "round $r $e has Subscription-Userinfo"
        else
            bad "round $r $e missing Subscription-Userinfo"
        fi
        body_has "$TMP/sub" 'vless://|trojan://|ss://|proxies:|outbounds' "round $r $e contains nodes"
    done

    section "round $r: 负例（一律不得 5xx / 不得连接失败）"
    c=$(http_code "$TMP/nx" "$HIDDIFY_BASE/$PROXY_PATH/00000000-0000-0000-0000-000000000000/auto/" -H "User-Agent: $UA")
    expect_not5xx "round $r wrong uuid" "$c"

    c=$(http_code "$TMP/long" "$HIDDIFY_BASE/$PROXY_PATH/$(printf 'a%.0s' {1..400})/auto/" -H "User-Agent: $UA")
    expect_not5xx "round $r overlong uuid" "$c"

    c=$(http_code "$TMP/auth" "$HIDDIFY_BASE/$PROXY_PATH/$USER_UUID/auto/" -H "User-Agent: $UA" -H "Authorization: $(user_auth)")
    expect_not5xx "round $r with Authorization header" "$c"

    for weird in 'Python-urllib/3.13' '' 'curl/8.0' 'Mozilla/5.0 (X11; Linux x86_64)'; do
        c=$(http_code "$TMP/ua" "$HIDDIFY_BASE/$PROXY_PATH/$USER_UUID/auto/" -H "User-Agent: $weird")
        expect_not5xx "round $r UA='${weird:-<empty>}'" "$c"
    done

    disabled=$(dbq "select uuid from hiddifypanel.user where enable=0 and deleted=0 limit 1")
    if [ -n "$disabled" ]; then
        c=$(http_code "$TMP/dis" "$HIDDIFY_BASE/$PROXY_PATH/$disabled/auto/" -H "User-Agent: $UA")
        expect_not5xx "round $r disabled user" "$c"
    else
        skip "round $r no disabled user in db"
    fi

    expired=$(dbq "select uuid from hiddifypanel.user where deleted=0 and usage_limit_GB>0 and current_usage_GB>=usage_limit_GB limit 1")
    if [ -n "$expired" ]; then
        c=$(http_code "$TMP/exp" "$HIDDIFY_BASE/$PROXY_PATH/$expired/auto/" -H "User-Agent: $UA")
        expect_not5xx "round $r exhausted user" "$c"
    else
        skip "round $r no exhausted user in db"
    fi
done

summary
