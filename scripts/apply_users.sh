#!/bin/bash
# Regenerate the configs that change with the user list, then reload those services.
# $1: "domain" (domains changed: telemt restarts) or "users" (only users changed: xray gets them from the panel live).
# Output and errors are kept in the log dir: apply-users.out.log and apply-users.err.log.
cd /opt/hiddify-manager
source /opt/hiddify-manager/scripts/common/utils.sh

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run by root" >&2
    exit 1
fi

apply_users() {
    ensure_generated_permissions
    echo "Dumping user configs into $HIDDIFY_GENERATED"
    dump_server_configs "xray,hiddify-core,wireguard,telemt" || {
        echo "Failed to dump user configs into $HIDDIFY_GENERATED" >&2
        return 1
    }
    echo "Reloading services"
    ensure_generated_permissions
    local pids=() rc=0 pid
    for svc in xray hiddify-core wireguard telegram/telemt; do 
        echo "Reloading $svc"
        run_timed "$svc" bash "$HIDDIFY_SERVICES/$svc/reload.sh" "$1" &
        pids+=("$!")
    done
    echo "Waiting for services to reload"
    # A bare `wait` returns 0 even when a reload failed: wait on each pid and keep the worst result.
    for pid in "${pids[@]}"; do
        wait "$pid" || rc=1
    done
    if [ "$rc" -ne 0 ]; then
        echo "Some services failed to reload; the configs on disk are newer than what they serve" >&2
        return 1
    fi
    echo "Services reloaded"
}

# Same mutex as install/update: two concurrent runs would both rewrite generated/ and restart services.
with_lock apply-users run_logged apply-users apply_users "$1"
