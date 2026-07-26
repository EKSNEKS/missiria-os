# wp-hosting-stack batches (paradiso)

Provision / clone / migrate WordPress tenants on the **paradiso** server
(`109.199.102.152`, Ubuntu 24.04) which runs the `wp-hosting-stack` toolkit at
`/root/wp-hosting-stack/`. Each tenant is fully isolated: dedicated Linux user,
MariaDB database + user, PHP-FPM pool/socket, nginx vhost (FastCGI cache),
Redis object cache, TLS.

> These scripts are the **canonical copies** for versioning. They run **live from
> `/root/wp-hosting-stack/`**, where `lib/common.sh`, `create-site.sh`,
> `deploy-wp`, and the MariaDB/Dovecot stack exist. Copy a changed script back
> to `/root/wp-hosting-stack/` (and `chmod +x`) to deploy it.

## Scripts

| Script | Purpose |
|--------|---------|
| `autopilot.sh` | Interactive wizard (NEW blank site, or COPY = repo files + DB cloned from a sister). Orchestrates create-site → import-site → deploy-wp → audit. |
| `import-site.sh` | Clone a **database** from an existing tenant into another tenant (+ Telegram/SMTP constants). DB-only; files come from the repo checkout. |
| `migrate-from-backup.sh` | Full **same-domain site** migration from the old-VPS nightly backups → paradiso (files + DB). |
| `migrate-mail.sh` | Per-domain **mailbox** migration (accounts + Maildir + aliases + Roundcube data) old-VPS → paradiso. |

Depends on the stack's own `create-site.sh` (provision) and `deploy-wp` (sync
theme/plugins from a tenant's `repo/` checkout) — both already in
`/root/wp-hosting-stack/`.

## One-time prerequisites

1. **Shared notify secrets** (Telegram bot + SMTP transport) — used by autopilot,
   import-site, migrate-from-backup. Create `/etc/wp-hosting/missiria-notify.conf`
   (root, `chmod 600`):
   ```sh
   TG_BOT_TOKEN="<telegram bot token>"
   TG_CHAT_ID="<telegram chat id>"
   SMTP_HOST="localhost"      # WP + Postfix co-located → local relay
   SMTP_PORT=25
   SMTP_SECURE=""
   # SMTP_AUTH defaults to false; per-site username/from derived from the domain
   ```
2. **SSH access to the old VPS** (only for the two `migrate-*` scripts, which pull
   from `root@81.17.98.31`). Authorise paradiso's key once:
   ```sh
   ssh paradiso 'cat /root/.ssh/id_ed25519.pub 2>/dev/null || cat /root/.ssh/id_rsa.pub' \
     | ssh root@81.17.98.31 'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys'
   ```

Per-tenant facts + secrets live in `/etc/wp-hosting/sites/<domain>.env` (root-only).

---

## autopilot.sh

Interactive launcher — answer the prompts, review the summary, launch.

```sh
sudo /root/wp-hosting-stack/autopilot.sh
```
- **NEW** — blank WordPress from a client repo.
- **COPY** — repo files (themes/plugins) + database cloned from a sister tenant,
  with the domain rewritten. Optional uploads copy. Optional SSL now / later.

Default client repo: `git@github.com:EKSNEKS/MIT-IX.git`.

---

## import-site.sh

Clone a sister tenant's **database** into an already-provisioned tenant.

```sh
sudo /root/wp-hosting-stack/import-site.sh <target-domain> --from-local  <source-domain>
sudo /root/wp-hosting-stack/import-site.sh <target-domain> --from-remote <ssh-host> --remote-db <db>
sudo /root/wp-hosting-stack/import-site.sh <target-domain> --from-file   <dump.sql>
     [--dry-run] [--mail-pass <pw>] [--no-notify]
```
- Detects the source table prefix + siteurl from the dump, backs up the target,
  `wp db reset`, imports, rewrites `old-domain → target-domain`.
- Sets `blog_public=1` (never leave a clone noindex).
- By default writes the MISSIRIA Telegram + SMTP constants and creates the
  `contact@<domain>` mailbox (password → the site `.env`).
- **Files are NOT copied** — run `deploy-wp <domain>` to sync theme/plugins from
  the tenant's repo checkout.

Example: `import-site.sh x-iptv.fr --from-local abonnement-iptv-x.fr`

---

## migrate-from-backup.sh

Full **same-domain** migration of a site from the old-VPS nightly backups
(`/var/backups/missiria-auto/<ts>/<domain>/` → `backup-info.txt`, `files.tar.gz`,
`<db>.sql.gz`) onto paradiso.

```sh
sudo /root/wp-hosting-stack/migrate-from-backup.sh <domain> \
     [--backup <YYYYmmdd_HHMMSS>] [--source root@81.17.98.31] [--ssl] [--dry-run] [--force]
```
Default: latest backup, `--no-ssl` (DNS still points to the old VPS). Steps:
stream backup → `create-site.sh` (blank tenant) → overlay `wp-content` → import DB
(prefix from dump) → salts / `blog_public=1` / Redis / notify → health check.

**No DNS change is made.** After it verifies, cut over:
1. Cloudflare: point A/AAAA for `<domain>` + `www` → `109.199.102.152`.
2. `sudo /root/wp-hosting-stack/create-site.sh <domain>` (idempotent) → issues the LE cert.

Verify first: `migrate-from-backup.sh <domain> --dry-run`.

---

## migrate-mail.sh

Per-domain **mailbox** migration, old VPS → paradiso. The two servers use
different mail schemes (old: Dovecot passwd-file + per-home Maildir + Roundcube
DB; paradiso: Dovecot+MariaDB `mailserver` + `/var/mail/vhosts` + Roundcube DB).

```sh
sudo /root/wp-hosting-stack/migrate-mail.sh <domain> \
     [--source root@81.17.98.31] [--skip-roundcube] [--dry-run]
```
Per mailbox:
- **account** — `virtual_users` row, original SHA512-CRYPT **password preserved** (`{CRYPT}$6$…`).
- **Maildir** — rsyncs every message → `/var/mail/vhosts/<domain>/<user>/`.
- **aliases** — postfix `virtual` → `virtual_aliases`.
- **roundcube** (best-effort, non-fatal) — identities + contacts + preferences, `user_id` remapped.

Login test after run: `https://mail.paradiso34.com` as `<user>@<domain>` (original password).
Inbound mail after cutover needs the domain **MX → mail.paradiso34.com** (+ SPF/DKIM).

Verify first: `migrate-mail.sh <domain> --dry-run`.

---

## Safety notes

- Sources (sister tenants, old VPS, backups) are touched **read-only**.
- No Cloudflare/DNS changes are made by any script — cutover is always manual.
- `create-site.sh` is idempotent; import/migrate refuse to clobber an existing
  tenant without `--force`.
- Every clone/migration forces `blog_public=1` (see MITP-0069/0072 — clones
  inherited the source's "Discourage search engines" flag).
