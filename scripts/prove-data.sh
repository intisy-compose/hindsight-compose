#!/usr/bin/env bash
# prove-data.sh: the bash twin of prove-data.ps1. Proves that a deleted database volume comes back:
# count every table, stop the stack, delete the pg0 volume, start the stack, wait for the self-restore,
# count again. Any difference exits 1. DESTRUCTIVE: it deletes the database volume, so run it only with
# the owner's go-ahead.
#
# The stack must be running (hindsight-server and hindsight-db-backup), because the counts come from
# the embedded Postgres. The restore itself is the db-backup sidecar's restore_if_empty, which reads
# the newest dump from data/hindsight; a fresh dump is always written right before the "before" count,
# so writes after an older dump cannot look like a failed restore. For the whole run hindsight runs with
# HINDSIGHT_WRITERS=false (no worker, no audit log, no LLM trace), so consolidation and retains do not
# change the tables between the counts; they are back on at the end, failed or not. The wait ends when
# public.memory_units is non-empty. public.async_operations is printed but not compared, because the
# restore rewrites it (processing back to pending) and a retain request still queues into it while the
# worker is off.
set -euo pipefail
scripts=$(dirname "$0")
# shellcheck source=scripts/stack.sh
. "$scripts/stack.sh"
# shellcheck source=scripts/data-on-disk.sh
. "$scripts/data-on-disk.sh"

[ $# -eq 0 ] || fail "Usage: ./docker-compose.sh prove-data"

# The pinned `name:` must win, because the volume deleted below is named after that project.
unset COMPOSE_PROJECT_NAME

dump_folder="$stack_root/data/hindsight"
pg0_volume="hindsight-compose_hindsight-pg0"
uncompared_tables=(public.async_operations)
restore_timeout_seconds=$((60 * 60))
writers_paused_tries=300
memory_table="public.memory_units"

# hindsight_table_counts: "schema.table|count" lines, read through the db-backup sidecar's psql, which
# shares pg0's network and has its password in its environment, so none reaches a command line.
hindsight_table_counts() { table_row_counts "$backup_container" 127.0.0.1 hindsight hindsight; }

count_lines() { grep -c . <<<"$1" || true; }

# table_count LINES TABLE: TABLE's count in "schema.table|count" LINES, or nothing.
table_count() { sed -n "s/^${2//./\\.}|//p" <<<"$1" | head -n 1; }

# invoke_stack VERB: runs a docker-compose.sh verb; only "stop" has its exit code trusted, because
# "start" is judged by the wait for the restore and the counts that follow it.
invoke_stack() {
    local verb=$1 stack_exit=0
    bash "$stack_root/docker-compose.sh" "$verb" || stack_exit=$?
    if [ "$verb" = stop ] && [ "$stack_exit" -ne 0 ]; then fail "docker-compose.sh stop failed with exit code $stack_exit"; fi
}

write_recovery_hint() {
    err "$pg0_volume was deleted. Recover with: ./docker-compose.sh start   then, if $memory_table stays empty,   ./docker-compose.sh restore --file data/hindsight/$1"
}

write_fresh_dump() {
    # shellcheck disable=SC2016 # the sidecar's shell expands it
    docker exec "$backup_container" sh -c 'timestamp=$(date +%Y%m%d-%H%M%S); pg_dump -h 127.0.0.1 -U hindsight -d hindsight --no-owner --clean --if-exists > /backups/hindsight-$timestamp.sql.tmp && mv /backups/hindsight-$timestamp.sql.tmp /backups/hindsight-$timestamp.sql' ||
        fail "the fresh dump failed"
}

# wait_for_restore: until memory_units holds rows, at most restore_timeout_seconds.
wait_for_restore() {
    local deadline=$((SECONDS + restore_timeout_seconds)) counts
    for _ in $(seq $((restore_timeout_seconds / 15))); do
        [ "$SECONDS" -lt "$deadline" ] || break
        sleep 15
        if counts=$(hindsight_table_counts 2>/dev/null); then
            [ "$(table_count "$counts" "$memory_table")" -gt 0 ] 2>/dev/null && return 0
        else
            info "database not answering yet"
        fi
    done
    err "$memory_table stayed empty for $((restore_timeout_seconds / 60)) minutes"
    return 1
}

# compare_table_counts BEFORE AFTER: one "name before=N after=M" line per table whose counts differ,
# the uncompared tables left out; nothing when they match.
compare_table_counts() {
    local name before_count after_count
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        [[ " ${uncompared_tables[*]} " != *" $name "* ]] || continue
        before_count=$(table_count "$1" "$name")
        after_count=$(table_count "$2" "$name")
        [ "${before_count:-missing}" = "${after_count:-missing}" ] ||
            echo "$name before=${before_count:-missing} after=${after_count:-missing}"
    done < <(printf '%s\n%s\n' "$1" "$2" | cut -d'|' -f1 | LC_ALL=C sort -u)
}

write_uncompared_counts() {
    local name before_count after_count
    for name in "${uncompared_tables[@]}"; do
        before_count=$(table_count "$1" "$name")
        after_count=$(table_count "$2" "$name")
        info "$name (not compared) before=${before_count:-missing} after=${after_count:-missing}"
    done
}

# set_writers true|false: recreates hindsight with its worker, audit log and LLM trace on or off.
set_writers() {
    if [ "$1" = false ]; then export HINDSIGHT_WRITERS=false; else unset HINDSIGHT_WRITERS; fi
    restart_hindsight "$compose_file" "$writers_paused_tries"
}

# resume_writers: the EXIT trap once the writers are paused, so a failed run never leaves the stack
# without its worker. When it fails itself the run fails, whatever it found.
resume_writers() {
    local run_exit=$?
    trap - EXIT
    step "Resuming hindsight's writers ..."
    if ! (set_writers true); then
        err "Run './docker-compose.sh start' to bring the stack back with its writers."
        [ "$run_exit" -ne 0 ] || run_exit=1
    fi
    exit "$run_exit"
}

for container in "$server_container" "$backup_container"; do
    container_is_running "$container" ||
        fail "$container is not running; start the stack first (both $server_container and $backup_container must be up)"
done
compose_file=$(gpu_compose_file)
[ -n "$compose_file" ] || fail "No supported GPU found (need NVIDIA via nvidia-smi), so the stack's compose file is unknown."

trap resume_writers EXIT
step "Pausing hindsight's writers (worker, audit log, LLM trace) for the run ..."
set_writers false

step "Writing a fresh dump ..."
write_fresh_dump
newest=$(newest_dump "$dump_folder" "hindsight-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].sql") || fail "$dump_folder cannot be listed"
[ -n "$newest" ] || fail "no complete dump exists in $dump_folder"
info "dump $newest"

step "Counting rows before ..."
before=$(hindsight_table_counts) || fail "the rows could not be counted; nothing was deleted"
[ "$(count_lines "$before")" -gt 0 ] || fail "no table was counted; nothing was deleted"
info "$(count_lines "$before") tables, $memory_table = $(table_count "$before" "$memory_table")"

step "Stopping the stack and deleting $pg0_volume ..."
invoke_stack stop
docker volume rm "$pg0_volume" || fail "could not remove $pg0_volume"

step "Starting the stack and waiting for the self-restore ..."
invoke_stack start
if ! wait_for_restore; then write_recovery_hint "$newest"; exit 1; fi

step "Counting rows after ..."
if ! after=$(hindsight_table_counts); then write_recovery_hint "$newest"; exit 1; fi
write_uncompared_counts "$before" "$after"
differences=$(compare_table_counts "$before" "$after")
if [ -n "$differences" ]; then
    while IFS= read -r line; do err "  DIFFERS $line"; done <<<"$differences"
    write_recovery_hint "$newest"
    exit 1
fi
ok "all $(count_lines "$after") tables match"
