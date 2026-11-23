"""One-line summary of an iOS crash report (.ips JSON or old text format): exception type, termination
indicator and the first 12 frames of the crashed thread. Function names only, no data. Usage: crash_summary.py <file>"""
import json, sys

raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
try:
    head, _, body = raw.partition("\n")
    h, d = json.loads(head), json.loads(body)
    exc = d.get("exception") or {}
    term = d.get("termination") or {}
    idx = d.get("faultingThread", 0)
    frames = []
    th = d.get("threads") or []
    images = d.get("usedImages") or []
    for f in (th[idx].get("frames") if idx < len(th) else [])[:12]:
        frames.append(f.get("symbol") or (images[f["imageIndex"]].get("name") if f.get("imageIndex", -1) < len(images) else "?"))
    print(f"date={h.get('timestamp', '?')} exception.type={exc.get('type', '?')} signal={exc.get('signal', '?')} "
          f"termination.indicator={term.get('indicator', '?')} frames={' < '.join(map(str, frames))}")
except Exception:
    lines = raw.splitlines()
    pick = lambda k: next((l.strip() for l in lines if l.startswith(k)), "?")
    i = next((n for n, l in enumerate(lines) if "Crashed:" in l), None)
    fr = [" ".join(l.split()[3:5]) for l in lines[i + 1:i + 13]] if i is not None else []
    print(f"date={pick('Date/Time')} exception.type={pick('Exception Type')} termination.indicator={pick('Termination')} frames={' < '.join(fr)}")
