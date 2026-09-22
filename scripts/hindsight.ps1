#Requires -Version 5.1
param([string]$Command = "start")


. "$PSScriptRoot\llama-lib.ps1"

function Write-Step([string]$msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-OK([string]$msg)   { Write-Host "  $msg" -ForegroundColor Green }
function Write-Info([string]$msg) { Write-Host "  $msg" -ForegroundColor Gray }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Read config from env vars (set by docker-compose.ps1 via Import-Config).
# llama tuning flags (NGL, CTX, PARALLEL, etc.) are consumed by llama-lib.ps1, not here.
$DockerLlama = $Env:DOCKER_LLAMA -eq "true"
$GpuType     = if ($Env:GPU_TYPE)   { $Env:GPU_TYPE }   else { "vulkan" }
$ModelFile   = if ($Env:MODEL_FILE) { $Env:MODEL_FILE } else { "Qwen2.5-7B-Instruct-Q4_K_M.gguf" }
$ModelUrl    = if ($Env:MODEL_URL)  { $Env:MODEL_URL }  else { "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_K_M.gguf" }
$Port        = [int]$(if ($Env:LLAMA_PORT) { $Env:LLAMA_PORT } else { 11434 })

# Paths
$Root      = Split-Path $PSScriptRoot
$ModelDir  = Join-Path $Root "data\llama"
$LlamaWin  = Join-Path $Root "llama-win"
$LlamaExe  = Join-Path $LlamaWin "llama-server.exe"
$ModelPath  = Join-Path $ModelDir $ModelFile
$WatcherPid = Join-Path $LlamaWin "watcher.pid"


function Stop-NativeLlama {
    # Kill the watcher first so it doesn't react to llama+proxy being stopped below.
    if (Test-Path $WatcherPid) {
        $watcherProcessId = [int](Get-Content $WatcherPid -Raw -ErrorAction SilentlyContinue).Trim()
        if (Get-Process -Id $watcherProcessId -ErrorAction SilentlyContinue) {
            Write-Info "Stopping event watcher (PID $watcherProcessId)..."
            Stop-Process -Id $watcherProcessId -Force
        }
        Remove-Item $WatcherPid -Force
    }
    # llama-server + proxy teardown lives in llama-lib.ps1 (shared with the watcher).
    Stop-NativeLlamaAndProxy
}

function Stop-DockerContainer([string]$Name) {
    $running = docker ps -q --filter "name=^${Name}$" 2>$null
    if ($running) { Write-Info "Stopping container '$Name'..."; docker rm -f $Name 2>$null | Out-Null }
}

function Wait-LlamaHealthy([System.Diagnostics.Process]$Process = $null) {
    $url = "http://localhost:$Port/health"
    Write-Info "Waiting for llama (up to 900s, first boot loads shaders)..."
    for ($i = 0; $i -lt 180; $i++) {
        if ($Process -and $Process.HasExited) {
            throw "llama-server exited (code $($Process.ExitCode)). Check: $LlamaWin\llama-err.log"
        }
        try {
            if ((Invoke-WebRequest $url -TimeoutSec 3 -UseBasicParsing -EA Stop).StatusCode -eq 200) {
                Write-OK "llama is ready."; return
            }
        } catch {}
        Start-Sleep 5
    }
    throw "llama did not become ready within 900s."
}

function Get-DockerComposeFile {
    $nv = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($nv) {
        & nvidia-smi 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return "docker-compose.nvidia.yml" }
    }
    wsl ls /dev/dxg 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { return "docker-compose.gpu.yml" }
    return $null
}

function Start-Stack {
    Write-Step "[0] Stopping any previous stack..."
    Stop-NativeLlama
    Stop-DockerContainer "llama"
    Stop-DockerContainer "hindsight"

    New-Item -ItemType Directory -Force $ModelDir | Out-Null

    if (-not (Test-Path $ModelPath)) {
        Write-Step "[1] Downloading model ($ModelFile, ~4.4 GB)..."
        $part = "$ModelPath.part"
        try {
            Start-BitsTransfer -Source $ModelUrl -Destination $part -DisplayName "llama model" -Description $ModelFile
            Move-Item $part $ModelPath
            Write-OK "Model downloaded."
        } catch { if (Test-Path $part) { Remove-Item $part -Force }; throw }
    } else {
        Write-Step "[1] Model already present."
    }

    if (-not $DockerLlama) {
        # Re-download if missing OR the build doesn't match GPU_TYPE (backend dll absent),
        # so switching GPU_TYPE (vulkan <-> cuda) swaps the binaries automatically.
        $backendDll = if ($GpuType -eq "cuda") { "ggml-cuda.dll" } else { "ggml-vulkan.dll" }
        if (-not ((Test-Path $LlamaExe) -and (Test-Path (Join-Path $LlamaWin $backendDll)))) {
            Write-Step "[2] Downloading llama-server ($GpuType build)..."
            New-Item -ItemType Directory -Force $LlamaWin | Out-Null
            if (Test-Path $LlamaExe) {
                Write-Info "Existing build is not '$GpuType' - clearing old binaries..."
                Get-ChildItem $LlamaWin -File | Where-Object { $_.Extension -in '.exe', '.dll' } | Remove-Item -Force
            }
            try {
                $rel = Invoke-RestMethod "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest" `
                           -Headers @{ "User-Agent" = "hindsight-setup" }
            } catch { throw "GitHub API failed: $_" }
            # CUDA needs TWO zips: the llama build AND the matching CUDA runtime (cudart-*).
            # Both share the '*bin-win-cuda-12.4-x64.zip' suffix. Vulkan is one self-contained zip.
            $pat = if ($GpuType -eq "cuda") { "*bin-win-cuda-12.4-x64.zip" } else { "*win-vulkan*x64*.zip" }
            $assets = @($rel.assets | Where-Object { $_.name -like $pat })
            if (-not $assets) { throw "No asset matching '$pat' in $($rel.tag_name). Available: $($rel.assets.name -join ', ')" }
            foreach ($asset in $assets) {
                Write-Info "Downloading: $($asset.name)"
                $zip = Join-Path $LlamaWin $asset.name
                Start-BitsTransfer -Source $asset.browser_download_url -Destination $zip -DisplayName $asset.name
                Expand-Archive $zip $LlamaWin -Force
                Remove-Item $zip
            }
            # Flatten if the build extracted into a subfolder.
            $sub = Get-ChildItem $LlamaWin -Directory |
                       Where-Object { Test-Path (Join-Path $_.FullName "llama-server.exe") } | Select-Object -First 1
            if ($sub) {
                Get-ChildItem $sub.FullName | Move-Item -Destination $LlamaWin -Force
                Remove-Item $sub.FullName -Force
            }
            if (-not (Test-Path $LlamaExe)) { throw "llama-server.exe not found after extraction in $LlamaWin" }
            Write-OK "llama-server ready ($GpuType)."
        } else {
            Write-Step "[2] llama-server ($GpuType) already present."
        }

        # llama-server runs on Port+1; the proxy listens on Port, strips grammar
        # constraints, and repairs malformed JSON. Both are launched via llama-lib.ps1.
        Write-Step "[3] Starting native llama-server ($GpuType) + JSON-repair proxy (:$Port -> :$($Port + 1))..."
        $started = Start-NativeLlamaAndProxy
        Write-OK "llama-server PID $($started.Llama.Id), proxy PID $($started.Proxy.Id) - logs: $LlamaWin\llama.log"

        Write-Step "[3c] Starting llama controller container..."
        # docker compose stderr (pull/up progress) must not abort under $ErrorActionPreference='Stop'
        try { docker compose -f "$Root\docker-compose.hindsight-only.yml" up -d llama 2>$null | Out-Null } catch {}
        Write-OK "Container 'llama' started — 'docker stop llama' to kill, 'docker start llama' to restart."

        Write-Step "[3d] Starting docker-event watcher..."
        $WatcherScript = Join-Path $PSScriptRoot "llama-watcher.ps1"
        $watcherProc = Start-Process powershell `
            -ArgumentList @("-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $WatcherScript) `
            -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $LlamaWin "watcher.log") `
            -RedirectStandardError  (Join-Path $LlamaWin "watcher-err.log")
        $watcherProc.Id | Set-Content $WatcherPid
        Write-OK "Watcher started (PID $($watcherProc.Id)) — logs: $LlamaWin\watcher.log"

        Write-Step "[4] Waiting for llama to be healthy..."
        Wait-LlamaHealthy -Process $started.Llama

        Write-Step "[5] Starting Hindsight container..."
        docker compose -f "$Root\docker-compose.hindsight-only.yml" pull hindsight
        docker compose -f "$Root\docker-compose.hindsight-only.yml" up -d --remove-orphans

    } else {
        $cf = Get-DockerComposeFile
        if (-not $cf) { throw "No supported GPU found (need NVIDIA via nvidia-smi or AMD via WSL /dev/dxg)." }
        Write-Step "[2] GPU: $cf"

        # Offline recovery: if the stack images are gone (e.g. clean reinstall) but the saved
        # tar exists, load it locally instead of re-pulling ~14 GB. Sentinel = hindsight image.
        $imageTar   = Join-Path $Root "images\stack-images.tar"
        $haveImages = [bool](docker image ls --format "{{.Repository}}:{{.Tag}}" 2>$null |
                          Where-Object { $_ -eq "ghcr.io/vectorize-io/hindsight:latest" })
        if (-not $haveImages -and (Test-Path $imageTar)) {
            Write-Step "[3] Loading stack images from local tar (offline, skips ~14 GB re-pull)..."
            docker load -i $imageTar
            $haveImages = $true
        }

        # CUDA uses the official prebuilt image (no build). Only AMD/Vulkan builds locally.
        if ($cf -eq "docker-compose.gpu.yml") {
            $built = docker image ls --format "{{.Repository}}:{{.Tag}}" 2>$null |
                         Where-Object { $_ -eq "llama-vulkan-dozen:latest" }
            if (-not $built) {
                Write-Step "[3b] Building Vulkan llama image (first time only)..."
                docker compose -f "$Root\$cf" build llama
            }
        }

        if (-not $haveImages) {
            Write-Step "[4] Pulling images (no local tar found)..."
            docker compose -f "$Root\$cf" pull 2>$null
        } else {
            Write-Step "[4] Images present locally - skipping pull."
        }
        Write-Step "[5] Starting Docker stack..."
        docker compose -f "$Root\$cf" up -d --remove-orphans
        Write-Step "[6] Waiting for llama to be healthy (slow first model load)..."
        Wait-LlamaHealthy
    }

    Write-Host ""
    Write-Host "Stack is up." -ForegroundColor Green
    Write-Host "  Hindsight UI : http://localhost:8888"
    Write-Host "  llama API    : http://localhost:$Port"
    if (-not $DockerLlama) {
        Write-Host "  llama logs   : .\docker-compose.ps1 logs"
    }
}

function Stop-Stack {
    Write-Step "Stopping everything..."
    Stop-NativeLlama
    Stop-DockerContainer "hindsight"
    Stop-DockerContainer "llama"
    if ($DockerLlama) {
        $cf = Get-DockerComposeFile
        if ($cf) { docker compose -f "$Root\$cf" down *>$null }
    }
    docker compose -f "$Root\docker-compose.hindsight-only.yml" down *>$null
    Write-OK "Done."
}

switch ($Command.ToLower()) {
    "start" { Start-Stack }
    "stop"  { Stop-Stack }
    "logs"  {
        $logFile = Join-Path $LlamaWin "llama.log"
        if (-not $DockerLlama -and (Test-Path $logFile)) {
            Get-Content -Tail 50 -Wait $logFile
        } else {
            docker logs llama -f
        }
    }
    default {
        Write-Host "Usage: .\docker-compose.ps1 [start|stop|logs]"
        Write-Host "  start  Start everything (default)"
        Write-Host "  stop   Stop everything - native llama + all containers"
        Write-Host "  logs   Tail llama output"
        exit 1
    }
}




