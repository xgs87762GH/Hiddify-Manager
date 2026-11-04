#!/bin/bash
# install.sh 的任务编排场景，全离线。
#
#   W1 WARP 决策表：hconfig warp_mode 为 disable → 传 false（走 disable.sh）；
#      warp / warp_reality / 键缺失 / hconfig 失败 / 大小写不同 → 一律照旧执行（true）。
#      读不到配置就静默关闭 WARP 是不能接受的：那会让"配置还没生成"的机器丢出站。
#   W2 决策 → runsh 的连线：disable 时真的执行 disable.sh，其余执行 install.sh。
#   W3 runsh 参数映射：false / 0 → disable.sh；true / 1 / 空 → install.sh；
#      目标目录没有对应脚本时不得报错。
#   C1 hiddify-core.service 必须带上网关开关
#      ENABLE_DEPRECATED_IMPLICIT_DEFAULT_HTTP_CLIENT=true（sing-box 1.14+ 的逃生阀），
#      且 ExecStart 未被改坏，单元能被 systemd-analyze verify 接受。
#
# install.sh 是顶层自执行脚本（cd /opt/hiddify-manager、main |& tee），不能整体 source，
# 这里按行锚点只截取 runsh 函数块与 WARP 决策片段，其余步骤一律不跑（不会有 apt/systemctl）。
#
# 用法：bash scripts/tests/smoke_install_tasks.sh [轮数]
set -u

ITERATIONS="${1:-1}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL_SH="$REPO/scripts/install.sh"
SERVICE_FILE="$REPO/services/hiddify-core/hiddify-core.service"
WORK=/tmp/hit

pass_count=0
fail_count=0
assert_total=0
failed_iterations=""

log() { echo -e "\033[1;34m==>\033[0m $*"; }
ok() { echo -e "    \033[1;32mPASS\033[0m $*"; assert_total=$((assert_total + 1)); }
bad() { echo -e "    \033[1;31mFAIL\033[0m $*"; fail_count=$((fail_count + 1)); }
skip() { echo -e "    \033[1;33mSKIP\033[0m $*"; }

RUNSH_SRC=""
DECISION_SRC=""

extract_snippets() {
    RUNSH_SRC=$(awk '/^function runsh\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$INSTALL_SH")
    DECISION_SRC=$(awk '/maybe_warp=true/{f=1} f{print} f&&/add_task "WARP"/{exit}' "$INSTALL_SH")
    [ -n "$RUNSH_SRC" ] ||
        { echo "FATAL: 没能从 install.sh 截出 runsh 函数（脚本结构变了？）" >&2; exit 2; }
    [ -n "$DECISION_SRC" ] ||
        { echo "FATAL: 没能从 install.sh 截出 WARP 决策片段" >&2; exit 2; }
    grep -q 'disable.sh' <<<"$RUNSH_SRC" ||
        { echo "FATAL: 截出的 runsh 里没有 disable.sh 映射" >&2; exit 2; }
}

# 用假 hconfig 跑一遍决策片段，返回 add_task 传出去的最后一个参数
decide_warp() { # $1=warp_mode 文本 $2=hconfig 退出码
    local mode="$1" hrc="${2:-0}"
    (
        add_task() { printf '%s\n' "${@: -1}"; }
        install_run() { :; }
        hconfig() { [ -n "$mode" ] && printf '%s\n' "$mode"; return "$hrc"; }
        eval "$DECISION_SRC"
    ) 2>/dev/null
}

# 用截取出来的 runsh 跑一个夹具目录，返回它真正执行的脚本名
runsh_probe() { # $1=服务目录 $2=第三个参数（可能是 false/0/true/空）
    (
        cd "$WORK/fixture" || exit 1
        eval "$RUNSH_SRC"
        runsh install.sh "services/$1" "${2-}"
    ) 2>&1
}

build_fixture() {
    rm -rf "$WORK"
    mkdir -p "$WORK/fixture/services/warp" "$WORK/fixture/services/nodis"
    cat >"$WORK/fixture/services/warp/install.sh" <<'EOF'
#!/bin/bash
echo install >>"$HIT_CALLS"
EOF
    cat >"$WORK/fixture/services/warp/disable.sh" <<'EOF'
#!/bin/bash
echo disable >>"$HIT_CALLS"
EOF
    chmod +x "$WORK/fixture/services/warp/"*.sh
    export HIT_CALLS="$WORK/calls.log"
    : >"$HIT_CALLS"
}

# ---------------------------------------------------------------- 场景 ----------
scenario_w1_warp_decision_table() {
    log "W1: WARP 决策表（只有精确的 disable 才关）"
    local case_name mode rc want got
    for row in "disable|disable|0|false" \
               "warp|warp|0|true" \
               "warp_reality|warp_reality|0|true" \
               "missing||0|true" \
               "hconfig-fails||1|true" \
               "capital-Disable|Disable|0|true" \
               "whitespace| disable |0|true"; do
        IFS='|' read -r case_name mode rc want <<<"$row"
        got=$(decide_warp "$mode" "$rc")
        [ "$got" = "$want" ] && ok "W1 [$case_name] 传给 install_run 的是 $want" ||
            bad "W1 [$case_name] 传的是 '$got'（期望 $want）"
    done
}

scenario_w2_decision_to_runsh() {
    log "W2: 决策值接到 runsh 上 —— disable 时真的跑 disable.sh"
    local v out
    v=$(decide_warp disable 0)
    : >"$HIT_CALLS"
    out=$(runsh_probe warp "$v")
    [ "$v" = "false" ] && ok "W2 disable 的决策值是 false" || bad "W2 disable 决策值是 '$v'"
    grep -qx "disable" "$HIT_CALLS" 2>/dev/null && ok "W2 disable.sh 被执行" ||
        bad "W2 disable.sh 没被执行（calls: $(tr '\n' ' ' <"$HIT_CALLS")）"
    grep -qx "install" "$HIT_CALLS" 2>/dev/null &&
        bad "W2 WARP 关闭时仍跑了 install.sh" || ok "W2 WARP 关闭时没跑 install.sh"
    grep -q "=== disable.sh services/warp" <<<"$out" &&
        ok "W2 日志里写明了改跑 disable.sh" || bad "W2 日志没体现改跑 disable.sh"

    v=$(decide_warp warp 0)
    : >"$HIT_CALLS"
    runsh_probe warp "$v" >/dev/null 2>&1
    grep -qx "install" "$HIT_CALLS" 2>/dev/null && ok "W2 warp 开启时跑 install.sh" ||
        bad "W2 warp 开启时没跑 install.sh"
}

scenario_w3_runsh_mapping() {
    log "W3: runsh 参数映射（false/0 → disable.sh，其余 → install.sh）"
    local arg out rc
    for arg in false 0; do
        : >"$HIT_CALLS"
        runsh_probe warp "$arg" >/dev/null 2>&1
        grep -qx "disable" "$HIT_CALLS" 2>/dev/null && ok "W3 参数 '$arg' → disable.sh" ||
            bad "W3 参数 '$arg' 没有走 disable.sh"
    done
    for arg in true 1 ""; do
        : >"$HIT_CALLS"
        runsh_probe warp "$arg" >/dev/null 2>&1
        grep -qx "install" "$HIT_CALLS" 2>/dev/null && ok "W3 参数 '${arg:-空}' → install.sh" ||
            bad "W3 参数 '${arg:-空}' 没有走 install.sh"
    done

    # 目标目录里没有 disable.sh 时必须安静跳过（不能因为缺文件就报错中断安装）
    out=$(runsh_probe nodis false); rc=$?
    [ "$rc" = "0" ] && ok "W3 缺 disable.sh 时 runsh 返回 0" || bad "W3 缺 disable.sh 时返回 $rc"
    [ -z "$out" ] && ok "W3 缺脚本时安静跳过（不中断安装）" ||
        bad "W3 缺脚本时输出异常：$(tr '\n' ' ' <<<"$out")"
}

scenario_c1_core_service_env() {
    log "C1: hiddify-core.service 的兼容开关与单元合法性"
    grep -qx 'Environment=ENABLE_DEPRECATED_IMPLICIT_DEFAULT_HTTP_CLIENT=true' "$SERVICE_FILE" &&
        ok "C1 单元里带了 ENABLE_DEPRECATED_IMPLICIT_DEFAULT_HTTP_CLIENT=true" ||
        bad "C1 单元里缺少兼容开关"
    grep -q '^ExecStart=/opt/hiddify-manager/services/hiddify-core/hiddify-core srun -c' "$SERVICE_FILE" &&
        ok "C1 ExecStart 未被改坏" || bad "C1 ExecStart 被改坏了"

    # 开关必须在 [Service] 段里，放到 [Unit] 段 systemd 会直接忽略
    local section
    section=$(awk '/^\[/{s=$0} /^Environment=ENABLE_DEPRECATED/{print s; exit}' "$SERVICE_FILE")
    [ "$section" = "[Service]" ] && ok "C1 开关位于 [Service] 段" ||
        bad "C1 开关不在 [Service] 段（当前段：${section:-空}）"

    if command -v systemd-analyze >/dev/null 2>&1; then
        local out rc
        out=$(systemd-analyze verify "$SERVICE_FILE" 2>&1); rc=$?
        if [ "$rc" = "0" ]; then
            ok "C1 systemd-analyze verify 通过"
        else
            echo "$out" | sed 's/^/    | /'
            bad "C1 systemd-analyze verify 失败（rc=$rc）"
        fi
    else
        skip "C1 没有 systemd-analyze，跳过单元校验"
    fi
}

# -------------------------------------------------------------------- driver ---
run_once() {
    local i="$1"
    echo
    echo "================ iteration $i ================"
    extract_snippets
    build_fixture
    local before=$fail_count
    scenario_w1_warp_decision_table
    scenario_w2_decision_to_runsh
    scenario_w3_runsh_mapping
    scenario_c1_core_service_env
    if [ "$fail_count" = "$before" ]; then
        pass_count=$((pass_count + 1))
    else
        failed_iterations="$failed_iterations $i"
    fi
}

start_ts=$(date +%s)
for i in $(seq 1 "$ITERATIONS"); do
    run_once "$i"
done
end_ts=$(date +%s)

echo
echo "================ summary ================"
echo "iterations: $ITERATIONS   all-green: $pass_count   failed: $fail_count   assertions: $assert_total   elapsed: $((end_ts - start_ts))s"
[ -n "$failed_iterations" ] && echo "failed iterations:$failed_iterations"
[ "$fail_count" -eq 0 ] || exit 1
exit 0
