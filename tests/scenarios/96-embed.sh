#!/usr/bin/env bash
# Embeds: the SDK frames <instance>/show?id=…, which lands on /embed, and an
# unregistered site gets the placeholder (the domain check happens on its
# POST). webtor.io does not serve embeds, so this suite is the only thing that
# still exercises web-ui's embed path -- it must stay alive in the image.
#
# Read-only: nothing is created, so it re-runs against a warm container.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

# 1. /show -> /embed, keeping the query the SDK put there.
loc="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "$BASE_URL/show?id=smoke&mode=video")"
case "$loc" in
  "301 "*"/embed?id=smoke&mode=video") ;;
  *) fail "/show did not redirect to /embed (got '$loc')" ;;
esac

# 2. The placeholder: a play button, not the "not available" page that an
# instance with embedding off answers with.
body="$(curl -fsS "$BASE_URL/embed?id=smoke&mode=video")" || fail "GET /embed failed"
case "$body" in
  *'data-umami-event="play-embed"'*) ;;
  *) fail "GET /embed did not render the embed placeholder: $(printf '%s' "$body" | head -c 300)" ;;
esac

# 3. Other sites may frame /embed: no frame-ancestors on it (FRAME_ANCESTORS
# is unset here, and /embed is exempt from it anyway).
csp="$(curl -sS -o /dev/null -D - "$BASE_URL/embed?id=smoke&mode=video" | tr -d '\r' | grep -i '^content-security-policy:' || true)"
case "$csp" in
  *frame-ancestors*) fail "/embed refuses to be framed: $csp" ;;
esac

# 4. The examples are served where embeds are.
code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/embed/example")"
assert_eq "$code" "200" "/embed/example status"

echo "OK: embed path alive"
