#!/bin/bash
# shellcheck disable=SC2034 # the names are used by the scripts that source this
# Shared by docker-compose.sh and every scripts/*.sh: the stack's paths, its console lines, config.env
# and the compose calls. Source only: loading this file defines variables and functions and does nothing
# else.

stack_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Git Bash on Windows: docker.exe needs a Windows path here, and must get container paths unrewritten.
if [ -n "${MSYSTEM:-}" ]; then stack_root=$(cd "$stack_root" && pwd -W); export MSYS_NO_PATHCONV=1; fi

config_file="$stack_root/config.env"
nvidia_compose_file="docker-compose.nvidia.yml"
host_llama_compose_file="docker-compose.hindsight-only.yml"
server_container="hindsight-server"
backup_container="hindsight-db-backup"
llama_container="hindsight-llama"

step() { printf '\033[36m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m%s\033[0m\n' "$*"; }
info() { printf '  \033[90m%s\033[0m\n' "$*"; }
err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
fail() { err "$*"; exit 1; }

# config_value NAME [DEFAULT]: the last value config.env gives NAME, trimmed and without surrounding
# quotes, or DEFAULT when it gives none or an empty one, as the ps1 treats an empty variable.
config_value() {
    local value=""
    if [ -f "$config_file" ]; then
        value=$(tr -d '\r' <"$config_file" | awk -v name="$1" '
            match($0, /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*=/) {
                key = substr($0, 1, RLENGTH - 1); gsub(/[ \t]/, "", key)
                if (key != name) next
                value = substr($0, RLENGTH + 1); sub(/^[ \t]+/, "", value); sub(/[ \t]+$/, "", value)
                gsub(/^"+|"+$/, "", value); found = 1
            }
            END { if (found) print value }')
    fi
    printf '%s\n' "${value:-${2:-}}"
}

# set_config_value NAME VALUE: rewrites the line that sets NAME, or appends one, keeping every other
# line, and writes the file back with LF endings, in place, so it keeps its mode.
set_config_value() {
    local name=$1 value=$2 line output="" found=false
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        if [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]] && [ "${BASH_REMATCH[1]}" = "$name" ]; then
            line="$name=$value"
            found=true
        fi
        output+="$line"$'\n'
    done <"$config_file"
    $found || output+="$name=$value"$'\n'
    printf '%s' "$output" >"$config_file"
}

assert_config_exists() {
    [ -f "$config_file" ] || fail "Config not found: $config_file"
}

# compose_with FILE ARGUMENTS...: docker compose on one of the stack's compose files. config.env feeds
# the interpolation when it exists; without it compose takes every default, as the ps1's does.
compose_with() {
    local file=$1
    shift
    local environment=()
    if [ -f "$config_file" ]; then environment=(--env-file "$config_file"); fi
    docker compose --project-directory "$stack_root" ${environment[@]+"${environment[@]}"} -f "$stack_root/$file" "$@"
}

# gpu_compose_file: the compose file of the Docker llama this host can run, or nothing. Linux has the
# NVIDIA one only; docker-compose.gpu.yml is the Dozen Vulkan image over WSL's /dev/dxg, which exists
# on Windows alone, so the ps1 is the only CLI that offers it.
gpu_compose_file() {
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then echo "$nvidia_compose_file"; fi
}

# native_path PATH: PATH as a program that is not part of Git Bash reads it, which MSYS_NO_PATHCONV
# above stops Git Bash from converting.
native_path() { if [ -n "${MSYSTEM:-}" ]; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

container_is_running() { [ -n "$(docker ps -q --filter "name=^$1$" 2>/dev/null)" ]; }

# is_count WORD [MINIMUM]: WORD is a whole number of at least MINIMUM (default 0).
is_count() { [[ $1 =~ ^[0-9]+$ ]] && [ "$1" -ge "${2:-0}" ]; }

# http_status URL [SECONDS]: the HTTP status URL answers with, 000 when it does not answer.
http_status() { curl -s -o /dev/null -m "${2:-3}" -w '%{http_code}' "$1" 2>/dev/null || true; }
