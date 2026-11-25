# AGENTS.md — linux-terminal-tools

Server management scripts and tools for mail.eksneks.com (IP: 81.17.98.31).

---

## Server overview

| Component | Detail |
|-----------|--------|
| Host | mail.eksneks.com |
| IP | 81.17.98.31 |
| Web server | nginx |
| Cache | Varnish (port 6081) |
| PHP | PHP-FPM 8.3 (socket: /var/run/php/php8.3-fpm.sock) |
| Database | MySQL (admin: root via socket, app user: missiria) |
| Mail | Postfix + Dovecot |
| SSL | Let's Encrypt / certbot |

---

## Directory layout

```
/var/www/
  MISSIRIA/
    eksit/          — IPTV WordPress sites
    apps/
      shark-app/    — Next.js
      leader-app/   — NestJS API + Next.js front
  AI/editor/        — AI editor app (Next.js)
  GEO/              — Geo/tracking (fox-track-service-nextjs)
  IT/dashboard-app/ — IT dashboard

/etc/nginx/
  sites-available/  — config files (one per domain)
  sites-enabled/    — symlinks to active configs

/etc/letsencrypt/live/<domain>/
  fullchain.pem
  privkey.pem

/home/missiria/linux-terminal-tools/batches/
  autopilot.sh      — main site launcher batch
```

---

## Nginx architecture patterns

### Standard (no Varnish)
```
:80  → PHP-FPM (or 301 → HTTPS)
:443 SSL → PHP-FPM
```

### Varnish (when ENABLE_VARNISH=y)
```
:8080         → PHP-FPM (backend, not public)
:80           → 301 HTTPS redirect
:443 SSL      → Varnish :6081 (front door)
Varnish :6081 → nginx :8080
```

---

## autopilot.sh — site launcher

**Path:** /home/missiria/linux-terminal-tools/batches/autopilot.sh
**Run as:** root

Phase 1 collects all inputs interactively, Phase 2 executes silently.

### What it does (in order)
1. **Files** — create web root or rsync from source domain
2. **Nginx** — baseline `nginx -t`, then install the vhost. If the intended vhost needs a certificate that does not exist yet, it is parked as `sites-available/<domain>.ssl-pending` and an HTTP-only bootstrap vhost is enabled instead
3. **Certbot** — `certbot certonly --nginx --cert-name <domain> -d <domain> -d www.<domain>` (HTTP-01, nginx authenticator, no installer: Certbot never edits vhosts), verify the issued files, then swap the parked HTTPS vhost in
4. **Database** — create MySQL DB + user, or clone from source
5. **Email** — create postfix virtual mailbox + dovecot passwdfile entry
6. **Varnish** — write Varnish nginx config (checks certs exist before writing SSL block)
7. **Audit** — DNS, nginx, SSL, HTTP, DB, email status report

### Key variables
| Variable | Default | Description |
|----------|---------|-------------|
| MODE | — | `new` or `copy` |
| DOMAIN | — | Target domain (no www.) |
| WEB_ROOT | — | Absolute path to web root |
| EMAIL_PREFIX | contact | Email user prefix; also used as certbot contact |
| PHP_VER | 8.3 | PHP-FPM version |
| ENABLE_VARNISH | n | `y` to enable Varnish architecture |
| SKIP_CERTBOT | n | `y` to skip SSL (dev/local) |
| DB_USER | missiria | MySQL app user |
| MYSQL_ADMIN_USER | root | MySQL admin user |

### Environment overrides
```bash
DB_USER=missiria DB_PASS=xxx MYSQL_ADMIN_PASS=yyy ./autopilot.sh
```

### Nginx / SSL bootstrap (YITP-0268)

**Order for a domain with no certificate:** baseline test → HTTP bootstrap vhost (final HTTPS vhost parked as `.ssl-pending`) → DNS + reachability preflight → `certbot certonly --nginx` → verify cert (files readable, key matches, covers apex + www, not expiring) → swap HTTPS vhost in → test → reload.

**Prerequisites:** A/AAAA records for `<domain>` and `www.<domain>` reach this server on port 80 (directly or through a proxy that passes `/.well-known/acme-challenge/`). A name that does not resolve stops the run before any ACME attempt.

**Rules the script enforces**
- Every vhost change goes through `_nginx_install`: whole-config `nginx -t` before reload; on failure the previous vhost file and symlink state are restored (or the new file removed if there was none). A replaced pre-existing vhost is kept as `<domain>.autopilot-bak.<timestamp>`.
- Any nginx or certificate failure stops the run with a nonzero exit and names the stage. Later steps (DB, email, Varnish, audit) do not run.

| Exit | Stage |
|------|-------|
| 10 | Files (source root missing, rsync failed) |
| 20 | Nginx (baseline invalid, adapted config rejected, HTTPS activation rejected, Varnish vhost rejected) |
| 21 | Certificate (unexpected lineage state, DNS preflight, issuance failed, post-issuance verification) |

- Existing valid certificate → not re-issued; the HTTPS vhost is enabled directly.
- `live/<domain>` with dangling links, a `live/<domain>-0001` lineage, or orphan renewal/archive entries → stop (exit 21). The script never creates or overwrites a lineage blindly, and never borrows another site's certificate.
- Copy mode rewrites every source-domain reference (server_name, root, cert paths, logs, Certbot `if ($host = …)` blocks). Includes named after the source site (e.g. `404-redirects-<source>.conf`) are commented out with `# [autopilot] source-site include not inherited:`. If anything of the source is still active, the step fails.
- Varnish step keeps a config that already has the `:8080` backend + `:6081` front door (inherited from the source) instead of replacing it with the generic template.

**Re-run / recovery**
```bash
# Finish or repair cert + HTTPS for a vhost that already exists
# (issuance failed, DNS was not ready, run interrupted, SKIP_CERTBOT earlier):
autopilot --resume-ssl domain.com
```
`--resume-ssl` also repairs the pre-fix leftover state — vhost in `sites-available` pointing at a missing certificate with its `sites-enabled` symlink removed: it parks that vhost as `.ssl-pending`, enables the HTTP bootstrap, issues, then activates HTTPS.

Manual equivalents if the script cannot be used:
```bash
nginx -t                                            # must pass first
ls -la /etc/nginx/sites-available/domain.com*       # .ssl-pending = parked HTTPS vhost
certbot certificates | grep -A6 domain.com          # lineage state
certbot certonly --nginx --cert-name domain.com -d domain.com -d www.domain.com
cp /etc/nginx/sites-available/domain.com.ssl-pending /etc/nginx/sites-available/domain.com
ln -sfn /etc/nginx/sites-available/domain.com /etc/nginx/sites-enabled/domain.com
nginx -t && systemctl reload nginx
```

**Tests:** `bash batches/tests/autopilot-ssl-bootstrap.test.sh` — sandbox nginx prefix + stub certbot, real `nginx -t`; never touches `/etc/nginx` or reloads the live server.

**"protocol options redefined for 0.0.0.0:443" warnings** — separate from certificate errors and never fatal. Cause: vhosts sharing the `:443` socket declare different listen options (`listen 443 ssl;` in most vhosts, `listen 443 ssl http2;` in a few). The autopilot HTTPS template uses `listen 443 ssl;` (fleet majority) so it adds none; a copied vhost keeps the source's listener form. Removing the existing warnings means aligning the `http2` vhosts with the rest — a fleet change, not part of provisioning.

---

## Common operations

### Re-issue SSL cert (chicken-and-egg fix)
When nginx config already has SSL cert paths but cert doesn't exist:
```bash
autopilot --resume-ssl domain.com
```
See "Nginx / SSL bootstrap" above for what it does and the manual equivalent.

### Add new domain
```bash
bash /home/missiria/linux-terminal-tools/batches/autopilot.sh
# → select "new" mode
```

### Clone domain
```bash
bash /home/missiria/linux-terminal-tools/batches/autopilot.sh
# → select "copy" mode, provide source domain
```

### Check cert expiry
```bash
certbot certificates
```

### Reload nginx safely
```bash
nginx -t && systemctl reload nginx
```

---

## Known gotchas

- **`certbot --nginx` (installer) injects SSL into the first matching server block** — possibly the 8080 backend. autopilot now uses `certonly --nginx`, which never edits vhosts; the gotcha only applies to manual `certbot --nginx` runs.
- **Never pipe `nginx -t` into `grep` in a condition** — the script runs with `set -o pipefail`, so the pipeline fails whenever nginx fails, even if grep matched. Use `nginx_test` (captures output in `$NGINX_TEST_OUTPUT`, returns nginx's status).
- **Varnish + SKIP_CERTBOT** — if SSL skipped, exec_varnish writes HTTP-only config. Later: `autopilot --resume-ssl <domain>` issues the cert; then write the SSL 443 front door (or re-run the launcher).
- **wp-config.php proxy headers** — Varnish setup injects `HTTP_X_FORWARDED_PROTO` and `HTTP_X_FORWARDED_HOST` handling into wp-config.php automatically.
- **MySQL admin auth** — root connects via socket by default (no password). Set MYSQL_ADMIN_PASS env if socket auth not available.
- **PHP-FPM socket** — autopilot auto-detects first available socket if php8.3-fpm.sock missing.
