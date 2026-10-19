#!/usr/bin/env bash
# Sign-in from another device, and sessions that outlive the container.
#
# A "car" browser opens /login and gets a QR code; a "phone" that signed in
# with the password approves it; the car claims and is signed in. Then the
# car's session must survive both a restart and a full recreate on the same
# volumes -- the sessions (redis) and the key that signs them
# (SESSION_SECRET) live on /data now, not in the container's own layer.
#
# Own container with ADMIN_PASSWORD, like 60-admin-password.sh, and its own
# named volume so the recreate step has something to come back to.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

port=18098
name=webtor-smoke-devlogin
vol=webtor-smoke-devlogin-data
image="${WEBTOR_IMAGE:-ghcr.io/webtor-io/self-hosted:latest}"
base="http://localhost:$port"
car="$(mktemp)"
phone="$(mktemp)"

cleanup() {
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker volume rm -f "$vol" >/dev/null 2>&1 || true
  rm -f "$car" "$phone"
}
trap cleanup EXIT

start() {
  docker run -d --name "$name" -e ADMIN_PASSWORD=smoke-test-password \
    -v "$vol:/data" -p "$port:8080" "$image" >/dev/null
  wait_for 180 "device-login instance to boot" curl -fsS -o /dev/null "$base/login"
}

nav=(-H 'Accept: text/html' -H 'Sec-Fetch-Mode: navigate')

docker rm -f "$name" >/dev/null 2>&1 || true
docker volume rm -f "$vol" >/dev/null 2>&1 || true
start

# --- The car opens the login page: password form AND a QR code with a code ---
car_page="$(curl -fsS -c "$car" -b "$car" "$base/login?return-url=/profile")"
case "$car_page" in
  *'type="password"'*) : ;;
  *) fail "the login page lost its password form" ;;
esac
token="$(first_group '/login/approve\?t=([A-Za-z0-9_-]+)' "$car_page")" \
  || fail "the login page carries no device-login QR link"
code="$(first_group 'data-device-code>([A-Z0-9]{3}-[A-Z0-9]{3})<' "$car_page")" \
  || fail "the login page shows no device-login code"
case "$car_page" in
  *'<svg'*) : ;;
  *) fail "the login page renders no QR code" ;;
esac
car_csrf="$(csrf_from "$car_page")" || fail "the car's login page has no _csrf token"

status="$(curl -fsS -b "$car" -c "$car" "$base/login/device/status")"
case "$status" in *'"pending"'*) : ;; *) fail "status before approval: $status" ;; esac

# --- The approve page is only for a signed-in administrator ---
anon_code="$(curl -s -o /dev/null -w '%{http_code}' "${nav[@]}" "$base/login/approve?t=$token")"
assert_eq "$anon_code" "302" "an anonymous visitor must be sent to /login from the approve page"

# --- The phone signs in with the password ---
phone_login="$(curl -fsS -c "$phone" -b "$phone" "$base/login")"
phone_csrf="$(csrf_from "$phone_login")" || fail "phone: no _csrf on /login"
pw_code="$(curl -s -o /dev/null -w '%{http_code}' -c "$phone" -b "$phone" \
  -X POST --data-urlencode "_csrf=$phone_csrf" -d 'password=smoke-test-password' "$base/login")"
assert_eq "$pw_code" "302" "phone password sign-in"

# --- The phone sees the same code, then approves ---
approve_page="$(curl -fsS -c "$phone" -b "$phone" "${nav[@]}" "$base/login/approve?t=$token")"
case "$approve_page" in
  *"$code"*) : ;;
  *) fail "the approve page does not show the car's code $code" ;;
esac
approve_csrf="$(csrf_from "$approve_page")" || fail "the approve page has no _csrf token"
approve_headers="$(curl -s -o /dev/null -D - -c "$phone" -b "$phone" -X POST \
  --data-urlencode "_csrf=$approve_csrf" --data-urlencode "t=$token" --data-urlencode "code=$code" \
  "$base/login/approve")"
grep -qi '^location: .*done=1' <<<"${approve_headers//$'\r'/}" \
  || fail "approving did not succeed: $approve_headers"

status="$(curl -fsS -b "$car" -c "$car" "$base/login/device/status")"
case "$status" in *'"approved"'*) : ;; *) fail "status after approval: $status" ;; esac

# --- The car claims and lands where it was headed ---
claim_headers="$(curl -s -o /dev/null -D - -c "$car" -b "$car" -X POST \
  --data-urlencode "_csrf=$car_csrf" "$base/login/device")"
grep -qi '^location: /profile' <<<"${claim_headers//$'\r'/}" \
  || fail "the claim did not redirect to the return-url: $claim_headers"
grep -qi '^set-cookie: session=' <<<"${claim_headers//$'\r'/}" \
  || fail "the claim did not set a (rotated) session cookie"

profile_code() {
  curl -s -o /dev/null -w '%{http_code}' -b "$car" "${nav[@]}" "$base/profile"
}
assert_eq "$(profile_code)" "200" "the car must be signed in after the claim"

# Single use: a second claim from the same car signs nothing new in.
second="$(curl -s -o /dev/null -w '%{http_code}' -b "$car" -X POST \
  --data-urlencode "_csrf=$car_csrf" "$base/login/device")"
assert_eq "$second" "302" "a second claim must just bounce back"

# --- The session survives a restart ... ---
docker restart "$name" >/dev/null
wait_for 180 "instance after restart" curl -fsS -o /dev/null "$base/login"
assert_eq "$(profile_code)" "200" "the car's session must survive a container restart"

# --- ... and a recreate on the same /data volume (an image update) ---
docker rm -f "$name" >/dev/null
start
wait_for 60 "car session after recreate" sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -b '$car' -H 'Accept: text/html' -H 'Sec-Fetch-Mode: navigate' '$base/profile')\" = 200 ]"

echo "PASS: device-login"
