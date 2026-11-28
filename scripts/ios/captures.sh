#!/usr/bin/env bash
# Scripted screenshots of the app on a booted simulator (no AI agent). The job log must stay empty of
# anything read on screen: only counters are printed, everything else goes to $OUT (encrypted afterwards).
# Env: UDID, APP (pro|patient), APP_URL (secret: .tar.gz of the Simulator .app) or APP_ARCHIVE (local .tar.gz), ROUTES (file), OUT (folder),
#      ROUTES_FILTRE (names, comma-separated, empty = all), SESSION (aucune|famille, patient only), QA_PATIENT_TOKEN (secret, single use), SCENARIOS (names, empty = all, "aucun" = none), SCENARIOS_FILE, QA_SESSION_TOKEN, QA_PATIENT_ID, QA_CONVERSATION_ID (secrets, optional)
set -uo pipefail
ROUTES_FILTRE=${ROUTES_FILTRE:-}; SESSION=${SESSION:-aucune}; SCENARIOS=${SCENARIOS:-}; SCENARIOS_FILE=${SCENARIOS_FILE:-scenarios/$APP.txt}
: "${UDID:?}" "${APP:?}" "${ROUTES:?}" "${OUT:?}"
APP_ARCHIVE=${APP_ARCHIVE:-}; [ -n "$APP_ARCHIVE" ] || : "${APP_URL:?APP_URL or APP_ARCHIVE is required}"
case "$APP" in pro) SCHEME=cabdivin-pro ;; patient) SCHEME=cabdivin ;; *) echo "app must be pro or patient"; exit 1 ;; esac
mkdir -p "$OUT"; J="$OUT/journal.txt"; : > "$J"
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$J"; }

if [ -n "$APP_ARCHIVE" ]; then cp "$APP_ARCHIVE" "$RUNNER_TEMP/app.tar.gz"; else curl -fsSL "$APP_URL" -o "$RUNNER_TEMP/app.tar.gz" 2>/dev/null; fi \
  && mkdir -p "$RUNNER_TEMP/app-dl" && tar -xzf "$RUNNER_TEMP/app.tar.gz" -C "$RUNNER_TEMP/app-dl" || { echo "download of the app failed"; exit 1; }
APPDIR=$(find "$RUNNER_TEMP/app-dl" -maxdepth 3 -name '*.app' -type d | head -1)
[ -n "$APPDIR" ] || { echo "no .app in the archive"; exit 1; }
xcrun simctl install "$UDID" "$APPDIR" || { echo "install failed"; exit 1; }
BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APPDIR/Info.plist")
EXE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APPDIR/Info.plist")
APPNAME1=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APPDIR/Info.plist" 2>/dev/null || true)
APPNAME2=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$APPDIR/Info.plist" 2>/dev/null || true)

# Expo dev menu (Debug build): no onboarding panel, no panel at launch, no floating button, no gestures
# (keys read from expo/expo packages/expo-dev-menu/ios/Modules/DevMenuPreferences.swift)
for k in EXDevMenuIsOnboardingFinished; do xcrun simctl spawn "$UDID" defaults write "$BID" "$k" -bool YES; done
for k in EXDevMenuShowsAtLaunch EXDevMenuShowFloatingActionButton EXDevMenuTouchGestureEnabled EXDevMenuMotionGestureEnabled EXDevMenuKeyCommandsEnabled; do
  xcrun simctl spawn "$UDID" defaults write "$BID" "$k" -bool NO
done

shot() { xcrun simctl io "$UDID" screenshot --type=png "$OUT/$1.png" >/dev/null 2>&1; }
H() { python3 scripts/ios/capture_helpers.py "$@"; }
app_pid() { xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | awk -v b="UIKitApplication:$BID" 'index($0,b){print $1; exit}'; }
# Foreground = the app runs (PID) AND the root node of the AXe tree carries the app's own name (not SpringBoard, not empty).
# FG_ROOT keeps that root label (an app or system name, never screen content) for the journal.
au_premier_plan() {
  local pid; pid=$(app_pid); FG_ROOT=$(H front)
  [ -n "$pid" ] && [ "$pid" != "-" ] && [ "$(H isfront "$APPNAME1" "$APPNAME2")" = 1 ]
}
CRASH_N=0
collect_crashes() {  # app's own crash reports only (file name = process name); tools (axe...) are counted apart
  mkdir -p "$OUT/plantages"; local f b n=0 new=0 tools="" proc
  for f in "$HOME"/Library/Logs/DiagnosticReports/*.ips "$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Library/Logs/CrashReporter/"*; do
    [ -f "$f" ] || continue
    b=$(basename "$f"); proc=${b%%-20[0-9][0-9]-*}
    if [ "$proc" = "$EXE" ]; then
      n=$((n + 1))
      if [ ! -e "$OUT/plantages/$b" ]; then
        cp "$f" "$OUT/plantages/" && new=$((new + 1)); log "  plantage de l'app : $(python3 scripts/ios/crash_summary.py "$f" 2>/dev/null)"
      fi
    else
      case " $tools " in *" $proc "*) ;; *) tools="$tools $proc" ;; esac
    fi
  done
  log "rapports de plantage de l'app : $n (nouveaux : $new)"
  log "plantages d'outils (ignores) :${tools:- aucun}"
}
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
log "ecran : ${W}x${SH} points"

scroll_down() {  # 4 swipes, like the Maestro flows
  local i
  for i in 1 2 3 4; do
    axe swipe --start-x $((W / 2)) --start-y $((SH * 3 / 4)) --end-x $((W / 2)) --end-y $((SH / 4)) --duration 0.5 --udid "$UDID" >/dev/null 2>&1; sleep 1
    [ -n "${TRACE_SCROLL:-}" ] && log "  defilement $i (${W}x${SH}) : repere=$(H has "$TRACE_SCROLL")"
  done
}

if [ "$APP" = pro ] && [ -n "${QA_SESSION_TOKEN:-}" ]; then
  ENC=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read().strip(),safe=""))' <<<"$QA_SESSION_TOKEN")
  openurl "${SCHEME}:/__qa/session?token=${ENC}"; unset ENC QA_SESSION_TOKEN
  sleep 25; close_sheet 20; shot 01-apres-session; log "session envoyee (alertes acceptees: $ALERT_N, feuilles fermees: $SHEET_N)"
elif [ "$APP" = patient ] && [ "${SESSION:-aucune}" = famille ] && [ -n "${QA_PATIENT_TOKEN:-}" ]; then
  # Single-use family link token: no relaunch from here on (the session does not survive a restart)
  ENC=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read().strip(),safe=""))' <<<"$QA_PATIENT_TOKEN")
  openurl "cabdivin://magic-link?token=${ENC}"; unset ENC QA_PATIENT_TOKEN
  sleep 20; close_sheet 4; shot 01-apres-lien
  if [ "$(H login)" = 1 ]; then
    log "session refusee (ecran de connexion toujours affiche apres le lien)"; ROUTES_FILTRE=aucune; SCENARIOS=aucun
  else
    log "session famille ouverte"; NORELAUNCH=1; SCENARIOS=aucun
  fi
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
  if [ -z "${NORELAUNCH:-}" ]; then
    xcrun simctl terminate "$UDID" "$BID" >/dev/null 2>&1; sleep 1
    xcrun simctl launch "$UDID" "$BID" >/dev/null 2>&1; sleep 6
    if [ "$APP" = pro ] && [ "$(H login)" = 1 ]; then log "$NAME : session perdue apres relance (ecran de connexion), parcours arrete"; break; fi
    close_sheet 2
  fi
  openurl "${SCHEME}:/${ROUTE}"; sleep "${WAIT:-8}"
  close_sheet 1
  shot "$NN-$NAME"
  scroll_down; shot "$NN-$NAME-bas"
  DONE=$((DONE + 1)); log "$NAME capture ok (alertes acceptees: $ALERT_N, feuilles fermees: $SHEET_N)"
done 3< "$([ "$ROUTES_FILTRE" = aucune ] && echo /dev/null || echo "$ROUTES")"


collect_crashes

if [ -n "${NORELAUNCH:-}" ]; then
  SCN_N=1
  run_scenario selecteur-date "ouvrir (tabs)/rdv/book
attendre 4
toucher-id rdv-book-date-field
capture selecteur
fermer-feuille
capture apres-fermeture" nofresh
  # last: sign out through the app, to invalidate the session
  run_scenario deconnexion "ouvrir (tabs)/accueil/profil
attendre 4
toucher Se déconnecter
capture confirmation
toucher Se déconnecter
attendre 5
capture apres-deconnexion" nofresh
fi

# ---------------------------------------------------------------------------------------------
# Interaction scenarios (scenarios/<app>.txt): "# name" opens a block, one step per line.
#   ouvrir <route> | toucher <label> | toucher-id <testID> | saisir <text> | attendre <s> | defiler bas|haut
#   retour | fermer-feuille | balayer-gauche <label> | glisser gauche|droite | sauter-si <text> | capture <name>
#   hors-reseau / en-reseau (NetInfo reachability probe blocked / restored) | pivoter (rotate the simulator to landscape, iPad) | saisir-touches <text> (axe type only) | coller <text> / saisir <text> (pbcopy + Cmd+V only) | verifier-premier-plan
#   relancer | defiler-vers <text|testID> ; toucher / toucher-id accept alternatives: "a || b"
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
    toucher|toucher-id)  # alternatives separated by " || ", tried in order
      local alt rest sub=tapx; [ "$verb" = toucher-id ] && sub=tapid
      local pass
      for pass in 1 2; do  # second pass after 3 s: the screen may still be animating
        rest=$arg
        while :; do
          alt=${rest%% || *}
          [ "$(H "$sub" "$alt")" = 1 ] && { sleep 1.5; return 0; }
          [[ "$rest" == *' || '* ]] || break
          rest=${rest#* || }
        done
        [ $pass = 1 ] && sleep 3
      done
      return 1 ;;
    saisir|saisir-touches|coller)
      # `saisir` = paste only: the former type.py (Cmd+A, 60 backspaces) sent the app to the home screen
      local p0 p1; p0=$(app_pid)
      if [ "$verb" = saisir-touches ]; then
        axe type "$(printf '%s' "$arg" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || printf '%s' "$arg")" --udid "$UDID" >/dev/null 2>&1
      else
        printf '%s' "$arg" | xcrun simctl pbcopy "$UDID" >/dev/null 2>&1; axe key-combo --modifiers 227 --key 25 --udid "$UDID" >/dev/null 2>&1
      fi
      sleep 1; H tap "Autoriser le collage" "Allow Paste" >/dev/null; sleep 1
      p1=$(app_pid); log "  [$SCN_NAME] pid avant/apres $verb : ${p0:-aucun} -> ${p1:-aucun}"; return 0 ;;
    relancer) fresh_start; return $? ;;
    defiler-vers)
      for _ in 1 2 3 4 5 6; do
        [ "$(H seen "$arg")" = 1 ] && return 0
        axe swipe --start-x $((W / 2)) --start-y $((SH * 3 / 4)) --end-x $((W / 2)) --end-y $((SH / 2)) --duration 0.5 --udid "$UDID" >/dev/null 2>&1; sleep 1
      done
      [ "$(H seen "$arg")" = 1 ]; return $? ;;
    verifier-premier-plan) au_premier_plan && return 0; return 1 ;;
    hors-reseau)  # the app reads "no internet" from NetInfo's reachability probe: black-hole its host on this Mac
      echo "127.0.0.1 clients3.google.com" | sudo tee -a /etc/hosts >/dev/null 2>&1
      sudo dscacheutil -flushcache >/dev/null 2>&1; sudo killall -HUP mDNSResponder >/dev/null 2>&1; sleep 2; return 0 ;;
    en-reseau)
      sudo sed -i '' '/clients3.google.com/d' /etc/hosts >/dev/null 2>&1
      sudo dscacheutil -flushcache >/dev/null 2>&1; sudo killall -HUP mDNSResponder >/dev/null 2>&1; sleep 2; return 0 ;;
    pivoter)  # landscape: the Simulator window must exist, the rotation is a menu shortcut (Cmd+Right)
      open -a Simulator --args -CurrentDeviceUDID "$UDID" >/dev/null 2>&1; sleep 10
      osascript -e 'tell application "Simulator" to activate' -e 'delay 2' -e 'tell application "System Events" to key code 124 using {command down}' >/dev/null 2>&1
      local prc=$?; sleep 4; log "  [$SCN_NAME] pivoter : osascript $prc"; [ "$prc" = 0 ]; return $? ;;
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
    glisser)  # horizontal swipe across the content at 64% of the screen height: "glisser gauche" or "glisser droite"
      local gy=$((SH * 64 / 100)) gx1=$((W * 4 / 5)) gx2=$((W / 5))
      [ "$arg" = droite ] && { gx1=$((W / 5)); gx2=$((W * 4 / 5)); }
      axe swipe --start-x "$gx1" --start-y "$gy" --end-x "$gx2" --end-y "$gy" --duration 0.3 --udid "$UDID" >/dev/null 2>&1; sleep 1.5; return 0 ;;
    sauter-si) [ "$(H has "$arg")" = 1 ] && return 2; return 0 ;;
    capture) close_sheet 1; shot "S${SCN_NN}-${SCN_NAME}-${arg}"; return 0 ;;
    *) return 1 ;;
  esac
}
run_scenario() {  # $1 = name, $2 = block (one step per line), $3 = "nofresh" to keep the running app
  SCN_NAME=$1; SCN_NN=$(printf '%02d' "$SCN_N"); SCN_N=$((SCN_N + 1))
  local line rc ok=0 ko=0
  if [ "${3:-}" != nofresh ] && ! fresh_start; then log "scenario $SCN_NAME : session perdue apres relance, scenarios arretes"; return 9; fi
  while IFS= read -r line <&5; do
    line=${line%$'\r'}; [[ -z "${line// }" || "$line" == \;* ]] && continue
    run_step "$line"; rc=$?
    if au_premier_plan; then FG="oui"; else FG="non"; fi
    if [ $rc = 0 ]; then ok=$((ok + 1)); log "  [$SCN_NAME] ok : $line (premier plan : $FG, racine : $FG_ROOT)"
    elif [ $rc = 2 ]; then log "  [$SCN_NAME] saute ($line)"; break
    else
      ko=$((ko + 1)); log "  [$SCN_NAME] ECHEC : $line (premier plan : $FG, racine : $FG_ROOT)"
      shot "S${SCN_NN}-${SCN_NAME}-ECHEC-${ko}"; log "  [$SCN_NAME] arbre a l'echec : $(H stats)"
      break
    fi
  done 5<<<"$2"
  log "scenario $SCN_NAME : $ok etapes ok, $ko echec"
  collect_crashes
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

# Errors of the app during the run: known noise filtered out, 400 lines at most
NOISE='CoreHaptics|UIKBFeedbackGenerator|UIFocus|boringssl|nw_|quic_|CFNetwork|CUIThemeStore|app_launch_measurement'
xcrun simctl spawn "$UDID" log show --last 30m --style compact \
  --predicate "process == \"$EXE\" AND (messageType == error OR messageType == fault OR eventMessage CONTAINS \"ERROR\")" 2>/dev/null \
  | grep -v -E "$NOISE" | head -400 > "$OUT/erreurs-app.txt"
xcrun simctl spawn "$UDID" log show --last 30m --style compact \
  --predicate "process == \"ReportCrash\" OR process == \"osanalyticshelper\" OR eventMessage CONTAINS[c] \"$EXE\"" 2>/dev/null \
  | grep -i -E "crash|terminat|exception|abort|signal|jetsam|watchdog" | tail -80 > "$OUT/plantages.txt"
collect_crashes
log "fin : $DONE routes capturees sur $TOTAL"
echo "captures: $DONE/$TOTAL routes, $(ls "$OUT"/*.png 2>/dev/null | wc -l | tr -d ' ') images"
