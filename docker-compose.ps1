#Requires -Version 5.1
param([string]$Command = "start")

# $args, not ValueFromRemainingArguments, so -Switch tokens still bind when splatted to a helper.
$forwarded = $args

Set-StrictMode -Version Latest

function Import-Config([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Config not found: $Path" }
    Get-Content $Path |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -match '=' } |
        ForEach-Object {
            $k, $v = $_ -split '=', 2
            Set-Item "env:$($k.Trim())" $v.Trim()
        }
}

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

function Invoke-Data([object[]]$DataArguments) {
    $subcommand = if ($DataArguments) { "$($DataArguments[0])".ToLower() } else { "status" }
    switch ($subcommand) {
        "status" { git -C $PSScriptRoot submodule status -- data; break }
        "use" {
            $source = if ($DataArguments.Count -ge 2) { "$($DataArguments[1])" } else { "" }
            if ($source) {
                $parts = $source.Split("@", 2)
                $url = if ($parts[0] -match "://|^git@") { $parts[0] } else { "https://github.com/$($parts[0]).git" }
                $ref = if ($parts.Count -eq 2) { $parts[1] } else { "main" }
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

$usage = @{
    "start"       = "Start the full stack (default)"
    "stop"        = "Stop everything"
    "logs"        = "Tail llama output"
    "consolidate" = "[-RunImmediately] run one consolidation pass, then back to retain-only"
    "reingest"    = "[-Limit N] [-MinKB N] rebuild the memory bank from Claude Code transcripts"
    "restore"     = "[-File dump.sql] restore the database from a backup dump (newest by default)"
    "save-images" = "Save the stack's images to images/ for an offline reinstall"
    "data"        = "status | use [owner/repo[@ref]]  point data/ at a data repo (none = template)"
}

$helpers = @("consolidate", "reingest", "restore", "save-images")

switch ($Command.ToLower()) {
    { $_ -in "start", "stop", "logs" } {
        Import-Config "$PSScriptRoot\config.env"
        Invoke-Helper "hindsight" @($Command)
    }
    { $_ -in $helpers } { Invoke-Helper $Command.ToLower() $forwarded }
    "data" { Invoke-Data $forwarded; break }
    default { Show-Usage -Commands $usage; exit 1 }
}
