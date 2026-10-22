#!/usr/bin/env bash
# AI subtitles need SUBTITLE_TRANSLATE_ENABLED=true and a key for either AI
# backend, ANTHROPIC_API_KEY or OPENAI_API_KEY. Two launchers decide on that
# pair, subtitle-translate's and web-ui's, and both must take either key: one
# that knows only the first leaves an instance given the second without AI
# subtitles, telling its operator to set a key they never meant to.
#
# The shared container has the switch and no key (docker-compose.yml). A
# second one gets the switch and OPENAI_API_KEY alone, plus the
# recommendations switch, which web-ui gates on the same keys itself. The key
# is a dummy: nothing here makes a call to the backend.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

name=webtor-smoke-ai
cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" \
  -e SUBTITLE_TRANSLATE_ENABLED=true -e AI_RECOMMENDATIONS_ENABLED=true \
  -e OPENAI_API_KEY=smoke-not-a-real-key \
  "${WEBTOR_IMAGE:-ghcr.io/webtor-io/self-hosted:latest}" >/dev/null

ai_exec() {
  docker exec "$name" "$@"
}

# translate_status <exec-fn> -- subtitle-translate's answer to a bare GET from
# inside the container: 000 when its launcher idled it (nothing listens), 501
# when it runs without a key, 400 when it runs with one (the request names no
# target language). 8102 is SUBTITLE_TRANSLATE_SERVICE_PORT.
translate_status() {
  "$1" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8102/ </dev/null || true
}

# webui_env <exec-fn> VAR -- "VAR=value" as the running web-ui process has it;
# see 93-webdav.sh for why the process and not common.env.
webui_env() {
  local pid
  pid="$("$1" pgrep -f 'web-ui serve' </dev/null)" || fail "no running web-ui process to inspect"
  "$1" sh -c "tr '\\0' '\\n' < /proc/$pid/environ | grep '^$2='" </dev/null || true
}

# --- Switch on, no key: both launchers keep the feature off, and say why ---
assert_eq "$(translate_status webtor_exec)" "000" \
  "subtitle-translate on the shared container (switch on, no key) must stay idle"
assert_eq "$(webui_env webtor_exec SUBTITLE_TRANSLATE_ENABLED)" "SUBTITLE_TRANSLATE_ENABLED=false" \
  "web-ui on the shared container (switch on, no key) must not offer AI tracks"
# Captured, not piped into grep -q: see csrf_from in lib.sh for what pipefail
# makes of that.
logs="$(docker compose -f "$TESTS_DIR/docker-compose.yml" -p "$COMPOSE_PROJECT" logs webtor 2>/dev/null)" \
  || fail "could not read the shared container's log"
case "$logs" in
  *'SUBTITLE_TRANSLATE_ENABLED=true but neither ANTHROPIC_API_KEY nor'*) : ;;
  *) fail "subtitle-translate did not explain in the log that no AI key is set" ;;
esac

# --- Switch on, OPENAI_API_KEY alone: the feature is on ---
wait_for 180 "second instance to boot" ai_exec curl -fsS -o /dev/null http://127.0.0.1:8080/

translate_serves() {
  local s
  s="$(translate_status ai_exec)"
  echo "subtitle-translate answered $s (000: its launcher idled it, 501: it runs without the key)"
  [ "$s" = "400" ]
}
wait_for 60 "subtitle-translate to run with OPENAI_API_KEY alone" translate_serves

assert_eq "$(webui_env ai_exec SUBTITLE_TRANSLATE_ENABLED)" "SUBTITLE_TRANSLATE_ENABLED=true" \
  "web-ui must offer AI tracks with the switch and OPENAI_API_KEY alone"

# Discover tells its script whether the recommendations service exists; it
# does only when web-ui built an AI client from the key.
discover="$(ai_exec curl -fsS http://127.0.0.1:8080/discover)" || fail "GET /discover on the second instance failed"
case "$discover" in
  *'window._aiEnabled = true'*) : ;;
  *) fail "Discover has no AI recommendations with the switch and OPENAI_API_KEY alone" ;;
esac

echo "PASS: ai-keys"
