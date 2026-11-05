#!/bin/sh
# db-backup.sh run | dump: the db-backup sidecar's program, run by its busybox sh. "run" restores the
# newest dump into an empty database, then dumps every quarter-hour into $backups and prunes the dumps;
# "dump" writes one dump and prints its name, which is how prove-data dumps. Sourced without either,
# it only defines the functions, which is how the tests call them.

backups=${BACKUPS:-/backups}
# A dump writes all the time, so a .tmp unchanged this long is left by a crash, whoever wrote it.
stale_tmp_minutes=${STALE_TMP_MINUTES:-10}

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$backups/backup.log"; }

# is_held_open FILE: a process of this container (the loop, or prove-data's exec) has FILE open.
is_held_open() {
  for descriptor in /proc/[0-9]*/fd/*; do
    [ "$(readlink "$descriptor" 2>/dev/null)" = "$1" ] && return 0
  done
  return 1
}

is_being_written() {
  is_held_open "$1" || [ -n "$(find "$1" -mmin "-$stale_tmp_minutes" 2>/dev/null)" ]
}

# Tiered (GFS) retention: keep newest 4, then 1/hour (<1d), 1/day (<1wk),
# 1/week (<4wk), 1/month (>=4wk). Keeps the newest backup in each period.
prune() {
  for f in "$backups"/hindsight-*.sql.tmp; do
    [ -e "$f" ] || continue
    is_being_written "$f" && continue
    log "deleted stale $(basename "$f")"
    rm -f "$f"
  done
  now=$(date +%s); i=0; seen=" "
  for f in $(printf '%s\n' "$backups"/hindsight-*.sql | sort -r); do
    [ -e "$f" ] || continue
    i=$((i+1)); [ "$i" -le 4 ] && continue
    b=$(basename "$f" .sql); ts=${b#hindsight-}
    ymd=${ts%-*}; hms=${ts#*-}; hh=${hms%????}
    fe=$(date -D "%Y%m%d-%H%M%S" -d "$ts" +%s 2>/dev/null); [ -z "$fe" ] && continue
    age=$((now - fe))
    if   [ "$age" -lt 86400 ];   then key="H$ymd$hh"
    elif [ "$age" -lt 604800 ];  then key="D$ymd"
    elif [ "$age" -lt 2419200 ]; then key="W$((fe/604800))"
    else key="M$((fe/2419200))"; fi
    case "$seen" in *" $key "*) log "deleted $(basename "$f")"; rm -f "$f" ;; *) seen="$seen$key " ;; esac
  done
}

# Self-heal stuck ops: a container restart leaves in-flight ops marked 'processing'
# under the old (now-dead) worker id; nothing reclaims them and they wedge the worker
# slot. Reset anything stuck in 'processing' with no update for >45 min back to pending.
reap() {
  n=$(psql -h 127.0.0.1 -U hindsight -d hindsight -tAc "WITH r AS (UPDATE async_operations SET status='pending', worker_id=NULL, claimed_at=NULL WHERE status='processing' AND updated_at < now() - interval '45 minutes' RETURNING 1) SELECT count(*) FROM r" 2>/dev/null)
  [ -n "$n" ] && [ "$n" != "0" ] && log "reaped $n stuck processing op(s) -> pending"
  return 0
}

# Self-heal: if the DB came up empty (e.g. volume deleted / Docker reinstalled) and a
# backup exists, restore the newest one automatically - no manual restore step needed.
restore_if_empty() {
  until pg_isready -h 127.0.0.1 -U hindsight -d hindsight >/dev/null 2>&1; do sleep 2; done
  cnt=""; n=0
  while [ "$n" -lt 60 ]; do
    cnt=$(psql -h 127.0.0.1 -U hindsight -d hindsight -tAc "SELECT count(*) FROM memory_units" 2>/dev/null) && break
    n=$((n+1)); sleep 3
  done
  # shellcheck disable=SC2012 # dump names are hindsight-<timestamp>.sql, and the newest by mtime is wanted
  latest=$(ls -1t "$backups"/hindsight-*.sql 2>/dev/null | head -1)
  if [ "$cnt" = "0" ] && [ -n "$latest" ]; then
    echo "[restore] empty DB + backup present -> restoring $latest"
    psql -h 127.0.0.1 -U hindsight -d hindsight -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='hindsight' AND pid <> pg_backend_pid()" >/dev/null 2>&1
    dd if="$latest" bs=1M 2>/dev/null | psql -h 127.0.0.1 -U hindsight -d hindsight --single-transaction -f - > "$backups/last-restore.log" 2>&1
    psql -h 127.0.0.1 -U hindsight -d hindsight -c "UPDATE async_operations SET status='pending', worker_id=NULL, claimed_at=NULL WHERE status='processing' AND task_payload IS NOT NULL" >> "$backups/last-restore.log" 2>&1
    echo "[restore] complete"
  fi
}

dump_to() {
  # shellcheck disable=SC3040 # busybox ash, the sidecar's sh, has pipefail
  (set -o pipefail; pg_dump -h 127.0.0.1 -U hindsight -d hindsight --no-owner --clean --if-exists 2> "$backups/last-error.log" | dd obs=1M of="$1" 2>/dev/null)
}

# dump_once: one dump, named hindsight-<UTC timestamp>.sql only once complete. musl's stdio moves
# 1 KiB per call, which crawls over Docker Desktop's file sharing, so dd writes 1 MiB blocks (and the
# restore above reads them).
dump_once() {
  ts=$(date +%Y%m%d-%H%M%S)
  if dump_to "$backups/hindsight-$ts.sql.tmp"; then
    mv "$backups/hindsight-$ts.sql.tmp" "$backups/hindsight-$ts.sql"
    log "created hindsight-$ts.sql"
    echo "hindsight-$ts.sql"
  else
    rm -f "$backups/hindsight-$ts.sql.tmp"
    log "FAILED hindsight-$ts.sql"
    return 1
  fi
}

run() {
  restore_if_empty
  prune
  reap
  while true; do
    # Align to the next wall-clock quarter-hour (:00 :15 :30 :45) instead of drifting.
    now=$(date +%s); sleep $(( 900 - (now % 900) ))
    dump_once >/dev/null || true
    prune
    reap
  done
}

case "${1:-}" in
  run) run ;;
  dump) dump_once ;;
esac
