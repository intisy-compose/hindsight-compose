#!/usr/bin/env bash
# hindsight.sh start | stop | logs: the bash twin of hindsight.ps1 on its Docker llama path. The native
# llama-server.exe, its JSON-repair proxy and the docker-event watcher that follows the llama container
# exist only on Windows, and Linux runs the Docker llama only, so nothing here starts a host process.
set -euo pipefail
# shellcheck source=scripts/stack.sh
. "$(dirname "$0")/stack.sh"

model_dir="$stack_root/data/llama"
image_tar="$stack_root/images/stack-images.tar"
default_model_file="Qwen2.5-7B-Instruct-Q4_K_M.gguf"
default_model_url="https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf"

llama_port() { config_value LLAMA_PORT 11434; }

stop_docker_container() {
    if container_is_running "$1"; then
        info "Stopping container '$1'..."
        docker rm -f "$1" >/dev/null 2>&1 || true
    fi
}

# run_compose FILE ARGUMENTS...: compose with its output shown, failing with the call when it exits
# non-zero.
run_compose() {
    local file=$1 compose_exit=0
    shift
    compose_with "$file" "$@" 2>&1 || compose_exit=$?
    [ "$compose_exit" -eq 0 ] || fail "docker compose -f $file $* exited with $compose_exit"
}

wait_llama_healthy() {
    local url
    url="http://localhost:$(llama_port)/health"
    info "Waiting for llama (up to 900s, first boot loads shaders)..."
    for _ in $(seq 180); do
        if [ "$(http_status "$url")" = 200 ]; then ok "llama is ready."; return 0; fi
        sleep 5
    done
    fail "llama did not become ready within 900s."
}

# compose_image FILE PREFIX: the first image FILE runs whose name starts with PREFIX.
compose_image() {
    compose_with "$1" config --images 2>/dev/null | tr -d '\r' | grep -F -- "$2" | head -n 1 || true
}

local_image_exists() {
    [ -n "$1" ] && docker image ls --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | tr -d '\r' | grep -qxF -- "$1"
}

# get_tailnet_status: the node's ts.net name once it runs on the tailnet, or nothing.
get_tailnet_status() {
    compose_with "$host_llama_compose_file" exec -T tailscale tailscale --socket=/var/run/tailscale/tailscaled.sock status --json 2>/dev/null |
        python3 -c 'import json,sys
try: s = json.load(sys.stdin)
except ValueError: sys.exit(0)
name = (s.get("Self") or {}).get("DNSName") or ""
print(name.rstrip(".") if s.get("BackendState") == "Running" else "")' 2>/dev/null | tr -d '\r' || true
}

# Hindsight itself does not need the tailnet, so a node that cannot join only loses the tailnet
# address; the gateway's certificate is for the ts.net name, written to config.env first.
connect_tailnet() {
    local tailnet_host="" deadline hint
    step "[0b] Joining the tailnet..."
    compose_with "$host_llama_compose_file" up -d tailscale >/dev/null 2>&1 || true
    deadline=$((SECONDS + 60))
    for _ in $(seq 30); do
        [ "$SECONDS" -lt "$deadline" ] || break
        tailnet_host=$(get_tailnet_status)
        [ -z "$tailnet_host" ] || break
        sleep 2
    done
    if [ -n "$tailnet_host" ]; then
        ok "Joined as $tailnet_host"
        if [ "$(config_value HINDSIGHT_HOST)" != "$tailnet_host" ]; then
            set_config_value HINDSIGHT_HOST "$tailnet_host"
            ok "Wrote HINDSIGHT_HOST to config.env."
        fi
        return 0
    fi
    hint="TS_AUTHKEY in config.env is empty"
    [ -z "$(config_value TS_AUTHKEY)" ] || hint="an expired or used-up TS_AUTHKEY is the usual cause"
    info "Not on the tailnet ($hint); the control plane is on localhost only."
}

show_urls() {
    local tailnet_host
    tailnet_host=$(config_value HINDSIGHT_HOST)
    echo "  Control plane : http://localhost:9999"
    if [ -n "$tailnet_host" ]; then echo "  On the tailnet: https://$tailnet_host   (from any device on your tailnet)"; fi
    echo "  Hindsight API : http://localhost:8888   (this PC only)"
    echo "  llama API     : http://localhost:$(llama_port)"
}

# download_model PATH: fetches the model into PATH.part and renames it once complete. A failed
# download keeps the .part, so the next start resumes it (curl -C -) instead of starting over.
download_model() {
    local model_path=$1 part="$1.part" model_file
    model_file=$(basename "$model_path")
    step "[1] Downloading model ($model_file, ~4.4 GB)..."
    curl -fL --retry 3 -C - -o "$part" "$(config_value MODEL_URL "$default_model_url")" ||
        fail "The model download failed; $part is kept and the next start resumes it."
    mv "$part" "$model_path"
    ok "Model downloaded."
}

warn_native_llama_setting() {
    [ "$(config_value DOCKER_LLAMA)" != true ] || return 0
    info "DOCKER_LLAMA=$(config_value DOCKER_LLAMA) selects the native Windows llama-server, which this CLI does not run; using the Docker llama."
}

# load_or_pull_images FILE: loads images/stack-images.tar when the hindsight image is missing and the
# tar exists, which spares the ~14 GB pull after a clean reinstall; pulls only when neither is there.
load_or_pull_images() {
    local file=$1 have_images=false
    if local_image_exists "$(compose_image "$file" "ghcr.io/vectorize-io/hindsight:")"; then have_images=true; fi
    if ! $have_images && [ -f "$image_tar" ]; then
        step "[3] Loading stack images from local tar (offline, skips ~14 GB re-pull)..."
        docker load -i "$image_tar" || fail "docker load -i $image_tar failed."
        have_images=true
    fi
    if $have_images; then
        step "[4] Images present locally - skipping pull."
    else
        step "[4] Pulling images (no local tar found)..."
        run_compose "$file" pull
    fi
}

start_stack() {
    local model_path file
    assert_config_exists
    model_path="$model_dir/$(config_value MODEL_FILE "$default_model_file")"
    connect_tailnet
    step "[0] Stopping any previous stack..."
    stop_docker_container "$llama_container"
    stop_docker_container "$server_container"

    mkdir -p "$model_dir"
    if [ -f "$model_path" ]; then step "[1] Model already present."; else download_model "$model_path"; fi

    warn_native_llama_setting
    file=$(gpu_compose_file)
    [ -n "$file" ] || fail "No supported GPU found (need NVIDIA via nvidia-smi; the AMD Vulkan image over WSL's /dev/dxg is Windows-only)."
    step "[2] GPU: $file"
    load_or_pull_images "$file"
    step "[5] Starting Docker stack..."
    run_compose "$file" up -d --remove-orphans
    step "[6] Waiting for llama to be healthy (slow first model load)..."
    wait_llama_healthy

    echo
    printf '\033[32m%s\033[0m\n' "Stack is up."
    show_urls
}

# stop_stack: every step runs even when one before it failed, so the compose down is always reached;
# the exit code says whether all of them worked.
stop_stack() {
    local file failed=false
    step "Stopping everything..."
    stop_docker_container "$server_container"
    stop_docker_container "$llama_container"
    file=$(gpu_compose_file)
    if [ -n "$file" ]; then
        compose_with "$file" down 2>&1 || { err "docker compose -f $file down failed."; failed=true; }
    fi
    compose_with "$host_llama_compose_file" down 2>&1 || { err "docker compose -f $host_llama_compose_file down failed."; failed=true; }
    if $failed; then exit 1; fi
    ok "Done."
}

case "${1:-}" in
    start) start_stack ;;
    stop)  stop_stack ;;
    logs)  exec docker logs -f "$llama_container" ;;
    *)     fail "Usage: ./docker-compose.sh [start|stop|logs]" ;;
esac
