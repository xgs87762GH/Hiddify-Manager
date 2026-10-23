#!/bin/bash
# Self-check for config_check_ok (the guard that stops a broken generated config from
# reloading hiddify-core / xray): bash scripts/common/test_utils.sh
set -e
eval "$(sed -n '/^function config_check_ok/,/^}/p' "$(dirname -- "$0")/utils.sh")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cfg="$tmp/generated.json"
echo '{}' >"$cfg"

fail=0
check() { # check <label> <expected-rc> <actual-rc>
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1: expected rc=$2 got rc=$3"
        fail=1
    fi
}

# 1. valid config -> reload allowed
cat >"$tmp/good" <<'EOS'
#!/bin/bash
exit 0
EOS
chmod +x "$tmp/good"
rc=0
config_check_ok good "$cfg" "$tmp/good" >"$tmp/out" 2>&1 || rc=$?
check "valid config passes" 0 $rc

# 2. invalid config -> reload refused, checker output surfaced
cat >"$tmp/bad" <<'EOS'
#!/bin/bash
echo "invalid inbound: port already in use" >&2
exit 1
EOS
chmod +x "$tmp/bad"
rc=0
config_check_ok bad "$cfg" "$tmp/bad" >"$tmp/out" 2>&1 || rc=$?
check "broken config is refused" 1 $rc
grep -q "do not reload" "$tmp/out" && grep -q "port already in use" "$tmp/out" || { echo "FAIL: error output not surfaced"; cat "$tmp/out"; fail=1; }

# 3. checker binary missing -> must not block a reload
rc=0
config_check_ok missing "$cfg" "$tmp/nope-does-not-exist" >"$tmp/out" 2>&1 || rc=$?
check "missing checker does not block" 0 $rc
grep -q "unavailable" "$tmp/out" || { echo "FAIL: no unavailable notice"; cat "$tmp/out"; fail=1; }

# 4. checker reports usage / unknown subcommand -> treat as broken checker, not broken config
for marker in "unknown command 'check'" "invalid choice: 'check'" "usage: hiddify-core [options]" "flag provided but not defined: -test"; do
    cat >"$tmp/usage" <<EOS
#!/bin/bash
echo "$marker"
exit 2
EOS
    chmod +x "$tmp/usage"
    rc=0
    config_check_ok usage "$cfg" "$tmp/usage" >"$tmp/out" 2>&1 || rc=$?
    check "usage error ($marker) does not block" 0 $rc
done

# 5. config not generated yet -> skip the check, do not block
rm -f "$cfg"
rc=0
config_check_ok absent "$cfg" "$tmp/bad" >"$tmp/out" 2>&1 || rc=$?
check "absent config file does not block" 0 $rc
grep -q "does not exist yet" "$tmp/out" || { echo "FAIL: no skip notice"; cat "$tmp/out"; fail=1; }

if [ $fail -eq 0 ]; then echo ok; else exit 1; fi
