#!/usr/bin/env bash
# The Linux CLI, with the same commands and messages as docker-compose.ps1.
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
    echo "docker-compose.sh needs bash 4.3 or newer; this is bash $BASH_VERSION" >&2
    exit 1
fi
set -euo pipefail
# Empty: every command has a Linux form. What is Windows-only lies inside start, stop and logs, not in
# a command of its own: the native llama-server.exe with its proxy and docker-event watcher
# (DOCKER_LLAMA=false), and the Dozen Vulkan image over WSL's /dev/dxg (docker-compose.gpu.yml).
# shellcheck disable=SC2034 # read by the CLI parity check, not here
windows_only=()

# The pinned `name:` must win, because the restore guard checks the volume by that name.
unset COMPOSE_PROJECT_NAME

caller_folder=$PWD
here=$(cd "$(dirname "$0")" && pwd)

usage() {
    cat <<'EOF'
Usage: ./docker-compose.sh [consolidate|data|logs|prove-data|reingest|restore|save-images|start|stop]
  consolidate  [--run-immediately] [--poll-seconds N] run one consolidation pass, then back to retain-only
  data         status | use [owner/repo[@ref]]  point data/ at a data repo (none = template)
  logs         Tail llama output
  prove-data   DESTRUCTIVE: delete the database volume and prove the self-restore brings every table back
  reingest     [--limit N] [--min-kb N] rebuild the memory bank from Claude Code transcripts
  restore      [--file dump.sql] [--database name] restore a backup dump (newest by default) in one transaction, into hindsight by default
  save-images  Save the stack's images to images/ for an offline reinstall
  start        Start the full stack (default)
  stop         Stop everything
EOF
    exit 1
}

no_options() { [ $# -eq 0 ] || usage; }

# run_helper NAME ARGUMENTS...: a helper resolves a relative path against the caller's folder, as the
# ps1's helpers run before it changes folder.
run_helper() {
    local name=$1
    shift
    cd "$caller_folder"
    exec bash "$here/scripts/$name.sh" "$@"
}

# split_data_source SOURCE: sets data_url and data_ref from owner/repo[@ref] or a git URL[@ref]. The
# ref follows the last @ after a URL's user@, so git@host:owner/repo@ref keeps its user.
split_data_source() {
    local rest=$1 user=""
    if [[ $rest =~ ^([A-Za-z][A-Za-z0-9+.-]*://[^/@]+@)(.*)$ || $rest =~ ^([^/@:]+@)([^/:]+:.*)$ ]]; then
        user=${BASH_REMATCH[1]}
        rest=${BASH_REMATCH[2]}
    fi
    data_ref=main
    if [[ $rest == *@* ]]; then
        data_ref=${rest##*@}
        rest=${rest%@*}
    fi
    if [[ -z $data_ref || $data_ref == -* ]]; then
        printf '\033[31m%s\033[0m\n' "A data ref must not be empty or start with '-': '$data_ref'" >&2
        exit 1
    fi
    data_url=$user$rest
    [[ $data_url == *://* || -n $user ]] || data_url="https://github.com/$data_url.git"
}

# point_data_at SOURCE: SOURCE is owner/repo[@ref] or a git URL[@ref]; none means the template.
point_data_at() {
    local source=${1:-} url ref=main
    if [ -n "$source" ]; then
        split_data_source "$source"
        url=$data_url
        ref=$data_ref
    else
        url=$(git -C "$here" config -f .gitmodules submodule.data.url)
    fi
    printf '\033[36m%s\033[0m\n' "Pointing data at $url @ $ref"
    [ -e "$here/data/.git" ] || git -C "$here" submodule update --init -- data >/dev/null 2>&1 || true
    git -C "$here" config submodule.data.url "$url"
    git -C "$here/data" remote set-url origin "$url"
    git -C "$here/data" fetch -q origin "$ref"
    git -C "$here/data" checkout -q FETCH_HEAD
    printf '  \033[32m%s\033[0m\n' "data now at $(git -C "$here/data" rev-parse --short HEAD)"
}

invoke_data() {
    local subcommand
    subcommand=$(printf '%s' "${1:-status}" | tr '[:upper:]' '[:lower:]')
    [ $# -eq 0 ] || shift
    case "$subcommand" in
        status) no_options "$@"; git -C "$here" submodule status -- data ;;
        use)    [ $# -le 1 ] && [[ ${1:-} != -* ]] || usage; point_data_at "$@" ;;
        *)      usage ;;
    esac
}

cd "$here"
command=$(printf '%s' "${1-start}" | tr '[:upper:]' '[:lower:]')
[ $# -eq 0 ] || shift
case "$command" in
    start | stop | logs) no_options "$@"; run_helper hindsight "$command" ;;
    consolidate)         run_helper consolidate "$@" ;;
    reingest)            run_helper reingest "$@" ;;
    restore)             run_helper restore "$@" ;;
    save-images)         run_helper save-images "$@" ;;
    prove-data)          run_helper prove-data "$@" ;;
    data)                invoke_data "$@" ;;
    *)                   usage ;;
esac
