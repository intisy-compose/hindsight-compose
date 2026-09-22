#Requires -Version 5.1
param([string]$Command = "start")

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
function Show-Usage([string]$Script = ".\docker-compose.ps1", [hashtable]$Commands) {
    $width = ($Commands.Keys | Measure-Object -Property Length -Maximum).Maximum
    Write-Host "Usage: $Script [$(($Commands.Keys | Sort-Object) -join '|')]"
    foreach ($cmd in $Commands.Keys | Sort-Object) {
        Write-Host ("  {0}  {1}" -f $cmd.PadRight($width), $Commands[$cmd])
    }
}

Import-Config "$PSScriptRoot\config.env"

$usage = @{
    "start" = "Start the full stack (default)"
    "stop"  = "Stop everything"
    "logs"  = "Tail llama output"
}

switch ($Command.ToLower()) {
    { $_ -in "start","stop","logs" } {
        & "$PSScriptRoot\scripts\hindsight.ps1" $Command
        exit $LASTEXITCODE
    }
    default { Show-Usage -Script ".\docker-compose.ps1" -Commands $usage; exit 1 }
}
