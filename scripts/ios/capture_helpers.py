"""Helpers of scripts/ios/captures.sh (no AI agent). Nothing read on screen is ever printed: only 0/1 or sizes.
Matching is case- and accent-insensitive, on the label, the value or the testID (AXUniqueId) of an element.
  size                -> "<width> <height>" of the screen in points
  tap <label>...      -> taps the first element whose label equals one of the given ones; prints 1 or 0
  tapx <text>         -> taps the element matching <text>: exact match first, else "contains"; prints 1 or 0
  tapid <testID>      -> taps the element whose testID is exactly <testID>; prints 1 or 0
  has <text>          -> prints 1 if an element contains <text>
  swiperow <text>     -> horizontal swipe (right to left) on the row that contains <text>; prints 1 or 0
  isfront <name>...   -> prints 1 if the root node label equals / contains one of the (non-empty) names
  seen <text>         -> prints 1 if an element matching <text> is visible on screen
  front               -> prints the label of the root (Application) node: "springboard" = the home screen is shown
  login               -> prints 1 if the login screen of the app is shown (testIDs "login-*")"""
import json, os, subprocess, sys, unicodedata

UDID = os.environ["UDID"]


def norm(s):
    s = unicodedata.normalize("NFKD", str(s or ""))
    return "".join(c for c in s if not unicodedata.combining(c)).strip().lower()


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


def texts(n):
    return {norm(n.get(k)) for k in ("AXLabel", "title", "AXValue", "AXUniqueId")} - {""}


def centre(n):
    f = n.get("frame") or {}
    if f.get("width", 0) <= 0 or f.get("height", 0) <= 0:
        return None
    return f["x"] + f["width"] / 2, f["y"] + f["height"] / 2


def screen():
    for n in walk(tree()):
        f = n.get("frame") or {}
        if f.get("width", 0) >= 300 and f.get("height", 0) >= 500:
            return round(f["width"]), round(f["height"])
    return 390, 844


def tap_at(c):
    subprocess.run(["axe", "tap", "-x", str(round(c[0])), "-y", str(round(c[1])), "--udid", UDID], capture_output=True)


def visible(c, w, h):
    return c is not None and 0 <= c[0] <= w and 0 <= c[1] <= h


def find(pred):
    w, h = screen()
    for n in walk(tree()):
        c = centre(n)
        if visible(c, w, h) and pred(texts(n)):
            return n, c, (w, h)
    return None, None, (w, h)


cmd, args = sys.argv[1], [norm(a) for a in sys.argv[2:]]
if cmd == "size":
    print(*screen())
elif cmd == "tap":
    n, c, _ = find(lambda t: bool(t & set(args)))
    if c:
        tap_at(c)
    print(1 if c else 0)
elif cmd == "tapx":
    q = args[0]
    w, h = screen()
    cands = [(texts(x), centre(x)) for x in walk(tree())]
    cands = [(t, c) for t, c in cands if visible(c, w, h)]
    hit = next((c for t, c in cands if q in t), None) or next((c for t, c in cands if any(q in s for s in t)), None)
    if hit:
        tap_at(hit)
    print(1 if hit else 0)
elif cmd == "tapid":
    n, c, _ = find(lambda t: args[0] in t)
    if c:
        tap_at(c)
    print(1 if c else 0)
elif cmd == "has":
    print(1 if any(any(args[0] in s for s in texts(n)) for n in walk(tree())) else 0)
elif cmd == "swiperow":
    n, c, (w, h) = find(lambda t: any(args[0] in s for s in t))
    if c:
        subprocess.run(["axe", "swipe", "--start-x", str(round(w * 0.85)), "--start-y", str(round(c[1])), "--end-x", str(round(w * 0.15)),
                        "--end-y", str(round(c[1])), "--duration", "0.4", "--udid", UDID], capture_output=True)
    print(1 if c else 0)
elif cmd == "isfront":
    root = next(iter(walk(tree())), None) or {}
    label = norm(root.get("AXLabel") or root.get("title") or "")
    print(1 if label and label != "springboard" and any(a and (a == label or a in label or label in a) for a in args) else 0)
elif cmd == "seen":
    w, h = screen()
    print(1 if any(visible(centre(n), w, h) and any(args[0] in s for s in texts(n)) for n in walk(tree())) else 0)
elif cmd == "front":
    t = tree()
    root = next(iter(walk(t)), None)
    print(norm((root or {}).get("AXLabel") or (root or {}).get("title") or "") or "?")
elif cmd == "login":
    print(1 if any(str(n.get("AXUniqueId") or "").startswith("login-") for n in walk(tree())) else 0)
