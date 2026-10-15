#!/usr/bin/env bash
# The player reads the file itself: movi-player opens the "download" export
# URL and seeks with Range requests, so no transcoding stands between the
# browser and the bytes. What it needs from this image, and what is held here:
#   - 206 with a correct Content-Range for a ranged GET (seeking),
#   - Accept-Ranges: bytes,
#   - Content-Range exposed to another origin (an embed on a third-party site):
#     without Access-Control-Expose-Headers the browser hides it, the player
#     falls back to forward-only playback and the seek bar goes away.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

jget() {
  local doc="$1" expr="$2" what="$3" val
  if ! val="$(printf '%s' "$doc" | python3 -c "
import json, sys

def walk(n):
    for it in (n.get('items') or []):
        yield it
        for sub in walk(it):
            yield sub

d = json.load(sys.stdin)
print($expr)
" 2>&1)"; then
    fail "$what: could not extract it -- $val
  from response: $doc"
  fi
  printf '%s' "$val"
}

resource="$(apiv1 POST /resource --data-binary "@$FIXTURE_DIR/smoke.torrent")"
id="$(jget "$resource" 'd["id"]' 'resource id')"
listing="$(apiv1 GET "/resource/$id/list?path=/")"
content_id="$(jget "$listing" \
  '[i["id"] for i in walk(d) if i.get("name") == "video.mp4"][0]' \
  'video.mp4 content id')"
export_json="$(apiv1 GET "/resource/$id/export/$content_id")"
url="$(jget "$export_json" 'd["exports"]["download"]["url"]' 'download url')"

headers="$(mktemp)"
body="$(mktemp)"
trap 'rm -f "$headers" "$body"' EXIT

# A cold swarm: the first bytes may take a while to arrive.
fetch_range() {
  curl -fsS -D "$headers" -o "$body" -H 'Origin: https://embedding.example' -H 'Range: bytes=0-1023' "$url"
}
wait_for 120 "ranged GET of the download URL" fetch_range

status="$(head -1 "$headers" | tr -d '\r')"
case "$status" in
  *" 206"*) : ;;
  *) fail "ranged GET did not answer 206 Partial Content: $status" ;;
esac

hdr() { grep -i "^$1:" "$headers" | head -1 | tr -d '\r' | cut -d: -f2- | sed 's/^ *//'; }

content_range="$(hdr content-range)"
case "$content_range" in
  "bytes 0-1023/"*) : ;;
  *) fail "Content-Range is not 'bytes 0-1023/<size>': '$content_range'" ;;
esac
assert_eq "$(hdr accept-ranges)" "bytes" "Accept-Ranges"
assert_eq "$(wc -c < "$body" | tr -d ' ')" "1024" "ranged body length"

expose="$(hdr access-control-expose-headers | tr 'A-Z' 'a-z')"
case "$expose" in
  *content-range*) : ;;
  *) fail "Content-Range is not exposed to other origins (Access-Control-Expose-Headers: '$expose'): an embed could not seek" ;;
esac
allow="$(hdr access-control-allow-origin)"
[ -n "$allow" ] || fail "no Access-Control-Allow-Origin: an embed on another site could not read the file"

# The bytes are an MP4, not an error page of the right length: its first box
# is `ftyp`, four bytes in.
magic="$(head -c 8 "$body" | tail -c 4)"
assert_eq "$magic" "ftyp" "first box of video.mp4"

echo "PASS: range"
