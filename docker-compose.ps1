#Requires -Version 5.1
param([string]$Command = "start")

# $args, not ValueFromRemainingArguments, so -Switch tokens still bind when splatted to a helper.
$forwarded = $args

Set-StrictMode -Version Latest

# The pinned `name:` must win, because the restore guard checks the volume by that name.
Remove-Item Env:\COMPOSE_PROJECT_NAME -ErrorAction SilentlyContinue

. "$PSScriptRoot\scripts\config.ps1"
. "$PSScriptRoot\gateway\tailnet-node.ps1"

function Show-Usage([hashtable]$Commands) {
    $width = ($Commands.Keys | Measure-Object -Property Length -Maximum).Maximum
    Write-Host "Usage: .\docker-compose.ps1 [$(($Commands.Keys | Sort-Object) -join '|')]"
    foreach ($cmd in $Commands.Keys | Sort-Object) {
        Write-Host ("  {0}  {1}" -f $cmd.PadRight($width), $Commands[$cmd])
    }
}

function Invoke-Helper([string]$Name, [object[]]$HelperArguments) {
    Set-StrictMode -Off
    & (Join-Path $PSScriptRoot "scripts\$Name.ps1") @HelperArguments
    exit $LASTEXITCODE
}

# Split-DataSource: the URL and ref of owner/repo[@ref] or a git URL[@ref]. The ref follows the last
# @ after a URL's user@, so git@host:owner/repo@ref keeps its user.
function Split-DataSource([string]$Source) {
    $user = ""
    $rest = $Source
    if ($Source -cmatch '^([A-Za-z][A-Za-z0-9+.-]*://[^/@]+@)(.*)$' -or $Source -cmatch '^([^/@:]+@)([^/:]+:.*)$') {
        $user = $Matches[1]
        $rest = $Matches[2]
    }
    $ref = "main"
    $at = $rest.LastIndexOf("@")
    if ($at -ge 0) {
        $ref = $rest.Substring($at + 1)
        $rest = $rest.Substring(0, $at)
    }
    if ($ref -eq "" -or $ref.StartsWith("-")) {
        Write-Host "A data ref must not be empty or start with '-': '$ref'" -ForegroundColor Red
        exit 1
    }
    $url = "$user$rest"
    if ($url -notmatch "://" -and -not $user) { $url = "https://github.com/$url.git" }
    return @{ Url = $url; Ref = $ref }
}

function Invoke-Data([object[]]$DataArguments) {
    $subcommand = if ($DataArguments) { "$($DataArguments[0])".ToLower() } else { "status" }
    switch ($subcommand) {
        "status" { git -C $PSScriptRoot submodule status -- data; break }
        "use" {
            $source = if ($DataArguments.Count -ge 2) { "$($DataArguments[1])" } else { "" }
            if ($source) {
                $resolved = Split-DataSource $source
                $url = $resolved.Url
                $ref = $resolved.Ref
            } else {
                $url = git -C $PSScriptRoot config -f .gitmodules submodule.data.url
                $ref = "main"
            }
            Write-Host "Pointing data at $url @ $ref" -ForegroundColor Cyan
            if (-not (Test-Path "$PSScriptRoot\data\.git")) { git -C $PSScriptRoot submodule update --init -- data 2>$null | Out-Null }
            git -C $PSScriptRoot config submodule.data.url $url
            git -C "$PSScriptRoot\data" remote set-url origin $url
            git -C "$PSScriptRoot\data" fetch -q origin $ref
            git -C "$PSScriptRoot\data" checkout -q FETCH_HEAD
            Write-Host "  data now at $(git -C "$PSScriptRoot\data" rev-parse --short HEAD)" -ForegroundColor Green
            break
        }
        default { Show-Usage -Commands $usage; exit 1 }
    }
}

<#
.SYNOPSIS
How the stack is deleted: stop, then its node leaves the tailnet and data\tailscale goes, so a later
start joins fresh. Removing the folder afterwards is the human's step.
.NOTES
The stop runs without strict mode, as every helper does through Invoke-Helper, and its throw counts as
a failed stop.
#>
function Invoke-Delete {
    $configFile = "$PSScriptRoot\config.env"
    Import-Config $configFile
    Set-StrictMode -Off
    $global:LASTEXITCODE = 0
    try { & (Join-Path $PSScriptRoot "scripts\hindsight.ps1") stop; $stopped = $LASTEXITCODE -eq 0 }
    catch { Write-Host "$_" -ForegroundColor Red; $stopped = $false }
    Set-StrictMode -Version Latest
    if (-not $stopped) { Write-Host "The stop failed, so the node stays in the tailnet." -ForegroundColor Red; exit 1 }
    $nodeName = if ($env:HINDSIGHT_HOST) { $env:HINDSIGHT_HOST } elseif ($env:TS_HOSTNAME) { $env:TS_HOSTNAME } else { "hindsight" }
    if (-not (Remove-TailnetIdentity (Join-Path $PSScriptRoot "data\tailscale") $nodeName $configFile)) { exit 1 }
    Write-Host "  Deleted. The volumes stay in Docker; remove this folder to finish." -ForegroundColor Green
}

$usage = @{
    "start"       = "Start the full stack (default)"
    "stop"        = "Stop everything"
    "delete"      = "Stop, then remove the stack's node from the tailnet (with TS_API_TOKEN) and data\tailscale; for a stack being removed"
    "logs"        = "Tail llama output"
    "consolidate" = "[-RunImmediately] run one consolidation pass, then back to retain-only"
    "reingest"    = "[-Limit N] [-MinKB N] rebuild the memory bank from Claude Code transcripts"
    "restore"     = "[-File dump.sql] [-Database name] restore a backup dump (newest by default) in one transaction, into hindsight by default"
    "save-images" = "Save the stack's images to images/ for an offline reinstall"
    "prove-data"  = "DESTRUCTIVE: delete the database volume and prove the self-restore brings every table back"
    "data"        = "status | use [owner/repo[@ref]]  point data/ at a data repo (none = template)"
}

$helpers = @("consolidate", "reingest", "restore", "save-images", "prove-data")

switch ($Command.ToLower()) {
    { $_ -in "start", "stop", "logs" } {
        Import-Config "$PSScriptRoot\config.env"
        Invoke-Helper "hindsight" @($Command)
    }
    { $_ -in $helpers } { Invoke-Helper $Command.ToLower() $forwarded }
    "data" { Invoke-Data $forwarded; break }
    "delete" { Invoke-Delete; break }
    default { Show-Usage -Commands $usage; exit 1 }
}
