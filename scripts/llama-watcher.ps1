#Requires -Version 5.1
<#
.SYNOPSIS
    Watches docker events for the hindsight-llama controller container and starts/stops the
    native llama-server.exe + proxy on the host to match.
    Started by hindsight.ps1 on stack start; runs hidden in the background.
    PID is saved to llama-win\watcher.pid. Launch/teardown logic lives in llama-lib.ps1.
#>

. "$PSScriptRoot\llama-lib.ps1"

# Load config.env into the process environment so llama-lib reads the same settings
# hindsight.ps1 used (port, GPU layers, context size, model alias, etc.).
$Root       = Split-Path $PSScriptRoot
$configPath = Join-Path $Root "config.env"
foreach ($line in Get-Content $configPath -ErrorAction Stop) {
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
        [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
    }
}

function Write-Watch([string]$Message) {
    "$(Get-Date -f 'HH:mm:ss') [watcher] $Message"
}

<#
.NOTES
  A destroyed container means the stack was taken down or deleted; `start` launches a new watcher.
  The `docker events` child is killed explicitly because it would otherwise block until its next event.
#>
function Exit-Watcher {
    Write-Watch "Container destroyed, watcher exits."
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$PID AND Name='docker.exe'" |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Remove-Item (Join-Path (Get-LlamaPaths).LlamaWin "watcher.pid") -Force -ErrorAction SilentlyContinue
    exit 0
}

Write-Watch "Watching docker events for container 'hindsight-llama'..."

# Explicit event filters keep healthcheck exec_* noise out of the stream.
docker events `
    --filter "container=hindsight-llama" `
    --filter "event=start" `
    --filter "event=stop" `
    --filter "event=die" `
    --filter "event=destroy" `
    --format "{{.Action}}" |
ForEach-Object {
    Write-Watch "Event: $_"
    switch ($_) {
        "start" {
            $started = Start-NativeLlamaAndProxy -SkipIfRunning
            if ($started) {
                Write-Watch "Started llama-server (PID $($started.Llama.Id)) + proxy (PID $($started.Proxy.Id))."
            } else {
                Write-Watch "llama-server already running, skipped start."
            }
        }
        default {
            # stop / die / destroy all tear the native processes down.
            Stop-NativeLlamaAndProxy
            Write-Watch "Stopped llama-server + proxy."
            if ($_ -eq "destroy") { Exit-Watcher }
        }
    }
}
