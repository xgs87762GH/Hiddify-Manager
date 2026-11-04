#!/bin/bash
# 生命周期命令 × 起始状态的全矩阵，全离线。
#
#   L1 version 升级 / L2 降级 / L3 同版本重复 / L4 来回切换 3 次
#      → 每次 HEAD 必须落在目标 tag，data/、generated/、.venv313 全程完好，
#        install.sh 每次都真跑过，git clean 不得删掉 data/
#   L5 version 异常输入：不存在的 tag / 不带 v 前缀 / 不带参数 → 必须报错且不动工作树
#   L6 reinstall：不拉新代码（远端已经前进也不跟）+ install.sh 被执行
#   L7 update 构建失败（server-update.md 坑 1）：代码已前进、面板却没重装
#      → 这种"半升级"必须能被识别出来，而不是悄悄当作成功
#   L8 update 时组件文件被改脏（坑 2）：ff-only 必须被挡住/报错，
#      且本地改动不能被静默回滚
#
# 每个场景都从夹具全新克隆一个目录，场景之间不共享工作树。
#
# 用法：bash scripts/tests/smoke_lifecycle_matrix.sh [轮数]
set -u

ITERATIONS="${1:-10}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=/tmp/hlm
ORIGIN="$WORK/manager.git"
PANEL_ORIGIN="$WORK/panel.git"
UF_ORIGIN="$WORK/userfront.git"
BRANCH=dev-custom
MGR="$WORK/manager"        # 夹具的工作树：用来给"远端"制造新提交

pass_count=0
fail_count=0
assert_total=0
failed_iterations=""

log() { echo -e "\033[1;34m==>\033[0m $*"; }
ok() { echo -e "    \033[1;32mPASS\033[0m $*"; assert_total=$((assert_total + 1)); }
bad() { echo -e "    \033[1;31mFAIL\033[0m $*"; fail_count=$((fail_count + 1)); }
skip() { echo -e "    \033[1;33mSKIP\033[0m $*"; }

prepare_env() {
    rm -rf "$WORK"
    mkdir -p "$WORK"
    git config --global protocol.file.allow always
    git config --global init.defaultBranch dev-custom
    git config --global user.email smoke@t
    git config --global user.name smoke
}

# ------------------------------------------------------------------ 夹具 -------
build_panel_fixture() {
    git init -q --bare "$UF_ORIGIN"
    local uf="$WORK/userfront"
    git init -q "$uf"
    echo "userfront v1" > "$uf/VERSION"
    git -C "$uf" add -A
    git -C "$uf" commit -qm "userfront v1"
    git -C "$uf" push -q "$UF_ORIGIN" HEAD:refs/heads/dev-custom
    git -C "$UF_ORIGIN" symbolic-ref HEAD refs/heads/dev-custom

    git init -q --bare "$PANEL_ORIGIN"
    local p="$WORK/panel"
    git init -q "$p"
    # 坑 2 的主角：构建会重写这个被跟踪的文件
    mkdir -p "$p/hiddifypanel/admin_v2"
    echo "panel v1" > "$p/VERSION"
    echo "export default {}" > "$p/hiddifypanel/admin_v2/components.d.ts"
    git -C "$p" add -A
    git -C "$p" commit -qm "panel v1"
    git -C "$p" submodule add -q "$UF_ORIGIN" hiddifypanel/user_front
    git -C "$p" commit -qm "panel: add user_front submodule"
    git -C "$p" push -q "$PANEL_ORIGIN" HEAD:refs/heads/dev-custom
    git -C "$PANEL_ORIGIN" symbolic-ref HEAD refs/heads/dev-custom
}

# update.sh 把工作目录写死成 /opt/hiddify-manager（所以它只能在那儿跑）。
# 本套件要在临时目录里跑它，只把这两行路径改成可覆盖的形式，其余逻辑原样保留。
generalize_update_sh() { # $1 = 输出文件
    sed -e 's#^cd /opt/hiddify-manager$#cd "${HIDDIFY_DIR:-/opt/hiddify-manager}"#' \
        -e 's#^source /opt/hiddify-manager/scripts/common/utils.sh$#source "${HIDDIFY_DIR:-/opt/hiddify-manager}/scripts/common/utils.sh"#' \
        "$REPO/scripts/update.sh" > "$1"
}

# utils.sh 第 1 行无条件 export HIDDIFY_DIR=/opt/hiddify-manager，会把我们传进去的
# 值覆盖掉；这里改成"没传才用默认值"，让 update.sh 能在临时目录里跑。
generalize_utils_sh() { # $1 = 输出文件
    awk 'NR==1 { print ": \"${HIDDIFY_DIR:=/opt/hiddify-manager}\""; print "export HIDDIFY_DIR"; next } { print }' \
        "$REPO/scripts/common/utils.sh" > "$1"
}

build_manager_fixture() {
    git init -q --bare "$ORIGIN"
    git init -q "$MGR"
    mkdir -p "$MGR/scripts/common" "$MGR/services/panel"
    cp "$REPO/scripts/onekey.sh" "$MGR/scripts/onekey.sh"
    generalize_utils_sh "$MGR/scripts/common/utils.sh"
    generalize_update_sh "$MGR/scripts/update.sh"
    cat > "$MGR/scripts/install.sh" <<'EOF'
#!/bin/bash
echo "FAKE INSTALL"
mkdir -p "$(dirname "$0")/../generated"
echo "install" >> "$(dirname "$0")/../generated/install-log"
echo installed > "$(dirname "$0")/../install-was-run"
EOF
    cat > "$MGR/services/panel/backup.sh" <<'EOF'
#!/bin/bash
echo "FAKE BACKUP"
EOF
    chmod +x "$MGR/scripts/install.sh" "$MGR/services/panel/backup.sh"
    printf 'build:\n\t@echo "FAKE BUILD"\n' > "$MGR/Makefile"
    build_panel_fixture
    git -C "$MGR" submodule add -q "$PANEL_ORIGIN" services/panel/src

    echo "manager v1" > "$MGR/VERSION"
    git -C "$MGR" add -A
    git -C "$MGR" commit -qm "v-smoke-1"
    git -C "$MGR" tag v-smoke-1
    git -C "$MGR" push -q "$ORIGIN" HEAD:refs/heads/dev-custom
    git -C "$MGR" push -q "$ORIGIN" v-smoke-1

    echo "manager v2" > "$MGR/VERSION"
    git -C "$MGR" add -A
    git -C "$MGR" commit -qm "v-smoke-2"
    git -C "$MGR" tag v-smoke-2
    git -C "$MGR" push -q "$ORIGIN" HEAD:refs/heads/dev-custom
    git -C "$MGR" push -q "$ORIGIN" v-smoke-2

    V1=$(git -C "$MGR" rev-parse v-smoke-1)
    V2=$(git -C "$MGR" rev-parse v-smoke-2)
}

# ------------------------------------------------------------------ 帮助 -------
# 全新克隆：$1=场景名 $2=起始 tag（留空 = 停在分支 tip）
fresh_clone() {
    ROOT="$WORK/root-$1"
    rm -rf "$ROOT"
    git clone -q -b "$BRANCH" "$ORIGIN" "$ROOT"
    if [ -n "${2:-}" ]; then
        git -C "$ROOT" checkout -q "$2"
    fi
    git -C "$ROOT" submodule update --init --recursive -q 2>/dev/null
}

seed_data() {
    mkdir -p "$ROOT/data" "$ROOT/generated" "$ROOT/.venv313"
    echo "precious" > "$ROOT/data/keep.txt"
    echo "generated" > "$ROOT/generated/marker"
    echo "venv" > "$ROOT/.venv313/marker"
}

assert_data_intact() {
    [ -f "$ROOT/data/keep.txt" ] && [ "$(cat "$ROOT/data/keep.txt")" = "precious" ] &&
        ok "$1 data/ 完好" || bad "$1 data/ 被破坏了"
    [ -f "$ROOT/generated/marker" ] && ok "$1 generated/ 完好" || bad "$1 generated/ 被破坏了"
    [ -f "$ROOT/.venv313/marker" ] && ok "$1 虚拟环境还在" || bad "$1 虚拟环境被删了"
}

assert_head() { # $1=期望 commit $2=场景名 $3=说明
    local got
    got=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)
    [ "$got" = "$1" ] && ok "$2 $3" || bad "$2 $3（got=${got:-空} want=$1）"
}

# HIDDIFY_DIR 必须一起导出：onekey.sh 调到 update.sh / install.sh 时是另起进程，
# 子脚本里的 `cd "${HIDDIFY_DIR:-/opt/hiddify-manager}"` 在没导出时会回落到真实安装目录，
# 于是"离线"场景会打到线上 /opt/hiddify-manager。这里除了导出，还在执行前做一次断言。
assert_sandbox() {
    case "$ROOT" in
        "$WORK"/*) ;;
        *) echo "FATAL: 拒绝在 $ROOT 上执行（必须位于 $WORK 之下）" >&2; exit 2 ;;
    esac
    [ "$ROOT" != "/opt/hiddify-manager" ] ||
        { echo "FATAL: 夹具目录等于线上目录，拒绝执行" >&2; exit 2; }
}

run_version() {
    assert_sandbox
    HIDDIFY_DIR="$ROOT" bash "$REPO/scripts/onekey.sh" version "$1" --dir "$ROOT" -y 2>&1
}
run_onekey() {
    assert_sandbox
    HIDDIFY_DIR="$ROOT" bash "$REPO/scripts/onekey.sh" "$@" --dir "$ROOT" -y 2>&1
}
install_count() { grep -c . "$ROOT/generated/install-log" 2>/dev/null || echo 0; }

# ------------------------------------------------------------------ L1.L4 -----
scenario_l1_upgrade() {
    log "L1: 老用户升级 v-smoke-1 → v-smoke-2"
    fresh_clone l1 v-smoke-1
    seed_data
    local out
    out=$(run_version v-smoke-2)
    echo "$out" | sed 's/^/    | /'
    assert_head "$V2" "L1" "HEAD 落在 v-smoke-2"
    assert_data_intact "L1"
    [ "$(install_count)" = "1" ] && ok "L1 install.sh 跑过 1 次" ||
        bad "L1 install.sh 跑了 $(install_count) 次"
    [ ! -f "$ROOT/install-was-run" ] && bad "L1 没有 install 痕迹" || ok "L1 有 install 痕迹"
}

scenario_l2_downgrade() {
    log "L2: 降级 v-smoke-2 → v-smoke-1（代码换、数据留）"
    fresh_clone l2 v-smoke-2
    seed_data
    local out
    out=$(run_version v-smoke-1)
    echo "$out" | sed 's/^/    | /'
    assert_head "$V1" "L2" "HEAD 落在 v-smoke-1"
    assert_data_intact "L2"
    echo "$out" | grep -q "数据库迁移不可逆" && ok "L2 提示了数据库迁移不可逆" ||
        bad "L2 没提示数据库不可逆"
}

scenario_l3_same_version_again() {
    log "L3: 同版本重复切换 v-smoke-2 → v-smoke-2"
    fresh_clone l3 v-smoke-2
    seed_data
    local out
    out=$(run_version v-smoke-2)
    echo "$out" | sed 's/^/    | /'
    assert_head "$V2" "L3" "HEAD 仍在 v-smoke-2"
    assert_data_intact "L3"
    [ "$(install_count)" = "1" ] && ok "L3 仍然跑了一次 install.sh" ||
        bad "L3 install.sh 跑了 $(install_count) 次"
}

scenario_l4_back_and_forth() {
    log "L4: 反复来回切换 3 次（v1 ↔ v2）"
    fresh_clone l4 v-smoke-1
    seed_data
    local i out want
    for i in 1 2 3; do
        if [ "$((i % 2))" = "1" ]; then want="$V2"; out=$(run_version v-smoke-2)
        else want="$V1"; out=$(run_version v-smoke-1); fi
        echo "$out" | sed 's/^/    | /'
        assert_head "$want" "L4" "第 $i 次切换到位"
        assert_data_intact "L4"
    done
    [ "$(install_count)" = "3" ] && ok "L4 三次都跑了 install.sh" ||
        bad "L4 install.sh 只跑了 $(install_count) 次"
    # 反复切换不应在仓库里堆垃圾（data/、generated/、.venv313 除外）
    local junk
    junk=$(git -C "$ROOT" status --porcelain 2>/dev/null |
        grep -v -e 'data/' -e 'generated/' -e '.venv313' -e 'install-was-run' | head -n 3)
    [ -z "$junk" ] && ok "L4 切换后没有残留垃圾改动" || bad "L4 残留改动：$junk"
}

# -------------------------------------------------------------------- L5 ------
scenario_l5_bad_input() {
    log "L5: version 的异常输入 → 必须报错且不动工作树"
    fresh_clone l5 v-smoke-1
    seed_data
    local out rc before
    before=$(git -C "$ROOT" rev-parse HEAD)

    out=$(run_version v-smoke-999); rc=$?
    echo "$out" | sed 's/^/    | /'
    [ "$rc" != "0" ] && ok "L5 不存在的 tag 以非 0 退出" || bad "L5 不存在的 tag 竟然成功了"
    echo "$out" | grep -q "找不到 tag" && ok "L5 提示找不到 tag" || bad "L5 没提示找不到 tag"

    out=$(run_version 14.2.4); rc=$?
    echo "$out" | sed 's/^/    | /'
    [ "$rc" != "0" ] && ok "L5 不带 v 前缀以非 0 退出" || bad "L5 不带 v 前缀竟然成功了"
    echo "$out" | grep -q "必须以 v 开头" && ok "L5 提示必须以 v 开头" || bad "L5 没提示 v 前缀"

    out=$(bash "$REPO/scripts/onekey.sh" version --dir "$ROOT" -y 2>&1); rc=$?
    echo "$out" | sed 's/^/    | /'
    [ "$rc" != "0" ] && ok "L5 不带版本号以非 0 退出" || bad "L5 不带版本号竟然成功了"
    echo "$out" | grep -q "用法" && ok "L5 给出了用法提示" || bad "L5 没给用法提示"

    [ "$(git -C "$ROOT" rev-parse HEAD)" = "$before" ] && ok "L5 工作树始终没被改动" ||
        bad "L5 HEAD 被动了"
    assert_data_intact "L5"
}

# -------------------------------------------------------------------- L6 ------
scenario_l6_reinstall() {
    log "L6: reinstall 按当前代码重装，不拉新代码"
    fresh_clone l6 v-smoke-2
    seed_data
    # 远端先前进一格：reinstall 不该把它拉下来
    echo "manager v3" > "$MGR/VERSION"
    git -C "$MGR" add -A
    git -C "$MGR" commit -qm "v-smoke-3"
    git -C "$MGR" tag v-smoke-3
    git -C "$MGR" push -q "$ORIGIN" HEAD:refs/heads/dev-custom
    git -C "$MGR" push -q "$ORIGIN" v-smoke-3
    local remote_tip
    remote_tip=$(git -C "$ORIGIN" rev-parse dev-custom)

    local out rc
    out=$(run_onekey reinstall); rc=$?
    echo "$out" | sed 's/^/    | /'
    [ "$rc" = "0" ] && ok "L6 reinstall 退出码 0" || bad "L6 reinstall 退出码 $rc"
    assert_head "$V2" "L6" "HEAD 仍在原处（没跟远端）"
    [ "$(git -C "$ORIGIN" rev-parse dev-custom)" = "$remote_tip" ] && ok "L6 远端确实有新提交" ||
        bad "L6 远端没有新提交，用例没构造出来"
    [ "$(git -C "$ROOT" rev-parse HEAD)" != "$remote_tip" ] && ok "L6 没有把新代码拉下来" ||
        bad "L6 把远端新代码拉下来了"
    [ "$(install_count)" = "1" ] && ok "L6 install.sh 被执行" || bad "L6 没跑 install.sh"
    assert_data_intact "L6"
}

# -------------------------------------------------------------------- L7 ------
scenario_l7_build_failure_half_upgrade() {
    log "L7: update 时 UI 构建失败（坑 1）→ 代码新、面板没重装，必须能识别"
    fresh_clone l7          # 停在分支 tip（= v-smoke-2）
    seed_data
    # 新代码里把 make build 改成失败，模拟译文件语法错误导致的构建失败
    printf 'build:\n\t@echo "BUILD FAILED"\n\t@exit 1\n' > "$MGR/Makefile"
    echo "manager v3" > "$MGR/VERSION"
    git -C "$MGR" add -A
    git -C "$MGR" commit -qm "v-smoke-4（构建会失败）"
    git -C "$MGR" tag v-smoke-4
    git -C "$MGR" push -q "$ORIGIN" HEAD:refs/heads/dev-custom
    git -C "$MGR" push -q "$ORIGIN" v-smoke-4
    V3=$(git -C "$MGR" rev-parse v-smoke-4)

    local out rc
    out=$(HIDDIFY_DIR="$ROOT" bash "$ROOT/scripts/update.sh" --no-gui --no-log 2>&1); rc=$?
    echo "$out" | sed 's/^/    | /'
    [ "$rc" != "0" ] && ok "L7 update 以非 0 退出（没有假装成功）" || bad "L7 update 竟然返回 0"
    echo "$out" | grep -q "BUILD FAILED" && ok "L7 构建确实失败了" || bad "L7 没看到构建失败"
    # 半升级的现场：代码已经前进，但 install.sh 没跑（面板还跑着旧代码）
    assert_head "$V3" "L7" "代码已前进到新提交"
    [ ! -f "$ROOT/install-was-run" ] && ok "L7 install.sh 没跑（面板仍是旧代码）" ||
        bad "L7 不该跑 install.sh"
    [ "$(install_count)" = "0" ] && ok "L7 半升级状态可被识别（代码≠已重装）" ||
        bad "L7 装过了，构不成半升级"
    assert_data_intact "L7"

    # 复原：让下一次迭代的夹具是干净的
    printf 'build:\n\t@echo "FAKE BUILD"\n' > "$MGR/Makefile"
    git -C "$MGR" add -A
    git -C "$MGR" commit -qm "restore the working Makefile"
    git -C "$MGR" push -q "$ORIGIN" HEAD:refs/heads/dev-custom >/dev/null 2>&1
}

# -------------------------------------------------------------------- L8 ------
scenario_l8_dirty_components() {
    log "L8: update 时组件文件被构建改脏（坑 2）→ 不能被静默回滚"
    fresh_clone l8
    seed_data
    local dirty="$ROOT/services/panel/src/hiddifypanel/admin_v2/components.d.ts"
    [ -f "$dirty" ] || { bad "L8 夹具里没有 components.d.ts"; return; }
    # 模拟 unplugin-vue-components 构建后重写该文件
    echo "// rewritten by build" > "$dirty"

    echo "manager v5" > "$MGR/VERSION"
    git -C "$MGR" add -A
    git -C "$MGR" commit -qm "v-smoke-5"
    git -C "$MGR" push -q "$ORIGIN" HEAD:refs/heads/dev-custom

    local out rc
    out=$(HIDDIFY_DIR="$ROOT" bash "$ROOT/scripts/update.sh" --no-gui --no-log 2>&1); rc=$?
    echo "$out" | sed 's/^/    | /'
    if echo "$out" | grep -qE "无法快进|子模块|fatal|error|overwritten|本地"; then
        ok "L8 给出了明确的失败原因"
    else
        bad "L8 静默通过了（脏文件被悄悄处理掉？）"
    fi
    grep -q "rewritten by build" "$dirty" 2>/dev/null &&
        ok "L8 本地改动没有被静默回滚" || bad "L8 本地改动被回滚了"
    # 教程里必须写清楚这条坑，否则运维无从下手
    grep -q "components.d.ts" "$REPO/docs/ops/server-update.md" &&
        ok "L8 教程（server-update.md 坑 2）写明了 components.d.ts" ||
        bad "L8 教程没写 components.d.ts 这条坑"
    assert_data_intact "L8"
}

# 清掉历史遗留的 safe.directory，避免属主类场景假通过
clear_safe_dirs() {
    local cfg
    for cfg in --global --system; do
        while git config $cfg --get-all safe.directory >/dev/null 2>&1; do
            git config $cfg --unset-all safe.directory >/dev/null 2>&1 || break
        done
    done
}

# -------------------------------------------------------------------- L9 ------
scenario_l9_update_foreign_ownership() {
    log "L9: 最外层 \$ROOT 属主异常（65534）→ onekey update 仍必须成功"
    fresh_clone l9
    seed_data
    if ! chown -R 65534:65534 "$ROOT" 2>/dev/null; then
        skip "L9 无法 chown（非 root），跳过"
        return
    fi
    clear_safe_dirs
    local out rc
    out=$(run_onekey update); rc=$?
    echo "$out" | sed 's/^/    | /'
    [ "$rc" = "0" ] && ok "L9 update 退出 0（属主例外已在 git 操作前登记）" || bad "L9 update 退出 $rc"
    echo "$out" | grep -qi "dubious ownership" && bad "L9 仍报 dubious ownership" ||
        ok "L9 没有 dubious ownership 错误"
    assert_data_intact "L9"
}

# ------------------------------------------------------------------- L10 ------
scenario_l10_no_warp_in_update() {
    log "L10: update 不直接触发 warp 任务（warp 决策只在 install.sh 内）"
    fresh_clone l10
    seed_data
    local bin="$WORK/fakebin-l10" c out rc
    rm -rf "$bin"; mkdir -p "$bin"
    for c in wgcf wg-quick wg; do
        printf '#!/bin/bash\necho "%s" >> %s/warp-called\n' "$c" "$WORK" > "$bin/$c"
        chmod +x "$bin/$c"
    done
    rm -f "$WORK/warp-called"
    out=$(PATH="$bin:$PATH" run_onekey update); rc=$?
    echo "$out" | sed 's/^/    | /'
    [ "$rc" = "0" ] && ok "L10 update 退出 0" || bad "L10 update 退出 $rc"
    [ ! -f "$WORK/warp-called" ] && ok "L10 未直接调用 wgcf/wg-quick/wg" ||
        bad "L10 直接调用了 warp 工具：$(tr '\n' ' ' < "$WORK/warp-called")"
}

# 线上目录指纹：本套件只允许在 $WORK 下活动，前后各取一次指纹做反证。
# 只要有人（包括被测脚本回落到默认路径）动了 /opt/hiddify-manager，这里必须变红。
live_fp() {
    [ -d /opt/hiddify-manager/.git ] || return 0
    { git -C /opt/hiddify-manager rev-parse HEAD 2>/dev/null
      git -C /opt/hiddify-manager status --porcelain 2>/dev/null
      cat /opt/hiddify-manager/VERSION 2>/dev/null
    } | md5sum | cut -d' ' -f1
}

# -------------------------------------------------------------------- driver ---
run_once() {
    local i="$1"
    echo
    echo "================ iteration $i ================"
    prepare_env
    build_manager_fixture

    local before=$fail_count
    scenario_l1_upgrade
    scenario_l2_downgrade
    scenario_l3_same_version_again
    scenario_l4_back_and_forth
    scenario_l5_bad_input
    scenario_l6_reinstall
    scenario_l7_build_failure_half_upgrade
    scenario_l8_dirty_components
    scenario_l9_update_foreign_ownership
    scenario_l10_no_warp_in_update
    if [ "$fail_count" = "$before" ]; then
        pass_count=$((pass_count + 1))
    else
        failed_iterations="$failed_iterations $i"
    fi
}

start_ts=$(date +%s)
LIVE_FP0=$(live_fp)
for i in $(seq 1 "$ITERATIONS"); do
    run_once "$i"
done
end_ts=$(date +%s)

echo
if [ "$(live_fp)" = "$LIVE_FP0" ]; then
    ok "全流程未触碰线上 /opt/hiddify-manager（指纹一致）"
else
    bad "线上 /opt/hiddify-manager 被改动了（指纹变化）"
fi

echo
echo "================ summary ================"
echo "iterations: $ITERATIONS   all-green: $pass_count   failed: $fail_count   assertions: $assert_total   elapsed: $((end_ts - start_ts))s"
[ -n "$failed_iterations" ] && echo "failed iterations:$failed_iterations"
[ "$fail_count" -eq 0 ] || exit 1
exit 0
