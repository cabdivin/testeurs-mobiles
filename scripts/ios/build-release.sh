#!/usr/bin/env bash
# Production iOS build of a Cabdivin app with `eas build --local` (no EAS cloud build), optional TestFlight upload.
# Public repo: every tool output goes to results/build-ios-<app>/*.log (encrypted afterwards);
# the public log only carries the step lines written here.
# Env: APP (pro|patient), REF, PROFIL (production|qa-simulateur), ENVOYER (oui|non), ARTIFACT_PASSPHRASE, EXPO_TOKEN, OMNICAB_DEPLOY_KEY, IOS_DIST_P12_B64,
#      IOS_DIST_P12_PASSWORD, IOS_PROFILE_B64, ASC_API_KEY_P8_B64, ASC_KEY_ID, ASC_ISSUER_ID, APPLE_TEAM_ID
set +x
set -uo pipefail
case "${APP:-}" in pro) BUNDLE_ID=com.cabdivin.pro ;; patient) BUNDLE_ID=com.cabdivin.patient ;; *) echo "::error::app must be pro or patient"; exit 1 ;; esac
PROFIL=${PROFIL:-production}
case "$PROFIL" in production|qa-simulateur) ;; *) echo "::error::profil must be production or qa-simulateur"; exit 1 ;; esac
if [ "$PROFIL" = qa-simulateur ] && [ "${ENVOYER:-non}" = oui ]; then echo "::error::qa-simulateur builds are never uploaded"; exit 1; fi
if [[ "${REF:-}" =~ ^[0-9a-f]{7,39}$ ]]; then echo "::error::ref looks like an abbreviated SHA: give a branch or the full 40-character SHA"; exit 1; fi
ROOT=${GITHUB_WORKSPACE:-$PWD}
LOGS="$ROOT/results/build-ios-$APP"; mkdir -p "$LOGS"
WORK="$RUNNER_TEMP/omnicab"; SIGN="$RUNNER_TEMP/sign"; OUT="$RUNNER_TEMP/out"; IPA="$OUT/$APP.ipa"
mkdir -p "$SIGN" "$OUT"; chmod 700 "$SIGN"
N=0
step() {  # step <name> <command...>: output to its own log, one public line
  local name=$1; shift; N=$((N + 1))
  local log; log="$LOGS/$(printf '%02d' $N)-$name.log"
  local t0=$SECONDS; "$@" >"$log" 2>&1; local rc=$?
  if [ $rc -eq 0 ]; then echo "step $name: ok ($((SECONDS - t0)) s)"; else echo "::error::step $name: failed, code $rc ($((SECONDS - t0)) s)"; fi
  return $rc
}
finish() { echo "app=$APP ref=$REF sha=${SHA:-?} profil=$PROFIL version=${VERSION:-?} build=${BUILD:-?} sent=${SENT:-non}" | tee -a "$GITHUB_STEP_SUMMARY"; }
trap finish EXIT

clone() {
  install -m 600 /dev/null "$SIGN/deploy_key"; printf '%s\n' "$OMNICAB_DEPLOY_KEY" > "$SIGN/deploy_key"
  export GIT_SSH_COMMAND="ssh -i $SIGN/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  rm -rf "$WORK" && git init -q "$WORK" && cd "$WORK" \
    && git remote add origin git@github.com:cabdivin/OmniCab.git \
    && git fetch -q --depth 1 origin "$REF" && git checkout -q FETCH_HEAD \
    && git log -1 --format='%h %s'
}

tools() {
  xcodebuild -version; node -v; npm -v
  command -v pod || sudo gem install cocoapods --no-document
  command -v fastlane || brew install fastlane
  pod --version && fastlane --version
}

signing() {
  cd "$WORK/mobile" || return 1
  printf '%s' "$IOS_DIST_P12_B64" | base64 --decode > "$SIGN/dist.p12"
  printf '%s' "$IOS_PROFILE_B64" | base64 --decode > "$SIGN/$APP.mobileprovision"
  printf '%s' "$ASC_API_KEY_P8_B64" | base64 --decode > "$SIGN/asc.p8"
  chmod 600 "$SIGN"/*
  SIGN="$SIGN" node -e '
    const fs = require("fs"), app = process.env.APP, s = process.env.SIGN;
    const f = `apps/${app}/eas.json`, j = JSON.parse(fs.readFileSync(f));
    j.build.production.ios = { ...(j.build.production.ios || {}), credentialsSource: "local" };
    Object.assign(j.submit.production.ios, { ascApiKeyPath: `${s}/asc.p8`, ascApiKeyId: process.env.ASC_KEY_ID,
      ascApiKeyIssuerId: process.env.ASC_ISSUER_ID, appleTeamId: process.env.APPLE_TEAM_ID });
    fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
    fs.writeFileSync(`apps/${app}/credentials.json`, JSON.stringify({ ios: { provisioningProfilePath: `${s}/${app}.mobileprovision`,
      distributionCertificate: { path: `${s}/dist.p12`, password: process.env.IOS_DIST_P12_PASSWORD } } }), { mode: 0o600 });'
  echo 'mobile/apps/*/credentials.json' >> "$WORK/.git/info/exclude"
  git -c user.name=runner -c user.email=runner@localhost commit -q -am "local build credentials (never pushed)"
  security cms -D -i "$SIGN/$APP.mobileprovision" > "$SIGN/profile.plist"
  /usr/libexec/PlistBuddy -c 'Print :Name' -c 'Print :ExpirationDate' -c 'Print :Entitlements:application-identifier' "$SIGN/profile.plist"
}

install_deps() { cd "$WORK/mobile" && npm ci --no-audit --no-fund; }

preflight() {
  cd "$WORK/mobile/apps/$APP" || return 1
  local entry; entry=$(node -e 'require("expo/scripts/resolveAppEntry")' "$PWD" ios absolute) || return 1
  npx expo export:embed --platform ios --dev false --reset-cache --entry-file "$entry" \
    --bundle-output dist/main.jsbundle --assets-dest dist || return 1
  node ../../scripts/check-release-bundle.mjs "$APP" --bundle dist/main.jsbundle && rm -rf dist
}

build() {
  cd "$WORK/mobile/apps/$APP" || return 1
  export EAS_LOCAL_BUILD_WORKINGDIR="$RUNNER_TEMP/eas-work" EAS_LOCAL_BUILD_ARTIFACTS_DIR="$OUT/artifacts"
  npx --yes eas-cli@latest build:version:get --platform ios --profile "$PROFIL" --non-interactive || true
  npx --yes eas-cli@latest build --local --platform ios --profile "$PROFIL" --non-interactive --output "$IPA" || return 1
  npx --yes eas-cli@latest build:version:get --platform ios --profile "$PROFIL" --non-interactive || true
}

check_sim() {  # simulator .app of the QA profile: route table AND the QA session route must be present
  local x="$RUNNER_TEMP/simapp"; rm -rf "$x"; mkdir -p "$x" && tar -xzf "$SIMTGZ" -C "$x" || return 1
  local a; a=$(find "$x" -maxdepth 3 -name '*.app' -type d | head -1); [ -d "$a" ] || { echo "no .app"; return 1; }
  local pb=/usr/libexec/PlistBuddy id m
  id=$($pb -c 'Print :CFBundleIdentifier' "$a/Info.plist")
  $pb -c 'Print :CFBundleShortVersionString' "$a/Info.plist" > "$OUT/version"
  $pb -c 'Print :CFBundleVersion' "$a/Info.plist" > "$OUT/build"
  echo "bundle id: $id"; [ "$id" = "$BUNDLE_ID" ] || { echo "wrong bundle id"; return 1; }
  $pb -c 'Print :CFBundleSupportedPlatforms' "$a/Info.plist" | grep -q iPhoneSimulator || { echo "not a simulator build"; return 1; }
  local b="$a/main.jsbundle"; [ -f "$b" ] || { echo "no main.jsbundle"; return 1; }
  ls -l "$b"
  grep -a -q 'omnicab.qa.session-injector.v1' "$b" || { echo "QA session injector missing"; return 1; }
  for m in $(case $APP in pro) echo journee agenda patients messages reglages ;; *) echo accueil famille rdv messages profil ;; esac); do
    grep -a -q "$m" "$b" || { echo "route marker $m missing"; return 1; }
  done
  echo "route table and QA session route present"
}

package_sim() {  # encrypted with ARTIFACT_PASSPHRASE so captures-ios.yml can decrypt it in its own runner
  [ -n "${ARTIFACT_PASSPHRASE:-}" ] || { echo "ARTIFACT_PASSPHRASE missing"; return 1; }
  mkdir -p "$ROOT/app-out" && openssl enc -aes-256-cbc -pbkdf2 -salt -in "$SIMTGZ" -out "$ROOT/app-out/app-ios.tgz.enc" -pass env:ARTIFACT_PASSPHRASE
}

check_ipa() {
  local x="$RUNNER_TEMP/ipa"; rm -rf "$x"; mkdir -p "$x" && unzip -q "$IPA" -d "$x" || return 1
  local a; a=$(ls -d "$x"/Payload/*.app | head -1); [ -d "$a" ] || return 1
  local pb=/usr/libexec/PlistBuddy id
  id=$($pb -c 'Print :CFBundleIdentifier' "$a/Info.plist")
  $pb -c 'Print :CFBundleShortVersionString' "$a/Info.plist" > "$OUT/version"
  $pb -c 'Print :CFBundleVersion' "$a/Info.plist" > "$OUT/build"
  echo "bundle id: $id"; [ "$id" = "$BUNDLE_ID" ] || { echo "wrong bundle id"; return 1; }
  [ -f "$a/embedded.mobileprovision" ] || { echo "no embedded profile"; return 1; }
  security cms -D -i "$a/embedded.mobileprovision" > "$x/p.plist"
  [ "$($pb -c 'Print :Entitlements:get-task-allow' "$x/p.plist")" = false ] || { echo "get-task-allow is not false"; return 1; }
  if $pb -c 'Print :ProvisionedDevices' "$x/p.plist" >/dev/null 2>&1; then echo "profile lists devices: not App Store"; return 1; fi
  codesign -dvv "$a" 2>&1 | grep -E '^(Authority|TeamIdentifier)='
  codesign -dvv "$a" 2>&1 | grep -q '^Authority=Apple Distribution' || { echo "not signed with Apple Distribution"; return 1; }
  node "$WORK/mobile/scripts/check-release-bundle.mjs" "$APP" --bundle "$a/main.jsbundle"
}

submit() {
  cd "$WORK/mobile/apps/$APP" && npx --yes eas-cli@latest submit --platform ios --path "$IPA" --profile production --non-interactive
}

step clone clone || exit 1
SHA=$(git -C "$WORK" rev-parse --short HEAD)
step tools tools || exit 1
if [ "$PROFIL" = qa-simulateur ]; then
  SIMTGZ="$OUT/$APP-sim.tar.gz"; IPA=$SIMTGZ
  step npm-ci install_deps || exit 1
  step eas-build-local build || exit 1
  step sim-check check_sim; RC=$?
  VERSION=$(cat "$OUT/version" 2>/dev/null); BUILD=$(cat "$OUT/build" 2>/dev/null)
  [ $RC -eq 0 ] || exit 1
  step package package_sim || exit 1
  exit 0
fi
step signing signing || exit 1
step npm-ci install_deps || exit 1
step preflight-bundle preflight || exit 1
step eas-build-local build || exit 1
step ipa-check check_ipa; RC=$?
VERSION=$(cat "$OUT/version" 2>/dev/null); BUILD=$(cat "$OUT/build" 2>/dev/null)
[ $RC -eq 0 ] || exit 1
if [ "${ENVOYER:-non}" = oui ]; then step testflight-submit submit && SENT=oui || exit 1; fi
exit 0
