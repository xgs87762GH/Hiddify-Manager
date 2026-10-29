#!/bin/bash
# Offline smoke for scripts/common/package_manager.sh download_package.
# Does not touch /opt; uses a throwaway workdir + fake packages.lock / packages.db.
set -eu

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/hsmoke-pkg-$$"
PASS=0
FAIL=0

ok() { echo -e "  \033[1;32mPASS\033[0m $*"; PASS=$((PASS + 1)); }
bad() { echo -e "  \033[1;31mFAIL\033[0m $*"; FAIL=$((FAIL + 1)); }

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$WORK/scripts/common" "$WORK/data" "$WORK/bin"
# Minimal stubs so package_manager can source utils without bringing the world in.
cat > "$WORK/scripts/common/utils.sh" <<'EOF'
#!/bin/bash
HIDDIFY_DIR="${HIDDIFY_DIR:-/opt/hiddify-manager}"
HIDDIFY_DATA="${HIDDIFY_DATA:-$HIDDIFY_DIR/data}"
error() { echo "ERROR: $*" >&2; }
warning() { echo "WARN: $*" >&2; }
success() { echo "OK: $*"; }
EOF

# Real package_manager under test (paths resolved relative to its SCRIPT_DIR).
cp "$REPO/scripts/common/package_manager.sh" "$WORK/scripts/common/package_manager.sh"
# Windows 检出的工作区可能是 CRLF：复制后统一转成 LF，否则 source 时会报 $'\r' 语法错误
sed -i 's/\r$//' "$WORK/scripts/common/package_manager.sh"

# Fake lock: one tiny "binary" we control.
PAYLOAD_A="payload-A-aaaaaaaa"
PAYLOAD_B="payload-B-bbbbbbbb"
HASH_A=$(printf '%s' "$PAYLOAD_A" | sha256sum | awk '{print $1}')
HASH_B=$(printf '%s' "$PAYLOAD_B" | sha256sum | awk '{print $1}')
printf '%s' "$PAYLOAD_A" > "$WORK/bin/artifact-A"
printf '%s' "$PAYLOAD_B" > "$WORK/bin/artifact-B"

# file:// URLs for curl -sL
URL_A="file://$WORK/bin/artifact-A"
URL_B="file://$WORK/bin/artifact-B"

cat > "$WORK/scripts/common/packages.lock" <<EOF
demo|1.0.0|amd64|$URL_A|$HASH_A
demo|1.0.1|amd64|$URL_B|$HASH_B
EOF
: > "$WORK/data/packages.db"

export HIDDIFY_DIR="$WORK"
export HIDDIFY_DATA="$WORK/data"
# package_manager hardcodes SCRIPT_DIR to /opt/... unless path contains "develop"
# Our WORK path should contain neither; force by sourcing after patching, or put
# "develop" in the path. Easiest: run from a develop-named copy.
DEV="$WORK/develop-tree"
mkdir -p "$DEV/scripts/common" "$DEV/data"
cp "$WORK/scripts/common/"* "$DEV/scripts/common/"
cp "$WORK/data/packages.db" "$DEV/data/packages.db" 2>/dev/null || : > "$DEV/data/packages.db"
# Git Bash / 部分环境的 wget、curl 都不支持 file://（add_package 用 wget，download_package 用 curl）。
# 放 stub 到 PATH 最前面，把 file:// 当本地复制；其它 URL 仍交给真实工具。
cat > "$WORK/bin/wget" <<'WGET_STUB'
#!/bin/bash
out=""
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -O) out="$2"; shift 2 ;;
        -q|--quiet) shift ;;
        *) url="$1"; shift ;;
    esac
done
case "$url" in
    file://*) cp "${url#file://}" "$out" ;;
    *) exec /usr/bin/wget -q "$url" -O "$out" ;;
esac
WGET_STUB
cat > "$WORK/bin/curl" <<'CURL_STUB'
#!/bin/bash
out=""
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) out="$2"; shift 2 ;;
        -s|--silent|-L|--location|-f|--fail|-S|--show-error) shift ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
case "$url" in
    file://*) cp "${url#file://}" "$out" ;;
    *)
      real=
      for c in /usr/bin/curl /mingw64/bin/curl.exe; do
        [ -x "$c" ] && real=$c && break
      done
      [ -n "$real" ] || { echo "curl stub: no real curl" >&2; exit 127; }
      exec "$real" -sL -o "$out" "$url"
      ;;
esac
CURL_STUB
chmod +x "$WORK/bin/wget" "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"

export HIDDIFY_DIR="$DEV"
export HIDDIFY_DATA="$DEV/data"
cd "$DEV"

# shellcheck source=/dev/null
source scripts/common/package_manager.sh

OUT="$DEV/demo.bin"
rm -f "$OUT" "$DEV/data/packages.db"
: > "$DEV/data/packages.db"

echo "== T3-A first download =="
set +e
download_package demo "$OUT" "1.0.0"
rc=$?
set -e
if [[ $rc -eq 0 && -f "$OUT" && "$(generate_hash "$OUT")" == "$HASH_A" ]]; then
  ok "first download rc=0 and hash A"
else
  bad "first download rc=$rc file=$([[ -f $OUT ]] && echo yes || echo no)"
fi
# set -e 下对空记录调用必须返回 0 并写入（回归点：函数内 grep 未命中曾返回 1 而中断调用方）
set +e
set_installed_version demo "1.0.0"
sv_rc=$?
set -e
if [[ $sv_rc -eq 0 ]] && grep -q '^demo|1\.0\.0$' "$CURRENT_PACKAGES"; then
  ok "set_installed_version 空记录返回 0 并写入记录（set -e 安全）"
else
  bad "set_installed_version 空记录 rc=$sv_rc（期望 0）"
  echo "demo|1.0.0" >> "$CURRENT_PACKAGES"
fi

echo "== T3-B skip when intact =="
set +e
download_package demo "$OUT" "1.0.0"
rc=$?
set -e
if [[ $rc -eq 1 ]]; then ok "skip intact returns 1"; else bad "expected rc=1 got $rc"; fi

echo "== T3-C record exists, file missing =="
rm -f "$OUT"
set +e
download_package demo "$OUT" "1.0.0"
rc=$?
set -e
if [[ $rc -eq 0 && -f "$OUT" && "$(generate_hash "$OUT")" == "$HASH_A" ]]; then
  ok "restored missing binary"
else
  bad "missing restore rc=$rc"
fi

echo "== T3-D corrupt hash =="
printf 'corrupt' > "$OUT"
set +e
download_package demo "$OUT" "1.0.0"
rc=$?
set -e
if [[ $rc -eq 0 && "$(generate_hash "$OUT")" == "$HASH_A" ]]; then
  ok "corrupt file re-downloaded"
else
  bad "corrupt restore rc=$rc hash=$(generate_hash "$OUT" 2>/dev/null || true)"
fi

echo "== T3-E force =="
set +e
download_package demo "$OUT" "1.0.0" force
rc=$?
set -e
if [[ $rc -eq 0 && -f "$OUT" ]]; then ok "force re-download rc=0"; else bad "force rc=$rc"; fi

echo "== force as \$3 =="
set +e
download_package demo "$OUT" force
rc=$?
set -e
# force as $3 clears version -> latest in lock for arch = 1.0.1 (B)
if [[ $rc -eq 0 && "$(generate_hash "$OUT")" == "$HASH_B" ]]; then
  ok "force as 3rd arg downloads latest (1.0.1)"
else
  bad "force-as-\$3 rc=$rc hash=$(generate_hash "$OUT" 2>/dev/null || true) want B"
fi

echo "== set -u + two-arg call (no \$3/\$4) =="
# 上面 force 用例已把文件换成 1.0.1；运行期记录同步成 1.0.1，才会命中“已装且校验通过”分支
echo "demo|1.0.1" > "$CURRENT_PACKAGES"
set -u
set +e
download_package demo "$OUT"
rc=$?
set -e
# already at 1.0.1 with intact file -> skip rc=1
if [[ $rc -eq 1 ]]; then ok "two-arg under set -u skips intact"; else bad "two-arg set -u rc=$rc"; fi

echo "== marker (\$5): archive gone, binary still there =="
ARCH="$DEV/demo.tgz"
BIN="$DEV/demo.extracted"
# Git Bash/NTFS：纯数据文件即使用 chmod +x，[[ -x ]] 仍可能为假；写成带 shebang 的脚本更稳。
printf '#!/bin/sh\nexit 0\n' > "$BIN"
chmod +x "$BIN"
rm -f "$ARCH"
# pretend packages.db says 1.0.1 installed; marker is extracted binary
set_installed_version demo "1.0.1"
set +e
# version empty -> latest 1.0.1; force empty; marker = BIN
download_package demo "$ARCH" "1.0.1" "" "$BIN"
rc=$?
set -e
if [[ $rc -eq 1 && ! -f "$ARCH" ]]; then
  ok "marker skips when extracted binary exists (no re-download)"
else
  bad "marker skip rc=$rc arch_exists=$([[ -f $ARCH ]] && echo y || echo n)"
fi

echo "== marker: binary missing -> re-download archive =="
rm -f "$BIN" "$ARCH"
set +e
download_package demo "$ARCH" "1.0.1" "" "$BIN"
rc=$?
set -e
if [[ $rc -eq 0 && -f "$ARCH" && "$(generate_hash "$ARCH")" == "$HASH_B" ]]; then
  ok "marker missing triggers archive re-download"
else
  bad "marker restore rc=$rc"
fi

echo "== regex metacharacters: '1.0.0' must not match the look-alike '1x0y0' =="
cat > "$PACKAGES_LOCK" <<EOF2
mytool|1x0y0|amd64|$URL_A|$HASH_A
EOF2
set +e
add_out=$(add_package mytool "1.0.0" amd64 "$URL_A" 2>&1)
add_rc=$?
set -e
if [[ $add_rc -eq 0 ]] &&
   grep -Fxq "mytool|1x0y0|amd64|$URL_A|$HASH_A" "$PACKAGES_LOCK" &&
   grep -Fxq "mytool|1.0.0|amd64|$URL_A|$HASH_A" "$PACKAGES_LOCK"; then
  ok "add_package keeps the look-alike row and appends the real one"
else
  bad "add_package mangled the lock (rc=$add_rc)"
  echo "$add_out"
  cat "$PACKAGES_LOCK"
fi

echo "== package name prefix: demo2 must not inherit demo2-tool's version =="
cat > "$PACKAGES_LOCK" <<EOF2
demo2-tool|9.9.9|amd64|$URL_A|$HASH_A
demo2|1.0.0|amd64|$URL_A|$HASH_A
EOF2
echo "demo2-tool|9.9.9" > "$CURRENT_PACKAGES"
rm -f "$DEV/prefix.bin"
set +e
prefix_out=$(download_package demo2 "$DEV/prefix.bin" "1.0.0" 2>&1)
prefix_rc=$?
set -e
case "$prefix_out" in
  *9.9.9*) bad "prefix collision: existing_version borrowed from demo2-tool" ;;
  *)
    if [[ $prefix_rc -eq 0 && -f "$DEV/prefix.bin" ]]; then
      ok "prefix collision: only the exact package name is used"
    else
      bad "prefix collision rc=$prefix_rc"
    fi
    ;;
esac

echo "== arch must be matched as a field, not as a substring of the URL =="
cat > "$PACKAGES_LOCK" <<EOF2
foo|1.0.0|arm64|https://dl/amd64/foo.tgz|$HASH_A
EOF2
got=$(get_latest_version foo amd64)
if [[ -z "$got" ]]; then ok "get_latest_version ignores 'amd64' appearing inside the URL"; else bad "arch substring leak: '$got'"; fi
got=$(get_latest_version foo arm64)
if [[ "$got" == "1.0.0" ]]; then ok "get_latest_version still finds the arm64 row"; else bad "arm64 lookup got '$got'"; fi

echo "== get_latest_version without arch returns the highest version =="
cat > "$PACKAGES_LOCK" <<EOF2
bar|1.0.0|amd64|$URL_A|$HASH_A
bar|2.0.0|arm64|$URL_A|$HASH_A
EOF2
got=$(get_latest_version bar)
if [[ "$got" == "2.0.0" ]]; then ok "no-arch lookup returns the highest version"; else bad "no-arch lookup got '$got'"; fi

echo "== arch=both writes one row per architecture =="
: > "$PACKAGES_LOCK"
set +e
add_package bothpkg "1.0.0" both "$URL_A" >/dev/null 2>&1
set -e
if grep -Fxq "bothpkg|1.0.0|amd64|$URL_A|$HASH_A" "$PACKAGES_LOCK" &&
   grep -Fxq "bothpkg|1.0.0|arm64|$URL_A|$HASH_A" "$PACKAGES_LOCK"; then
  ok "arch=both expands to amd64 + arm64"
else
  bad "arch=both rows missing"
  cat "$PACKAGES_LOCK"
fi

echo
echo "================ summary ================"
echo "pass=$PASS fail=$FAIL"
[[ "$FAIL" -eq 0 ]]
