"""Matrix of the captures workflow: one job per device x theme, with its index (for the QA_TOKEN_CAPTURES_<n> secret).
Env: DEVICES, THEMES (comma-separated). Prints matrix=<json> for $GITHUB_OUTPUT."""
import json, os, re

split = lambda k: [x.strip() for x in os.environ.get(k, "").split(",") if x.strip()]
devices, themes = split("DEVICES"), split("THEMES")
bad = [t for t in themes if t not in ("light", "dark")]
if bad or not devices or not themes:
    raise SystemExit(f"Bad devices/themes: {devices} {themes}")
rows = []
for d in devices:
    for t in themes:
        rows.append({"idx": len(rows) + 1, "device": d, "theme": t,
                     "slug": re.sub(r"[^a-z0-9]+", "-", d.lower()).strip("-")})
print("matrix=" + json.dumps(rows))
