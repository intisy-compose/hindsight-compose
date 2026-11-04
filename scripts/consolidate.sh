#!/usr/bin/env bash
# consolidate.sh [--run-immediately] [--poll-seconds N]: the bash twin of consolidate.ps1. Runs one
# Hindsight consolidation pass to completion, then returns the stack to retain-only mode, so
# consolidation never competes with live retains on the single GPU. By default it first waits for the
# retain queue to drain; --run-immediately starts at once. --poll-seconds is how often the operation
# counts are read (default 30).
set -euo pipefail
# shellcheck source=scripts/stack.sh
. "$(dirname "$0")/stack.sh"

usage_line="Usage: ./docker-compose.sh consolidate [--run-immediately] [--poll-seconds N]"
operations_url="http://localhost:8888/v1/default/banks/claude_code/operations"
health_url="http://localhost:8888/health"
run_immediately=false
poll_seconds=30

while [ $# -gt 0 ]; do
    case "$1" in
        --run-immediately) run_immediately=true; shift ;;
        --poll-seconds)
            { [ $# -ge 2 ] && is_count "$2" 1; } || fail "$usage_line"
            poll_seconds=$2
            shift 2 ;;
        *) fail "$usage_line" ;;
    esac
done

# The stack's own compose file, not docker-compose.hindsight-only.yml: that one points hindsight at a
# llama on the host, which only the Windows native mode has.
compose_file=$(gpu_compose_file)
[ -n "$compose_file" ] || fail "No supported GPU found (need NVIDIA via nvidia-smi), so the stack's compose file is unknown."

# operation_counts: "RETAINS CONSOLIDATIONS", the pending or processing operations of each kind.
operation_counts() {
    local listing
    listing=$(curl -fsS -m 30 "$operations_url?limit=200") || fail "Hindsight's operations could not be read from $operations_url."
    python3 -c 'import json, sys
operations = json.load(sys.stdin).get("operations") or []
active = ("pending", "processing")
retains = sum(1 for o in operations if "retain" in (o.get("task_type") or "") and o.get("status") in active)
consolidations = sum(1 for o in operations if o.get("task_type") == "consolidation" and o.get("status") in active)
print(retains, consolidations)' <<<"$listing" | tr -d '\r'
}

# restart_hindsight SLOTS: recreates hindsight with SLOTS consolidation worker slots and waits for it.
# db-backup is recreated with it because it lives in hindsight's network namespace: left alone, it stays
# in the old container's dead namespace and every dump fails until the next start.
restart_hindsight() {
    HINDSIGHT_CONSOLIDATION_SLOTS=$1 compose_with "$compose_file" up -d hindsight db-backup >/dev/null 2>&1 || true
    for _ in $(seq 40); do
        [ "$(http_status "$health_url")" != 200 ] || return 0
        sleep 3
    done
    fail "Hindsight did not become healthy after restart."
}

# Free any consolidation op a previous (now-gone) worker left in 'processing'.
reset_stale_consolidation() {
    docker exec -i "$server_container" python3 - <<'EOF'
import asyncio, asyncpg
async def run():
    c = await asyncpg.connect("postgresql://hindsight:hindsight@127.0.0.1:5432/hindsight")
    r = await c.execute("UPDATE async_operations SET status='pending', worker_id=NULL, claimed_at=NULL WHERE status='processing' AND operation_type='consolidation' AND task_payload IS NOT NULL")
    print("reset stale consolidation:", r)
    await c.close()
asyncio.run(run())
EOF
}

wait_for_retains() {
    local counts
    step "Waiting for live retains to finish before consolidating..."
    while true; do
        counts=$(operation_counts)
        [ "${counts% *}" -gt 0 ] || break
        info "retains still pending: ${counts% *}"
        sleep "$poll_seconds"
    done
    ok "Retain queue empty."
}

# Two consecutive empty polls are required, because Hindsight briefly has 0 ops between batches.
consolidate_to_completion() {
    local empty_streak=0 counts retains consolidations
    step "Consolidating to completion (polling every ${poll_seconds}s)..."
    while [ "$empty_streak" -lt 2 ]; do
        sleep "$poll_seconds"
        counts=$(operation_counts)
        retains=${counts% *}
        consolidations=${counts#* }
        info "consolidation pending/processing: $consolidations  (retains waiting: $retains)"
        if [ "$consolidations" -eq 0 ]; then empty_streak=$((empty_streak + 1)); else empty_streak=0; fi
    done
}

$run_immediately || wait_for_retains

step "Enabling consolidation (dedicated pass)..."
restart_hindsight 1
reset_stale_consolidation

consolidate_to_completion

step "Consolidation complete -returning to retain-only mode..."
restart_hindsight 0
ok "Done. Consolidation cleared; retains have the GPU again."
