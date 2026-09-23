## Stack

| service | image | role |
| --- | --- | --- |
| `hindsight` | `ghcr.io/vectorize-io/hindsight` | the memory API |
| `hindsight-pg0` | postgres | vector + relational store |
| `db-backup` | `postgres:18-alpine` | periodic dumps into `./data/hindsight` |
| `llama` | built from `gpu/Dockerfile.*` | local OpenAI-compatible LLM endpoint |

## Compose files

Compose is split so you pick an LLM backend without editing the base:

- `docker-compose.base.yml` - hindsight + postgres + backups (always used).
- `docker-compose.gpu.yml` - llama with WSL GPU passthrough (`/dev/dxg`, Vulkan/CUDA).
- `docker-compose.nvidia.yml` - llama with the NVIDIA container runtime.
- `docker-compose.hindsight-only.yml` - no bundled llama; point hindsight at an
  LLM already running on the host (`host.docker.internal`).

## Quick start

Requires [Docker](https://docs.docker.com/get-docker/). For GPU modes, a working
WSL2 GPU setup or the NVIDIA container toolkit.

```bash
git clone https://github.com/intisy-compose/hindsight-compose
cd hindsight-compose
cp config.env.example config.env   # model, GPU backend, ports, context size

# Windows launcher (start | stop | logs)
./docker-compose.ps1 start

# Or compose directly, choosing a backend overlay:
docker compose -f docker-compose.base.yml -f docker-compose.gpu.yml up -d
```

## Configuration

`config.env` (gitignored; copy from `config.env.example`) selects the model
(`MODEL_FILE`, `MODEL_URL`, `MODEL_ALIAS`), GPU backend (`DOCKER_LLAMA`,
`GPU_TYPE`), ports (`LLAMA_PORT`) and llama.cpp tuning (`LLAMA_CTX`, `LLAMA_NGL`,
`LLAMA_KV_CACHE_TYPE`, ...). Defaults suit a 12 GB GPU.

Model weights, the Postgres volume and llama binaries are large and live under
`data/`, `images/` and `llama-win/`, all gitignored - they are downloaded or
built on first run, never committed.
