# scripts

## check_iptv.py

CLI IPTV checker. Xtream Codes accounts + M3U links. Single check or bulk via CSV.

### Usage

```
python3 check_iptv.py check xstream <host> <username> <password>
python3 check_iptv.py check m3u <m3u_url>

python3 check_iptv.py bulk xstream <csvfile> [--output-csv report.csv]
python3 check_iptv.py bulk m3u <csvfile> [--output-csv report.csv]
```

Bulk CSV columns:
- xstream: `host,username,password`
- m3u: `m3u_url`

### Global options

| Flag | Default | Desc |
|---|---|---|
| `--timeout` | 10 | HTTP timeout (s) |
| `--retries` | 2 | Retry count on transient errors (429/500/502/503/504) |
| `--backoff` | 2.0 | Backoff pause between retries |
| `--user-agent` | `Mozilla/5.0` | HTTP User-Agent |
| `--no-color` | off | Disable colored output |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Active full account / valid M3U |
| 1 | Error / unusable |
| 2 | Expired |
| 3 | Active trial account |

Bulk mode exits with the max code across all rows.

### Requires

Python 3, stdlib only (no deps).
