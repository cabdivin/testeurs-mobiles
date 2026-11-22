#!/usr/bin/env bash
# Scripted screenshots of the app on a booted simulator (no AI agent). The job log must stay empty of
# anything read on screen: only counters are printed, everything else goes to $OUT (encrypted afterwards).
# Env: UDID, APP (pro|patient), APP_URL (secret: .tar.gz of the Simulator .app), ROUTES (file), OUT (folder),
#      ROUTES_FILTRE (names, comma-separated, empty = all), QA_SESSION_TOKEN, QA_PATIENT_ID, QA_CONVERSATION_ID (secrets, optional)
set -uo pipefail
ROUTES_FILTRE=${ROUTES_FILTRE:-}
: "${UDID:?}" "${APP:?}" "${APP_URL:?}" "${ROUTES:?}" "${OUT:?}"
case "$APP" in pro) SCHEME=cabdivin-pro ;; patient) SCHEME=cabdivin ;; *) echo "app must be pro or patient"; exit 1 ;; esac
mkdir -p "$OUT"; J="$OUT/journal.txt"; : > "$J"
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$J"; }

mkdir -p "$RUNNER_TEMP/app-dl" && curl -fsSL "$APP_URL" -o "$RUNNER_TEMP/app.tar.gz" 2>/dev/null \
  && tar -xzf "$RUNNER_TEMP/app.tar.gz" -C "$RUNNER_TEMP/app-dl" || { echo "download of the app failed"; exit 1; }
APPDIR=$(find "$RUNNER_TEMP/app-dl" -maxdepth 3 -name '*.app' -type d | head -1)
[ -n "$APPDIR" ] || { echo "no .app in the archive"; exit 1; }
xcrun simctl install "$UDID" "$APPDIR" || { echo "install failed"; exit 1; }
BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APPDIR/Info.plist")
EXE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APPDIR/Info.plist")

# Expo dev menu (Debug build): no onboarding panel, no panel at launch, no floating button, no gestures
# (keys read from expo/expo packages/expo-dev-menu/ios/Modules/DevMenuPreferences.swift)
for k in EXDevMenuIsOnboardingFinished; do xcrun simctl spawn "$UDID" defaults write "$BID" "$k" -bool YES; done
for k in EXDevMenuShowsAtLaunch EXDevMenuShowFloatingActionButton EXDevMenuTouchGestureEnabled EXDevMenuMotionGestureEnabled EXDevMenuKeyCommandsEnabled; do
  xcrun simctl spawn "$UDID" defaults write "$BID" "$k" -bool NO
done

shot() { xcrun simctl io "$UDID" screenshot --type=png "$OUT/$1.png" >/dev/null 2>&1; }
H() { python3 scripts/ios/capture_helpers.py "$@"; }
ALERT_N=0
# The system alert "Open in <app>?" (SpringBoard) appears after a delay: probe every 0.5 s for 6 s at most
accept_alert() {
  for _ in $(seq 1 12); do
    if [ "$(H tap Ouvrir Open فتح)" = 1 ]; then ALERT_N=$((ALERT_N + 1)); sleep 1; return 0; fi
    sleep 0.5
  done
  return 1
}
# Notification permission sheet of the app: only ever "Plus tard" (never "Activer les notifications")
close_sheet() {  # $1 = number of probes (0.5 s apart)
  for _ in $(seq 1 "$1"); do
    if [ "$(H tap "Plus tard" Later لاحقاً لاحقا)" = 1 ]; then SHEET_N=$((SHEET_N + 1)); sleep 1; return 0; fi
    sleep 0.5
  done
  return 1
}
SHEET_N=0
openurl() { xcrun simctl openurl "$UDID" "$1" >/dev/null 2>&1; accept_alert; }

xcrun simctl launch "$UDID" "$BID" >/dev/null 2>&1 || { echo "launch failed"; exit 1; }
sleep 20; shot 00-lancement; log "lancement ok"
read -r W SH < <(H size)

scroll_down() {  # 4 swipes, like the Maestro flows
  for _ in 1 2 3 4; do
    axe swipe --start-x $((W / 2)) --start-y $((SH * 3 / 4)) --end-x $((W / 2)) --end-y $((SH / 4)) --duration 0.5 --udid "$UDID" >/dev/null 2>&1; sleep 1
  done
}

if [ "$APP" = pro ] && [ -n "${QA_SESSION_TOKEN:-}" ]; then
  ENC=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read().strip(),safe=""))' <<<"$QA_SESSION_TOKEN")
  openurl "${SCHEME}:/__qa/session?token=${ENC}"; unset ENC QA_SESSION_TOKEN
  sleep 25; close_sheet 20; shot 01-apres-session; log "session envoyee (alertes acceptees: $ALERT_N, feuilles fermees: $SHEET_N)"
else
  log "pas de session"
fi

SEL=",${ROUTES_FILTRE// /},"
N=2; DONE=0; TOTAL=0
while IFS="|" read -r NAME ROUTE WAIT <&3; do
  [[ -z "${NAME// }" || "$NAME" == \#* ]] && continue
  TOTAL=$((TOTAL + 1)); NN=$(printf '%02d' "$N"); N=$((N + 1))
  if [ -n "${ROUTES_FILTRE// /}" ] && [[ "$SEL" != *",$NAME,"* ]]; then continue; fi
  if [[ "$ROUTE" == *'{patient}'* ]]; then
    [ -n "${QA_PATIENT_ID:-}" ] || { log "$NAME saute (QA_PATIENT_ID vide)"; continue; }
    ROUTE=${ROUTE//\{patient\}/$QA_PATIENT_ID}
  fi
  if [[ "$ROUTE" == *'{conversation}'* ]]; then
    [ -n "${QA_CONVERSATION_ID:-}" ] || { log "$NAME saute (QA_CONVERSATION_ID vide)"; continue; }
    ROUTE=${ROUTE//\{conversation\}/$QA_CONVERSATION_ID}
  fi
  # Each route starts from a fresh launch: a modal opened by the previous link must not stay on top
  xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1; sleep 1
  xcrun simctl launch "$UDID" "$BID" >/dev/null 2>&1; sleep 6
  if [ "$APP" = pro ] && [ "$(H login)" = 1 ]; then log "$NAME : session perdue apres relance (ecran de connexion), parcours arrete"; break; fi
  close_sheet 2
  openurl "${SCHEME}:/${ROUTE}"; sleep "${WAIT:-8}"
  close_sheet 1
  shot "$NN-$NAME"
  scroll_down; shot "$NN-$NAME-bas"
  DONE=$((DONE + 1)); log "$NAME capture ok (alertes acceptees: $ALERT_N, feuilles fermees: $SHEET_N)"
done 3< "$ROUTES"

# JavaScript / native errors of the app during the run (200 lines at most)
xcrun simctl spawn "$UDID" log show --last 30m --style compact \
  --predicate "process == \"$EXE\" AND (messageType == error OR messageType == fault OR eventMessage CONTAINS \"ERROR\")" 2>/dev/null \
  | head -200 > "$OUT/erreurs-app.txt"
log "fin : $DONE routes capturees sur $TOTAL"
echo "captures: $DONE/$TOTAL routes, $(ls "$OUT"/*.png 2>/dev/null | wc -l | tr -d ' ') images"
