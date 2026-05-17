#!/usr/bin/env bash
#
# fetch-whisperkit-model.sh
#
# Pre-build step that populates ios/Steward/Resources/WhisperKitModels/<model>/
# with a real WhisperKit CoreML model. Run this once before the first device
# build so the app bundle ships the model and never lazy-downloads at runtime
# (implementation-addendum §4 hard reject #15).
#
# Default model: openai_whisper-large-v3-turbo (~1.6GB on disk, mlmodelc format).
#
# Usage:
#   scripts/fetch-whisperkit-model.sh                       # default model
#   scripts/fetch-whisperkit-model.sh openai_whisper-base   # smaller dev model
#
# Requires:
#   - git
#   - git-lfs  (the HF repo uses LFS for model weights)
#

set -euo pipefail

MODEL="${1:-openai_whisper-large-v3-turbo}"
DEST_ROOT="ios/Steward/Resources/WhisperKitModels"
DEST_DIR="${DEST_ROOT}/${MODEL}"
HF_REPO="argmaxinc/whisperkit-coreml"

if ! command -v git-lfs >/dev/null 2>&1; then
  echo "ERROR: git-lfs is required. Install with: brew install git-lfs && git lfs install" >&2
  exit 1
fi

mkdir -p "${DEST_ROOT}"

if [[ -d "${DEST_DIR}" ]] && [[ -n "$(ls -A "${DEST_DIR}" 2>/dev/null)" ]]; then
  echo "Model already present at ${DEST_DIR} — skipping. Delete to force re-download."
  exit 0
fi

echo "Fetching ${MODEL} from huggingface.co/${HF_REPO} via git-lfs..."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

git clone --depth 1 --filter=blob:none --sparse \
  "https://huggingface.co/${HF_REPO}" "${TMP_DIR}/repo"

(
  cd "${TMP_DIR}/repo"
  git sparse-checkout set "${MODEL}"
  git lfs pull --include "${MODEL}/*"
)

if [[ ! -d "${TMP_DIR}/repo/${MODEL}" ]]; then
  echo "ERROR: HF repo did not contain ${MODEL}. Check the model name." >&2
  exit 1
fi

mkdir -p "${DEST_DIR}"
cp -R "${TMP_DIR}/repo/${MODEL}/." "${DEST_DIR}/"

echo "OK. Bundled ${MODEL} at ${DEST_DIR}"
echo "Add the WhisperKitModels/ folder to Xcode (target Steward, 'Copy items if needed') if it isn't already in the project."
