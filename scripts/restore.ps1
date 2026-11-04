#Requires -Version 5.1
<#
.SYNOPSIS
    Restore the Hindsight database from a host-side SQL dump written by the db-backup sidecar.
    Use after a Docker reinstall (or any data loss) to recover the memory bank.

.DESCRIPTION
    The dump is applied in one transaction and psql stops at the first error, so a failed restore
    leaves the database as it was and exits 1 with psql's error lines.

.PARAMETER File      Path to a specific .sql dump. Defaults to the newest restorable hindsight-YYYYMMDD-HHMMSS.sql in data\hindsight\.
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
$DumpNamePattern = '^hindsight-\d{8}-\d{6}\.sql$'
$DumpTrailer = "PostgreSQL database dump complete"

if (-not $Database -or $Database.StartsWith("-") -or $Database.Contains("=")) {
    throw "Usage: .\docker-compose.ps1 restore [-File dump.sql] [-Database name]"
}

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

<#
.SYNOPSIS
    Why the dump cannot be restored, or $null.
.NOTES
    --clean drops every table first, so a dump cut short at a statement boundary, or one that holds no
    memory, would commit an empty database: it must end with pg_dump's trailer and hold at least one
    row of public.memory_units.
#>
function Get-DumpRejection([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $tailLength = [int][Math]::Min(400, $stream.Length)
        [void]$stream.Seek(-$tailLength, [System.IO.SeekOrigin]::End)
        $buffer = New-Object byte[] $tailLength
        [void]$stream.Read($buffer, 0, $tailLength)
    } finally { $stream.Dispose() }
    if (-not [System.Text.Encoding]::ASCII.GetString($buffer).Contains($DumpTrailer)) {
        return "it does not end with '$DumpTrailer', so it is cut short or not a pg_dump"
    }
    $copy = Select-String -LiteralPath $Path -Pattern '^COPY public\.memory_units ' -List -Context 0, 1
    if (-not $copy -or -not $copy.Context.PostContext) { return "it holds no data for public.memory_units" }
    if ($copy.Context.PostContext[0] -eq '\.') { return "its public.memory_units holds no rows" }
    return $null
}

function Resolve-DumpFile([string]$Path) {
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Backup not found: $Path" }
        $reason = Get-DumpRejection $Path
        if ($reason) { throw "$(Split-Path $Path -Leaf) cannot be restored: $reason; nothing was copied." }
        return $Path
    }
    $dumps = @(Get-ChildItem $BackupDir -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -match $DumpNamePattern -and $_.Length -gt 0 } |
                   Sort-Object Name -Descending)
    if (-not $dumps) { throw "No backups found in $BackupDir" }
    $lastRejection = ""
    foreach ($dump in $dumps) {
        $reason = Get-DumpRejection $dump.FullName
        if (-not $reason) { return $dump.FullName }
        Write-Host "  skipping $($dump.Name): $reason" -ForegroundColor Gray
        $lastRejection = "$($dump.Name): $reason"
    }
    throw "No dump in $BackupDir can be restored; the last one checked, $lastRejection."
}

function Invoke-PsqlRestore([string]$TargetDatabase) {
    $command = "PGPASSWORD=hindsight /home/hindsight/.pg0/installation/*/bin/psql -h 127.0.0.1 -U hindsight -d '$TargetDatabase' -v ON_ERROR_STOP=1 --single-transaction -f $ContainerDump"
    return Invoke-Docker exec $ServerContainer sh -c $command
}

$File = Resolve-DumpFile $File

$running = docker ps -q --filter "name=^$ServerContainer$" 2>$null
if (-not $running) { throw "hindsight container is not running. Start the stack first." }

Write-Step "Restoring Hindsight DB '$Database' from $File ..."
if ($Database -eq "hindsight") {
    Write-Host "  This is the live database: writes made while it restores are lost, and hindsight needs a restart afterwards." -ForegroundColor Gray
}
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
