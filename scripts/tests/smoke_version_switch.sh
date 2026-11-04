#!/bin/bash
# End-to-end smoke test for `onekey.sh version <tag>` on a git checkout, fully offline.
#
# git 检出上切版本以前只能手工 `git checkout <tag>`，而 v14.2.4 及更早版本把 .j2 的
# 渲染产物（如 services/warp/wireguard/install.sh）也提交了进来：装完必然被改写，
# 于是 git 直接拒绝切换，升级卡死。现在 onekey.sh 自己完成"强制换代码、留数据"：
#
#   A  从一个被渲染产物弄脏的检出切到另一个 tag：必须切成功，且渲染产物被还原
#   B  data/、generated/ 与虚拟环境必须原样保留（裸跑 git clean -fdx 会删掉它们）
#   C  切换后必须真的跑了 install.sh（否则等于只换了代码没生效）
#   D  普通 untracked 垃圾文件应被清掉（保留的是数据，不是垃圾）
#   E  不存在的 tag 必须报错退出，不能动工作树
#   F  嵌套子模块（面板里的 user_front）属主是别的 uid 时，切版本必须自动登记
#      safe.directory 例外并同步成功——这正是线上 "dubious ownership" 的现场
#   G  嵌套子模块 .git 指向不存在的 gitdir → 切版本必须挪开并重克隆
#   H  升级 → 降级 → 再升级的往返链路：三轮之后 data/、generated/、.venv313 仍完好
#   I  最外层 $ROOT 本身（含 .git）属主异常：root 连 rev-parse 都读不了，
#      切版本必须先登记例外再动手，否则 fetch 那一步就 die
#   J  顶层面板子模块半残（release 安装的现场：services/panel/src/.git 指向不存在
#      的 gitdir）：必须被 fixup_broken_submodules 挪成 .release-backup* 并重克隆
#   K  连切两次同一个 tag：第二次仍必须成功、install.sh 再跑一次、数据不动
#      （线上"更新点了两下"就是这个路径）
#   L  版本参数非法（空 / 不以 v 开头 / 带 shell 元字符）：必须拒绝，且不能有副作用
#   M  面板子模块整个目录被删光：切版本必须重新克隆出来并同步到指针
#   N  $ROOT 是符号链接：必须顺着链接切真实目录，而不是在链接上另建仓库
#   O  $ROOT 路径含空格：所有 git 调用必须引用正确，不能被拆成两个参数
#
# 每个场景都从夹具裸仓库**全新克隆**一个目录（fresh_clone），场景之间不共享工作树，
# 避免上一个场景留下的 safe.directory、脏文件、半残子模块串味到下一个场景。
#
# 用法：bash scripts/tests/smoke_version_switch.sh [轮数]
set -u

ITERATIONS="${1:-10}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=/tmp/hvs
ORIGIN="$WORK/manager.git"
FOREIGN_UID=65534 # 任何非 root：root 读它会触发 git 的 ownership 校验

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

# 面板 + 面板里的嵌套子模块（hiddifypanel/user_front），都放在本地裸仓库里。
# 线上就是这一层嵌套子模块的属主是 hiddify-panel，而 git 以 root 运行。
build_nested_submodules() {
    git init -q --bare "$WORK/userfront.git"
    local uf="$WORK/userfront"
    git init -q "$uf"
    echo "userfront v1" > "$uf/VERSION"
    git -C "$uf" add -A
    git -C "$uf" commit -qm "userfront v1"
    git -C "$uf" push -q "$WORK/userfront.git" HEAD:refs/heads/dev-custom
    git -C "$WORK/userfront.git" symbolic-ref HEAD refs/heads/dev-custom

    git init -q --bare "$WORK/panel.git"
    local p="$WORK/panel"
    git init -q "$p"
    mkdir -p "$p/hiddifypanel"
    echo "panel v1" > "$p/VERSION"
    git -C "$p" add -A
    git -C "$p" commit -qm "panel v1"
    git -C "$p" submodule add -q "$WORK/userfront.git" hiddifypanel/user_front
    git -C "$p" commit -qm "panel: add user_front submodule"
    git -C "$p" push -q "$WORK/panel.git" HEAD:refs/heads/dev-custom
    git -C "$WORK/panel.git" symbolic-ref HEAD refs/heads/dev-custom
}

# v-smoke-2 相对 v-smoke-1 不仅换了 VERSION，还把面板指针往前推了一格：
# 这样每个场景都能顺带断言"子模块确实同步到了新指针"，而不是只换外层代码。
bump_panel_to_v2() {
    local p="$WORK/panel"
    echo "panel v2" > "$p/VERSION"
    git -C "$p" commit -qam "panel v2"
    git -C "$p" push -q "$WORK/panel.git" HEAD:refs/heads/dev-custom
    PANEL_V2=$(git -C "$p" rev-parse HEAD)
}

# 两个 tag 的仓库：v-smoke-1（当前）与 v-smoke-2（目标）。
# services/warp/wireguard/install.sh 是"被误提交的 .j2 渲染产物"，旁边放着 install.sh.j2。
build_repo() {
    git init -q --bare "$ORIGIN"
    local work="$WORK/manager"
    git init -q "$work"
    mkdir -p "$work/scripts" "$work/services/warp/wireguard"
    cp "$REPO/scripts/onekey.sh" "$work/scripts/onekey.sh"
    # 装完的落点放在 generated/：切版本时的 git clean -fd 会清掉仓库根的 untracked 文件，
    # 计数只能落在"切版本时被保留"的目录里，否则数不出"每次都真跑过 install.sh"。
    cat > "$work/scripts/install.sh" <<'EOF'
#!/bin/bash
echo "FAKE INSTALL"
mkdir -p "$(dirname "$0")/../generated"
echo "install" >> "$(dirname "$0")/../generated/install-log"
echo installed > "$(dirname "$0")/../install-was-run"
EOF
    chmod +x "$work/scripts/install.sh"
    # 面板子模块（里面还有嵌套的 user_front）：切版本时必须一起同步
    build_nested_submodules
    git -C "$work" submodule add -q "$WORK/panel.git" services/panel/src
    # 被误提交的渲染产物 + 它的模板：这就是 v14.2.4 的现场
    echo 'export WGCF_LICENSE_KEY="{{hconfigs[warp_plus_code]}}"' > "$work/services/warp/wireguard/install.sh"
    echo 'export WGCF_LICENSE_KEY="{{hconfigs[warp_plus_code]}}"' > "$work/services/warp/wireguard/install.sh.j2"
    echo "v-smoke-1" > "$work/VERSION"
    git -C "$work" add -A
    git -C "$work" commit -qm "v-smoke-1"
    git -C "$work" tag v-smoke-1
    git -C "$work" push -q "$ORIGIN" HEAD:refs/heads/dev-custom
    git -C "$work" push -q "$ORIGIN" v-smoke-1
    V1=$(git -C "$work" rev-parse v-smoke-1)

    bump_panel_to_v2
    local sm="$work/services/panel/src"
    git -C "$sm" fetch -q origin 2>/dev/null
    git -C "$sm" checkout -q "$PANEL_V2" 2>/dev/null
    echo "v-smoke-2" > "$work/VERSION"
    git -C "$work" add -A
    git -C "$work" commit -qm "v-smoke-2"
    git -C "$work" tag v-smoke-2
    git -C "$work" push -q "$ORIGIN" HEAD:refs/heads/dev-custom
    git -C "$work" push -q "$ORIGIN" v-smoke-2
    V2=$(git -C "$work" rev-parse v-smoke-2)
}

# 每个场景一个全新工作树：从夹具裸仓库克隆、切到起始 tag、初始化（含嵌套）子模块。
fresh_clone() {
    local name="$1"
    ROOT="$WORK/root-$name"
    rm -rf "$ROOT"
    git clone -q -b dev-custom "$ORIGIN" "$ROOT"
    git -C "$ROOT" checkout -q v-smoke-1
    git -C "$ROOT" submodule update --init --recursive -q 2>/dev/null
}

# 调用方一律写成 out=$(run_version v-x)，那是子 shell，变量传不回来；
# 所以退出码落到文件里，用 last_rc 读，避免"$? 被下一条命令覆盖"这类假通过。
run_version() {
    local out rc
    out=$(bash "$REPO/scripts/onekey.sh" version "$@" --dir "$ROOT" -y 2>&1)
    rc=$?
    printf '%s' "$rc" > "$WORK/.rc"
    printf '%s' "$out"
}

last_rc() { cat "$WORK/.rc" 2>/dev/null || echo 0; }

assert_head() { # $1 = 期望的 commit
    local got
    got=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)
    if [ "$got" = "$1" ]; then
        ok "HEAD 已在 $2"
    else
        bad "HEAD 不在 $2（got=${got:-空} want=$1）"
    fi
}

assert_panel_synced() { # 面板 checkout == 外层记录的指针
    local want got
    want=$(git -C "$ROOT" ls-tree HEAD services/panel/src 2>/dev/null | awk '{print $3}')
    got=$(git -C "$ROOT/services/panel/src" rev-parse HEAD 2>/dev/null)
    if [ -n "$got" ] && [ "$got" = "$want" ]; then
        ok "面板子模块已同步到指针"
    else
        bad "面板子模块未同步（got=${got:-空} want=$want）"
    fi
}

assert_data_intact() { # data/ generated/ .venv313 三件套
    [ -f "$ROOT/data/keep.txt" ] && [ "$(cat "$ROOT/data/keep.txt")" = "precious" ] &&
        ok "data/ 完好" || bad "data/ 被破坏了"
    [ -f "$ROOT/generated/marker" ] && ok "generated/ 完好" || bad "generated/ 被破坏了"
    [ -f "$ROOT/.venv313/marker" ] && ok "虚拟环境还在" || bad "虚拟环境被删了"
}

seed_data() {
    mkdir -p "$ROOT/data" "$ROOT/generated" "$ROOT/.venv313"
    echo "precious" > "$ROOT/data/keep.txt"
    echo "generated" > "$ROOT/generated/marker"
    echo "venv" > "$ROOT/.venv313/marker"
}

install_run_count() { grep -c . "$ROOT/generated/install-log" 2>/dev/null || echo 0; }

# 半残目录被挪开后不能被随后的 git clean -fd 又删掉（否则备份形同不存在）
assert_backup_kept() { # $1 = 备份目录
    if [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]; then
        ok "$(basename "$1") 的内容仍保留（未被 clean 删空）"
    else
        bad "$(basename "$1") 被清成了空目录"
    fi
}

# ------------------------------------------------------------------ scenarios ---
scenario_a_b_c_d() {
    log "A/B/C/D: 脏树 → 切到 v-smoke-2；data/generated/venv 保留；跑 install.sh；清掉垃圾"
    fresh_clone a
    seed_data
    echo "junk" > "$ROOT/junk.txt" # 普通 untracked 垃圾，应该被清掉
    # 模拟"安装把渲染产物改写"：v14.2.4 的现场
    echo 'export WGCF_LICENSE_KEY="real-key"' > "$ROOT/services/warp/wireguard/install.sh"

    local out
    out=$(run_version v-smoke-2)
    echo "$out" | sed 's/^/    | /'

    assert_head "$V2" "v-smoke-2"
    [ -z "$(git -C "$ROOT" status --porcelain -- services/warp/wireguard/install.sh)" ] &&
        ok "A 渲染产物已还原（工作树干净）" || bad "A 渲染产物仍被改写"
    assert_data_intact
    [ -f "$ROOT/install-was-run" ] && ok "C install.sh 被执行" || bad "C 没有跑 install.sh"
    [ ! -f "$ROOT/junk.txt" ] && ok "D 垃圾文件已清理" || bad "D 垃圾文件还在"
    assert_panel_synced
}

scenario_e() {
    log "E: 不存在的 tag → 必须报错，工作树不动"
    fresh_clone e
    seed_data
    local before out
    before=$(git -C "$ROOT" rev-parse HEAD)
    out=$(run_version v-smoke-999)
    echo "$out" | sed 's/^/    | /'
    [ "$(git -C "$ROOT" rev-parse HEAD)" = "$before" ] &&
        ok "E 工作树未被改动" || bad "E HEAD 被动了"
    echo "$out" | grep -q "找不到 tag" && ok "E 给出了明确报错" || bad "E 没有报错信息"
    assert_data_intact
}

scenario_f_nested_foreign_submodule() {
    log "F: 嵌套子模块属主是其它 uid → 切版本必须自动加例外并同步成功"
    fresh_clone f
    seed_data
    local sm="$ROOT/services/panel/src/hiddifypanel/user_front"

    if [ ! -e "$sm/.git" ]; then
        bad "F 嵌套子模块未初始化，场景无法构造"
        return
    fi
    chown -R "$FOREIGN_UID":"$FOREIGN_UID" "$sm" 2>/dev/null
    chown -R "$FOREIGN_UID":"$FOREIGN_UID" \
        "$ROOT/.git/modules/services/panel/src/modules/hiddifypanel/user_front" 2>/dev/null

    clear_safe_directories

    local out
    out=$(run_version v-smoke-2)
    echo "$out" | sed 's/^/    | /'

    assert_head "$V2" "v-smoke-2"

    # 期望值：面板仓库里记录的 user_front 子模块指针（不是面板自己的 sha）
    local want got
    want=$(git -C "$ROOT/services/panel/src" ls-tree HEAD hiddifypanel/user_front 2>/dev/null | awk '{print $3}')
    got=$(git -C "$sm" rev-parse HEAD 2>/dev/null)
    if [ -n "$got" ] && [ "$got" = "$want" ]; then
        ok "F 嵌套子模块已同步到子模块指针"
    else
        bad "F 嵌套子模块未同步（got=${got:-空} want=$want）"
    fi
    assert_data_intact
}

scenario_g_broken_nested_submodule() {
    log "G: 嵌套子模块 .git 指向不存在的 gitdir → 切版本必须挪开并重克隆"
    fresh_clone g
    seed_data
    local sm="$ROOT/services/panel/src/hiddifypanel/user_front" bak out
    [ -e "$sm/.git" ] || { bad "G 嵌套子模块未初始化，场景无法构造"; return; }
    printf 'gitdir: %s\n' "$WORK/nonexistent/user_front" >"$sm/.git"

    out=$(run_version v-smoke-2)
    echo "$out" | sed 's/^/    | /'

    assert_head "$V2" "v-smoke-2"
    # 重克隆后 .git 可能是相对路径的 gitdir 指针，用 rev-parse 判定它重新成为独立仓库
    if [ -e "$sm/.git" ] && [ "$(git -C "$sm" rev-parse --show-toplevel 2>/dev/null)" = "$sm" ]; then
        ok "G 嵌套子模块已重克隆"
    else
        bad "G 嵌套子模块未重克隆"
    fi
    bak=$(ls -d "$sm".release-backup* 2>/dev/null | head -n 1)
    [ -n "$bak" ] && ok "G 半残目录已备份为 $(basename "$bak")" || bad "G 未生成 .release-backup"
    [ -n "$bak" ] && assert_backup_kept "$bak"
    assert_data_intact
}

scenario_h_upgrade_downgrade_upgrade() {
    log "H: 升级 → 降级 → 再升级的往返链路，数据全程完好"
    fresh_clone h
    seed_data

    local out i
    for i in 1 2 3; do
        case "$i" in
            1|3) out=$(run_version v-smoke-2) ;;
            2) out=$(run_version v-smoke-1) ;;
        esac
        echo "$out" | sed 's/^/    | /'
        case "$i" in
            1) assert_head "$V2" "第 1 步 v-smoke-2（升级）" ;;
            2) assert_head "$V1" "第 2 步 v-smoke-1（降级）" ;;
            3) assert_head "$V2" "第 3 步 v-smoke-2（再升级）" ;;
        esac
        assert_data_intact
    done

    local n
    n=$(install_run_count)
    [ "$n" = "3" ] && ok "H 三次切换都真的跑了 install.sh（$n 次）" ||
        bad "H install.sh 只跑了 $n 次，期望 3 次"
    [ "$(git -C "$ROOT" describe --tags 2>/dev/null)" = "v-smoke-2" ] &&
        ok "H 最终落在 v-smoke-2" || bad "H 最终版本不是 v-smoke-2"
    assert_panel_synced
}

scenario_i_root_foreign_ownership() {
    log "I: 最外层 $ROOT 属主异常 → 切版本必须先登记 safe.directory 再动手"
    fresh_clone i
    seed_data

    # 整机级异常：工作树与 .git（含 modules）全部换成别的属主
    chown -R "$FOREIGN_UID":"$FOREIGN_UID" "$ROOT" 2>/dev/null
    clear_safe_directories

    # 现场确认：root 此时连最外层仓库都读不了，否则说明场景没构造出来
    if git -C "$ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
        skip "I 未触发 dubious ownership（当前环境无法构造），跳过"
        return 0
    fi
    ok "I 已构造出顶层 dubious ownership"

    local out
    out=$(run_version v-smoke-2)
    echo "$out" | sed 's/^/    | /'
    echo "$out" | grep -q "dubious ownership" && bad "I git 仍在拒绝该仓库"

    assert_head "$V2" "v-smoke-2"
    assert_panel_synced
    assert_data_intact
}

scenario_j_top_submodule_broken() {
    log "J: 顶层面板子模块半残 → 必须挪开并重克隆（release 安装的现场）"
    fresh_clone j
    seed_data
    local sm="$ROOT/services/panel/src" bak out
    [ -e "$sm/.git" ] || { bad "J 面板子模块未初始化，场景无法构造"; return; }
    printf 'gitdir: %s\n' "$WORK/nonexistent/panel" >"$sm/.git"

    out=$(run_version v-smoke-2)
    echo "$out" | sed 's/^/    | /'

    assert_head "$V2" "v-smoke-2"
    if [ -e "$sm/.git" ] && [ "$(git -C "$sm" rev-parse --show-toplevel 2>/dev/null)" = "$sm" ]; then
        ok "J 面板子模块已重克隆"
    else
        bad "J 面板子模块未重克隆"
    fi
    bak=$(ls -d "$sm".release-backup* 2>/dev/null | head -n 1)
    [ -n "$bak" ] && ok "J 半残目录已备份为 $(basename "$bak")" || bad "J 未生成 .release-backup"
    [ -n "$bak" ] && assert_backup_kept "$bak"
    assert_panel_synced
    assert_data_intact
}

scenario_k_same_tag_twice() {
    log "K: 连切两次同一个 tag → 第二次仍要成功，install 再跑一次，数据不动"
    fresh_clone k
    seed_data

    local out
    out=$(run_version v-smoke-2)
    echo "$out" | sed 's/^/    | /'
    assert_head "$V2" "第 1 次切到 v-smoke-2"
    [ "$(last_rc)" = "0" ] && ok "K 第 1 次退出 0" || bad "K 第 1 次退出 $(last_rc)"

    out=$(run_version v-smoke-2)
    echo "$out" | sed 's/^/    | /'
    [ "$(last_rc)" = "0" ] && ok "K 第 2 次（幂等）退出 0" || bad "K 第 2 次退出 $(last_rc)"
    assert_head "$V2" "v-smoke-2（重复切换后）"
    echo "$out" | grep -qi "切换失败\|致命\|fatal" && bad "K 第二次切版本报错了"
    [ "$(install_run_count)" = "2" ] && ok "K install.sh 两次都跑了" ||
        bad "K install.sh 只跑了 $(install_run_count) 次（期望 2）"
    assert_data_intact
    assert_panel_synced
}

scenario_l_invalid_version_arg() {
    log "L: 版本参数非法（空 / 不以 v 开头 / 注入元字符）→ 拒绝且无副作用"
    fresh_clone l
    seed_data
    local before out pwned="$WORK/pwned"
    before=$(git -C "$ROOT" rev-parse HEAD)

    out=$(run_version)
    echo "$out" | sed 's/^/    | /'
    [ "$(last_rc)" != "0" ] && ok "L 空参数被拒绝（rc=$(last_rc)）" || bad "L 空参数竟然执行了"
    echo "$out" | grep -q "用法" && ok "L 空参数给出用法" || bad "L 空参数没有提示"

    out=$(run_version "14.2.4")
    echo "$out" | sed 's/^/    | /'
    [ "$(last_rc)" != "0" ] && ok "L 缺 v 前缀被拒绝（rc=$(last_rc)）" || bad "L 缺 v 前缀竟被接受"
    echo "$out" | grep -q "必须以 v 开头" && ok "L 报错信息明确" || bad "L 报错信息含糊"

    rm -f "$pwned"
    out=$(run_version "v1;touch $pwned")
    echo "$out" | sed 's/^/    | /'
    [ "$(last_rc)" != "0" ] && ok "L 带元字符的版本被拒绝" || bad "L 带元字符的版本被执行了"
    [ ! -e "$pwned" ] && ok "L 没有执行注入的命令" || { bad "L 元字符被当成命令执行"; rm -f "$pwned"; }

    [ "$(git -C "$ROOT" rev-parse HEAD)" = "$before" ] && ok "L 工作树从未被移动" ||
        bad "L HEAD 被动了"
    [ "$(install_run_count)" = "0" ] && ok "L 一次 install.sh 都没跑" ||
        bad "L 意外跑了 $(install_run_count) 次 install.sh"
    assert_data_intact
}

scenario_m_submodule_dir_removed() {
    log "M: 面板子模块整个目录被删光 → 切版本必须重新克隆并同步"
    fresh_clone m
    seed_data
    local sm="$ROOT/services/panel/src" out
    rm -rf "$sm"

    out=$(run_version v-smoke-2)
    echo "$out" | sed 's/^/    | /'

    assert_head "$V2" "v-smoke-2"
    [ "$(last_rc)" = "0" ] && ok "M 退出 0" || bad "M 退出 $(last_rc)"
    if [ -e "$sm/.git" ] && [ "$(git -C "$sm" rev-parse --show-toplevel 2>/dev/null)" = "$sm" ]; then
        ok "M 面板子模块已重新克隆"
    else
        bad "M 面板子模块没有重建"
    fi
    assert_panel_synced
    assert_data_intact
}

scenario_n_root_is_symlink() {
    log "N: $ROOT 是符号链接 → 必须顺着链接切真实目录"
    fresh_clone n
    local real="$ROOT" link="$WORK/link-n" out
    rm -f "$link"
    ln -s "$real" "$link"
    ROOT="$link"
    seed_data

    out=$(run_version v-smoke-2)
    echo "$out" | sed 's/^/    | /'

    [ "$(last_rc)" = "0" ] && ok "N 退出 0" || bad "N 退出 $(last_rc)"
    [ "$(git -C "$real" rev-parse HEAD)" = "$V2" ] && ok "N 真实目录已切到 v-smoke-2" ||
        bad "N 真实目录没被切"
    [ -f "$real/data/keep.txt" ] && ok "N data/ 完好" || bad "N data/ 丢了"
    [ -f "$real/install-was-run" ] && ok "N install.sh 跑了" || bad "N install.sh 没跑"
    assert_panel_synced
}

scenario_o_path_with_space() {
    log "O: $ROOT 路径含空格 → 所有 git 调用都必须正确引用"
    fresh_clone "o with space"
    seed_data
    local out
    out=$(run_version v-smoke-2)
    echo "$out" | sed 's/^/    | /'

    [ "$(last_rc)" = "0" ] && ok "O 退出 0" || bad "O 退出 $(last_rc)"
    [ "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" = "$V2" ] && ok "O 已切到 v-smoke-2" ||
        bad "O 没切过去"
    echo "$out" | grep -qi "fatal\|not a git repository" && bad "O 输出里有 git 致命错误"
    assert_data_intact
    assert_panel_synced
}

scenario_p_plaindir_no_git() {
    log "P: 面板子模块是『有源码、无 .git』的普通目录（release/zip 残留）→ 让位并重克隆"
    fresh_clone p
    seed_data
    local sm="$ROOT/services/panel/src" out bak
    [ -e "$sm/.git" ] || { bad "P 面板子模块未初始化，场景无法构造"; return; }
    rm -f "$sm/.git"
    echo "leftover from release" > "$sm/LEFTOVER.marker"

    out=$(run_version v-smoke-2)
    echo "$out" | sed 's/^/    | /'

    [ "$(last_rc)" = "0" ] && ok "P 退出 0" || bad "P 退出 $(last_rc)"
    assert_head "$V2" "v-smoke-2"
    assert_data_intact
    bak=$(ls -d "$sm".release-backup* 2>/dev/null | head -n 1)
    [ -n "$bak" ] && ok "P 普通目录已被让位为 $(basename "$bak")" || bad "P 未生成 .release-backup"
    [ -n "$bak" ] && assert_backup_kept "$bak"
    [ -n "$bak" ] && [ -f "$bak/LEFTOVER.marker" ] &&
        ok "P 备份里保留了原源码（非空壳）" || bad "P 备份没有原源码"
    if [ -e "$sm/.git" ] && [ "$(git -C "$sm" rev-parse --show-toplevel 2>/dev/null)" = "$sm" ]; then
        ok "P 原路径已重克隆为真正仓库"
    else
        bad "P 原路径未重克隆"
    fi
    assert_panel_synced
}

scenario_q_empty_dir_not_moved() {
    log "Q: 面板子模块是空目录 → 不得让位，交给 git 填充"
    fresh_clone q
    seed_data
    local sm="$ROOT/services/panel/src" out
    rm -rf "$sm"
    mkdir -p "$sm"

    out=$(run_version v-smoke-2)
    echo "$out" | sed 's/^/    | /'

    [ "$(last_rc)" = "0" ] && ok "Q 退出 0" || bad "Q 退出 $(last_rc)"
    assert_head "$V2" "v-smoke-2"
    assert_data_intact
    [ -z "$(ls -d "$sm".release-backup* 2>/dev/null)" ] &&
        ok "Q 空目录没有被让位" || bad "Q 空目录被误让位了"
    if [ -e "$sm/.git" ] && [ "$(git -C "$sm" rev-parse --show-toplevel 2>/dev/null)" = "$sm" ]; then
        ok "Q 空目录已被 git 填充为仓库"
    else
        bad "Q 空目录没有被填充"
    fi
    assert_panel_synced
}

scenario_r_existing_backup_survives_clean() {
    log "R: 切换前已存在的 *.release-backup 不得被 git clean 删掉"
    fresh_clone r
    seed_data
    local out
    mkdir -p "$ROOT/services/panel/src.release-backup-old"
    echo "old backup" > "$ROOT/services/panel/src.release-backup-old/OLD.marker"

    out=$(run_version v-smoke-2)
    echo "$out" | sed 's/^/    | /'

    [ "$(last_rc)" = "0" ] && ok "R 退出 0" || bad "R 退出 $(last_rc)"
    assert_head "$V2" "v-smoke-2"
    assert_data_intact
    [ -f "$ROOT/services/panel/src.release-backup-old/OLD.marker" ] &&
        ok "R 预先存在的 backup 未被 git clean 删除" ||
        bad "R 预先存在的 backup 被删了"
    assert_panel_synced
}

# 前面场景可能已经登记过例外（global 与 system 都有）；全部清掉，
# 模拟一台"从没信任过这些目录"的服务器，否则属主类场景会假通过。
clear_safe_directories() {
    local cfg
    for cfg in --global --system; do
        while git config $cfg --get-all safe.directory >/dev/null 2>&1; do
            git config $cfg --unset-all safe.directory >/dev/null 2>&1 || break
        done
    done
}

# -------------------------------------------------------------------- driver ---
run_once() {
    local i="$1"
    echo
    echo "================ iteration $i ================"
    prepare_env
    build_repo

    local before=$fail_count
    scenario_a_b_c_d
    scenario_e
    scenario_f_nested_foreign_submodule
    scenario_g_broken_nested_submodule
    scenario_h_upgrade_downgrade_upgrade
    scenario_i_root_foreign_ownership
    scenario_j_top_submodule_broken
    scenario_k_same_tag_twice
    scenario_l_invalid_version_arg
    scenario_m_submodule_dir_removed
    scenario_n_root_is_symlink
    scenario_o_path_with_space
    scenario_p_plaindir_no_git
    scenario_q_empty_dir_not_moved
    scenario_r_existing_backup_survives_clean
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
