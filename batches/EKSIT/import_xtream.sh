#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-http://portal4k.shop:80}"
USER="${USER_NAME:-testagain25}"
PASS="${PASSWORD:-7h2hb23cpq}"
UA="${UA:-IPTV Smarters Pro}"

# Derive hostname from HOST (strip scheme and port) for the default filename.
HOSTNAME="$(printf '%s' "$HOST" | sed -E 's#^[a-zA-Z]+://##; s#[:/].*$##')"
OUT="${OUT:-${HOSTNAME}-data-$(date +%d-%m-%Y).json}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

api() {
  local action="$1"
  curl -fsSL \
    -H "User-Agent: $UA" \
    -H "Accept: application/json" \
    "$HOST/player_api.php?username=$USER&password=$PASS&action=$action"
}

echo "Fetching live categories..."
api get_live_categories > "$TMP/live_categories.json"

echo "Fetching live channels..."
api get_live_streams > "$TMP/live_streams.json"

echo "Fetching VOD categories..."
api get_vod_categories > "$TMP/vod_categories.json"

echo "Fetching movies..."
api get_vod_streams > "$TMP/vod_streams.json"

echo "Building JSON..."
jq -n \
  --arg host "$HOST" \
  --arg username "$USER" \
  --arg password "$PASS" \
  --slurpfile live_categories "$TMP/live_categories.json" \
  --slurpfile live_streams "$TMP/live_streams.json" \
  --slurpfile vod_categories "$TMP/vod_categories.json" \
  --slurpfile vod_streams "$TMP/vod_streams.json" '
{
  generated_at: now | todate,
  server: $host,
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
  }
}
' > "$OUT"

echo "Done: $OUT"
jq '.live.categories | length as $lc | .movies.categories | length as $mc | {live_categories:$lc, movie_categories:$mc}' 
"$OUT"
