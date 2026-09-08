#!/usr/bin/env bash
# Fetch a Whisper ggml model from Hugging Face into models/.
# Usage: scripts/fetch-model.sh [base.en|small.en|large-v3-turbo|...]
set -euo pipefail
MODEL="${1:-small.en}"
case "$MODEL" in
  tiny.en|base.en|small.en|medium.en|tiny|base|small|medium|large-v3|large-v3-turbo)
    FILE="ggml-$MODEL.bin" ;;
  *)
    FILE="$MODEL" ;;
esac
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$FILE"
mkdir -p models
if [ -f "models/$FILE" ]; then
  echo "models/$FILE already present"
  exit 0
fi
echo "Downloading $URL"
curl -L --fail --progress-bar "$URL" -o "models/$FILE"
echo "Saved models/$FILE ($(du -h "models/$FILE" | cut -f1))"
