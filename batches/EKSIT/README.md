# EKSIT — Xtream Codes Import Scripts

Two bash scripts, pull Xtream Codes IPTV portal data via `player_api.php`, dump structured JSON.

## Common deps
- `curl`, `jq` (both)
- `python3` (dynamic script only, parses M3U URL)

## 1. `import_xtream.sh`

Fixed-config puller. Host/user/pass hardcoded as defaults, overridable via env vars.

**Env vars:**
- `HOST` (default `http://portal4k.shop:80`)
- `USER_NAME` (default `testagain25`)
- `PASSWORD` (default `7h2hb23cpq`)
- `UA` (default `IPTV Smarters Pro`)
- `OUT` (default `<hostname>-data-<DD-MM-YYYY>.json`)

**Run:**
```
./import_xtream.sh
# or
HOST=http://myportal:80 USER_NAME=foo PASSWORD=bar ./import_xtream.sh
```

**Fetches:** live categories, live streams, VOD categories, VOD streams.
**Output JSON:** `{ generated_at, server, live.categories[].channels[], movies.categories[].movies[] }`, each channel/movie gets injected `stream_url`.

Bug: line 80-81, `jq '...'` piped to `"$OUT"` split across two lines without `\` continuation — bash treats `"$OUT"` as separate command (tries to execute file as command), breaks final summary print. Core JSON build (line 37-77) unaffected.

## 2. `import_xtream_dynamic.sh`

Takes raw M3U URL as input, extracts host/user/pass itself. No hardcoded creds.

**Usage:**
```
./import_xtream_dynamic.sh 'http://host:port/get.php?username=USER&password=PASS&type=m3u_plus&output=ts' [output.json]
```
- Arg 1: M3U URL (required)
- Arg 2: output filename (optional, same default naming as above)
- `UA` env var override same as script 1

**Fetches:** account info, live categories/streams, VOD categories/streams, series categories/series (series calls tolerate failure, fall back to `[]`).

**Output JSON:** adds `source_m3u`, `account`, plus `series.categories[].series[]` block on top of script 1's shape.

## Differences at a glance

| | import_xtream.sh | import_xtream_dynamic.sh |
|---|---|---|
| Creds source | env vars, hardcoded defaults | parsed from M3U URL arg |
| Account info | no | yes |
| Series data | no | yes |
| python3 required | no | yes |
| Output line bug | yes (broken multi-line jq pipe) | no |
