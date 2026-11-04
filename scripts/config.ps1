# Dot-sourced by docker-compose.ps1 and by the scripts that read config.env themselves.

function Test-ProtectedConfigName([string]$Name) {
    $Name -in @("PATH", "IFS", "BASH_ENV", "ENV", "DOCKER_HOST") -or $Name -like "LD_*"
}

<#
.NOTES
    The same rule as game-compose's docker-compose.sh: only upper-case names are taken, and a name
    that changes how this script or its tools run is skipped with a warning.
#>
function Import-Config([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Config not found: $Path" }
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
        $name, $value = $line -split '=', 2
        $name = $name.Trim()
        if ($name -cnotmatch '^[A-Z_][A-Z0-9_]*$') { continue }
        if (Test-ProtectedConfigName $name) {
            Write-Host "Warning: config.env sets $name, which is ignored." -ForegroundColor Yellow
            continue
        }
        Set-Item "env:$name" $value.Trim()
    }
}
