#Requires -Version 5.1
<#
.SYNOPSIS
    Restore the Hindsight database from a host-side SQL dump written by the db-backup sidecar.
    Use after a Docker reinstall (or any data loss) to recover the memory bank.

.DESCRIPTION
    The dump is applied in one transaction and psql stops at the first error, so a failed restore
    leaves the database as it was and exits 1 with psql's error lines.

.PARAMETER File      Path to a specific .sql dump. Defaults to the newest in data\hindsight\.
.PARAMETER Database  Database to restore into, inside the same Postgres. Defaults to hindsight.
.EXAMPLE
    .\docker-compose.ps1 restore                          # restore the newest backup
    .\docker-compose.ps1 restore -File ...                # restore a specific dump
    .\docker-compose.ps1 restore -Database scratch        # restore into another, existing database
#>
param([string]$File, [string]$Database = "hindsight")

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$m) { Write-Host $m -ForegroundColor Cyan }
function Write-OK([string]$m)   { Write-Host "  $m" -ForegroundColor Green }
function Write-Fail([string]$m) { Write-Host "  $m" -ForegroundColor Red }

$Root            = Split-Path $PSScriptRoot
$BackupDir       = Join-Path $Root "data\hindsight"   # where the db-backup sidecar writes dumps
$ServerContainer = "hindsight-server"
$ContainerDump   = "/tmp/hindsight-restore.sql"
$ErrorLinePattern = "ERROR|FATAL|psql: error"

<#
.SYNOPSIS
    Run docker and return its output lines and exit code.
.NOTES
    Under PowerShell 5.1 with ErrorActionPreference Stop, a native command's stderr becomes a
    terminating error, so psql's first notice would end the script before its exit code is read.
#>
function Invoke-Docker {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(docker @args 2>&1 | ForEach-Object { "$_" })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return [pscustomobject]@{ Output = $output; ExitCode = $exitCode }
}

function Assert-Docker([object]$Result, [string]$Action) {
    if ($Result.ExitCode -ne 0) {
        $Result.Output | ForEach-Object { Write-Fail $_ }
        throw "$Action failed with exit code $($Result.ExitCode)"
    }
}

function Resolve-DumpFile([string]$Path) {
    if (-not $Path) {
        $latest = Get-ChildItem $BackupDir -Filter "hindsight-*.sql" -ErrorAction SilentlyContinue |
                      Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) { throw "No backups found in $BackupDir" }
        $Path = $latest.FullName
    }
    if (-not (Test-Path $Path)) { throw "Backup not found: $Path" }
    return $Path
}

function Invoke-PsqlRestore([string]$TargetDatabase) {
    $command = "PGPASSWORD=hindsight /home/hindsight/.pg0/installation/*/bin/psql -h 127.0.0.1 -U hindsight -d '$TargetDatabase' -v ON_ERROR_STOP=1 --single-transaction -f $ContainerDump"
    return Invoke-Docker exec $ServerContainer sh -c $command
}

$File = Resolve-DumpFile $File

$running = docker ps -q --filter "name=^$ServerContainer$" 2>$null
if (-not $running) { throw "hindsight container is not running. Start the stack first." }

Write-Step "Restoring Hindsight DB '$Database' from $File ..."
Assert-Docker (Invoke-Docker cp $File "${ServerContainer}:$ContainerDump") "Copying the dump into $ServerContainer"
try {
    $restore = Invoke-PsqlRestore $Database
} finally {
    # docker cp leaves the file owned by root in the sticky /tmp, where the hindsight user cannot delete it.
    $cleanup = Invoke-Docker exec -u root $ServerContainer rm -f $ContainerDump
    if ($cleanup.ExitCode -ne 0) { Write-Fail "Could not remove $ContainerDump from ${ServerContainer}: $($cleanup.Output -join ' ')" }
}

if ($restore.ExitCode -ne 0) {
    $errorLines = @($restore.Output | Where-Object { $_ -match $ErrorLinePattern })
    if (-not $errorLines) { $errorLines = @($restore.Output | Select-Object -Last 10) }
    $errorLines | ForEach-Object { Write-Fail $_ }
    Write-Fail "Restore FAILED: psql exited with $($restore.ExitCode); nothing was committed, '$Database' is unchanged."
    exit 1
}

$restore.Output | Select-String -Pattern "COPY|INSERT 0" | Select-Object -Last 10 | ForEach-Object { Write-Host "  $_" }
Write-OK "Restore finished. Restart hindsight to load the restored data cleanly: docker restart $ServerContainer"
