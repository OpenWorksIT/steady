#!/usr/bin/env python3
"""Names the generated web app "Steady" and adds the practice icons. Safe to run more than once.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import json
import pathlib
import shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent / "web"
index = ROOT / "index.html"
manifest = ROOT / "manifest.json"

if index.exists():
    s = index.read_text()
    s = s.replace("<title>steady</title>", "<title>Steady</title>")
    s = s.replace('content="steady"', 'content="Steady"')
    s = s.replace('content="A new Flutter project."', 'content="Between-session check-ins"')
    index.write_text(s)
    print("patched web/index.html")
if manifest.exists():
    m = json.loads(manifest.read_text())
    m.update({"name": "Steady", "short_name": "Steady", "description": "Between-session check-ins",
              "background_color": "#FFFFFF", "theme_color": "#2C5F7C"})
    manifest.write_text(json.dumps(m, indent=4) + "\n")
    print("patched web/manifest.json")

brand = ROOT.parent / "branding" / "web"
if brand.exists() and ROOT.exists():
    for f in brand.rglob("*.png"):
        dest = ROOT / f.relative_to(brand)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(f, dest)
    print("copied web icons")
