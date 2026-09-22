#Requires -Version 5.1
<#
.SYNOPSIS
    Restore the Hindsight database from a host-side SQL dump created by backup.ps1.
    Use after a Docker reinstall (or any data loss) to recover the memory bank.

.PARAMETER File  Path to a specific .sql dump. Defaults to the newest in backups\.
.EXAMPLE
    .\scripts\restore.ps1            # restore the newest backup
    .\scripts\restore.ps1 -File ...  # restore a specific dump
#>
param([string]$File)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$m) { Write-Host $m -ForegroundColor Cyan }
function Write-OK([string]$m)   { Write-Host "  $m" -ForegroundColor Green }
function Write-Info([string]$m) { Write-Host "  $m" -ForegroundColor Gray }

$Root      = Split-Path $PSScriptRoot
$BackupDir = Join-Path $Root "data\hindsight"   # where the db-backup sidecar writes dumps

if (-not $File) {
    $latest = Get-ChildItem $BackupDir -Filter "hindsight-*.sql" -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { throw "No backups found in $BackupDir" }
    $File = $latest.FullName
}
if (-not (Test-Path $File)) { throw "Backup not found: $File" }

$running = docker ps -q --filter "name=^hindsight$" 2>$null
if (-not $running) { throw "hindsight container is not running. Start the stack first." }

Write-Step "Restoring Hindsight DB from $File ..."
docker cp $File hindsight:/tmp/hindsight-restore.sql | Out-Null
docker exec hindsight sh -c "PGPASSWORD=hindsight /home/hindsight/.pg0/installation/*/bin/psql -h 127.0.0.1 -U hindsight -d hindsight -v ON_ERROR_STOP=0 -f /tmp/hindsight-restore.sql" 2>&1 | Select-String -Pattern "ERROR|ROLLBACK|COPY|INSERT 0" | Select-Object -Last 10
docker exec hindsight rm -f /tmp/hindsight-restore.sql | Out-Null
Write-OK "Restore finished. Restart hindsight to load the restored data cleanly: docker restart hindsight"
