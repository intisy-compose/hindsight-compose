#!/usr/bin/env bash
# shellcheck disable=SC2016 # fixtures and patterns hold a literal $
# The Linux CLI's tests: each case copies the CLI into a scratch stack and runs it against a fake
# docker, curl, git, nvidia-smi and sleep first on PATH, so nothing on the host is touched and no wait
# takes real time. Run it from a worktree or CI, never the live stack folder.
# Plain bash: an `ok` or `FAIL` line per case, non-zero exit on any failure.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repository=$(cd "$here/../.." && pwd)
fakes="$here/fakes"
scratch=$(mktemp -d)
stack="$scratch/hindsight-compose"
state="$scratch/state"
home="$scratch/home"
caller="$scratch/caller"
trap 'rm -rf "$scratch"' EXIT

failures=0
case_name=""
case_failed=false
output=""
status=0

new_stack() {
    rm -rf "$stack" "$state" "$home" "$caller"
    mkdir -p "$stack/scripts" "$stack/data/llama" "$stack/data/hindsight" "$state" "$home/.claude/projects" "$caller"
    cp "$repository/docker-compose.sh" "$repository"/docker-compose*.yml "$repository/config.env.example" "$stack/"
    cp "$repository"/scripts/*.sh "$stack/scripts/"
    : >"$stack/data/llama/Qwen2.5-7B-Instruct-Q4_K_M.gguf"
    : >"$state/calls"
    stack_native=$stack
    scratch_native=$scratch
    if [ -n "${MSYSTEM:-}" ]; then stack_native=$(cd "$stack" && pwd -W); scratch_native=$(cd "$scratch" && pwd -W); fi
    write_config
}

write_config() {
    printf '%s\n' DOCKER_LLAMA=true GPU_TYPE=cuda MODEL_FILE=Qwen2.5-7B-Instruct-Q4_K_M.gguf LLAMA_PORT=11434 \
        TS_AUTHKEY=tskey-test HINDSIGHT_HOST= PUBLIC_ACCESS=false >"$stack/config.env"
}

begin() {
    case_name=$1
    case_failed=false
    output=""
    new_stack
}

finish() {
    if $case_failed; then
        failures=$((failures + 1))
        printf '     %s\n' "${output//$'\n'/$'\n'     }"
    else
        echo "ok   $case_name"
    fi
}

# run_cli ARGUMENTS...: runs the scratch CLI with the fakes from $caller, keeping its output and exit code.
run_cli() {
    output=$(cd "$caller" && HOME="$home" PATH="$fakes:$PATH" FAKE_DOCKER_DIR="$state" \
        bash "$stack/docker-compose.sh" "$@" 2>&1)
    status=$?
}

check() {
    local description=$1
    shift
    if ! "$@"; then
        $case_failed || echo "FAIL $case_name"
        echo "     - $description"
        case_failed=true
    fi
}

status_is() { [ "$status" -eq "$1" ]; }
said() { grep -qF -- "$1" <<<"$output"; }
not_said() { ! said "$1"; }
not() { ! "$@"; }
called() { grep -qE -- "$1" "$state/calls"; }
not_called() { ! called "$1"; }
call_count() { grep -cE -- "$1" "$state/calls"; }
config_has() { grep -qxF -- "$1" "$stack/config.env"; }
no_cr() { [ "$(tr -cd '\r' <"$1" | wc -c)" -eq 0 ]; }
set_state() { printf '%s\n' "${@:2}" >"$state/$1"; }
state_is() { [ "$(cat "$state/$1" 2>/dev/null)" = "$2" ]; }

# called_before FIRST SECOND: the first call matching FIRST comes before the first matching SECOND.
called_before() {
    local first second
    first=$(grep -nE -- "$1" "$state/calls" | head -n 1 | cut -d: -f1)
    second=$(grep -nE -- "$2" "$state/calls" | head -n 1 | cut -d: -f1)
    [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]
}

ps1_commands() {
    tr -d '\r' <"$repository/docker-compose.ps1" | awk '
        /^\$usage[[:space:]]*=[[:space:]]*@\{/ { inside = 1; next }
        inside && /^\}/ { exit }
        inside && /^[[:space:]]*"[^"]+"[[:space:]]*=/ { key = $0; sub(/^[[:space:]]*"/, "", key); sub(/".*/, "", key); print key }'
}

# write_dump NAME [BYTES] [AGE_MINUTES]: a dump file in data/hindsight.
write_dump() {
    head -c "${2:-64}" /dev/zero | tr '\0' x >"$stack/data/hindsight/$1"
    if [ -n "${3:-}" ]; then touch -d "-$3 minutes" "$stack/data/hindsight/$1"; fi
}

# write_transcript NAME KB [LINES...]: a transcript of the given JSON lines, padded with a tool-result
# line to at least KB kilobytes.
write_transcript() {
    local file="$home/.claude/projects/My-Project/$1" kb=$2
    shift 2
    mkdir -p "${file%/*}"
    printf '%s\n' "$@" >"$file"
    printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"%s"}]}}\n' \
        "$(head -c $((kb * 1024)) /dev/zero | tr '\0' p)" >>"$file"
}

counts_lines() { printf '%s\n' "public.async_operations|$1" "public.banks|2" "public.memory_units|$2"; }

## Skeleton

begin "the usage lists every command of the ps1's usage table"
run_cli help
check "exits 1" status_is 1
while IFS= read -r command; do
    check "usage names $command" grep -qE "^  $command " <<<"$output"
done < <(ps1_commands)
finish

begin "the usage text is the ps1's, with ./docker-compose.sh, / paths and long options"
run_cli help
check "the command list" said "Usage: ./docker-compose.sh [consolidate|data|logs|prove-data|reingest|restore|save-images|start|stop]"
check "consolidate" said "  consolidate  [--run-immediately] [--poll-seconds N] run one consolidation pass, then back to retain-only"
check "reingest" said "  reingest     [--limit N] [--min-kb N] rebuild the memory bank from Claude Code transcripts"
check "restore" said "  restore      [--file dump.sql] [--database name] restore a backup dump (newest by default) in one transaction, into hindsight by default"
check "start is the default" said "  start        Start the full stack (default)"
check "no PowerShell spelling" not_said "-RunImmediately"
check "no -File" not_said "-File"
finish

begin "an unknown or empty command shows the usage and calls nothing"
run_cli frobnicate
check "exits 1" status_is 1
check "prints the usage" said "Usage: ./docker-compose.sh ["
run_cli ""
check "an empty one exits 1" status_is 1
check "calls no docker" not_called .
finish

begin "no command at all runs start"
run_cli
check "exits 0" status_is 0
check "starts the stack" called "^compose -f docker-compose.nvidia.yml up -d --remove-orphans$"
finish

begin "a command refuses an option it does not take"
for arguments in "start --bogus" "stop x" "logs -f" "consolidate --poll-seconds" "consolidate --poll-seconds 0" \
    "consolidate --poll-seconds x" "consolidate -RunImmediately" "reingest --limit" "reingest --limit -1" \
    "reingest --min-kb x" "reingest -Limit 1" "restore --file" "restore --database" "restore dump.sql" \
    "restore -File x" "save-images x" "prove-data --force" "data status x" "data use a b" "data use --x" "data frob"; do
    # shellcheck disable=SC2086 # split on purpose
    run_cli $arguments
    check "$arguments exits 1" status_is 1
    check "$arguments prints a usage" said "Usage: ./docker-compose.sh"
done
check "calls no docker" not_called "^(compose|ps|exec|cp|volume|save|logs|git) "
finish

begin "COMPOSE_PROJECT_NAME is unset"
output=$(cd "$caller" && COMPOSE_PROJECT_NAME=elsewhere PATH="$fakes:$PATH" FAKE_DOCKER_DIR="$state" \
    bash "$stack/docker-compose.sh" stop 2>&1)
check "docker never sees it" grep -qx unset "$state/compose-project-name"
finish

begin "the command is case-insensitive, as in the ps1"
run_cli LOGS
check "follows the llama container" called "^logs -f hindsight-llama$"
finish

## start

begin "start refuses without config.env"
rm "$stack/config.env"
run_cli start
check "exits 1" status_is 1
check "says so" said "Config not found: $stack_native/config.env"
check "calls no docker" not_called .
finish

begin "start joins the tailnet, writes HINDSIGHT_HOST, and starts the NVIDIA stack"
run_cli start
check "exits 0" status_is 0
check "says it joined" said "Joined as hindsight.tail-test.ts.net"
check "says it wrote it" said "Wrote HINDSIGHT_HOST to config.env."
check "the ts.net name" config_has HINDSIGHT_HOST=hindsight.tail-test.ts.net
check "the other lines stay" config_has TS_AUTHKEY=tskey-test
check "LF endings" no_cr "$stack/config.env"
check "compose reads config.env" state_is last-env-file config.env
check "tailscale first" called_before "^compose -f docker-compose.hindsight-only.yml up -d tailscale$" "^compose -f docker-compose.nvidia.yml up"
check "says the GPU" said "[2] GPU: docker-compose.nvidia.yml"
check "images present, no pull" said "[4] Images present locally - skipping pull."
check "no pull" not_called " pull$"
check "asks llama's health" called "^curl -s -o /dev/null -m 3 -w %\{http_code\} http://localhost:11434/health$"
check "says it is ready" said "llama is ready."
check "says it is up" said "Stack is up."
check "the control plane" said "  Control plane : http://localhost:9999"
check "the tailnet" said "  On the tailnet: https://hindsight.tail-test.ts.net   (from any device on your tailnet)"
check "the API" said "  Hindsight API : http://localhost:8888   (this PC only)"
check "the llama API" said "  llama API     : http://localhost:11434"
check "never the Dozen image" not_called "docker-compose.gpu.yml"
check "no build" not_called " build"
finish

begin "start keeps config.env as it is when HINDSIGHT_HOST is already the node's name"
sed -i 's/^HINDSIGHT_HOST=.*/HINDSIGHT_HOST=hindsight.tail-test.ts.net/' "$stack/config.env"
chmod 0600 "$stack/config.env"
run_cli start
check "exits 0" status_is 0
check "writes nothing" not_said "Wrote HINDSIGHT_HOST"
if [ -z "${MSYSTEM:-}" ]; then check "still 0600" [ "$(stat -c %a "$stack/config.env")" = 600 ]; fi
finish

begin "start appends HINDSIGHT_HOST when config.env has no line for it"
sed -i '/^HINDSIGHT_HOST=/d' "$stack/config.env"
run_cli start
check "appended" config_has HINDSIGHT_HOST=hindsight.tail-test.ts.net
check "once" [ "$(grep -c '^HINDSIGHT_HOST=' "$stack/config.env")" -eq 1 ]
finish

begin "start goes on without the tailnet when the node does not join"
set_state tailnet stopped
run_cli start
check "exits 0" status_is 0
check "names the usual cause" said "Not on the tailnet (an expired or used-up TS_AUTHKEY is the usual cause); the control plane is on localhost only."
check "still starts" called "^compose -f docker-compose.nvidia.yml up -d --remove-orphans$"
check "no tailnet URL" not_said "On the tailnet:"
sed -i 's/^TS_AUTHKEY=.*/TS_AUTHKEY=/' "$stack/config.env"
run_cli start
check "names an empty key" said "Not on the tailnet (TS_AUTHKEY in config.env is empty); the control plane is on localhost only."
finish

begin "start removes a running llama and server container before starting"
set_state running hindsight-llama hindsight-server
run_cli start
check "removes llama" called_before "^rm -f hindsight-llama$" "^compose -f docker-compose.nvidia.yml up"
check "removes the server" called_before "^rm -f hindsight-server$" "^compose -f docker-compose.nvidia.yml up"
check "says so" said "Stopping container 'hindsight-llama'..."
finish

begin "start without an NVIDIA GPU fails before starting the stack"
set_state gpu none
run_cli start
check "exits 1" status_is 1
check "says why" said "No supported GPU found (need NVIDIA via nvidia-smi; the AMD Vulkan image over WSL's /dev/dxg is Windows-only)."
check "no stack up" not_called "up -d --remove-orphans"
check "never the Dozen image" not_called "docker-compose.gpu.yml"
finish

begin "start with DOCKER_LLAMA=false says the native llama is Windows-only and runs the Docker one"
sed -i 's/^DOCKER_LLAMA=.*/DOCKER_LLAMA=false/' "$stack/config.env"
run_cli start
check "exits 0" status_is 0
check "says so" said "DOCKER_LLAMA=false selects the native Windows llama-server, which this CLI does not run; using the Docker llama."
check "runs the Docker llama" called "^compose -f docker-compose.nvidia.yml up -d --remove-orphans$"
check "no host llama file for the stack" not_called "^compose -f docker-compose.hindsight-only.yml up -d --remove-orphans"
finish

begin "start loads the saved images when the hindsight image is missing"
set_state images-present no
mkdir -p "$stack/images" && : >"$stack/images/stack-images.tar"
run_cli start
check "exits 0" status_is 0
check "loads the tar" called "^load -i .*/images/stack-images.tar$"
check "says so" said "[3] Loading stack images from local tar (offline, skips ~14 GB re-pull)..."
check "no pull" not_called " pull$"
finish

begin "start pulls when the images are missing and no tar is saved"
set_state images-present no
run_cli start
check "exits 0" status_is 0
check "says so" said "[4] Pulling images (no local tar found)..."
check "pulls before up" called_before "^compose -f docker-compose.nvidia.yml pull$" "^compose -f docker-compose.nvidia.yml up -d --remove-orphans$"
finish

begin "start downloads a missing model to .part with resume, then renames it"
rm "$stack/data/llama/Qwen2.5-7B-Instruct-Q4_K_M.gguf"
run_cli start
check "exits 0" status_is 0
check "says so" said "[1] Downloading model (Qwen2.5-7B-Instruct-Q4_K_M.gguf, ~4.4 GB)..."
check "curl resumes into .part" called "^curl -fL --retry 3 -C - -o .*/data/llama/Qwen2.5-7B-Instruct-Q4_K_M.gguf.part https://huggingface.co/bartowski/"
check "renamed" [ -f "$stack/data/llama/Qwen2.5-7B-Instruct-Q4_K_M.gguf" ]
check "no .part left" [ ! -e "$stack/data/llama/Qwen2.5-7B-Instruct-Q4_K_M.gguf.part" ]
check "says done" said "Model downloaded."
finish

begin "a failed model download keeps the .part and starts nothing"
rm "$stack/data/llama/Qwen2.5-7B-Instruct-Q4_K_M.gguf"
set_state download-exit 56
run_cli start
check "exits 1" status_is 1
check "says the .part is kept" said "The model download failed; $stack_native/data/llama/Qwen2.5-7B-Instruct-Q4_K_M.gguf.part is kept and the next start resumes it."
check "the .part is kept" [ -s "$stack/data/llama/Qwen2.5-7B-Instruct-Q4_K_M.gguf.part" ]
check "no stack up" not_called "up -d --remove-orphans"
finish

begin "start fails when llama never becomes healthy"
set_state llama-health 000
run_cli start
check "exits 1" status_is 1
check "says so" said "llama did not become ready within 900s."
check "asked 180 times" [ "$(call_count "^curl .*11434/health$")" -eq 180 ]
check "not up" not_said "Stack is up."
finish

begin "start fails with the compose call when compose up fails"
set_state up-exit 17
run_cli start
check "exits 1" status_is 1
check "names the call" said "docker compose -f docker-compose.nvidia.yml up -d --remove-orphans exited with 17"
finish

## stop and logs

begin "stop removes the containers and downs both compose files"
set_state running hindsight-server hindsight-llama
run_cli stop
check "exits 0" status_is 0
check "says it stops" said "Stopping everything..."
check "removes the server" called "^rm -f hindsight-server$"
check "removes llama" called "^rm -f hindsight-llama$"
check "downs the NVIDIA stack" called "^compose -f docker-compose.nvidia.yml down$"
check "downs the host-llama file" called "^compose -f docker-compose.hindsight-only.yml down$"
check "says done" said "Done."
finish

begin "stop reaches the last compose down when the first fails, and fails"
set_state down-exit-docker-compose.nvidia.yml 1
run_cli stop
check "exits 1" status_is 1
check "says which failed" said "docker compose -f docker-compose.nvidia.yml down failed."
check "still downs the host-llama file" called "^compose -f docker-compose.hindsight-only.yml down$"
check "not done" not_said "Done."
finish

begin "stop works without config.env and without a GPU"
rm "$stack/config.env"
set_state gpu none
run_cli stop
check "exits 0" status_is 0
check "no NVIDIA down" not_called "docker-compose.nvidia.yml down"
check "downs the host-llama file" called "^compose -f docker-compose.hindsight-only.yml down$"
finish

begin "stop starts no host process and kills none by name"
run_cli stop
check "no pkill, kill or taskkill" not_called "^(pkill|kill|taskkill)"
check "no watcher" not_said "watcher"
finish

## consolidate

begin "consolidate --run-immediately enables a slot, resets stale ops, waits for two empty polls, then disables it"
set_state operations '{"operations":[{"task_type":"consolidation","status":"processing"}]}'
run_cli consolidate --run-immediately --poll-seconds 1
check "exits 0" status_is 0
check "does not wait for retains" not_said "Waiting for live retains"
check "recreates hindsight with the stack's file" called "^compose -f docker-compose.nvidia.yml up -d hindsight$"
check "never the host-llama file" not_called "hindsight-only.yml up -d hindsight"
check "slots 1, then 0" [ "$(tr '\n' ' ' <"$state/slots")" = "1 0 " ]
check "resets stale ops" said "reset stale consolidation: UPDATE 0"
check "polls three times" [ "$(call_count "operations\?limit=200$")" -eq 3 ]
check "reports the busy poll" said "consolidation pending/processing: 1  (retains waiting: 0)"
check "says done" said "Done. Consolidation cleared; retains have the GPU again."
finish

begin "consolidate waits for the retain queue first"
set_state operations '{"operations":[{"task_type":"retain","status":"pending"},{"task_type":"batch_retain","status":"processing"},{"task_type":"retain","status":"completed"}]}'
run_cli consolidate
check "exits 0" status_is 0
check "says it waits" said "Waiting for live retains to finish before consolidating..."
check "counts both retain kinds" said "retains still pending: 2"
check "then empty" said "Retain queue empty."
check "before enabling" called_before "operations\?limit=200$" "up -d hindsight$"
finish

begin "consolidate fails when hindsight does not come back"
set_state hindsight-health 000
run_cli consolidate --run-immediately
check "exits 1" status_is 1
check "says so" said "Hindsight did not become healthy after restart."
finish

begin "consolidate fails when the operations cannot be read"
set_state hindsight-health 200
mkdir -p "$scratch/bad" && printf '%s\n' '#!/bin/bash' 'echo "curl $*" >>"$FAKE_DOCKER_DIR/calls"; exit 7' >"$scratch/bad/curl" && chmod +x "$scratch/bad/curl"
output=$(cd "$caller" && HOME="$home" PATH="$scratch/bad:$fakes:$PATH" FAKE_DOCKER_DIR="$state" bash "$stack/docker-compose.sh" consolidate 2>&1)
status=$?
check "exits 1" status_is 1
check "says so" said "Hindsight's operations could not be read"
check "never enables consolidation" not_called "up -d hindsight$"
rm -rf "$scratch/bad"
finish

## reingest

begin "reingest posts the conversation text of each large enough transcript, newest first"
write_transcript older.jsonl 60 '{"type":"user","message":{"content":"how does the gateway work"}}'
touch -d "-1 hour" "$home/.claude/projects/My-Project/older.jsonl"
write_transcript newer.jsonl 60 '{"type":"assistant","message":{"content":[{"type":"text","text":"through Caddy"},{"type":"tool_use","name":"Bash"}]}}' 'not json'
write_transcript tiny.jsonl 1 '{"type":"user","message":{"content":"small"}}'
run_cli reingest
check "exits 0" status_is 0
check "says how many" said "Re-ingesting 2 transcript(s) into bank 'claude_code'..."
check "posts to the memories API" called "^curl -sS -f -m 180 -o /dev/null -H Content-Type: application/json --data-binary @- http://localhost:8888/v1/default/banks/claude_code/memories$"
check "the user's text" grep -qF '[user] how does the gateway work' "$state/posts"
check "the assistant's text block" grep -qF '[assistant] through Caddy' "$state/posts"
check "no tool noise" not grep -qF 'tool_use' "$state/posts"
check "no tool result" not grep -qF 'pppp' "$state/posts"
check "async, with the document id" grep -qF '"async": true, "items": [{"content": "[assistant] through Caddy\n\n", "document_id": "newer"}]' "$state/posts"
check "newest first" [ "$(head -n 1 "$state/posts" | grep -c newer)" -eq 1 ]
check "skips the tiny one" not grep -qF small "$state/posts"
check "says done" said "Submitted 2 async retain request(s) across 2 transcript(s)."
finish

begin "reingest --limit 1 --min-kb 0 takes the newest transcript of any size"
write_transcript older.jsonl 0 '{"type":"user","message":{"content":"older"}}'
touch -d "-1 hour" "$home/.claude/projects/My-Project/older.jsonl"
write_transcript newer.jsonl 0 '{"type":"user","message":{"content":"newer"}}'
run_cli reingest --limit 1 --min-kb 0
check "exits 0" status_is 0
check "one transcript" said "Re-ingesting 1 transcript(s) into bank 'claude_code'..."
check "the newest" grep -qF '[user] newer' "$state/posts"
check "not the older" not grep -qF '[user] older' "$state/posts"
finish

begin "reingest splits a long conversation into chunks of whole lines"
lines=()
for index in $(seq 30); do lines+=("{\"type\":\"user\",\"message\":{\"content\":\"line $index $(head -c 1000 /dev/zero | tr '\0' a)\"}}"); done
write_transcript long.jsonl 0 "${lines[@]}"
run_cli reingest --min-kb 0
check "exits 0" status_is 0
check "three chunks" said "long.jsonl: 30 KB -> 3 chunk(s)"
check "three posts" [ "$(wc -l <"$state/posts")" -eq 3 ]
check "no line split" [ "$(grep -o '\[user\] line' "$state/posts" | wc -l)" -eq 30 ]
finish

begin "reingest goes on past a failed POST and counts only the submitted ones"
write_transcript one.jsonl 0 '{"type":"user","message":{"content":"one"}}'
write_transcript empty.jsonl 0 '{"type":"system","message":{"content":"none"}}'
set_state post-exit 22
run_cli reingest --min-kb 0
check "exits 0" status_is 0
check "names the failed chunk" said "POST failed (one chunk 0): curl: (22) The requested URL returned error: 500"
check "skips the textless one" said "skip (no text): empty.jsonl"
check "counts none" said "Submitted 0 async retain request(s) across 2 transcript(s)."
finish

begin "reingest refuses without the transcript folder"
rm -rf "$home/.claude"
run_cli reingest
check "exits 1" status_is 1
check "says so" said "Transcript folder not found: $home/.claude/projects"
finish

## restore

begin "restore copies the newest complete dump in and runs psql in one transaction, stopping at the first error"
write_dump hindsight-20261103-120000.sql 64
write_dump hindsight-20261104-120000.sql 64
write_dump hindsight-20261104-130000.sql.tmp 64
write_dump hindsight-20261104-140000.sql 0
set_state running hindsight-server
run_cli restore
check "exits 0" status_is 0
check "copies the newest complete one" called "^cp .*/data/hindsight/hindsight-20261104-120000.sql hindsight-server:/tmp/hindsight-restore.sql$"
check "psql in one transaction, stopping at the first error" called "^exec -e PGPASSWORD hindsight-server sh -c .* psql -h 127.0.0.1 -U hindsight -d hindsight -v ON_ERROR_STOP=1 --single-transaction -f /tmp/hindsight-restore.sql$"
check "the password by environment" state_is pgpassword set
check "never on a command line" not_called "PGPASSWORD="
check "removes the dump as root" called_before "^exec -e PGPASSWORD" "^exec -u root hindsight-server rm -f /tmp/hindsight-restore.sql$"
check "shows the COPY lines" said "  COPY 12"
check "says how to reload" said "Restore finished. Restart hindsight to load the restored data cleanly: docker restart hindsight-server"
finish

begin "restore --file --database restores a named dump into another database"
write_dump other.sql 64
set_state running hindsight-server
run_cli restore --file ../hindsight-compose/data/hindsight/other.sql --database scratch
check "exits 0" status_is 0
check "copies the named file, relative to the caller" called "^cp ($scratch_native/|\.\./)hindsight-compose/data/hindsight/other.sql hindsight-server:"
check "into scratch" called " -d scratch -v ON_ERROR_STOP=1 "
check "says so" said "Restoring Hindsight DB 'scratch' from "
finish

begin "restore of a missing file fails before anything is copied"
set_state running hindsight-server
run_cli restore --file nowhere.sql
check "exits 1" status_is 1
check "says so" said "Backup not found: nowhere.sql"
check "copies nothing" not_called "^cp "
finish

begin "restore with no dumps says so"
set_state running hindsight-server
run_cli restore
check "exits 1" status_is 1
check "says so" said "No backups found in $stack_native/data/hindsight"
finish

begin "restore refuses while hindsight is not running"
write_dump hindsight-20261104-120000.sql 64
run_cli restore
check "exits 1" status_is 1
check "says so" said "hindsight container is not running. Start the stack first."
check "copies nothing" not_called "^cp "
finish

begin "a failed psql prints its errors, removes the dump, and says nothing was committed"
write_dump hindsight-20261104-120000.sql 64
set_state running hindsight-server
set_state psql-output 'SET' 'psql:/tmp/hindsight-restore.sql:12: ERROR:  syntax error at or near "BROKEN"'
set_state psql-exit 3
run_cli restore --database scratch
check "exits 1" status_is 1
check "prints the error line" said 'ERROR:  syntax error at or near "BROKEN"'
check "not the SET line" not_said "  SET"
check "says nothing was committed" said "Restore FAILED: psql exited with 3; nothing was committed, 'scratch' is unchanged."
check "still removes the dump" called "^exec -u root hindsight-server rm -f /tmp/hindsight-restore.sql$"
check "not finished" not_said "Restore finished."
finish

begin "a failed psql without error lines prints its last ten lines"
write_dump hindsight-20261104-120000.sql 64
set_state running hindsight-server
set_state psql-output line-{1..12}
set_state psql-exit 2
run_cli restore
check "exits 1" status_is 1
check "the last line" said "  line-12"
check "the tenth from last" said "  line-3"
check "not the eleventh from last" not_said "  line-2"
finish

begin "a failed copy stops before psql"
write_dump hindsight-20261104-120000.sql 64
set_state running hindsight-server
set_state cp-exit 1
run_cli restore
check "exits 1" status_is 1
check "says so" said "Copying the dump into hindsight-server failed"
check "no psql" not_called "^exec -e PGPASSWORD"
finish

begin "a failed cleanup is said"
write_dump hindsight-20261104-120000.sql 64
set_state running hindsight-server
set_state cleanup-exit 1
run_cli restore
check "says so" said "Could not remove /tmp/hindsight-restore.sql from hindsight-server"
check "the restore still worked" said "Restore finished."
finish

## save-images

begin "save-images saves every image of the NVIDIA and host-llama files once"
run_cli save-images
check "exits 0" status_is 0
check "says how many" said "Saving 6 images to $stack_native/images/stack-images.tar ..."
check "saves them sorted" called "^save -o .*/images/stack-images.tar alpine:3.24.2 caddy:2.11.4-alpine ghcr.io/ggml-org/llama.cpp:server-cuda-b9641 ghcr.io/vectorize-io/hindsight:0.8.2 postgres:18.4-alpine tailscale/tailscale:v1.102.4$"
check "says done" said "Done. This tar is loaded automatically by start when images are missing."
finish

## prove-data

begin "prove-data refuses unless both containers run, and deletes nothing"
set_state running hindsight-server
run_cli prove-data
check "exits 1" status_is 1
check "says so" said "hindsight-db-backup is not running; start the stack first (both hindsight-server and hindsight-db-backup must be up)"
check "no volume removed" not_called "^volume rm"
finish

begin "prove-data dumps, counts, stops, deletes pg0, starts, waits, and compares"
set_state running hindsight-server hindsight-db-backup
write_dump hindsight-20261104-120000.sql 64
counts_lines 3 7 >"$state/counts-1"
counts_lines 0 0 >"$state/counts-2"
counts_lines 9 7 >"$state/counts"
run_cli prove-data
check "exits 0" status_is 0
check "dumps first" called_before "^exec hindsight-db-backup sh -c .*pg_dump" "^exec hindsight-db-backup psql"
check "names the dump" said "dump hindsight-20261104-120000.sql"
check "counts through the sidecar" called "^exec hindsight-db-backup psql -h 127.0.0.1 -U hindsight -d hindsight -At -F \| -c "
check "before" said "3 tables, public.memory_units = 7"
check "stops before deleting" called_before "^compose -f docker-compose.hindsight-only.yml down$" "^volume rm hindsight-compose_hindsight-pg0$"
check "starts after deleting" called_before "^volume rm hindsight-compose_hindsight-pg0$" "^compose -f docker-compose.nvidia.yml up -d --remove-orphans$"
check "waits past an empty table" [ "$(cat "$state/count-calls")" -eq 4 ]
check "async_operations not compared" said "public.async_operations (not compared) before=3 after=9"
check "says they match" said "all 3 tables match"
finish

begin "prove-data names each difference and how to recover"
set_state running hindsight-server hindsight-db-backup
write_dump hindsight-20261104-120000.sql 64
counts_lines 3 7 >"$state/counts-1"
printf '%s\n' "public.async_operations|3" "public.memory_units|6" >"$state/counts"
run_cli prove-data
check "exits 1" status_is 1
check "the changed table" said "DIFFERS public.memory_units before=7 after=6"
check "the missing table" said "DIFFERS public.banks before=2 after=missing"
check "the hint" said "hindsight-compose_hindsight-pg0 was deleted. Recover with: ./docker-compose.sh start   then, if public.memory_units stays empty,   ./docker-compose.sh restore --file data/hindsight/hindsight-20261104-120000.sql"
finish

begin "prove-data gives up after 15 minutes of an empty memory_units"
set_state running hindsight-server hindsight-db-backup
write_dump hindsight-20261104-120000.sql 64
counts_lines 3 7 >"$state/counts-1"
counts_lines 0 0 >"$state/counts"
run_cli prove-data
check "exits 1" status_is 1
check "says so" said "public.memory_units stayed empty for 15 minutes"
check "the hint" said "was deleted. Recover with:"
check "60 waits" [ "$(cat "$state/count-calls")" -eq 61 ]
finish

begin "prove-data deletes nothing when no table is counted"
set_state running hindsight-server hindsight-db-backup
write_dump hindsight-20261104-120000.sql 64
: >"$state/counts-1"
run_cli prove-data
check "exits 1" status_is 1
check "says so" said "no table was counted; nothing was deleted"
check "no stop" not_called "down$"
check "no volume removed" not_called "^volume rm"
finish

begin "prove-data deletes nothing when the fresh dump fails or the stop fails"
set_state running hindsight-server hindsight-db-backup
set_state fresh-dump-exit 1
run_cli prove-data
check "a failed dump exits 1" status_is 1
check "says so" said "the fresh dump failed"
set_state fresh-dump-exit 0
write_dump hindsight-20261104-120000.sql 64
set_state down-exit-docker-compose.hindsight-only.yml 1
run_cli prove-data
check "a failed stop exits 1" status_is 1
check "says so" said "docker-compose.sh stop failed with exit code 1"
check "no volume removed" not_called "^volume rm"
finish

begin "prove-data says so when the volume cannot be removed"
set_state running hindsight-server hindsight-db-backup
write_dump hindsight-20261104-120000.sql 64
set_state volume-rm-exit 1
run_cli prove-data
check "exits 1" status_is 1
check "says so" said "could not remove hindsight-compose_hindsight-pg0"
check "no start" not_called "up -d --remove-orphans$"
finish

## data

begin "data status shows the submodule"
run_cli data
check "exits 0" status_is 0
check "status by default" called "^git -C .* submodule status -- data$"
finish

begin "data use points data at another repo and ref"
run_cli data use someone/hindsight-data@v2
check "exits 0" status_is 0
check "says so" said "Pointing data at https://github.com/someone/hindsight-data.git @ v2"
check "sets the url" called "^git -C .* config submodule.data.url https://github.com/someone/hindsight-data.git$"
check "fetches the ref" called "^git -C .*/data fetch -q origin v2$"
check "says where" said "data now at 0abc123"
run_cli data use
check "none means the template" said "Pointing data at https://github.com/intisy-compose/hindsight-data-template.git @ main"
finish

echo
if [ "$failures" -eq 0 ]; then echo "all cases pass"; else echo "$failures cases fail"; fi
[ "$failures" -eq 0 ]
