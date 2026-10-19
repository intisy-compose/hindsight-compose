#Requires -Version 5.1
<#
.SYNOPSIS
    Prove that a deleted database volume comes back: count every table, stop the stack, delete the
    pg0 volume, start the stack, wait for the self-restore, count again. Any difference exits 1.
    DESTRUCTIVE: it deletes the database volume. Run it only with the owner's go-ahead.

.NOTES
    The stack must be running (hindsight-server and hindsight-db-backup), because the counts come from the
    embedded Postgres. The restore itself is the db-backup sidecar's restore_if_empty, which reads the
    newest dump from data/hindsight; a fresh dump is always written right before the "before" count, so
    writes after an older dump cannot look like a failed restore. The database must hold data: the wait
    ends when public.memory_units is non-empty. public.async_operations is printed but not compared,
    because the worker rewrites it after a restore (processing back to pending).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "data-on-disk.ps1")

$Root = Split-Path $PSScriptRoot
$DumpFolder = Join-Path $Root "data\hindsight"
$Pg0Volume = "hindsight-compose_hindsight-pg0"
$ServerContainer = "hindsight-server"
$BackupContainer = "hindsight-db-backup"
$UncomparedTables = @("public.async_operations")
$RestoreTimeoutMinutes = 15
$MemoryTable = "public.memory_units"

function Write-Step([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Info([string]$Message) { Write-Host "  $Message" -ForegroundColor Gray }

function Invoke-Stack([string]$Verb) {
    & (Join-Path $Root "docker-compose.ps1") $Verb
    if ($LASTEXITCODE -ne 0) { throw "docker-compose.ps1 $Verb failed with exit code $LASTEXITCODE" }
}

function Test-ContainerIsRunning([string]$Name) {
    return [bool](docker ps -q --filter "name=^$Name$")
}

function Get-Pg0PsqlPath {
    $path = docker exec $ServerContainer sh -c "ls -d /home/hindsight/.pg0/installation/*/bin/psql 2>/dev/null | head -n 1"
    if ($LASTEXITCODE -ne 0 -or -not $path) { throw "pg0's psql was not found in $ServerContainer" }
    return "$path".Trim()
}

function Get-HindsightTableCounts {
    return Get-TableRowCounts -Container $ServerContainer -DatabaseHost "127.0.0.1" -User "hindsight" -Database "hindsight" -Psql (Get-Pg0PsqlPath) -Password "hindsight"
}

function Write-FreshDump {
    $script = 'timestamp=$(date +%Y%m%d-%H%M%S); pg_dump -h 127.0.0.1 -U hindsight -d hindsight --no-owner --clean --if-exists > /backups/hindsight-$timestamp.sql.tmp && mv /backups/hindsight-$timestamp.sql.tmp /backups/hindsight-$timestamp.sql'
    docker exec -e PGPASSWORD=hindsight $BackupContainer sh -c $script
    if ($LASTEXITCODE -ne 0) { throw "the fresh dump failed" }
}

function Write-VerifiedFreshDump {
    Write-FreshDump
    $newest = Get-NewestDump $DumpFolder "hindsight-*.sql"
    if (-not $newest) { throw "no complete dump exists in $DumpFolder" }
    Write-Info "dump $($newest.Name)"
}

function Wait-ForRestore {
    $deadline = (Get-Date).AddMinutes($RestoreTimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        try {
            $counts = Get-HindsightTableCounts
            if ($counts.Contains($MemoryTable) -and $counts[$MemoryTable] -gt 0) { return }
        }
        catch { Write-Info "database not answering yet" }
    }
    throw "$MemoryTable stayed empty for $RestoreTimeoutMinutes minutes"
}

function Compare-Counts([System.Collections.IDictionary]$Before, [System.Collections.IDictionary]$After, [string[]]$Uncompared = @()) {
    $differences = @()
    foreach ($name in (@($Before.Keys) + @($After.Keys) | Sort-Object -Unique)) {
        if ($name -in $Uncompared) { continue }
        $beforeCount = if ($Before.Contains($name)) { $Before[$name] } else { "missing" }
        $afterCount = if ($After.Contains($name)) { $After[$name] } else { "missing" }
        if ("$beforeCount" -ne "$afterCount") { $differences += "$name before=$beforeCount after=$afterCount" }
    }
    return $differences
}

function Write-UncomparedCounts([System.Collections.IDictionary]$Before, [System.Collections.IDictionary]$After) {
    foreach ($name in $UncomparedTables) {
        $beforeCount = if ($Before.Contains($name)) { $Before[$name] } else { "missing" }
        $afterCount = if ($After.Contains($name)) { $After[$name] } else { "missing" }
        Write-Info "$name (not compared) before=$beforeCount after=$afterCount"
    }
}

foreach ($container in @($ServerContainer, $BackupContainer)) {
    if (-not (Test-ContainerIsRunning $container)) { throw "$container is not running; start the stack first (both $ServerContainer and $BackupContainer must be up)" }
}

Write-Step "Writing a fresh dump ..."
Write-VerifiedFreshDump

Write-Step "Counting rows before ..."
$before = Get-HindsightTableCounts
Write-Info "$($before.Count) tables, $MemoryTable = $($before[$MemoryTable])"

Write-Step "Stopping the stack and deleting $Pg0Volume ..."
Invoke-Stack "stop"
docker volume rm $Pg0Volume
if ($LASTEXITCODE -ne 0) { throw "could not remove $Pg0Volume" }

Write-Step "Starting the stack and waiting for the self-restore ..."
Invoke-Stack "start"
Wait-ForRestore

Write-Step "Counting rows after ..."
$after = Get-HindsightTableCounts
Write-UncomparedCounts $before $after
$differences = Compare-Counts $before $after $UncomparedTables
if ($differences) {
    $differences | ForEach-Object { Write-Host "  DIFFERS $_" -ForegroundColor Red }
    exit 1
}
Write-Host "  all $($after.Count) tables match" -ForegroundColor Green
