#Requires -Version 5.1
<#
.SYNOPSIS
    Shared lifecycle helpers for the native llama-server.exe + JSON-repair proxy.

    Single source of truth for the launch arguments and start/stop logic, used by
    both hindsight.ps1 (stack start/stop) and llama-watcher.ps1 (docker-event reactions).
    Keeping them here prevents the two callers' launch flags from drifting apart.

    Callers must load config into the process environment first (hindsight.ps1 via
    docker-compose.ps1's Import-Config; llama-watcher.ps1 by reading config.env).
#>

# Directory of this library (= the scripts/ folder). Captured at load time so the
# path helpers resolve correctly no matter which script dot-sources us.
$script:LlamaScriptsDir = $PSScriptRoot

function Get-LlamaPaths {
    $scriptsDir = $script:LlamaScriptsDir
    $rootDir    = Split-Path $scriptsDir
    $llamaWin   = Join-Path $rootDir "llama-win"
    $modelFile  = if ($env:MODEL_FILE) { $env:MODEL_FILE } else { "Qwen2.5-7B-Instruct-Q4_K_M.gguf" }
    [pscustomobject]@{
        Root        = $rootDir
        LlamaWin    = $llamaWin
        LlamaExe    = Join-Path $llamaWin "llama-server.exe"
        LlamaPid    = Join-Path $llamaWin "llama.pid"
        ProxyPid    = Join-Path $llamaWin "proxy.pid"
        ProxyScript = Join-Path $scriptsDir "llama-proxy.py"
        ModelPath   = Join-Path $rootDir "data\llama\$modelFile"
    }
}

function Get-LlamaConfig {
    $listenPort = [int]$(if ($env:LLAMA_PORT) { $env:LLAMA_PORT } else { 11434 })
    [pscustomobject]@{
        ListenPort   = $listenPort        # port the proxy listens on (what Hindsight calls)
        InternalPort = $listenPort + 1     # port llama-server listens on (behind the proxy)
        GpuLayers    = [int]$(if ($env:LLAMA_NGL)          { $env:LLAMA_NGL }          else { 99 })
        ContextSize  = [int]$(if ($env:LLAMA_CTX)          { $env:LLAMA_CTX }          else { 8192 })
        Parallel     = [int]$(if ($env:LLAMA_PARALLEL)     { $env:LLAMA_PARALLEL }     else { 1 })
        HttpThreads  = [int]$(if ($env:LLAMA_THREADS_HTTP) { $env:LLAMA_THREADS_HTTP } else { 2 })
        UbatchSize   = [int]$(if ($env:LLAMA_UBATCH_SIZE)  { $env:LLAMA_UBATCH_SIZE }  else { 256 })
        KvCacheType  = if ($env:LLAMA_KV_CACHE_TYPE) { $env:LLAMA_KV_CACHE_TYPE } else { "f16" }
        ModelAlias   = if ($env:MODEL_ALIAS) { $env:MODEL_ALIAS } else { "qwen2.5:7b" }
    }
}

# Stop the proxy and llama-server, removing their PID files. Also force-kills any
# orphaned llama-server.exe by name so a stale process can't hold the GPU/port.
function Stop-NativeLlamaAndProxy {
    $paths = Get-LlamaPaths
    foreach ($pidFile in @($paths.ProxyPid, $paths.LlamaPid)) {
        if (Test-Path $pidFile) {
            $savedProcessId = [int](Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
            Stop-Process -Id $savedProcessId -Force -ErrorAction SilentlyContinue
            Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        }
    }
    Get-Process -Name "llama-server" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

# Start llama-server.exe (on InternalPort) and the JSON-repair proxy (on ListenPort).
# With -SkipIfRunning, returns $null without touching anything if llama-server is
# already alive — so reacting to a duplicate docker 'start' event won't kill a live server.
# Otherwise clears any stale processes, starts both, writes PID files, and returns
# an object with the .Llama and .Proxy process handles.
function Start-NativeLlamaAndProxy {
    [CmdletBinding()]
    param([switch]$SkipIfRunning)

    $paths  = Get-LlamaPaths
    $config = Get-LlamaConfig

    if ($SkipIfRunning -and (Test-Path $paths.LlamaPid)) {
        $existingProcessId = [int](Get-Content $paths.LlamaPid -Raw -ErrorAction SilentlyContinue).Trim()
        if (Get-Process -Id $existingProcessId -ErrorAction SilentlyContinue) {
            return $null
        }
    }

    Stop-NativeLlamaAndProxy   # clear any stale processes / PID files first

    # flash-attn is required for quantized KV cache; it's always on here and also
    # speeds up attention, so the cache-type flags are safe to pass unconditionally.
    $llamaArguments = @(
        "--model",        $paths.ModelPath,
        "--alias",        $config.ModelAlias,
        "--host",         "127.0.0.1",
        "--port",         "$($config.InternalPort)",
        "-ngl",           "$($config.GpuLayers)",
        "-c",             "$($config.ContextSize)",
        "--parallel",     "$($config.Parallel)",
        "--threads-http", "$($config.HttpThreads)",
        "--ubatch-size",  "$($config.UbatchSize)",
        "--flash-attn",   "on",
        "--cache-type-k", $config.KvCacheType,
        "--cache-type-v", $config.KvCacheType
    )
    $llamaProcess = Start-Process $paths.LlamaExe -ArgumentList $llamaArguments `
                        -WorkingDirectory $paths.LlamaWin -PassThru -WindowStyle Hidden `
                        -RedirectStandardOutput (Join-Path $paths.LlamaWin "llama.log") `
                        -RedirectStandardError  (Join-Path $paths.LlamaWin "llama-err.log")
    $llamaProcess.Id | Set-Content $paths.LlamaPid

    $proxyProcess = Start-Process python3 `
                        -ArgumentList @($paths.ProxyScript, "$($config.ListenPort)", "$($config.InternalPort)") `
                        -PassThru -WindowStyle Hidden `
                        -RedirectStandardOutput (Join-Path $paths.LlamaWin "proxy.log") `
                        -RedirectStandardError  (Join-Path $paths.LlamaWin "proxy-err.log")
    $proxyProcess.Id | Set-Content $paths.ProxyPid

    [pscustomobject]@{ Llama = $llamaProcess; Proxy = $proxyProcess }
}
