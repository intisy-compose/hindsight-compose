#Requires -Version 5.1
<#
.SYNOPSIS
    Runs a one-off Hindsight consolidation pass to completion, then returns the stack
    to retain-only mode. Intended for idle time (e.g. nightly, or "after everything is
    done") so consolidation never competes with live retains on the single GPU.

    By default it first waits for the retain queue to drain, then enables consolidation
    (HINDSIGHT_CONSOLIDATION_SLOTS=1), lets it finish, and switches it back off.

.PARAMETER RunImmediately
    Skip waiting for live retains; start consolidating right away.
.PARAMETER PollSeconds
    How often to poll operation counts (default 30s).
.EXAMPLE
    .\scripts\consolidate.ps1                 # wait for retains, then consolidate fully
    .\scripts\consolidate.ps1 -RunImmediately # consolidate now regardless of retain queue
#>
param(
    [switch]$RunImmediately,
    [int]$PollSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$m) { Write-Host $m -ForegroundColor Cyan }
function Write-OK([string]$m)   { Write-Host "  $m" -ForegroundColor Green }
function Write-Info([string]$m) { Write-Host "  $m" -ForegroundColor Gray }
function Import-Config([string]$Path) {
    foreach ($line in Get-Content $Path -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') {
            [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
}

$Root    = Split-Path $PSScriptRoot
$Compose = Join-Path $Root "docker-compose.hindsight-only.yml"
$Api     = "http://localhost:8888/v1/default/banks/claude_code/operations"

# config.env feeds docker compose's ${...} interpolation (model alias, ports, etc.)
Import-Config (Join-Path $Root "config.env")

function Get-OpCounts {
    $ops = (Invoke-RestMethod -Uri "$Api`?limit=200").operations
    $active = @('pending', 'processing')
    [pscustomobject]@{
        RetainPending = @($ops | Where-Object { $_.task_type -match 'retain' -and $_.status -in $active }).Count
        ConsolPending = @($ops | Where-Object { $_.task_type -eq 'consolidation' -and $_.status -in $active }).Count
    }
}

function Restart-Hindsight {
    docker compose -f $Compose up -d hindsight 2>$null | Out-Null
    for ($i = 0; $i -lt 40; $i++) {
        try { if ((Invoke-WebRequest "http://localhost:8888/health" -TimeoutSec 3 -UseBasicParsing -EA Stop).StatusCode -eq 200) { return } } catch {}
        Start-Sleep 3
    }
    throw "Hindsight did not become healthy after restart."
}

# Free any consolidation op a previous (now-gone) worker left in 'processing'.
function Reset-StaleConsolidation {
    $py = @'
import asyncio, asyncpg
async def run():
    c = await asyncpg.connect("postgresql://hindsight:hindsight@127.0.0.1:5432/hindsight")
    r = await c.execute("UPDATE async_operations SET status='pending', worker_id=NULL, claimed_at=NULL WHERE status='processing' AND operation_type='consolidation' AND task_payload IS NOT NULL")
    print("reset stale consolidation:", r)
    await c.close()
asyncio.run(run())
'@
    $tmp = Join-Path $env:TEMP "consol_reset.py"
    $py | Set-Content $tmp
    docker cp $tmp hindsight:/tmp/consol_reset.py | Out-Null
    docker exec hindsight python3 /tmp/consol_reset.py
}

if (-not $RunImmediately) {
    Write-Step "Waiting for live retains to finish before consolidating..."
    while ((Get-OpCounts).RetainPending -gt 0) {
        Write-Info "retains still pending: $((Get-OpCounts).RetainPending)"
        Start-Sleep $PollSeconds
    }
    Write-OK "Retain queue empty."
}

Write-Step "Enabling consolidation (dedicated pass)..."
$env:HINDSIGHT_CONSOLIDATION_SLOTS = "1"
Restart-Hindsight
Reset-StaleConsolidation

Write-Step "Consolidating to completion (polling every ${PollSeconds}s)..."
# Require two consecutive empty polls -Hindsight briefly has 0 ops between batches.
$emptyStreak = 0
do {
    Start-Sleep $PollSeconds
    $counts = Get-OpCounts
    Write-Info "consolidation pending/processing: $($counts.ConsolPending)  (retains waiting: $($counts.RetainPending))"
    if ($counts.ConsolPending -eq 0) { $emptyStreak++ } else { $emptyStreak = 0 }
} while ($emptyStreak -lt 2)

Write-Step "Consolidation complete -returning to retain-only mode..."
$env:HINDSIGHT_CONSOLIDATION_SLOTS = "0"
Restart-Hindsight
Write-OK "Done. Consolidation cleared; retains have the GPU again."
