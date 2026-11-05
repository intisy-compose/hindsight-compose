## Stack

| service | image | role |
| --- | --- | --- |
| `hindsight` | `ghcr.io/vectorize-io/hindsight` | the memory API |
| `hindsight-pg0` | postgres | vector + relational store |
| `db-backup` | `postgres` | periodic dumps into `./data/hindsight` |
| `llama` | `gpu/Dockerfile.*` or the llama.cpp CUDA image | local OpenAI-compatible LLM endpoint |

## Compose files

Compose is split so you pick an LLM backend without editing the base:

- `docker-compose.base.yml` - hindsight + postgres + backups (always used).
- `docker-compose.nvidia.yml` - llama with the NVIDIA container runtime.
- `docker-compose.gpu.yml` - llama with WSL GPU passthrough (`/dev/dxg`, Vulkan through Dozen).
  Windows only.
- `docker-compose.hindsight-only.yml` - no bundled llama; point hindsight at an
  LLM already running on the host (`host.docker.internal`).

## Quick start

Requires [Docker](https://docs.docker.com/get-docker/) and an NVIDIA GPU with the NVIDIA container
toolkit, or on Windows an AMD GPU through WSL2.

```bash
git clone --recursive https://github.com/intisy-compose/hindsight-compose
cd hindsight-compose
cp config.env.example config.env   # model, GPU backend, ports, context size

./docker-compose.sh start     # Linux; run it with no valid command to list them
.\docker-compose.ps1 start    # Windows, the same commands

# Or compose directly, choosing a backend overlay (each one includes the base):
docker compose -f docker-compose.nvidia.yml up -d
```

## Two CLIs

`docker-compose.ps1` (Windows) and `docker-compose.sh` (Linux, bash 4.3 or later, with docker, git,
`python3` and `curl`) have the same commands, options spelled `-RunImmediately` and
`--run-immediately`. The Linux CLI runs the Docker llama only: `start` picks
`docker-compose.nvidia.yml` when `nvidia-smi` works and refuses otherwise. The native Windows
llama-server (`DOCKER_LLAMA=false`, with its JSON-repair proxy and the watcher that follows the
`hindsight-llama` container) and the Vulkan image over `/dev/dxg` are the Windows CLI's alone, so
Linux starts no process on the host.

## Deleting the stack

`stop` keeps the node in the tailnet, so the next `start` comes back under the same name. To remove
the stack for good, run `.\docker-compose.ps1 delete` (or `./docker-compose.sh delete`), then remove
the folder. `delete` runs `stop` (the native llama, its proxy and watcher included), removes the node
from the tailnet, and removes `data/tailscale`, so a later `start` joins fresh. It finds the node by
the stable node ID in `data/tailscale/tailscaled.state`, never by its name, so another device named
`hindsight` stays.

The removal goes through the Tailscale API with `TS_API_TOKEN` from `config.env`: an access token
from [Settings, Keys](https://login.tailscale.com/admin/settings/keys) of an account that may remove
devices (Owner, Admin or IT admin). Without one, `delete` prints the node's name and ID to remove on
the [Machines page](https://login.tailscale.com/admin/machines) instead. When the API refuses or
does not answer, `data/tailscale` stays and `delete` can run again. When `stop` fails, nothing is
removed. The volumes stay in Docker until `docker volume rm` removes them; the database is also in
the dumps under `data/`.

## Configuration

`config.env` (gitignored; copy from `config.env.example`) selects the model
(`MODEL_FILE`, `MODEL_URL`, `MODEL_ALIAS`), GPU backend (`DOCKER_LLAMA`,
`GPU_TYPE`), ports (`LLAMA_PORT`) and llama.cpp tuning (`LLAMA_CTX`, `LLAMA_NGL`,
`LLAMA_KV_CACHE_TYPE`, ...). Defaults suit a 12 GB GPU.

`DOCKER_LLAMA=false` runs a native Windows llama-server next to
`docker-compose.hindsight-only.yml` instead of the containerised llama; the Linux CLI says so and
runs the Docker llama.

Maintenance runs through the same CLI: `consolidate`, `reingest`, `restore`, `save-images` and
`prove-data`. Their implementations live in `scripts/` (a `.ps1` and a `.sh` each), which is not
meant to be run directly. `restore` applies a dump in one transaction and stops at the first error,
into `hindsight` or, with `--database` (`-Database`), another existing database. Before anything is
copied it refuses a dump that does not end with pg_dump's trailer or holds no row of
`public.memory_units`, because its `--clean` would otherwise empty the database; by default it takes
the newest `hindsight-YYYYMMDD-HHMMSS.sql` that passes.

The database restores itself: when the pg0 volume comes up empty, the `db-backup` sidecar restores
the newest dump in `data/hindsight` before anything else uses it, so neither CLI takes a restore
decision. `prove-data` deletes the volume and proves that.

`data/` is its own git repo (a submodule), defaulting to the public
[`hindsight-data-template`](https://github.com/intisy-compose/hindsight-data-template). Point it at
your own with `./docker-compose.sh data use <owner/repo[@ref]>`. The dumps and model weights inside
it are gitignored there, and `images/` and `llama-win/` are gitignored here: all of them are
downloaded or built on first run, never committed.

`tests/cli/run.sh` tests the Linux CLI against fakes of docker, curl, git and nvidia-smi; run it
from a worktree or CI, never from a live stack's folder.
