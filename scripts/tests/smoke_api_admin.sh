#!/usr/bin/env bash
# 在线冒烟：admin REST v2 读接口 + 用户 CRUD + 负例 + apply 生效。
# 用法: bash scripts/tests/smoke_api_admin.sh [轮数]     默认 1 轮
# CRUD 只操作本脚本自己创建、名字以 smoke- 开头的用户，退出时（含失败）一定清理。
# 检测不到运行中的实例会 SKIP 并退出 0。
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib_online.sh"
ROUNDS=${1:-1}
TMP=$HIDDIFY_TMP
CREATED_UUID=""

discover
# PROXY_PATH 由 discover 填充，赋值必须在它之后（set -u 下提前展开会直接退出）
API="$HIDDIFY_BASE/$PROXY_PATH/api/v2/admin"

cleanup_created_user() {
    [ -z "$CREATED_UUID" ] && return 0
    http_code "$TMP/cleanup" "$API/user/$CREATED_UUID/" -X DELETE -H "Authorization: $(admin_auth)" >/dev/null
}
trap cleanup_created_user EXIT

for r in $(seq 1 "$ROUNDS"); do
    section "round $r: 只读 admin REST"
    for e in /me/ /dashboard/ /server_status/ /user/; do
        c=$(http_code "$TMP/api" "$API$e" -H "Authorization: $(admin_auth)")
        expect_code "round $r GET $e" 200 "$c"
    done

    section "round $r: 认证负例"
    c=$(http_code "$TMP/noauth" "$API/me/")
    case "$c" in
        401|403|302|400) ok "round $r anonymous rejected (HTTP $c)" ;;
        *) bad "round $r anonymous (HTTP $c)" ;;
    esac
    c=$(http_code "$TMP/bad" "$API/me/" -H "Authorization: Basic $(printf '00000000-0000-0000-0000-000000000000:' | base64 -w0)")
    expect_not5xx "round $r wrong admin uuid" "$c"
    c=$(http_code "$TMP/missing" "$API/user/00000000-0000-0000-0000-000000000000/" -H "Authorization: $(admin_auth)")
    expect_not5xx "round $r GET missing user" "$c"
    c=$(http_code "$TMP/badbody" "$API/user/" -X POST -H "Authorization: $(admin_auth)" -H 'Content-Type: application/json' -d '{}')
    expect_not5xx "round $r POST without name" "$c"

    section "round $r: 用户 CRUD 往返"
    name="smoke-$$-$r-$(date +%s)"
    c=$(http_code "$TMP/post" "$API/user/" -X POST -H "Authorization: $(admin_auth)" \
        -H 'Content-Type: application/json' -d "{\"name\":\"$name\",\"enable\":false}")
    if [ "$c" = "200" ] || [ "$c" = "201" ]; then
        ok "round $r POST create (HTTP $c)"
        CREATED_UUID=$(json_get "$TMP/post" uuid)
    else
        bad "round $r POST create (HTTP $c): $(head -c 200 "$TMP/post" 2>/dev/null)"
        CREATED_UUID=""
    fi

    if [ -n "$CREATED_UUID" ]; then
        c=$(http_code "$TMP/get" "$API/user/$CREATED_UUID/" -H "Authorization: $(admin_auth)")
        expect_code "round $r GET created user" 200 "$c"
        got=$(json_get "$TMP/get" name 2>/dev/null)
        [ "$got" = "$name" ] && ok "round $r created user name matches" || bad "round $r name mismatch ('$got')"

        c=$(http_code "$TMP/patch" "$API/user/$CREATED_UUID/" -X PATCH -H "Authorization: $(admin_auth)" \
            -H 'Content-Type: application/json' -d '{"comment":"online-smoke"}')
        expect_code "round $r PATCH created user" 200 "$c"
        got=$(json_get "$TMP/patch" comment 2>/dev/null)
        [ "$got" = "online-smoke" ] && ok "round $r PATCH comment applied" || bad "round $r comment not applied ('$got')"

        c=$(http_code "$TMP/list" "$API/user/" -H "Authorization: $(admin_auth)")
        if grep -q "$CREATED_UUID" "$TMP/list" 2>/dev/null; then
            ok "round $r created user appears in list"
        else
            bad "round $r created user missing from list (HTTP $c)"
        fi

        c=$(http_code "$TMP/del" "$API/user/$CREATED_UUID/" -X DELETE -H "Authorization: $(admin_auth)")
        expect_code "round $r DELETE created user" 200 "$c"
        CREATED_UUID=""
        c=$(http_code "$TMP/list2" "$API/user/" -H "Authorization: $(admin_auth)")
        if grep -q "$name" "$TMP/list2" 2>/dev/null; then
            bad "round $r deleted user still in list"
        else
            ok "round $r deleted user gone from list"
        fi
    else
        skip "round $r CRUD follow-up (create failed)"
    fi

    section "round $r: 配置生效"
    if root_run "bash '$HIDDIFY_ROOT/scripts/apply_configs.sh'" >"$TMP/apply" 2>&1; then
        ok "round $r apply_configs.sh exit 0"
    else
        bad "round $r apply_configs.sh failed: $(tail -n 2 "$TMP/apply" | tr '\n' ' ')"
    fi
done

summary
