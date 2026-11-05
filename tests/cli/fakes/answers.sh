#!/bin/bash
# shellcheck disable=SC2154 # state is set by the fake docker, which sources this
# The fake docker's answers, keyed on the command. Its state is a folder of small files, each written
# by the test that needs it and read here with a default:
#   running          the containers `docker ps` reports as running, one per line (default none)
#   tailnet          running | stopped (default running): what `tailscale status --json` reports
#   images-present   yes | no (default yes): the hindsight image is in `docker image ls`
#   counts, counts-N the table counts psql prints, "schema.table|count" lines; the Nth count call
#                    answers counts-N when it exists, else counts
#   psql-output      what the restoring psql prints (default two COPY lines)
#   psql-hold        present: the restoring psql waits for release (see hold_psql)
#   up-exit, pull-exit, down-exit-<compose file>, load-exit, cp-exit, psql-exit, cleanup-exit,
#   fresh-dump-exit, volume-rm-exit, counts-exit-N, pg-isready-exit: exit codes (default 0)
# A compose `up -d hindsight` appends its HINDSIGHT_CONSOLIDATION_SLOTS to slots; every compose up of
# hindsight, alone or with the stack, appends its HINDSIGHT_WRITERS to writers; a psql exec notes in
# pgpassword whether PGPASSWORD reached it through the environment.

state_value() { cat "$state/$1" 2>/dev/null || echo "${2:-}"; }

answer_running() {
    local name=${1#name=^}
    name=${name%$}
    grep -qxF -- "$name" "$state/running" 2>/dev/null && echo "0123456789ab"
    return 0
}

answer_tailnet_status() {
    if [ "$(state_value tailnet running)" = running ]; then
        echo '{"BackendState": "Running", "Self": {"DNSName": "hindsight.tail-test.ts.net."}}'
    else
        echo '{"BackendState": "NeedsLogin", "Self": {"DNSName": ""}}'
    fi
}

answer_images() {
    case "$1" in
        docker-compose.nvidia.yml)
            printf '%s\n' ghcr.io/vectorize-io/hindsight:0.8.2 postgres:18.4-alpine ghcr.io/ggml-org/llama.cpp:server-cuda-b9641 caddy:2.11.4-alpine tailscale/tailscale:v1.102.4 ;;
        *)
            printf '%s\n' ghcr.io/vectorize-io/hindsight:0.8.2 postgres:18.4-alpine alpine:3.24.2 caddy:2.11.4-alpine tailscale/tailscale:v1.102.4 ;;
    esac
}

answer_counts() {
    local call
    call=$(($(state_value count-calls 0) + 1))
    echo "$call" >"$state/count-calls"
    [ "$(state_value "counts-exit-$call" 0)" -eq 0 ] || return "$(state_value "counts-exit-$call")"
    if [ -f "$state/counts-$call" ]; then cat "$state/counts-$call"; else state_value counts "public.memory_units|5"; fi
}

# hold_psql: with psql-hold set, notes psql-started and waits up to 10 s for release, so a test can
# signal the restore while psql runs.
hold_psql() {
    [ -f "$state/psql-hold" ] || return 0
    : >"$state/psql-started"
    for _ in $(seq 100); do
        [ ! -e "$state/release" ] || return 0
        "${REAL_SLEEP:?}" 0.1
    done
}

answer_psql_restore() {
    hold_psql
    echo "${PGPASSWORD:+set}" >"$state/pgpassword"
    state_value psql-output "$(printf '%s\n' 'SET' 'COPY 12' 'COPY 5')"
    return "$(state_value psql-exit 0)"
}

answer() {
    case "$*" in
        "ps -q --filter "*) answer_running "$4" ;;
        "image ls --format "*) [ "$(state_value images-present yes)" = no ] || echo "ghcr.io/vectorize-io/hindsight:0.8.2" ;;
        "compose -f "*" exec -T tailscale "*) answer_tailnet_status ;;
        "compose -f "*" config --images") answer_images "$3" ;;
        "compose -f "*" up -d --remove-orphans")
            echo "${HINDSIGHT_WRITERS-unset}" >>"$state/writers"
            return "$(state_value up-exit 0)" ;;
        "compose -f "*" up -d hindsight")
            echo "${HINDSIGHT_CONSOLIDATION_SLOTS-unset}" >>"$state/slots"
            echo "${HINDSIGHT_WRITERS-unset}" >>"$state/writers" ;;
        "compose -f "*" pull") return "$(state_value pull-exit 0)" ;;
        "compose -f "*" down") return "$(state_value "down-exit-$3" 0)" ;;
        "load -i "*) return "$(state_value load-exit 0)" ;;
        "save -o "*) printf 'tar' >"$3" ;;
        "cp "*) return "$(state_value cp-exit 0)" ;;
        "exec -e PGPASSWORD hindsight-server sh -c "*) answer_psql_restore ;;
        "exec -u root hindsight-server rm -f "*) return "$(state_value cleanup-exit 0)" ;;
        "exec -i hindsight-server python3 -") cat >/dev/null; echo "reset stale consolidation: UPDATE 0" ;;
        "exec hindsight-db-backup sh -c "*) return "$(state_value fresh-dump-exit 0)" ;;
        "exec hindsight-db-backup psql "*) answer_counts ;;
        "exec hindsight-db-backup pg_isready "*) return "$(state_value pg-isready-exit 0)" ;;
        "volume rm "*) return "$(state_value volume-rm-exit 0)" ;;
        *) return 0 ;;
    esac
}
