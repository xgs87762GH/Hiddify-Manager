#!/bin/bash
# restart.sh / status.sh 的行为场景，全离线。
#
#   R1  安装/更新/应用配置进行中（hiddify-install 等单元 active）→ 拒绝重启：
#       真实退出码必须是 12（不是被 tee 吞掉的 0），且结束标记仍要写出来，
#       否则面板只能靠"日志安静 6 秒"猜结束。
#   R1b 同上并发两次：都不许动任何服务。
#   R2  没有进行中任务 + warp_mode=disable → 只对 hiddify-panel 走 systemd-run 延迟重启
#       （不能直接 systemctl restart，否则脚本自己所在的 cgroup 被杀、日志截断），
#       wg-quick@warp 必须跳过，日志末行必须是结束标记；重复执行后日志里只有一条标记。
#   R3  找不到可用的 systemd-run → 回退直连 restart hiddify-panel，仍要 rc=0 且写标记。
#   R4  warp_mode=warp → wg-quick@warp 必须参与重启。
#   R5  安装目录路径含空格 → 照常工作（脚本里所有路径都要能带空格）。
#   S1  status.sh 末行必须是结束标记，且被"取日志尾部 4096 字节找 Finished!"的判据命中。
#   S2  warp_mode 决定是否调用 services/warp/status.sh（关闭时不做 WARP 状态探测）。
#
# 手法同 smoke_lifecycle_matrix.sh：把脚本里写死的 /opt/hiddify-manager 泛化成
# ${HIDDIFY_DIR:-/opt/hiddify-manager}，拷进 /tmp 夹具后执行；systemctl / systemd-run /
# curl / sleep 全部用 PATH 里的桩替换，绝不碰真机上的服务。
#
# 用法：bash scripts/tests/smoke_restart_status.sh [轮数]
set -u

ITERATIONS="${1:-1}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=/tmp/hrs
BIN="$WORK/bin"
BASE="$WORK/base"
MARK="---------------------Finished!------------------------"

pass_count=0
fail_count=0
assert_total=0
failed_iterations=""

log() { echo -e "\033[1;34m==>\033[0m $*"; }
ok() { echo -e "    \033[1;32mPASS\033[0m $*"; assert_total=$((assert_total + 1)); }
bad() { echo -e "    \033[1;31mFAIL\033[0m $*"; fail_count=$((fail_count + 1)); }
skip() { echo -e "    \033[1;33mSKIP\033[0m $*"; }

# ---------------------------------------------------------------- 夹具 ----------
# 把写死的安装目录泛化成可覆盖形式，其余逻辑原样保留。
generalize() { # $1=源文件 $2=目标文件
    sed -e 's#^cd /opt/hiddify-manager$#cd "${HIDDIFY_DIR:-/opt/hiddify-manager}"#' \
        -e 's#^source /opt/hiddify-manager/scripts/common/utils.sh$#source "${HIDDIFY_DIR:-/opt/hiddify-manager}/scripts/common/utils.sh"#' \
        -e 's#/opt/hiddify-manager/data/log/#"${HIDDIFY_DIR:-/opt/hiddify-manager}/data/log/"#g' \
        -e 's#^PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin$#PATH="${HRS_BIN:+$HRS_BIN:}/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin"#' \
        "$1" >"$2"
}

build_stubs() {
    rm -rf "$BIN"
    mkdir -p "$BIN"

    # 记录每一次调用的假 systemctl
    cat >"$BIN/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >>"${HRS_CALLS:?}"
case "$1" in
    is-enabled) exit 0 ;;
    is-active)
        unit="${@: -1}"
        [ -f "${HRS_STATE:?}/$unit.active" ] && exit 0
        exit 3
        ;;
esac
exit 0
EOF

    # 假 systemd-run：HRS_SYSRUN_FAIL=1 时模拟"没有可用的 systemd-run"
    cat >"$BIN/systemd-run" <<'EOF'
#!/bin/bash
echo "systemd-run $*" >>"${HRS_CALLS:?}"
[ "${HRS_SYSRUN_FAIL:-0}" = "1" ] && exit 1
exit 0
EOF

    printf '#!/bin/bash\nexit 0\n' >"$BIN/sleep"   # 去掉重试等待，保持离线快速
    printf '#!/bin/bash\nexit 0\n' >"$BIN/curl"    # 不让 status.sh 真去探测外网
    chmod +x "$BIN"/*
}

build_base() {
    rm -rf "$BASE"
    mkdir -p "$BASE/scripts/common" "$BASE/services/warp" "$BASE/data/log" "$BASE/.fixture"
    generalize "$REPO/scripts/restart.sh" "$BASE/scripts/restart.sh"
    generalize "$REPO/scripts/status.sh" "$BASE/scripts/status.sh"

    cat >"$BASE/scripts/common/utils.sh" <<'EOF'
export DOCKER_MODE=false
hiddify_service_units() { echo hiddify-core hiddify-haproxy hiddify-panel hiddify-cli wg-quick@warp; }
get_pretty_service_status() { echo active; }
hconfig() {
    local f="${HIDDIFY_DIR:-/opt/hiddify-manager}/.fixture/$1"
    [ -f "$f" ] && cat "$f"
    return 0
}
error() { echo "ERROR: $*"; }
warning() { echo "WARN: $*"; }
log_file() { echo "${HIDDIFY_DIR:-/opt/hiddify-manager}/data/log/$1.log"; }
EOF

    cat >"$BASE/services/warp/status.sh" <<'EOF'
#!/bin/bash
echo "FAKE WARP STATUS"
echo "warp-status-called" >>"${HRS_CALLS:?}"
EOF
    chmod +x "$BASE/services/warp/status.sh"

    # 泛化结果自检：万一脚本换写法导致 sed 没命中，宁可当场炸掉也不要回落到线上目录
    grep -q 'HIDDIFY_DIR:-/opt/hiddify-manager}' "$BASE/scripts/restart.sh" ||
        { echo "FATAL: restart.sh 未被泛化（cd 行没命中）" >&2; exit 2; }
    grep -q 'HIDDIFY_DIR:-/opt/hiddify-manager}' "$BASE/scripts/status.sh" ||
        { echo "FATAL: status.sh 未被泛化（cd 行没命中）" >&2; exit 2; }
    # restart.sh 第 2 行会把 PATH 整个重写；不把它泛化掉，PATH 里的桩就形同虚设，
    # 场景会直接调用真机的 systemctl / systemd-run（实测会重启线上服务）。
    grep -q 'HRS_BIN' "$BASE/scripts/restart.sh" ||
        { echo "FATAL: restart.sh 的 PATH 行未被泛化（桩会被真机命令盖过）" >&2; exit 2; }
}

# 预检：确认 systemctl/systemd-run 的桩真的被脚本调用到，否则宁可中止也不打真机。
preflight() {
    local probe="$WORK/probe" calls="$WORK/probe.calls" state="$WORK/probe.state"
    rm -rf "$probe" "$state"; mkdir -p "$state"
    cp -a "$BASE" "$probe"
    echo disable >"$probe/.fixture/warp_mode"
    : >"$calls"
    env HRS_BIN="$BIN" HIDDIFY_DIR="$probe" HRS_CALLS="$calls" HRS_STATE="$state" \
        PATH="$BIN:$PATH" bash "$probe/scripts/restart.sh" >/dev/null 2>&1
    grep -q "systemctl is-enabled" "$calls" ||
        { echo "FATAL: 桩未被调用，可能已打到真机 systemd，立即中止" >&2; exit 2; }
}

# 每个场景一份独立副本，互不干扰
mkroot() { # $1=场景名
    ROOT="$WORK/root-$1"
    rm -rf "$ROOT"
    cp -a "$BASE" "$ROOT"
    CALLS="$WORK/calls-$1.log"
    STATE="$WORK/state-$1"
    : >"$CALLS"
    rm -rf "$STATE"
    mkdir -p "$STATE"
}

set_warp() { echo "$1" >"$ROOT/.fixture/warp_mode"; }
busy() { : >"$STATE/$1.active"; }
idle() { rm -f "$STATE/$1.active"; }
calls() { cat "$CALLS" 2>/dev/null; }
log_tail() { tail -c 4096 "$ROOT/data/log/$1.log" 2>/dev/null; }

run_script() { # $1=脚本名 其余=额外环境变量（KEY=VAL）
    local name="$1"; shift
    local out rc
    out=$(env "$@" HIDDIFY_DIR="$ROOT" HRS_CALLS="$CALLS" HRS_STATE="$STATE" HRS_BIN="$BIN" \
        PATH="$BIN:$PATH" bash "$ROOT/scripts/$name" 2>&1)
    rc=$?
    echo "$out"
    return $rc
}

# ---------------------------------------------------------------- 场景 ----------
scenario_r1_guard_refuses() {
    log "R1: 安装进行中 → restart.sh 必须拒绝（真实退出码 12 + 仍写结束标记）"
    mkroot r1
    set_warp disable
    busy hiddify-install
    local out rc
    out=$(run_script restart.sh); rc=$?
    echo "$out" | sed 's/^/    | /'

    [ "$rc" = "12" ] && ok "R1 真实退出码是 12（没有被 tee 吞成 0）" ||
        bad "R1 退出码是 $rc（期望 12：管道退出码必须取 main 的）"
    echo "$out" | grep -q "hiddify-install" && ok "R1 提示里点名了进行中的单元" ||
        bad "R1 没有指出是哪个单元在进行中"
    grep -qxF -- "$MARK" "$ROOT/data/log/restart.log" 2>/dev/null &&
        ok "R1 拒绝分支也写了结束标记" || bad "R1 日志里没有结束标记（面板会一直等）"
    grep -qE "^systemctl (restart|start|stop) " "$CALLS" &&
        bad "R1 拒绝时仍调用了服务操作：$(calls | tr '\n' ';')" ||
        ok "R1 拒绝时没有碰任何服务"
    idle hiddify-install
}

scenario_r1b_guard_concurrent() {
    log "R1b: 并发两次拒绝 → 都不许动服务"
    mkroot r1b
    set_warp disable
    busy hiddify-update
    local rc1 rc2
    run_script restart.sh >"$WORK/r1b-1.out" 2>&1; rc1=$?
    run_script restart.sh >"$WORK/r1b-2.out" 2>&1; rc2=$?
    [ "$rc1" = "12" ] && [ "$rc2" = "12" ] && ok "R1b 两次都返回 12" ||
        bad "R1b 两次返回 $rc1 / $rc2（期望 12/12）"
    grep -qE "^systemctl (restart|start) " "$CALLS" &&
        bad "R1b 拒绝时仍调用了服务操作" || ok "R1b 未触碰服务"
    [ "$(grep -cxF -- "$MARK" "$ROOT/data/log/restart.log" 2>/dev/null)" = "1" ] &&
        ok "R1b 每次运行重写日志、标记只有一条" || bad "R1b 日志标记数量异常"
    idle hiddify-update
}

scenario_r2_delayed_panel_restart() {
    log "R2: 无进行中任务 + warp 关闭 → 面板延迟重启、跳过 wg-quick@warp、写结束标记"
    mkroot r2
    set_warp disable
    local out rc
    out=$(run_script restart.sh); rc=$?
    echo "$out" | sed 's/^/    | /'

    [ "$rc" = "0" ] && ok "R2 正常退出 0" || bad "R2 退出码 $rc"
    grep -q "systemctl is-enabled" "$CALLS" &&
        ok "R2 走的是桩（没有打真机 systemd）" || bad "R2 没有走桩，结果不可信"
    grep -q "systemd-run .*--unit=hiddify-panel-restart" "$CALLS" &&
        ok "R2 面板重启交给 systemd-run 延迟执行（不杀自己）" ||
        bad "R2 没有走 systemd-run 延迟重启"
    grep -q "^systemctl restart hiddify-panel" "$CALLS" &&
        bad "R2 直接 restart hiddify-panel（会切断自身日志）" ||
        ok "R2 没有直接重启面板"
    grep -q "^systemctl restart wg-quick@warp" "$CALLS" &&
        bad "R2 warp 关闭却重启了 wg-quick@warp" || ok "R2 warp 关闭时跳过 wg-quick@warp"
    [ "$(log_tail restart | tail -n 1)" = "$MARK" ] &&
        ok "R2 日志末行是结束标记" || bad "R2 日志末行不是结束标记"
    grep -q "scheduled(+1s)" <<<"$out" && ok "R2 输出里写明了延迟重启" ||
        bad "R2 输出没体现面板是延迟重启的"

    # 重复执行：日志被重写而不是追加，标记依然只有一条
    run_script restart.sh >/dev/null 2>&1
    [ "$(grep -cxF -- "$MARK" "$ROOT/data/log/restart.log" 2>/dev/null)" = "1" ] &&
        ok "R2 重复执行后日志里仍只有一条结束标记" || bad "R2 重复执行后标记数量异常"
}

scenario_r3_systemd_run_missing() {
    log "R3: systemd-run 不可用 → 回退直连重启面板"
    mkroot r3
    set_warp disable
    local out rc
    out=$(run_script restart.sh HRS_SYSRUN_FAIL=1); rc=$?
    echo "$out" | sed 's/^/    | /'
    [ "$rc" = "0" ] && ok "R3 回退分支退出 0" || bad "R3 回退分支退出 $rc"
    grep -q "^systemctl restart hiddify-panel" "$CALLS" &&
        ok "R3 回退时直接重启面板" || bad "R3 回退时没有重启面板"
    [ "$(log_tail restart | tail -n 1)" = "$MARK" ] &&
        ok "R3 回退分支日志末行是结束标记" || bad "R3 回退分支没有结束标记"
}

scenario_r4_warp_enabled() {
    log "R4: warp_mode=warp → wg-quick@warp 参与重启"
    mkroot r4
    set_warp warp
    local rc
    run_script restart.sh >/dev/null 2>&1; rc=$?
    [ "$rc" = "0" ] && ok "R4 退出 0" || bad "R4 退出码 $rc"
    grep -q "^systemctl restart wg-quick@warp" "$CALLS" &&
        ok "R4 warp 开启时重启 wg-quick@warp" || bad "R4 warp 开启却跳过了 wg-quick@warp"
}

scenario_r5_path_with_space() {
    log "R5: 安装目录含空格 → 照常工作"
    mkroot r5
    local spaced="$WORK/root with space" out rc
    rm -rf "$spaced"; cp -a "$BASE" "$spaced"
    echo disable >"$spaced/.fixture/warp_mode"
    out=$(env HIDDIFY_DIR="$spaced" HRS_CALLS="$CALLS" HRS_STATE="$STATE" HRS_BIN="$BIN" PATH="$BIN:$PATH" \
        bash "$spaced/scripts/restart.sh" 2>&1); rc=$?
    if [ "$rc" = "0" ]; then
        ok "R5 含空格路径退出 0"
    else
        echo "$out" | sed 's/^/    | /'; bad "R5 含空格路径退出 $rc"
    fi
    [ "$(tail -n 1 "$spaced/data/log/restart.log" 2>/dev/null)" = "$MARK" ] &&
        ok "R5 含空格路径也写出了结束标记" || bad "R5 含空格路径没有结束标记"
}

scenario_s1_status_marker() {
    log "S1: status.sh 末行必须是结束标记（面板靠尾部 4096 字节判定）"
    mkroot s1
    set_warp disable
    local out rc
    out=$(run_script status.sh); rc=$?
    echo "$out" | sed 's/^/    | /'
    [ "$rc" = "0" ] && ok "S1 status.sh 退出 0" || bad "S1 status.sh 退出 $rc"
    [ "$(log_tail status | tail -n 1)" = "$MARK" ] &&
        ok "S1 日志末行是结束标记" || bad "S1 日志末行不是结束标记"
    log_tail status | grep -q "Finished!" &&
        ok "S1 尾部 4096 字节内能命中 Finished!" || bad "S1 尾部 4096 字节内没有 Finished!"
    # 标记必须真的在最后：其后再无输出（面板判据是"尾部出现"，这里更严）
    [ "$(log_tail status | grep -n 'Finished!' | tail -n 1 | cut -d: -f1)" = \
        "$(log_tail status | wc -l)" ] &&
        ok "S1 结束标记是最后一行内容" || bad "S1 结束标记之后还有输出"
}

scenario_s2_status_warp_probe() {
    log "S2: warp_mode 决定 status.sh 是否做 WARP 探测"
    mkroot s2
    set_warp disable
    local out rc
    out=$(run_script status.sh); rc=$?
    [ "$rc" = "0" ] && ok "S2 warp 关闭时退出 0" || bad "S2 warp 关闭时退出 $rc"
    echo "$out" | grep -q "FAKE WARP STATUS" &&
        bad "S2 warp 关闭仍调用了 services/warp/status.sh" ||
        ok "S2 warp 关闭时不探测 WARP"

    set_warp warp
    : >"$CALLS"
    out=$(run_script status.sh); rc=$?
    [ "$rc" = "0" ] && ok "S2 warp 开启时退出 0" || bad "S2 warp 开启时退出 $rc"
    grep -q "warp-status-called" "$CALLS" &&
        ok "S2 warp 开启时才调用 services/warp/status.sh" || bad "S2 warp 开启却没有探测 WARP"
    [ "$(log_tail status | tail -n 1)" = "$MARK" ] &&
        ok "S2 warp 开启时日志末行仍是结束标记" || bad "S2 warp 开启时标记丢失"
}

# -------------------------------------------------------------------- driver ---
run_once() {
    local i="$1"
    echo
    echo "================ iteration $i ================"
    build_stubs
    build_base
    preflight
    local before=$fail_count
    scenario_r1_guard_refuses
    scenario_r1b_guard_concurrent
    scenario_r2_delayed_panel_restart
    scenario_r3_systemd_run_missing
    scenario_r4_warp_enabled
    scenario_r5_path_with_space
    scenario_s1_status_marker
    scenario_s2_status_warp_probe
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
