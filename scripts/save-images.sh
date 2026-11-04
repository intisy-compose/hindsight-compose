#!/usr/bin/env bash
# save-images.sh: the bash twin of save-images.ps1. Saves the stack's Docker images to
# images/stack-images.tar, an offline recovery kit: after a clean reinstall `start` loads it instead of
# re-pulling ~14 GB. Re-run it after changing an image version so the kit stays current. The images
# are the CUDA and the native variants', as on Windows, so one kit serves both CLIs.
set -euo pipefail
# shellcheck source=scripts/stack.sh
. "$(dirname "$0")/stack.sh"

[ $# -eq 0 ] || fail "Usage: ./docker-compose.sh save-images"
image_folder="$stack_root/images"
tar="$image_folder/stack-images.tar"
mkdir -p "$image_folder"

listing=$(for file in "$nvidia_compose_file" "$host_llama_compose_file"; do compose_with "$file" config --images; done) ||
    fail "docker compose config --images failed."
mapfile -t images < <(tr -d '\r' <<<"$listing" | grep -v '^$' | LC_ALL=C sort -u)
[ ${#images[@]} -gt 0 ] || fail "The compose files name no images."

step "Saving ${#images[@]} images to $tar ..."
docker save -o "$tar" "${images[@]}" || fail "docker save failed."
size=$(wc -c <"$tar" | tr -d ' ')
printf '  %s  %s GB\n' "$(basename "$tar")" "$(awk -v bytes="$size" 'BEGIN { printf "%.2f", bytes / 1073741824 }')"
printf '\033[32m%s\033[0m\n' "Done. This tar is loaded automatically by start when images are missing."
