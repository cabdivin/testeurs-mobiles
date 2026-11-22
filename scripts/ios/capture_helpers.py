"""Helpers of scripts/ios/captures.sh (no AI agent). Nothing read on screen is ever printed.
  size   -> prints "<width> <height>" of the screen in points (from the AXe tree)
  alert  -> taps the "Open" button of the system alert "Open in ...?" if one is shown (prints 1, else 0)"""
import json, os, subprocess, sys

UDID = os.environ["UDID"]
OPEN = {"open", "ouvrir", "فتح"}


def tree():
    out = subprocess.run(["axe", "describe-ui", "--udid", UDID], capture_output=True, text=True, timeout=60).stdout
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return []


def walk(n):
    if isinstance(n, list):
        for c in n:
            yield from walk(c)
    elif isinstance(n, dict):
        yield n
        yield from walk(n.get("children") or [])


cmd = sys.argv[1]
if cmd == "size":
    for n in walk(tree()):
        f = n.get("frame") or {}
        if f.get("width", 0) >= 300 and f.get("height", 0) >= 500:
            print(round(f["width"]), round(f["height"]))
            break
    else:
        print("390 844")
elif cmd == "alert":
    for n in walk(tree()):
        label = (n.get("AXLabel") or n.get("title") or "").strip().lower()
        kind = (n.get("type") or n.get("role_description") or "")
        f = n.get("frame") or {}
        if label in OPEN and "Button" in kind and f.get("width", 0) > 0:
            subprocess.run(["axe", "tap", "-x", str(round(f["x"] + f["width"] / 2)), "-y", str(round(f["y"] + f["height"] / 2)),
                            "--udid", UDID], capture_output=True)
            print(1)
            break
    else:
        print(0)
