#!/bin/bash
# Builds Plinth.app and wraps it in a disk image with a shortcut to Applications for drag-to-install.
#
#   ./scripts/build-dmg.sh                  # build/Plinth.dmg, about 25 MB: the realistic try-on downloads its model
#   ./scripts/build-dmg.sh --with-model     # build/Plinth-with-model.dmg, about 2 GB: the model is inside the app
#   ./scripts/build-dmg.sh --with-model=/path/to/RepaintModel
#
# Ad-hoc signed: it runs here, but other Macs need "Open Anyway" until it is signed and notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

MODEL=""
for arg in "$@"; do
    case "$arg" in
        --with-model) MODEL="$HOME/Library/Application Support/Plinth/RepaintModel" ;;
        --with-model=*) MODEL="${arg#--with-model=}" ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done
if [ -n "$MODEL" ]; then
    for part in TextEncoder.mlmodelc Unet.mlmodelc VAEEncoder.mlmodelc VAEDecoder.mlmodelc vocab.json merges.txt; do
        [ -e "$MODEL/$part" ] || { echo "Not a complete model folder, $part is missing: $MODEL" >&2; exit 1; }
    done
fi

./scripts/build-app.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto build/Plinth.app "$STAGE/Plinth.app"
ln -s /Applications "$STAGE/应用程序"

OUT="build/Plinth.dmg"
if [ -n "$MODEL" ]; then
    # Into the copy that goes in the image only: build/Plinth.app stays the small one.
    ditto --norsrc --noextattr --noqtn "$MODEL" "$STAGE/Plinth.app/Contents/Resources/RepaintModel"
    # The model's licence asks for its text to go wherever the model goes.
    cp Support/RepaintModel-NOTICE.txt "$STAGE/Plinth.app/Contents/Resources/RepaintModel/NOTICE.txt"
    cp Support/RepaintModel-LICENSE.txt "$STAGE/Plinth.app/Contents/Resources/RepaintModel/LICENSE.txt"
    codesign --force --deep --sign - "$STAGE/Plinth.app"
    OUT="build/Plinth-with-model.dmg"
fi

hdiutil create -ov -quiet -fs HFS+ -format UDZO -volname "Plinth" -srcfolder "$STAGE" "$OUT"
echo "Built $OUT"
