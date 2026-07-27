#!/usr/bin/env bash
# Build the DiffusionGemma vLLM server venv from the pinned requirements.
#
# The systemd unit (systemd/diffusiongemma.service) runs from this venv — its
# ExecStart points at <venv>/bin/vllm. This script makes that runtime a
# reproducible, version-controlled thing instead of a hand-built orphan.
#
#   serving/diffusion/build-venv.sh                 # build at the default path
#   serving/diffusion/build-venv.sh /path/to/venv   # build somewhere else
#   LOCK=1 serving/diffusion/build-venv.sh          # byte-exact from the lockfile
#
# Default path matches the systemd unit. If you change it, change the unit too.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="${1:-/data1/venvs/diffusion}"
REQ="$HERE/requirements.txt"
[[ "${LOCK:-0}" == 1 ]] && REQ="$HERE/requirements.lock.txt"

echo "→ building diffusion vLLM venv"
echo "   venv: $VENV"
echo "   from: $REQ"

python3 -m venv "$VENV"
"$VENV/bin/pip" install --upgrade pip
"$VENV/bin/pip" install --no-cache-dir -r "$REQ"

echo "→ verifying the stack imports and sees the GPU"
"$VENV/bin/python" - <<'PY'
import torch, torchvision, torchaudio, vllm
from torchvision.ops import nms  # the op that fails on a mismatched trio
print(f"   torch {torch.__version__} | vision {torchvision.__version__} | audio {torchaudio.__version__}")
print(f"   vllm  {vllm.__version__}")
print(f"   cuda available: {torch.cuda.is_available()} ({torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'no GPU'})")
PY

echo "→ done. Point the systemd unit at $VENV/bin/vllm (default already does)."
echo "   Snapshot the exact set with:  $VENV/bin/pip freeze > $HERE/requirements.lock.txt"
