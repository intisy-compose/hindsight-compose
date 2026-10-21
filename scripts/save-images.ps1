#Requires -Version 5.1
# Save the stack's Docker images to a host tar (offline recovery kit) so a clean reinstall
# (deleted images) can `docker load` them locally instead of re-pulling ~14 GB over the network.
# hindsight.ps1 auto-loads this tar on start when the images are missing.
# Re-run this after changing an image version so the kit stays current.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path $PSScriptRoot
$dir  = Join-Path $Root "images"
$tar  = Join-Path $dir "stack-images.tar"
New-Item -ItemType Directory -Force $dir | Out-Null

# The CUDA and native variants; the AMD/Vulkan llama image is built locally by hindsight.ps1.
$images = @(
    "docker-compose.nvidia.yml", "docker-compose.hindsight-only.yml" |
        ForEach-Object { docker compose -f (Join-Path $Root $_) config --images } |
        Sort-Object -Unique
)

Write-Host "Saving $($images.Count) images to $tar ..." -ForegroundColor Cyan
docker save -o $tar @images
Get-Item $tar | Select-Object Name, @{ n = 'GB'; e = { [math]::Round($_.Length / 1GB, 2) } }
Write-Host "Done. This tar is loaded automatically by hindsight.ps1 when images are missing." -ForegroundColor Green
