#!/bin/bash
# Unix counterpart of docker-compose.ps1. Commands: start | stop | logs
# llama always runs in a container here: the native llama-server path is Windows-only.
cd "$(dirname "$0")"

if [ ! -f config.env ]; then
    echo "Config not found: config.env - copy config.env.example and edit it." >&2; exit 1
fi
set -a
# shellcheck disable=SC1091
. <(grep -E '^[^#]+=' config.env)
set +a

MODEL_FILE="${MODEL_FILE:-Qwen2.5-7B-Instruct-Q4_K_M.gguf}"
MODEL_URL="${MODEL_URL:-https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf}"
LLAMA_PORT="${LLAMA_PORT:-11434}"
ALL_COMPOSE_FILES=(docker-compose.nvidia.yml docker-compose.gpu.yml docker-compose.hindsight-only.yml)

select_compose_file() {
    if [ "${DOCKER_LLAMA:-}" != "true" ]; then
        echo docker-compose.hindsight-only.yml
    elif command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        echo docker-compose.nvidia.yml
    elif [ -e /dev/dxg ]; then
        echo docker-compose.gpu.yml
    else
        echo docker-compose.hindsight-only.yml
    fi
}

download_model() {
    mkdir -p data/llama
    [ -f "data/llama/$MODEL_FILE" ] && return
    echo "Downloading model ($MODEL_FILE)..."
    curl -fL --progress-bar -o "data/llama/$MODEL_FILE.part" "$MODEL_URL" \
        && mv "data/llama/$MODEL_FILE.part" "data/llama/$MODEL_FILE"
}

start_stack() {
    local compose_file
    compose_file=$(select_compose_file)
    echo "Compose file: $compose_file"
    if [ "$compose_file" = docker-compose.hindsight-only.yml ]; then
        echo "No bundled llama: hindsight expects an LLM on the host at :$LLAMA_PORT."
    else
        download_model || exit 1
    fi
    docker compose -f "$compose_file" up -d --build --remove-orphans || exit 1
    echo
    echo "Stack is up."
    echo "  Hindsight UI : http://localhost:8888"
    echo "  llama API    : http://localhost:$LLAMA_PORT"
}

stop_stack() {
    echo "Stopping everything..."
    for compose_file in "${ALL_COMPOSE_FILES[@]}"; do
        docker compose -f "$compose_file" down >/dev/null 2>&1
    done
    echo "Done."
}

case "${1:-start}" in
    start) start_stack ;;
    stop)  stop_stack ;;
    logs)  docker logs -f llama ;;
    *)
        echo "Usage: ./docker-compose.sh [start|stop|logs]"
        echo "  start  Start the full stack (default)"
        echo "  stop   Stop everything"
        echo "  logs   Tail llama output"
        exit 1
        ;;
esac
