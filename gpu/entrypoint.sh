#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_DIR="${MODEL_DIR:-/models}"
MODEL_FILE="${MODEL_FILE:-Qwen2.5-7B-Instruct-Q4_K_M.gguf}"
MODEL_URL="${MODEL_URL:-https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf}"
NGL="${NGL:-99}"
CTX="${CTX:-8192}"
PORT="${PORT:-11434}"
ALIAS="${MODEL_ALIAS:-qwen2.5:7b}"

mkdir -p "$MODEL_DIR"
MODEL_PATH="$MODEL_DIR/$MODEL_FILE"

if [[ "${GPU_BACKEND:-}" == "cuda" ]]; then
  echo "[entrypoint] CUDA devices:"
  nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null \
    || echo "[entrypoint] WARNING: no NVIDIA device found"
else
  echo "[entrypoint] Vulkan devices:"
  vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName' \
    || echo "[entrypoint] WARNING: no Vulkan device enumerated (check /dev/dxg + /usr/lib/wsl mount)"
fi

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "[entrypoint] Downloading model -> $MODEL_PATH"
  wget -c --tries=20 --retry-connrefused --waitretry=5 --timeout=30 \
       --progress=dot:giga -O "$MODEL_PATH.part" "$MODEL_URL"
  mv "$MODEL_PATH.part" "$MODEL_PATH"
fi
echo "[entrypoint] Model: $(ls -la "$MODEL_PATH")"

echo "[entrypoint] Starting llama-server (ngl=$NGL ctx=$CTX port=$PORT alias=$ALIAS)"
exec /opt/llama/bin/llama-server \
  --model "$MODEL_PATH" \
  --alias "$ALIAS" \
  --host 0.0.0.0 --port "$PORT" \
  -ngl "$NGL" -c "$CTX" \
  "$@"
