#!/bin/bash
# Print the SceneWorks Sana Sprint q4 snapshot directory, or nothing, within a hard deadline.
# The Hugging Face cache may live on another volume (e.g. ~/.cache/huggingface -> /Volumes/Models)
# that macOS privacy consent withholds from this process; a read there blocks rather than fails,
# so the lookup runs in the background and is abandoned (SIGKILL, no wait) on timeout.
set -uo pipefail
deadline=${1:-30}
out=$(mktemp)
/bin/bash -c 'ls -d "$1"/models--SceneWorks--Sana_Sprint_1.6B_1024px_mlx/snapshots/*/q4 2>/dev/null | head -1' _ \
  "$HOME/.cache/huggingface/hub" > "$out" &
probe=$!
for ((i = 0; i < deadline * 4; i++)); do
  kill -0 "$probe" 2>/dev/null || break
  sleep 0.25
done
if kill -0 "$probe" 2>/dev/null; then
  # Never wait on a lookup blocked in the kernel: kill it and its children and return now.
  pkill -9 -P "$probe" 2>/dev/null
  kill -9 "$probe" 2>/dev/null
  disown "$probe" 2>/dev/null
  rm -f "$out"
  exit 0
fi
wait "$probe" 2>/dev/null
cat "$out"
rm -f "$out"
