#!/usr/bin/env python3
"""Prints the full bust-image prompt for every hairstyle in Resources/hairstyles.json that has no photo yet.

    python3 scripts/hairstyle-prompts.py            # styles without hair-<id>.jpg
    python3 scripts/hairstyle-prompts.py --all      # every style
    python3 scripts/hairstyle-prompts.py f6 m9      # just these ids

Save each generated image as Sources/FitHair/Resources/hair-<id>.jpg, 4:5 portrait (the existing ones are 640×800).
"""
import json, sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
res = root / "Sources/FitHair/Resources"
styles = json.loads((res / "hairstyles.json").read_text())["styles"]

TEMPLATE = ("Studio photograph of a matte white plaster bust sculpture of a {person} with an oval face, modern classical "
            "sculpture style, eyes open with a calm gaze. The hair is sculpted in the same white plaster with fine carved "
            "strands: {hairstyle}. Front view turned about 10 degrees. Head, neck and the top of the shoulders, cut flat like "
            "a museum bust. Soft diffused studio key light from upper left, gentle shadows. Plain seamless light warm-gray "
            "background (#DCDAD7), no props, no text. Minimal, high-end fashion editorial, centered, space above the head.")
PERSON = {"female": "beautiful young East Asian woman", "male": "handsome young East Asian man"}

args = [a for a in sys.argv[1:] if not a.startswith("--")]
show_all = "--all" in sys.argv
for s in styles:
    missing = not (res / f"hair-{s['id']}.jpg").exists()
    if args and s["id"] not in args: continue
    if not args and not show_all and not missing: continue
    print(f"## {s['id']} · {s['name']}  →  Sources/FitHair/Resources/hair-{s['id']}.jpg" + ("" if missing else "  (已有图)"))
    print(TEMPLATE.format(person=PERSON[s["gender"]], hairstyle=s["prompt"]))
    print()
