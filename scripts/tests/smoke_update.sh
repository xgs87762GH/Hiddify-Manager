#!/bin/bash
# End-to-end smoke test for scripts/update.sh, fully offline.
#
# It builds a throwaway manager checkout under $ROOT (the path update.sh works
# in), points its panel submodule at a local repository, and makes that
# submodule belong to another uid — exactly the "detected dubious ownership"
# that broke the panel update. Then it runs the real update flow for:
#
#   A  fresh update, no safe.directory exceptions, foreign-owned submodule
#   B  the manager is already up to date but the panel is behind -> must sync
#   C  a panel-only bump (outer commit moving just the submodule pointer)
#   D  the server still has an older update.sh -> it must hand over and work
#   E  a local commit diverged from the remote -> ff-only must refuse, work kept
#
# Every scenario must leave HEAD on origin/dev-custom and the panel checkout on
# the commit the pointer asks for.
#
# Usage: bash scripts/tests/smoke_update.sh [iterations]
set -u

ITERATIONS="${1:-10}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT=/opt/hiddify-manager
WORK=/tmp/hsmoke
HOME_DIR="$WORK/home"
PID_DIR="$WORK/run"
export HOME="$HOME_DIR"
export HIDDIFY_UPDATE_COPIED=

MGR_ORIGIN="$WORK/manager.git"
PANEL_ORIGIN="$WORK/panel.git"
FOREIGN_UID=65534 # anything but root: root reading it trips the ownership check

pass_count=0
fail_count=0
failed_iterations=""

log() { echo -e "\033[1;34m==>\033[0m $*"; }
ok() { echo -e "    \033[1;32mPASS\033[0m $*"; }
bad() { echo -e "    \033[1;31mFAIL\033[0m $*"; fail_count=$((fail_count + 1)); }

# ---------------------------------------------------------------- fixtures ---
prepare_env() {
    rm -rf "$WORK"
    mkdir -p "$HOME_DIR" "$PID_DIR"
    git config --global protocol.file.allow always
    git config --global init.defaultBranch dev-custom
    git config --global user.email smoke@t
    git config --global user.name smoke
    rm -rf "${ROOT:?}/"* "${ROOT:?}/.[!.]*" 2>/dev/null
    # 本脚本可能以 root 运行（写 /opt、chown 需要），而 $REPO 属于运行者账号；
    # 不认这个目录的话，取历史 update.sh 时会报 dubious ownership。
    git config --global --add safe.directory "$REPO"
}

restore_preexisting() {
    [ -d "$ROOT.data.preexisting" ] && rm -rf "$ROOT/data" && mv "$ROOT.data.preexisting" "$ROOT/data"
    return 0
}

stash_preexisting() {
    # never lose whatever is already in /opt/hiddify-manager on this machine
    if [ -d "$ROOT/data" ] && [ -n "$(ls -A "$ROOT/data" 2>/dev/null)" ]; then
        mv "$ROOT/data" "$ROOT.data.preexisting"
    fi
}

build_panel_repo() {
    git init -q --bare "$PANEL_ORIGIN"
    local work="$WORK/panel"
    git init -q "$work"
    echo "panel v1" > "$work/VERSION"
    git -C "$work" add -A
    git -C "$work" commit -qm "panel v1"
    PANEL_V1=$(git -C "$work" rev-parse HEAD)
    echo "panel v2" > "$work/VERSION"
    git -C "$work" commit -qam "panel v2"
    PANEL_V2=$(git -C "$work" rev-parse HEAD)
    echo "panel v3" > "$work/VERSION"
    git -C "$work" commit -qam "panel v3"
    PANEL_V3=$(git -C "$work" rev-parse HEAD)
    git -C "$work" push -q "$PANEL_ORIGIN" HEAD:refs/heads/dev-custom
}

build_manager_repo() {
    git init -q --bare "$MGR_ORIGIN"
    local work="$WORK/manager"
    git init -q "$work"
    mkdir -p "$work/scripts/common" "$work/services/panel"
    cp "$REPO/scripts/update.sh" "$work/scripts/update.sh"
    cp "$REPO/scripts/common/utils.sh" "$work/scripts/common/utils.sh"
    cat > "$work/services/panel/backup.sh" <<'EOF'
#!/bin/bash
echo "FAKE BACKUP"
EOF
    chmod +x "$work/services/panel/backup.sh"
    printf 'build:\n\t@echo "FAKE BUILD"\n' > "$work/Makefile"
    echo "manager v1" > "$work/VERSION"
    git -C "$work" add -A
    git -C "$work" commit -qm "manager v1"
    git -C "$work" push -q "$MGR_ORIGIN" HEAD:refs/heads/dev-custom
    echo "$work"
}

# The update.sh a server installed before these fixes: take it out of git
# history so the scenario matches what is really deployed, not a guess.
PRE_FIX_COMMIT=3d81605c
old_update_sh() {
    if git -C "$REPO" cat-file -e "$PRE_FIX_COMMIT:scripts/update.sh" 2>/dev/null; then
        git -C "$REPO" show "$PRE_FIX_COMMIT:scripts/update.sh"
        return
    fi
    awk '
      /^# This script runs from a copy in \/tmp/ {skip=1; next}
      skip==1 && /^}$/ {skip=0; next}
      skip==1 {next}
      {print}
    ' "$REPO/scripts/update.sh" |
        awk '/hand_over_to_new_script/ && !/^#/ {next} {print}'
}

# --------------------------------------------------------------- helpers -----
commit_in() { git -C "$1" rev-parse HEAD; }

bump_panel_in() { # $1 = manager work tree, $2 = panel commit to point at
    git -C "$1/services/panel/src" checkout -q "$2"
    git -C "$1" add services/panel/src
    git -C "$1" commit -qm "panel -> $2"
    git -C "$1" push -q "$MGR_ORIGIN" HEAD:refs/heads/dev-custom
}

clone_server() {
    rm -rf "$ROOT"
    mkdir -p /opt
    git clone -q -b dev-custom "$MGR_ORIGIN" "$ROOT"
}

make_submodule_foreign() {
    chown -R "$FOREIGN_UID":"$FOREIGN_UID" "$ROOT/services/panel/src" 2>/dev/null
    chown -R "$FOREIGN_UID":"$FOREIGN_UID" "$ROOT/.git/modules" 2>/dev/null
}

assert_head_is_remote() {
    local h r
    h=$(git -C "$ROOT" rev-parse HEAD)
    r=$(git -C "$ROOT" rev-parse origin/dev-custom)
    if [ "$h" != "$r" ]; then bad "HEAD ($h) != origin/dev-custom ($r)"; return 1; fi
    ok "HEAD is at origin/dev-custom"
}

assert_submodule_synced() {
    [ -d "$ROOT/services/panel/src" ] || { bad "services/panel/src is missing"; return 1; }
    local want have
    want=$(git -C "$ROOT" ls-tree HEAD services/panel/src | awk '{print $3}')
    have=$(git -C "$ROOT/services/panel/src" rev-parse HEAD 2>/dev/null)
    if [ "$want" != "$have" ]; then bad "panel at $have, pointer wants $want"; return 1; fi
    ok "panel submodule matches the pointer"
}

run_update() { (cd "$ROOT" && bash scripts/update.sh --no-gui --no-log 2>&1); }

# --------------------------------------------------------------- scenarios ---
scenario_a() {
    log "A: fresh update, no exceptions, submodule owned by another user"
    work="$WORK/manager"
    bump_panel_in "$work" "$PANEL_V2"
    # the server sits one commit behind, on panel v1
    clone_server
    git -C "$ROOT" reset -q --hard HEAD~1
    git -C "$ROOT" submodule update --init --recursive -q
    make_submodule_foreign
    local out
    out=$(run_update)
    echo "$out" | sed 's/^/    | /'
    echo "$out" | grep -q "dubious ownership" && bad "git still refuses the submodule"
    echo "$out" | grep -q "FAKE BACKUP" || bad "backup did not run"
    echo "$out" | grep -q "Syncing submodules" || bad "submodules were never synced"
    echo "$out" | grep -q "FAKE BUILD" || bad "make build did not run"
    assert_head_is_remote
    assert_submodule_synced
}

scenario_b() {
    log "B: already up to date, panel rolled back -> must still sync"
    git -C "$ROOT/services/panel/src" reset -q --hard "$PANEL_V1"
    make_submodule_foreign
    local out
    out=$(run_update)
    echo "$out" | sed 's/^/    | /'
    echo "$out" | grep -q "Already up to date" || bad "expected 'Already up to date'"
    assert_submodule_synced
}

scenario_c() {
    log "C: panel-only bump"
    bump_panel_in "$WORK/manager" "$PANEL_V3"
    local out
    out=$(run_update)
    echo "$out" | sed 's/^/    | /'
    assert_head_is_remote
    assert_submodule_synced
}

scenario_e() {
    log "E: local commit diverged -> ff-only must refuse and keep the local work"
    # 远端前进一格
    echo "remote" > "$WORK/manager/REMOTE_MARKER"
    git -C "$WORK/manager" add REMOTE_MARKER
    git -C "$WORK/manager" commit -qm "remote moved on"
    git -C "$WORK/manager" push -q "$MGR_ORIGIN" HEAD:refs/heads/dev-custom
    # 服务器本地也提交一格，形成分叉
    echo "local hotfix" > "$ROOT/LOCAL_HOTFIX"
    git -C "$ROOT" add LOCAL_HOTFIX
    git -C "$ROOT" commit -qm "local hotfix"
    local out local_sha
    local_sha=$(git -C "$ROOT" rev-parse HEAD)
    out=$(run_update)
    echo "$out" | sed 's/^/    | /'
    echo "$out" | grep -q "FAKE BACKUP" || bad "backup did not run before the refusal"
    echo "$out" | grep -q "无法快进" || bad "update.sh did not stop on a non-fast-forward"
    [ -f "$ROOT/LOCAL_HOTFIX" ] || bad "the local commit was destroyed"
    [ "$(git -C "$ROOT" rev-parse HEAD)" = "$local_sha" ] ||
        bad "HEAD moved away from the local commit"
    [ "$(git -C "$MGR_ORIGIN" rev-parse dev-custom)" != "$(git -C "$ROOT" rev-parse HEAD)" ] ||
        bad "HEAD silently jumped onto the remote tip"
    ok "local commit preserved, update refused"
    # 不在收尾 reset：scenario_d 的 clone_server 会整体重建 $ROOT
}

scenario_d() {
    # The situation of a server installed before these fixes: its own update.sh
    # knows nothing about the safe.directory handling, so the first run can only
    # update the code. The second run uses the new script and must finish.
    log "D: pre-fix update.sh -> first run updates the code, second one finishes"
    work="$WORK/manager"
    old_update_sh > "$work/scripts/update.sh"
    git -C "$work" add scripts/update.sh
    git -C "$work" commit -qm "the update.sh installed before the fix"
    git -C "$work" push -q "$MGR_ORIGIN" HEAD:refs/heads/dev-custom
    cp "$REPO/scripts/update.sh" "$work/scripts/update.sh"
    git -C "$work" add scripts/update.sh
    git -C "$work" commit -qm "the current update.sh"
    git -C "$work" push -q "$MGR_ORIGIN" HEAD:refs/heads/dev-custom

    clone_server
    git -C "$ROOT" reset -q --hard HEAD~1
    git -C "$ROOT" submodule update --init --recursive -q
    make_submodule_foreign
    grep -q "add_safe_directories" "$ROOT/scripts/update.sh" &&
        bad "the server-side script is not the old one"

    # Earlier scenarios left their exceptions behind, and this one is about a
    # server that has none: start from a clean global config, like a fresh host.
    rm -f "$HOME_DIR/.gitconfig"
    git config --global protocol.file.allow always

    local out1 out2 control
    control=$(cd "$ROOT" && git -C services/panel/src rev-parse HEAD 2>&1)
    echo "    control (must show the ownership failure): $control"
    echo "$control" | grep -q "dubious ownership" ||
        bad "the fixture does not reproduce the ownership failure"
    out1=$(run_update)
    echo "    first run:"
    echo "$out1" | sed 's/^/    | /'
    grep -q "add_safe_directories" "$ROOT/scripts/update.sh" ||
        bad "the first run did not bring in the new script"

    out2=$(run_update)
    echo "    second run:"
    echo "$out2" | sed 's/^/    | /'
    echo "$out2" | grep -q "dubious ownership" && bad "git still refuses the submodule"
    echo "$out2" | grep -q "FAKE BUILD" || bad "the second run did not apply the code"
    assert_head_is_remote
    assert_submodule_synced
}

# ------------------------------------------------------------------- driver ---
run_once() {
    local i="$1"
    echo
    echo "================ iteration $i ================"
    prepare_env
    build_panel_repo
    work=$(build_manager_repo)
    git -C "$work" submodule add -q "$PANEL_ORIGIN" services/panel/src >/dev/null
    git -C "$work" add -A
    git -C "$work" commit -qm "add the panel submodule"
    git -C "$work" push -q "$MGR_ORIGIN" HEAD:refs/heads/dev-custom
    bump_panel_in "$work" "$PANEL_V1"

    local before=$fail_count
    scenario_a
    scenario_b
    scenario_c
    scenario_e
    scenario_d
    if [ "$fail_count" = "$before" ]; then
        pass_count=$((pass_count + 1))
    else
        failed_iterations="$failed_iterations $i"
    fi
}

trap 'restore_preexisting' EXIT
stash_preexisting
for i in $(seq 1 "$ITERATIONS"); do
    run_once "$i"
done

echo
echo "================ summary ================"
echo "iterations: $ITERATIONS   all-green: $pass_count   failed: $fail_count"
[ -n "$failed_iterations" ] && echo "failed iterations:$failed_iterations"
[ "$fail_count" -eq 0 ] || exit 1
exit 0
