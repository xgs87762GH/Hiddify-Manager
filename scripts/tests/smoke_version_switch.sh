#!/bin/bash
# End-to-end smoke test for `onekey.sh version <tag>` on a git checkout, fully offline.
#
# git 检出上切版本以前只能手工 `git checkout <tag>`，而 v14.2.4 及更早版本把 .j2 的
# 渲染产物（如 services/warp/wireguard/install.sh）也提交了进来：装完必然被改写，
# 于是 git 直接拒绝切换，升级卡死。现在 onekey.sh 自己完成"强制换代码、留数据"：
#
#   A  从一个被渲染产物弄脏的检出切到另一个 tag：必须切成功，且渲染产物被还原
#   B  data/ 与虚拟环境必须原样保留（裸跑 git clean -fdx 会删掉它们）
#   C  切换后必须真的跑了 install.sh（否则等于只换了代码没生效）
#   D  普通 untracked 垃圾文件应被清掉（保留的是数据，不是垃圾）
#   E  不存在的 tag 必须报错退出，不能动工作树
#
# 用法：bash scripts/tests/smoke_version_switch.sh
set -u

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=/tmp/hvs
ORIGIN="$WORK/manager.git"
ROOT="$WORK/root"

pass=0
fail=0
log() { echo -e "\033[1;34m==>\033[0m $*"; }
ok() { echo -e "    \033[1;32mPASS\033[0m $*"; pass=$((pass + 1)); }
bad() { echo -e "    \033[1;31mFAIL\033[0m $*"; fail=$((fail + 1)); }

prepare_env() {
    rm -rf "$WORK"
    mkdir -p "$WORK"
    git config --global protocol.file.allow always
    git config --global init.defaultBranch dev-custom
    git config --global user.email smoke@t
    git config --global user.name smoke
}

# 两个 tag 的仓库：v-smoke-1（当前）与 v-smoke-2（目标）。
# services/warp/wireguard/install.sh 是"被误提交的 .j2 渲染产物"，旁边放着 install.sh.j2。
build_repo() {
    git init -q --bare "$ORIGIN"
    local work="$WORK/manager"
    git init -q "$work"
    mkdir -p "$work/scripts" "$work/services/warp/wireguard"
    cp "$REPO/scripts/onekey.sh" "$work/scripts/onekey.sh"
    cat > "$work/scripts/install.sh" <<'EOF'
#!/bin/bash
echo "FAKE INSTALL"
echo installed > "$(dirname "$0")/../install-was-run"
EOF
    chmod +x "$work/scripts/install.sh"
    # 被误提交的渲染产物 + 它的模板：这就是 v14.2.4 的现场
    echo 'export WGCF_LICENSE_KEY="{{hconfigs[warp_plus_code]}}"' > "$work/services/warp/wireguard/install.sh"
    echo 'export WGCF_LICENSE_KEY="{{hconfigs[warp_plus_code]}}"' > "$work/services/warp/wireguard/install.sh.j2"
    echo "v-smoke-1" > "$work/VERSION"
    git -C "$work" add -A
    git -C "$work" commit -qm "v-smoke-1"
    git -C "$work" tag v-smoke-1
    git -C "$work" push -q "$ORIGIN" HEAD:refs/heads/dev-custom
    git -C "$work" push -q "$ORIGIN" v-smoke-1

    echo "v-smoke-2" > "$work/VERSION"
    git -C "$work" add -A
    git -C "$work" commit -qm "v-smoke-2"
    git -C "$work" tag v-smoke-2
    git -C "$work" push -q "$ORIGIN" HEAD:refs/heads/dev-custom
    git -C "$work" push -q "$ORIGIN" v-smoke-2
    V2=$(git -C "$work" rev-parse v-smoke-2)
}

clone_server() {
    git clone -q -b dev-custom "$ORIGIN" "$ROOT"
    git -C "$ROOT" checkout -q v-smoke-1
}

run_version() { bash "$REPO/scripts/onekey.sh" version "$1" --dir "$ROOT" -y 2>&1; }

# ------------------------------------------------------------------ scenarios ---
scenario_a_b_c_d() {
    log "A/B/C/D: 脏树 → 切到 v-smoke-2；data/ 与 venv 保留；跑 install.sh；清掉垃圾"
    # 面板数据与虚拟环境：切版本时绝不能动
    mkdir -p "$ROOT/data" "$ROOT/.venv313"
    echo "precious" > "$ROOT/data/keep.txt"
    echo "venv" > "$ROOT/.venv313/marker"
    echo "junk" > "$ROOT/junk.txt" # 普通 untracked 垃圾，应该被清掉
    # 模拟"安装把渲染产物改写"：v14.2.4 的现场
    echo 'export WGCF_LICENSE_KEY="real-key"' > "$ROOT/services/warp/wireguard/install.sh"

    local out
    out=$(run_version v-smoke-2)
    echo "$out" | sed 's/^/    | /'

    [ "$(git -C "$ROOT" rev-parse HEAD)" = "$V2" ] && ok "A HEAD 已在 v-smoke-2" || bad "A HEAD 不是 v-smoke-2"
    [ -z "$(git -C "$ROOT" status --porcelain -- services/warp/wireguard/install.sh)" ] &&
        ok "A 渲染产物已还原（工作树干净）" || bad "A 渲染产物仍被改写"
    [ -f "$ROOT/data/keep.txt" ] && [ "$(cat "$ROOT/data/keep.txt")" = "precious" ] &&
        ok "B data/ 完好" || bad "B data/ 被破坏了"
    [ -f "$ROOT/.venv313/marker" ] && ok "B 虚拟环境还在" || bad "B 虚拟环境被删了"
    [ -f "$ROOT/install-was-run" ] && ok "C install.sh 被执行" || bad "C 没有跑 install.sh"
    [ ! -f "$ROOT/junk.txt" ] && ok "D 垃圾文件已清理" || bad "D 垃圾文件还在"
}

scenario_e() {
    log "E: 不存在的 tag → 必须报错，工作树不动"
    local before out
    before=$(git -C "$ROOT" rev-parse HEAD)
    out=$(run_version v-smoke-999)
    echo "$out" | sed 's/^/    | /'
    if [ "$(git -C "$ROOT" rev-parse HEAD)" = "$before" ]; then
        ok "E 工作树未被改动"
    else
        bad "E HEAD 被动了"
    fi
}

# -------------------------------------------------------------------- driver ---
prepare_env
build_repo
clone_server
scenario_a_b_c_d
scenario_e

echo
echo "================ summary ================"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
