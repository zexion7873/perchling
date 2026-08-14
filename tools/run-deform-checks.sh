#!/usr/bin/env bash
# Guards on the built-in pet's generator, in tools/hippo/. Three of them:
#
#   1. the generator still reproduces examples/perchling.json exactly — which is
#      `perchling --export`, which is BUILTIN_MANIFEST, so this is the check
#      that the art and the thing that draws it have not drifted apart
#   2. every parameter the squash/stretch transform is frozen to reach still
#      moves — a table nobody deformed is simply absent from that set
#   3. the floor never moves, whatever the deformation
#
# Guard 2 is the second design. The first asserted that every ink's topmost row
# moves under a squash; it passed immediately and was then shown to catch a
# deliberately frozen forelimb zero times out of ten, because the limbs sit
# inside the body silhouette and never reach an extreme row.
#
# No Swift, no rebuild, nothing written: this reads examples/perchling.json and
# runs Python. Regenerating the manifest is tools/hippo/emit_swiftfmt.py.
set -uo pipefail
cd "$(dirname "$0")/.."
exec python3 tools/hippo/check_deform.py
