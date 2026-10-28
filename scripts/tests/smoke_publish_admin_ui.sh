#!/bin/bash
# Offline smoke for scripts/publish_admin_ui.sh argument handling.
# Touches nothing outside a temp dir, never builds and never talks to the network.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO/scripts/publish_admin_ui.sh"
PASS=0
FAIL=0

ok() { echo -e "  \033[1;32mPASS\033[0m $*"; PASS=$((PASS + 1)); }
bad() { echo -e "  \033[1;31mFAIL\033[0m $*"; FAIL=$((FAIL + 1)); }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "== --help =="
set +e
out=$(bash "$SCRIPT" --help 2>&1)
rc=$?
set -e
# 帮助文本必须来自 usage()，而不是被截断的文件头注释：
# 旧实现 sed -n '2,11p' 输出的是以 # 开头的注释行。
if [[ $rc -eq 0 ]] &&
   grep -q -- '--panel-src' <<<"$out" &&
   grep -q -- '--no-push' <<<"$out" &&
   ! grep -q '^#' <<<"$out"; then
  ok "--help prints usage text (not the raw comment block)"
else
  bad "--help rc=$rc"
  sed 's/^/    | /' <<<"$out"
fi

echo "== unknown option =="
set +e
out=$(bash "$SCRIPT" --bogus 2>&1)
rc=$?
set -e
if [[ $rc -eq 2 ]] && grep -q '未知参数' <<<"$out"; then
  ok "unknown option exits 2"
else
  bad "unknown option rc=$rc"
fi

echo "== --panel-src without value =="
set +e
out=$(bash "$SCRIPT" --panel-src 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  ok "--panel-src without value fails (rc=$rc, no silent fallback)"
else
  bad "--panel-src without value should fail, got rc=0"
fi

echo "== --panel-src pointing at a directory that is not the panel =="
set +e
out=$(bash "$SCRIPT" --panel-src "$tmp" 2>&1)
rc=$?
set -e
if [[ $rc -eq 1 ]] && grep -q '不是面板源码目录' <<<"$out"; then
  ok "rejects a directory without admin_v2/package.json"
else
  bad "non-panel dir rc=$rc"
  sed 's/^/    | /' <<<"$out"
fi

echo
echo "================ summary ================"
echo "pass=$PASS fail=$FAIL"
[[ "$FAIL" -eq 0 ]]
