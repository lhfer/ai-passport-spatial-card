#!/usr/bin/env python3
"""Check the versioned public payload without printing possible secret values."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
errors = []
try:
    names = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
except subprocess.CalledProcessError:
    sys.exit("Run this check inside the source repository.")
files = [ROOT / n for n in names if n and (ROOT / n).is_file()]
if not files:
    sys.exit("No versioned files found; stage the public payload first.")
for p in files:
    rel = p.relative_to(ROOT).as_posix()
    parts = p.relative_to(ROOT).parts
    if any(x in parts for x in ["node_modules", ".claude", ".worktrees", "DerivedData", "build", "build-host", "backups"]):
        errors.append(f"Private/generated directory: {rel}")
    if rel.startswith("hub/data/") and rel != "hub/data/.gitkeep":
        errors.append(f"Local Hub data: {rel}")
    if p.name.startswith(".env") and p.name != ".env.example":
        errors.append(f"Environment file: {rel}")
    if p.suffix.lower() in [".pem", ".p12", ".p8", ".key", ".mobileprovision"]:
        errors.append(f"Credential file: {rel}")
    if p.stat().st_size >= 100 * 1024 * 1024:
        errors.append(f"Oversized Git object: {rel}")
    try:
        text = p.read_text()
    except (UnicodeError, OSError):
        continue
    if re.search(r"/Users/[A-Za-z0-9._-]+/", text):
        errors.append(f"Personal home path: {rel}")
    if re.search(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----", text):
        errors.append(f"Private key content: {rel}")
    if re.search(r"DEVELOPMENT_TEAM:\s*[\"']?[A-Z0-9]{10}\b", text):
        errors.append(f"Personal signing team: {rel}")

objects = ROOT / "visionos/SpatialCard/Resources/objects"
manifest = json.loads((objects / "model-manifest.json").read_text())
model = objects / manifest["file"]
if hashlib.sha256(model.read_bytes()).hexdigest() != manifest["sha256"]:
    errors.append("Extended model checksum differs from manifest")
with zipfile.ZipFile(model) as archive:
    if archive.testzip() is not None:
        errors.append("Extended model archive failed its CRC check")
    for name in archive.namelist():
        if name.endswith(".usdz") or any(p.startswith("._") for p in Path(name).parts):
            errors.append("Extended model contains preview or AppleDouble metadata")
    if json.loads(archive.read("metadata.json"))["license"] != "MIT":
        errors.append("Extended model license metadata differs from MIT")
    if json.loads(archive.read("objectMetadata.json"))["trainingMode"] != "extended":
        errors.append("Unexpected model training mode")
    for name, expected in manifest["model_payload_sha256"].items():
        if hashlib.sha256(archive.read(name)).hexdigest() != expected:
            errors.append(f"Model payload checksum differs: {name}")

card = json.loads((ROOT / "assets/card/card.json").read_text())
if card["xhs"]["userId"] != "YOUR_XHS_USER_ID":
    errors.append("Replace the personal profile with the public sample before publishing")
if json.loads((ROOT / "visionos/SpatialCard/Resources/hub.json").read_text()) != {}:
    errors.append("Remove personal Hub configuration before publishing")
for n in ["docs/media/hero.svg", "docs/media/recognition.gif", "docs/media/handheld.gif"]:
    if not (ROOT / n).is_file():
        errors.append(f"Missing README media: {n}")
if errors:
    print("\n".join(errors))
    sys.exit(1)
print(f"Public payload: {len(files)} files checked; model checksums and anonymous defaults verified.")
print("Also run a secret scanner and visually review images and recordings.")
