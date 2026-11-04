#!/usr/bin/env bash
# restore.sh [--file dump.sql] [--database name]: the bash twin of restore.ps1. Restores the Hindsight
# database from a host-side SQL dump written by the db-backup sidecar, the newest restorable one in
# data/hindsight by default, into hindsight by default or another existing database of the same
# Postgres. The dump is applied in one transaction and psql stops at the first error, so a failed
# restore leaves the database as it was and exits 1 with psql's error lines.
set -euo pipefail
scripts=$(dirname "$0")
# shellcheck source=scripts/stack.sh
. "$scripts/stack.sh"
# shellcheck source=scripts/data-on-disk.sh
. "$scripts/data-on-disk.sh"

usage_line="Usage: ./docker-compose.sh restore [--file dump.sql] [--database name]"
backup_folder="$stack_root/data/hindsight"
dump_pattern="hindsight-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].sql"
container_dump="/tmp/hindsight-restore.sql"
error_line_pattern="ERROR|FATAL|psql: error"
dump_trailer="PostgreSQL database dump complete"
file=""
database="hindsight"

while [ $# -gt 0 ]; do
    case "$1" in
        --file | --database)
            [ $# -ge 2 ] && [ -n "$2" ] && [[ $2 != -* ]] || fail "$usage_line"
            if [ "$1" = --file ]; then file=$2; else database=$2; fi
            shift 2 ;;
        *) fail "$usage_line" ;;
    esac
done
[[ $database != *=* ]] || fail "$usage_line"

# get_dump_rejection PATH: why the dump cannot be restored, or nothing. `--clean` drops every table
# first, so a dump that is cut short at a statement boundary, or holds no memory, would commit an empty
# database: it must end with pg_dump's trailer and hold at least one row of public.memory_units.
get_dump_rejection() {
    local path=$1 rows_exit=0
    if ! tail -c 400 "$path" | grep -qF "$dump_trailer"; then
        echo "it does not end with '$dump_trailer', so it is cut short or not a pg_dump"
        return 0
    fi
    awk 'found { row = ($0 != "\\."); done = 1; exit }
         /^COPY public\.memory_units / { found = 1 }
         END { if (!done) exit 2; exit (row ? 0 : 1) }' "$path" || rows_exit=$?
    case "$rows_exit" in
        0) ;;
        1) echo "its public.memory_units holds no rows" ;;
        *) echo "it holds no data for public.memory_units" ;;
    esac
}

# resolve_dump_file PATH: PATH, or the newest restorable dump when PATH is empty; fails unless the dump
# exists and passes get_dump_rejection, before anything is copied.
resolve_dump_file() {
    local path=$1 dumps name reason last_rejection=""
    if [ -n "$path" ]; then
        [ -f "$path" ] || fail "Backup not found: $path"
        reason=$(get_dump_rejection "$path")
        [ -z "$reason" ] || fail "${path##*/} cannot be restored: $reason; nothing was copied."
        native_path "$path"
        return 0
    fi
    dumps=$(complete_dumps "$backup_folder" "$dump_pattern") || fail "Cannot list $backup_folder"
    [ -n "$dumps" ] || fail "No backups found in $backup_folder"
    while IFS= read -r name; do
        reason=$(get_dump_rejection "$backup_folder/$name")
        if [ -z "$reason" ]; then native_path "$backup_folder/$name"; return 0; fi
        info "skipping $name: $reason" >&2
        last_rejection="$name: $reason"
    done <<<"$dumps"
    fail "No dump in $backup_folder can be restored; the last one checked, $last_rejection."
}

# run_psql_restore DATABASE: pg0's psql on the copied dump. The password comes from this process's
# environment, so it never reaches a command line, and the database name is an argument, never shell text.
run_psql_restore() {
    # shellcheck disable=SC2016 # the container's shell expands it
    PGPASSWORD=hindsight docker exec -e PGPASSWORD "$server_container" sh -c \
        'exec "$(ls -d /home/hindsight/.pg0/installation/*/bin/psql | head -n 1)" "$@"' psql \
        -h 127.0.0.1 -U hindsight -d "$1" -v ON_ERROR_STOP=1 --single-transaction -f "$container_dump" 2>&1
}

# docker cp leaves the file owned by root in the sticky /tmp, where the hindsight user cannot delete it.
remove_container_dump() {
    local output
    output=$(docker exec -u root "$server_container" rm -f "$container_dump" 2>&1) ||
        err "  Could not remove $container_dump from $server_container: $output"
}

report_failed_restore() {
    local output=$1 exit_code=$2 error_lines
    error_lines=$(grep -E "$error_line_pattern" <<<"$output" || true)
    [ -n "$error_lines" ] || error_lines=$(tail -n 10 <<<"$output")
    while IFS= read -r line; do err "  $line"; done <<<"$error_lines"
    fail "  Restore FAILED: psql exited with $exit_code; nothing was committed, '$database' is unchanged."
}

file=$(resolve_dump_file "$file")
container_is_running "$server_container" || fail "hindsight container is not running. Start the stack first."

step "Restoring Hindsight DB '$database' from $file ..."
if [ "$database" = hindsight ]; then
    info "This is the live database: writes made while it restores are lost, and hindsight needs a restart afterwards."
fi
trap 'remove_container_dump; exit 130' INT TERM
if ! copy_output=$(docker cp "$file" "$server_container:$container_dump" 2>&1); then
    while IFS= read -r line; do err "  $line"; done <<<"$copy_output"
    remove_container_dump
    fail "Copying the dump into $server_container failed"
fi
restore_exit=0
restore_output=$(run_psql_restore "$database") || restore_exit=$?
trap - INT TERM
remove_container_dump

[ "$restore_exit" -eq 0 ] || report_failed_restore "$restore_output" "$restore_exit"
grep -E "COPY|INSERT 0" <<<"$restore_output" | tail -n 10 | sed 's/^/  /' || true
ok "Restore finished. Restart hindsight to load the restored data cleanly: docker restart $server_container"
