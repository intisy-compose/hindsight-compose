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
    .\docker-compose.ps1 consolidate                 # wait for retains, then consolidate fully
    .\docker-compose.ps1 consolidate -RunImmediately # consolidate now regardless of retain queue
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
. "$PSScriptRoot\config.ps1"
. "$PSScriptRoot\llama-lib.ps1"
. "$PSScriptRoot\backup-sidecar.ps1"

$Root    = Split-Path $PSScriptRoot
$Api     = "http://localhost:8888/v1/default/banks/claude_code/operations"

# config.env feeds docker compose's ${...} interpolation (model alias, ports, etc.)
Import-Config (Join-Path $Root "config.env")
$Compose = Join-Path $Root (Get-StackComposeFile)

function Get-OpCounts {
    $active = @('pending', 'processing')
    # The API returns at most 100 operations, and completed ones fill an unfiltered page.
    $ops = foreach ($status in $active) { (Invoke-RestMethod -Uri "$Api`?status=$status&limit=100").operations }
    [pscustomobject]@{
        RetainPending = @($ops | Where-Object { $_.task_type -match 'retain' -and $_.status -in $active }).Count
        ConsolPending = @($ops | Where-Object { $_.task_type -eq 'consolidation' -and $_.status -in $active }).Count
    }
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
    $ErrorActionPreference = 'Continue'
    docker cp $tmp hindsight-server:/tmp/consol_reset.py 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker cp of the reset script exited with $LASTEXITCODE" }
    docker exec hindsight-server python3 /tmp/consol_reset.py
    if ($LASTEXITCODE -ne 0) { throw "Resetting stale consolidations exited with $LASTEXITCODE" }
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
Restart-Hindsight $Compose
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
Restart-Hindsight $Compose
Write-OK "Done. Consolidation cleared; retains have the GPU again."
