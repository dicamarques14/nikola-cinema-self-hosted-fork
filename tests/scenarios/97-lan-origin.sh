#!/usr/bin/env bash
# A browser on another machine opens the instance over plain http by its LAN
# address. Browsers keep a Secure cookie only on https and localhost, so on
# such an address a Secure session cookie is dropped, every request starts a
# new session, and every form answers 400 "CSRF token mismatch" (#116). curl
# applies the same rule (Secure cookies only for https, localhost, 127.0.0.1
# and ::1), so a non-loopback name pinned to the published port stands in for
# that browser on any runner. Every other scenario uses localhost and cannot
# see this. Creates nothing.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

host=webtor-lan.test
port="${BASE_URL##*:}"
lan="http://$host:$port"
pin=(--resolve "$host:$port:127.0.0.1")
jar="$(mktemp)"
trap 'rm -f "$jar"' EXIT

body="$(curl -fsS "${pin[@]}" -c "$jar" "$lan/profile")" || fail "GET /profile at $lan failed"
grep -q $'\tsession\t' "$jar" \
  || fail "a browser at $lan would drop the session cookie: $(curl -sS "${pin[@]}" -o /dev/null -D - "$lan/" | tr -d '\r' | grep -i '^set-cookie: session=' | sed 's/=[^;]*;/=...;/')"
csrf_token="$(csrf_from "$body")" || fail "GET /profile at $lan rendered no _csrf token"

# The home form submitted empty: past CSRF it is a 302 back with ?err=,
# without a session it is 400 "CSRF token mismatch".
code="$(curl -sS "${pin[@]}" -b "$jar" -o /dev/null -w '%{http_code}' \
  -X POST --data-urlencode "_csrf=$csrf_token" -d 'resource=' "$lan/")"
assert_eq "$code" "302" "a form submitted from a plain-http LAN address"

echo "PASS: lan-origin"
