#Requires -Version 5.1
# Save the stack's Docker images to a host tar (offline recovery kit) so a clean reinstall
# (deleted images) can `docker load` them locally instead of re-pulling ~14 GB over the network.
# hindsight.ps1 auto-loads this tar on start when the images are missing.
# Re-run this after pulling a newer hindsight image so the kit stays current.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path $PSScriptRoot
$dir  = Join-Path $Root "images"
$tar  = Join-Path $dir "stack-images.tar"
New-Item -ItemType Directory -Force $dir | Out-Null

# CUDA path uses the official prebuilt server image. (On AMD/Vulkan, swap in
# 'llama-vulkan-dozen:latest', which hindsight.ps1 builds locally.)
$images = @(
    "ghcr.io/ggml-org/llama.cpp:server-cuda",
    "ghcr.io/vectorize-io/hindsight:latest",
    "postgres:18-alpine",
    "alpine:latest"
)

Write-Host "Saving $($images.Count) images to $tar ..." -ForegroundColor Cyan
docker save -o $tar @images
Get-Item $tar | Select-Object Name, @{ n = 'GB'; e = { [math]::Round($_.Length / 1GB, 2) } }
Write-Host "Done. This tar is loaded automatically by hindsight.ps1 when images are missing." -ForegroundColor Green
