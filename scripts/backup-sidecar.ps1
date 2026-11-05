#Requires -Version 5.1
<#
.SYNOPSIS
    Dot-sourced by hindsight.ps1, consolidate.ps1 and prove-data.ps1: waiting for hindsight and
    keeping the db-backup sidecar in hindsight's network namespace. The twin of the same functions in
    stack.sh.
.NOTES
    db-backup lives in hindsight's network namespace, which every start of hindsight replaces, and
    hindsight's first start on a new volume or after a recreate can fail on its own database and be
    restarted by Docker. A sidecar joined to the old namespace makes no dump and no self-restore, so it
    is rejoined only once hindsight answers.
#>

$script:HindsightHealthUrl = "http://localhost:8888/health"

function Wait-HindsightHealthy([int]$Tries = 40, [string]$Message = "Hindsight did not become healthy after restart.") {
    for ($i = 0; $i -lt $Tries; $i++) {
        try { if ((Invoke-WebRequest $script:HindsightHealthUrl -TimeoutSec 3 -UseBasicParsing -EA Stop).StatusCode -eq 200) { return } } catch {}
        Start-Sleep 3
    }
    throw $Message
}

function Test-BackupSidecarReachesDatabase {
    $ErrorActionPreference = 'Continue'
    docker exec hindsight-db-backup pg_isready -h 127.0.0.1 -U hindsight -d hindsight -t 5 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

function Join-BackupSidecar([string]$ComposeFile) {
    # Under 'Stop', Windows PowerShell 5.1 turns compose's progress on stderr into a terminating error.
    $ErrorActionPreference = 'Continue'
    docker compose -f $ComposeFile up -d --force-recreate --no-deps db-backup 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker compose up -d db-backup exited with $LASTEXITCODE" }
}

<#
.NOTES
    A sidecar that reaches pg0 is left alone, because it may be restoring a dump into an empty volume.
#>
function Confirm-BackupSidecarJoined([string]$ComposeFile) {
    if (Test-BackupSidecarReachesDatabase) { Write-Host "  The backup sidecar reaches the database." -ForegroundColor Green; return }
    Write-Host "  The backup sidecar does not reach the database; rejoining it..." -ForegroundColor Gray
    Join-BackupSidecar $ComposeFile
}

function Restart-Hindsight([string]$ComposeFile, [int]$Tries = 40) {
    $ErrorActionPreference = 'Continue'
    docker compose -f $ComposeFile up -d hindsight 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker compose up -d hindsight exited with $LASTEXITCODE" }
    Wait-HindsightHealthy -Tries $Tries
    Join-BackupSidecar $ComposeFile
}
