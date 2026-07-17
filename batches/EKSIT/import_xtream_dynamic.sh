#!/usr/bin/env bash
set -euo pipefail

M3U_URL="${1:-}"
M3U_URL="$(printf '%s' "$M3U_URL" | sed 's/\\//g')"
OUT="${2:-}"
UA="${UA:-IPTV Smarters Pro}"

if [[ -z "$M3U_URL" ]]; then
  echo "Usage:"
  echo "  $0 'http://host:port/get.php?username=USER&password=PASS&type=m3u_plus&output=ts' output.json"
  exit 1
fi

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing dependency: $1"
    exit 1
  }
}

need curl
need jq
need python3

HOST="$(python3 - "$M3U_URL" <<'PY'
import sys
from urllib.parse import urlparse
u = urlparse(sys.argv[1])
print(f"{u.scheme}://{u.netloc}")
PY
)"

USERNAME="$(python3 - "$M3U_URL" <<'PY'
import sys
from urllib.parse import urlparse, parse_qs
q = parse_qs(urlparse(sys.argv[1]).query)
print(q.get("username", [""])[0])
PY
)"

PASSWORD="$(python3 - "$M3U_URL" <<'PY'
import sys
from urllib.parse import urlparse, parse_qs
q = parse_qs(urlparse(sys.argv[1]).query)
print(q.get("password", [""])[0])
PY
)"

if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
  echo "Could not extract username/password from URL."
  exit 1
fi

# Default output filename: [hostname]-data-[D-M-Y].json (strip scheme and port from HOST).
if [[ -z "$OUT" ]]; then
  HOSTNAME="$(printf '%s' "$HOST" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*$##')"
  OUT="${HOSTNAME}-data-$(date +%d-%m-%Y).json"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

api() {
  local action="$1"
  curl -fsSL \
    -H "User-Agent: $UA" \
    -H "Accept: application/json" \
    "$HOST/player_api.php?username=$USERNAME&password=$PASSWORD&action=$action"
}

echo "Host: $HOST"
echo "Username: $USERNAME"

echo "Fetching account info..."
curl -fsSL \
  -H "User-Agent: $UA" \
  -H "Accept: application/json" \
  "$HOST/player_api.php?username=$USERNAME&password=$PASSWORD" \
  > "$TMP/account.json"

echo "Fetching live categories..."
api get_live_categories > "$TMP/live_categories.json"

echo "Fetching live channels..."
api get_live_streams > "$TMP/live_streams.json"

echo "Fetching VOD categories..."
api get_vod_categories > "$TMP/vod_categories.json"

echo "Fetching movies..."
api get_vod_streams > "$TMP/vod_streams.json"

echo "Fetching series categories..."
api get_series_categories > "$TMP/series_categories.json" || echo "[]" > "$TMP/series_categories.json"

echo "Fetching series..."
api get_series > "$TMP/series.json" || echo "[]" > "$TMP/series.json"

jq -n \
  --arg source_m3u "$M3U_URL" \
  --arg host "$HOST" \
  --arg username "$USERNAME" \
  --arg password "$PASSWORD" \
  --slurpfile account "$TMP/account.json" \
  --slurpfile live_categories "$TMP/live_categories.json" \
  --slurpfile live_streams "$TMP/live_streams.json" \
  --slurpfile vod_categories "$TMP/vod_categories.json" \
  --slurpfile vod_streams "$TMP/vod_streams.json" \
  --slurpfile series_categories "$TMP/series_categories.json" \
  --slurpfile series "$TMP/series.json" '
{
  generated_at: now | todate,
  source_m3u: $source_m3u,
  account: $account[0],
  live: {
    categories: ($live_categories[0] | map(
      . as $cat |
      $cat + {
        channels: (
          $live_streams[0]
          | map(select(.category_id == $cat.category_id))
          | map(. + {
              stream_url: "\($host)/live/\($username)/\($password)/\(.stream_id).ts"
            })
        )
      }
    ))
  },
  movies: {
    categories: ($vod_categories[0] | map(
      . as $cat |
      $cat + {
        movies: (
          $vod_streams[0]
          | map(select(.category_id == $cat.category_id))
          | map(. + {
              stream_url: "\($host)/movie/\($username)/\($password)/\(.stream_id).\(.container_extension // "mp4")"
            })
        )
      }
    ))
  },
  series: {
    categories: ($series_categories[0] | map(
      . as $cat |
      $cat + {
        series: (
          $series[0]
          | map(select(.category_id == $cat.category_id))
        )
      }
    ))
  }
}
' > "$OUT"

echo "Done: $OUT"
jq '{
  live_categories: (.live.categories | length),
  movie_categories: (.movies.categories | length),
  series_categories: (.series.categories | length)
}' "$OUT"
