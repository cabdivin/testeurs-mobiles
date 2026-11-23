#!/usr/bin/env bash
# Scripted screenshots of the app on a booted simulator (no AI agent). The job log must stay empty of
# anything read on screen: only counters are printed, everything else goes to $OUT (encrypted afterwards).
# Env: UDID, APP (pro|patient), APP_URL (secret: .tar.gz of the Simulator .app), ROUTES (file), OUT (folder),
#      ROUTES_FILTRE (names, comma-separated, empty = all), SCENARIOS (names, empty = all, "aucun" = none), SCENARIOS_FILE, QA_SESSION_TOKEN, QA_PATIENT_ID, QA_CONVERSATION_ID (secrets, optional)
set -uo pipefail
ROUTES_FILTRE=${ROUTES_FILTRE:-}; SCENARIOS=${SCENARIOS:-}; SCENARIOS_FILE=${SCENARIOS_FILE:-scenarios/$APP.txt}
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
  if [ -n "${ROUTES_FILTRE// /}" ] && [ "$ROUTES_FILTRE" != aucune ] && [[ "$SEL" != *",$NAME,"* ]]; then continue; fi
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
done 3< "$([ "$ROUTES_FILTRE" = aucune ] && echo /dev/null || echo "$ROUTES")"


# ---------------------------------------------------------------------------------------------
# Interaction scenarios (scenarios/<app>.txt): "# name" opens a block, one step per line.
#   ouvrir <route> | toucher <label> | toucher-id <testID> | saisir <text> | attendre <s> | defiler bas|haut
#   retour | fermer-feuille | balayer-gauche <label> | sauter-si <text> | capture <name>
# Journal: step lines only (never screen content).
fresh_start() {
  xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1; sleep 1
  xcrun simctl launch "$UDID" "$BID" >/dev/null 2>&1; sleep 6
  if [ "$APP" = pro ] && [ "$(H login)" = 1 ]; then return 1; fi
  close_sheet 2; return 0
}
subst_route() {  # sets ROUTE_OUT, returns 1 when a token is empty
  ROUTE_OUT=$1
  if [[ "$ROUTE_OUT" == *'{patient}'* ]]; then [ -n "${QA_PATIENT_ID:-}" ] || return 1; ROUTE_OUT=${ROUTE_OUT//\{patient\}/$QA_PATIENT_ID}; fi
  if [[ "$ROUTE_OUT" == *'{conversation}'* ]]; then [ -n "${QA_CONVERSATION_ID:-}" ] || return 1; ROUTE_OUT=${ROUTE_OUT//\{conversation\}/$QA_CONVERSATION_ID}; fi
  return 0
}
# one step; return 0 = ok, 1 = failed, 2 = skip the rest of the scenario
run_step() {
  local verb=${1%% *} arg=""; [[ "$1" == *' '* ]] && arg=${1#* }
  case "$verb" in
    ouvrir) subst_route "$arg" || return 1; openurl "${SCHEME}:/${ROUTE_OUT}"; sleep 6; close_sheet 1; return 0 ;;
    toucher) [ "$(H tapx "$arg")" = 1 ] && { sleep 1.5; return 0; }; return 1 ;;
    toucher-id) [ "$(H tapid "$arg")" = 1 ] && { sleep 1.5; return 0; }; return 1 ;;
    saisir) python3 scripts/ios/type.py "$arg" >/dev/null 2>&1; sleep 1; H tap "Autoriser le collage" "Allow Paste" >/dev/null; sleep 1; return 0 ;;
    attendre) sleep "$arg"; return 0 ;;
    defiler)
      if [ "$arg" = haut ]; then axe swipe --start-x $((W / 2)) --start-y $((SH / 4)) --end-x $((W / 2)) --end-y $((SH * 3 / 4)) --duration 0.5 --udid "$UDID" >/dev/null 2>&1
      else axe swipe --start-x $((W / 2)) --start-y $((SH * 3 / 4)) --end-x $((W / 2)) --end-y $((SH / 4)) --duration 0.5 --udid "$UDID" >/dev/null 2>&1; fi
      sleep 1; return 0 ;;
    retour) axe gesture swipe-from-left-edge --screen-width "$W" --screen-height "$SH" --udid "$UDID" >/dev/null 2>&1; sleep 1.5; return 0 ;;
    fermer-feuille)
      if [ "$(H tap Annuler Cancel Fermer Close)" != 1 ]; then
        axe swipe --start-x $((W / 2)) --start-y $((SH / 3)) --end-x $((W / 2)) --end-y $((SH * 9 / 10)) --duration 0.6 --udid "$UDID" >/dev/null 2>&1
      fi
      sleep 1.5; return 0 ;;
    balayer-gauche) [ "$(H swiperow "$arg")" = 1 ] && { sleep 1; return 0; }; return 1 ;;
    sauter-si) [ "$(H has "$arg")" = 1 ] && return 2; return 0 ;;
    capture) close_sheet 1; shot "S${SCN_NN}-${SCN_NAME}-${arg}"; return 0 ;;
    *) return 1 ;;
  esac
}
run_scenario() {  # $1 = name, $2 = block (one step per line)
  SCN_NAME=$1; SCN_NN=$(printf '%02d' "$SCN_N"); SCN_N=$((SCN_N + 1))
  local line rc ok=0 ko=0
  if ! fresh_start; then log "scenario $SCN_NAME : session perdue apres relance, scenarios arretes"; return 9; fi
  while IFS= read -r line <&5; do
    line=${line%$'\r'}; [[ -z "${line// }" || "$line" == \;* ]] && continue
    run_step "$line"; rc=$?
    if [ $rc = 0 ]; then ok=$((ok + 1)); log "  [$SCN_NAME] ok : $line"
    elif [ $rc = 2 ]; then log "  [$SCN_NAME] saute ($line)"; break
    else ko=$((ko + 1)); log "  [$SCN_NAME] ECHEC : $line"; break; fi
  done 5<<<"$2"
  log "scenario $SCN_NAME : $ok etapes ok, $ko echec"
}
SCN_N=1
if [ "$SCENARIOS" != aucun ] && [ -f "$SCENARIOS_FILE" ]; then
  SSEL=",${SCENARIOS// /},"; CUR=""; BLOCK=""
  flush() { [ -n "$CUR" ] || return 0
    if [ -z "${SCENARIOS// /}" ] || [[ "$SSEL" == *",$CUR,"* ]]; then run_scenario "$CUR" "$BLOCK"; return $?; fi; return 0; }
  STOP=0
  while IFS= read -r L <&6 || [ -n "$L" ]; do
    L=${L%$'\r'}
    if [[ "$L" =~ ^#[[:space:]]*(.+)$ ]]; then
      flush; [ $? = 9 ] && { STOP=1; break; }
      CUR=${BASH_REMATCH[1]}; BLOCK=""
    else BLOCK+="$L"$'\n'; fi
  done 6< "$SCENARIOS_FILE"
  [ $STOP = 0 ] && flush
fi

# JavaScript / native errors of the app during the run (200 lines at most)
xcrun simctl spawn "$UDID" log show --last 30m --style compact \
  --predicate "process == \"$EXE\" AND (messageType == error OR messageType == fault OR eventMessage CONTAINS \"ERROR\")" 2>/dev/null \
  | head -200 > "$OUT/erreurs-app.txt"
log "fin : $DONE routes capturees sur $TOTAL"
echo "captures: $DONE/$TOTAL routes, $(ls "$OUT"/*.png 2>/dev/null | wc -l | tr -d ' ') images"
