"""Helpers of scripts/ios/captures.sh (no AI agent). Nothing read on screen is ever printed.
  size           -> "<width> <height>" of the screen in points (from the AXe tree)
  tap <label>... -> taps the first element whose label is one of the given ones (case-insensitive); prints 1, else 0
  login          -> prints 1 if the login screen of the app is shown (testIDs "login-*"), else 0"""
import json, os, subprocess, sys

UDID = os.environ["UDID"]


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


def labels(n):
    return {str(n.get(k) or "").strip().lower() for k in ("AXLabel", "title", "AXValue")} - {""}


cmd = sys.argv[1]
if cmd == "size":
    for n in walk(tree()):
        f = n.get("frame") or {}
        if f.get("width", 0) >= 300 and f.get("height", 0) >= 500:
            print(round(f["width"]), round(f["height"]))
            break
    else:
        print("390 844")
elif cmd == "tap":
    wanted = {a.lower() for a in sys.argv[2:]}
    for n in walk(tree()):
        f = n.get("frame") or {}
        if labels(n) & wanted and f.get("width", 0) > 0 and f.get("height", 0) > 0:
            subprocess.run(["axe", "tap", "-x", str(round(f["x"] + f["width"] / 2)), "-y", str(round(f["y"] + f["height"] / 2)),
                            "--udid", UDID], capture_output=True)
            print(1)
            break
    else:
        print(0)
elif cmd == "login":
    print(1 if any(str(n.get("AXUniqueId") or "").startswith("login-") for n in walk(tree())) else 0)
