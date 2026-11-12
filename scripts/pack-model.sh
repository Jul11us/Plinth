#!/bin/bash
# Packs the image model of the realistic try-on into build/RepaintModel.zip, the one file the app downloads on
# first use, and prints what to put in Support/Info.plist so the app knows where it is and that it is the right one.
#
#   ./scripts/pack-model.sh                      # the model installed on this Mac
#   ./scripts/pack-model.sh /path/to/RepaintModel
#
# Upload build/RepaintModel.zip anywhere that serves it over https at a fixed address, then rebuild the app.
# The model's licence (CreativeML Open RAIL-M) has to travel with it: its text and a note of where the model comes
# from (Support/RepaintModel-LICENSE.txt, -NOTICE.txt) are packed in beside the model.
set -euo pipefail
cd "$(dirname "$0")/.."

MODEL="${1:-$HOME/Library/Application Support/Plinth/RepaintModel}"
for part in TextEncoder.mlmodelc Unet.mlmodelc VAEEncoder.mlmodelc VAEDecoder.mlmodelc vocab.json merges.txt; do
    [ -e "$MODEL/$part" ] || { echo "Not a complete model folder, $part is missing: $MODEL" >&2; exit 1; }
done

# A copy to add the two texts to, so the installed model is left as it is. On APFS the copy takes no space.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -cR "$MODEL" "$STAGE/RepaintModel"
cp Support/RepaintModel-LICENSE.txt "$STAGE/RepaintModel/LICENSE.txt"
cp Support/RepaintModel-NOTICE.txt "$STAGE/RepaintModel/NOTICE.txt"

mkdir -p build
rm -f build/RepaintModel.zip
# Plain files only: no resource forks, no Finder leftovers.
ditto -c -k --norsrc --noextattr --noqtn "$STAGE/RepaintModel" build/RepaintModel.zip

SUM="$(shasum -a 256 build/RepaintModel.zip | cut -d' ' -f1)"
SIZE="$(stat -f %z build/RepaintModel.zip)"
echo "Built build/RepaintModel.zip ($SIZE bytes)"
echo
echo "After uploading it, set these two in Support/Info.plist and rebuild:"
echo "    <key>PlinthRepaintModelURL</key>"
echo "    <string>https://…/RepaintModel.zip</string>"
echo "    <key>PlinthRepaintModelSHA256</key>"
echo "    <string>$SUM</string>"
