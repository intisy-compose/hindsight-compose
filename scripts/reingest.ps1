#Requires -Version 5.1
<#
.SYNOPSIS
    Rebuild the Hindsight 'claude_code' memory bank by re-ingesting Claude Code
    conversation transcripts. The live DB was lost on a Docker Desktop reinstall (it
    sat in a Docker named volume, not the host folder); the transcripts in
    ~/.claude/projects are the source of truth, so retaining them rebuilds the memories.

    Each transcript's user/assistant text is extracted, chunked, and submitted as ASYNC
    retain requests, so they queue and process on the GPU over the following hours.

.PARAMETER Limit  Only process the newest N transcripts (0 = all).
.PARAMETER MinKB  Skip transcripts smaller than this (default 50 KB; skips tiny agent logs).
.EXAMPLE
    .\docker-compose.ps1 reingest -Limit 1   # smoke-test on the newest transcript
    .\docker-compose.ps1 reingest            # rebuild from all transcripts
#>
param([int]$Limit = 0, [int]$MinKB = 50)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Self-contained console helpers (no external dependency, so this runs detached anywhere).
function Write-Step([string]$m) { Write-Host $m -ForegroundColor Cyan }
function Write-OK([string]$m)   { Write-Host "  $m" -ForegroundColor Green }
function Write-Info([string]$m) { Write-Host "  $m" -ForegroundColor Gray }

$Bank        = "claude_code"
$Api         = "http://localhost:8888/v1/default/banks/$Bank/memories"
$Projects    = Join-Path $env:USERPROFILE ".claude\projects"
$ChunkChars  = 12000   # per memory item; Hindsight further sub-batches large content
$ItemsPerReq = 1       # one item per async POST: a bad chunk only loses itself, not a batch

# Extract just the user/assistant conversation text from a Claude Code .jsonl transcript,
# skipping tool-call/tool-result noise so the rebuilt memories stay signal-rich.
function Get-ConversationText([string]$file) {
    $sb = [System.Text.StringBuilder]::new()
    foreach ($line in [System.IO.File]::ReadLines($file)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $event = $line | ConvertFrom-Json } catch { continue }
        if ($event.type -ne 'user' -and $event.type -ne 'assistant') { continue }
        $content = $event.message.content
        if ($null -eq $content) { continue }
        if ($content -is [string]) {
            [void]$sb.AppendLine("[$($event.type)] $content")
        } else {
            foreach ($block in $content) {
                if ($block.type -eq 'text' -and $block.text) {
                    [void]$sb.AppendLine("[$($event.type)] $($block.text)")
                }
            }
        }
    }
    $sb.ToString()
}

function Split-Chunks([string]$text, [int]$size) {
    # Group whole lines up to ~$size chars. Splitting on line boundaries (never mid-line)
    # avoids cutting a UTF-16 surrogate pair in half, which produced invalid JSON and 400s.
    $chunks = New-Object System.Collections.Generic.List[string]
    $buf = [System.Text.StringBuilder]::new()
    foreach ($line in ($text -split "`r?`n")) {
        if ($buf.Length -gt 0 -and ($buf.Length + $line.Length) -gt $size) {
            $chunks.Add($buf.ToString()); [void]$buf.Clear()
        }
        [void]$buf.AppendLine($line)
    }
    if ($buf.Length -gt 0) { $chunks.Add($buf.ToString()) }
    , $chunks.ToArray()
}

# POST one async retain request. Builds items JSON manually so a single-item array still
# serializes as a JSON array (PowerShell 5.1 ConvertTo-Json collapses 1-element arrays).
function Submit-Retain([object[]]$contents, [string]$documentId) {
    # Build the items array by serializing each item separately and joining. This avoids
    # PowerShell 5.1's ConvertTo-Json collapsing a 1-element array into a bare object
    # (which the API rejects with 422). Empty/whitespace chunks are skipped.
    $itemJsons = @($contents |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { @{ content = $_; document_id = $documentId } | ConvertTo-Json -Compress -Depth 3 })
    if (-not $itemJsons) { return $false }
    $body = '{"async":true,"items":[' + ($itemJsons -join ',') + ']}'
    Invoke-RestMethod -Uri $Api -Method Post -Body $body -ContentType "application/json" -TimeoutSec 180 | Out-Null
    return $true
}

$files = @(Get-ChildItem $Projects -Recurse -Filter *.jsonl -ErrorAction Stop |
               Where-Object { $_.Length -ge ($MinKB * 1KB) } |
               Sort-Object LastWriteTime -Descending)
if ($Limit -gt 0) { $files = @($files | Select-Object -First $Limit) }

Write-Step "Re-ingesting $($files.Count) transcript(s) into bank '$Bank'..."
$submitted = 0
foreach ($file in $files) {
    $text = Get-ConversationText $file.FullName
    if ([string]::IsNullOrWhiteSpace($text)) { Write-Info "skip (no text): $($file.Name)"; continue }
    $chunks = Split-Chunks $text $ChunkChars
    Write-Info "$($file.Name): $([math]::Round($text.Length / 1KB)) KB -> $($chunks.Count) chunk(s)"
    for ($i = 0; $i -lt $chunks.Count; $i += $ItemsPerReq) {
        $end   = [Math]::Min($i + $ItemsPerReq - 1, $chunks.Count - 1)
        $slice = $chunks[$i..$end]
        try { if (Submit-Retain -contents $slice -documentId $file.BaseName) { $submitted++ } }
        catch { Write-Info "  POST failed ($($file.BaseName) chunk $i): $($_.Exception.Message)" }
    }
}
Write-OK "Submitted $submitted async retain request(s) across $($files.Count) transcript(s)."
Write-Info "They process on the GPU in the background. Watch: docker logs hindsight -f"
