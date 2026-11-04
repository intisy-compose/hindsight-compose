#!/usr/bin/env bash
# reingest.sh [--limit N] [--min-kb N]: the bash twin of reingest.ps1. Rebuilds the Hindsight
# 'claude_code' memory bank from the Claude Code transcripts in ~/.claude/projects, the source of
# truth: each transcript's user and assistant text is chunked and submitted as async retain requests,
# which queue and process on the GPU over the following hours. --limit takes only the newest N
# transcripts (0 = all); --min-kb skips smaller ones (default 50, which skips tiny agent logs).
set -euo pipefail
# shellcheck source=scripts/stack.sh
. "$(dirname "$0")/stack.sh"

usage_line="Usage: ./docker-compose.sh reingest [--limit N] [--min-kb N]"
bank="claude_code"
memories_url="http://localhost:8888/v1/default/banks/$bank/memories"
projects="$HOME/.claude/projects"
chunk_characters=12000
limit=0
min_kb=50

while [ $# -gt 0 ]; do
    case "$1" in
        --limit | --min-kb)
            { [ $# -ge 2 ] && is_count "$2"; } || fail "$usage_line"
            if [ "$1" = --limit ]; then limit=$2; else min_kb=$2; fi
            shift 2 ;;
        *) fail "$usage_line" ;;
    esac
done

# The transcripts are read by python3, which prints one tab-separated record per line: "count N",
# "info TEXT", or "post DOCUMENT CHUNK BODY" with the request body as one line of JSON, and "end" last,
# so a reader that stopped early is told apart from one that finished.
read_transcripts_program='import json, os, sys
sys.stdout.reconfigure(encoding="utf-8", newline="\n")
projects, limit, min_kb, chunk_size = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])

def record(*fields):
    print("\t".join(str(field).replace("\t", " ").replace("\n", " ") for field in fields), flush=True)

def transcripts():
    found = []
    for folder, _, names in os.walk(projects):
        for name in names:
            path = os.path.join(folder, name)
            if name.endswith(".jsonl") and os.path.getsize(path) >= min_kb * 1024:
                found.append(path)
    found.sort(key=os.path.getmtime, reverse=True)
    return found[:limit] if limit > 0 else found

def conversation_text(path):
    lines = []
    with open(path, encoding="utf-8", errors="replace") as transcript:
        for line in transcript:
            if not line.strip():
                continue
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if not isinstance(event, dict) or event.get("type") not in ("user", "assistant"):
                continue
            message = event.get("message")
            content = message.get("content") if isinstance(message, dict) else None
            if isinstance(content, str):
                lines.append("[%s] %s" % (event["type"], content))
            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text" and block.get("text"):
                        lines.append("[%s] %s" % (event["type"], block["text"]))
    return "".join(line + "\n" for line in lines)

# Whole lines up to about chunk_size characters, never split mid-line.
def chunks(text):
    result, buffer, length = [], [], 0
    for line in text.replace("\r\n", "\n").split("\n"):
        if length > 0 and length + len(line) > chunk_size:
            result.append("".join(buffer))
            buffer, length = [], 0
        buffer.append(line + "\n")
        length += len(line) + 1
    if length > 0:
        result.append("".join(buffer))
    return result

files = transcripts()
record("count", len(files))
for path in files:
    name = os.path.basename(path)
    document = os.path.splitext(name)[0]
    text = conversation_text(path)
    if not text.strip():
        record("info", "skip (no text): " + name)
        continue
    parts = chunks(text)
    record("info", "%s: %d KB -> %d chunk(s)" % (name, round(len(text) / 1024), len(parts)))
    for index, part in enumerate(parts):
        if part.strip():
            record("post", document, index, json.dumps({"async": True, "items": [{"content": part, "document_id": document}]}))
record("end")'

# submit_retain BODY: POSTs one async retain request; prints curl's error when it fails.
submit_retain() {
    curl -sS -f -m 180 -o /dev/null -H "Content-Type: application/json" --data-binary @- "$memories_url" <<<"$1" 2>&1
}

[ -d "$projects" ] || fail "Transcript folder not found: $projects"

submitted=0
transcript_count=0
finished=false
while IFS=$'\t' read -r kind first second body; do
    case "$kind" in
        count)
            transcript_count=$first
            step "Re-ingesting $transcript_count transcript(s) into bank '$bank'..." ;;
        info) info "$first" ;;
        post)
            if failure=$(submit_retain "$body"); then
                submitted=$((submitted + 1))
            else
                info "  POST failed ($first chunk $second): ${failure:-curl failed}"
            fi ;;
        end) finished=true ;;
    esac
done < <(python3 -c "$read_transcripts_program" "$(native_path "$projects")" "$limit" "$min_kb" "$chunk_characters")

$finished || fail "Reading the transcripts in $projects stopped early; $submitted request(s) were submitted."
ok "Submitted $submitted async retain request(s) across $transcript_count transcript(s)."
info "They process on the GPU in the background. Watch: docker logs hindsight-server -f"
