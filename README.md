# Linux Terminal Tools

Operational shell toolkit for day-to-day infrastructure and WordPress maintenance.

This repository provides interactive scripts to manage:
- MySQL databases
- WordPress database maintenance
- Nginx virtual hosts
- Mailbox diagnostics
- WordPress cron + forced updates

All scripts include a consistent CLI header/UI and are intended for Linux server usage.

## Included Scripts

| Script | Purpose | Interactive | Typical Privilege |
|---|---|---|---|
| `db-manager.sh` | Generic DB operations (cleanup, drop, global replace, export, file rename, WP manager launcher) | Yes | `root`/DB admin |
| `wp-manager.sh` | WordPress-focused DB operations (migration, content cleanup, maintenance bundle) | Yes | `root`/DB admin |
| `wp-cron-master.sh` | Trigger `wp-cron.php` and optionally force WP updates via WP-CLI in memory-safe mode | No (argument driven) | `root`/sudo |
| `nx-manager.sh` | Nginx vhost create/update/delete + config test/reload | Yes | `root` |
| `email-manager.sh` | Mail alias + Maildir permission audit for one email account | No (email argument) | `root`/sudo |

## Prerequisites

- Linux host with `bash`
- `mysql` and `mysqldump` available for DB scripts
- Nginx layout using `/etc/nginx/sites-available` and `/etc/nginx/sites-enabled` (for `nx-manager.sh`, `wp-cron-master.sh`)
- `curl` (for cron trigger mode)
- `sudo` (for forced updates mode)
- `wp` (WP-CLI) optional; required only for forced update mode in `wp-cron-master.sh`
- `systemctl` + `nginx -t` support (for Nginx reload path)

## Quick Start

```bash
cd /Users/missiria/Projects/EKSNEKS/TOOLS/linux-terminal-tools
chmod +x *.sh
```

Run scripts:

```bash
./db-manager.sh
./wp-manager.sh
./nx-manager.sh
./email-manager.sh contact@example.com
./wp-cron-master.sh all
```

## Script Usage

### `db-manager.sh`

Main menu:
1. Cleanup tables by prefix or known plugin table set
2. Drop entire database
3. Global search/replace across text columns
4. Launch `wp-manager.sh`
5. Mass file rename in a directory tree
6. Export DB by number
7. Exit

Environment overrides:
- `DB_USER` (default: `root`)
- `MYSQL_BIN` (default: `mysql`)
- `MYSQLDUMP_BIN` (default: `mysqldump`)
- `DEFAULT_BACKUP_DIR` (default: `/tmp`)
- `DEFAULT_EXPORT_PATH` (default: `/home/missiria/dump.sql`)

### `wp-manager.sh`

WordPress DB menu highlights:
1. Full domain migration (`options`, `posts.guid`, `posts.post_content`, non-serialized `postmeta`)
2. Search/replace in `post_content`
3. Remove query parameter in links inside `post_content` (including quote-ending URL patterns)
4. Set `siteurl` + `home`
5. Clear transients
6. Delete revisions
7. Delete trash/auto-draft posts + spam/trash comments
8. Cleanup orphan metadata/relationships
9. Optimize all WP tables for selected prefix
10. Run popular maintenance bundle
11. Exit

Notable behavior:
- Database is selected by number from available MySQL databases.
- For destructive operations, the script can create backups before execution.
- For post-related operations, affected `ID/title` details are shown before changes.

Environment overrides:
- `DB_USER`, `MYSQL_BIN`, `MYSQLDUMP_BIN`, `DEFAULT_BACKUP_DIR`

### `wp-cron-master.sh`

Modes:

```bash
./wp-cron-master.sh all      # default: cron trigger + forced updates (skips updates if WP-CLI missing)
./wp-cron-master.sh cron     # only wp-cron endpoint trigger
./wp-cron-master.sh updates  # only forced WP-CLI updates
./wp-cron-master.sh --help
```

Behavior:
- Extracts active domains from Nginx `server_name` directives and hits `http://<domain>/wp-cron.php?doing_wp_cron`
- Extracts Nginx `root` paths and runs forced updates via:
  - `wp core update`
  - `wp plugin update --all`
  - `wp theme update --all`
  - WP language update commands
- Runs updates as `www-data`
- If `wp` is not installed, update phase is skipped with a warning.
- Uses memory-safe default:
  - `WP_CLI_PHP_ARGS="-d memory_limit=256M"` (override supported)

### `nx-manager.sh`

Menu:
1. Update/link an existing Nginx domain
2. Delete Nginx domain config + symlink
3. Insert/create domain config (WordPress/PHP template)
4. Exit

Guardrails:
- Requires root
- Runs `nginx -t` before reload
- Auto-reloads Nginx on valid config

### `email-manager.sh`

Usage:

```bash
./email-manager.sh user@domain.com
```

Checks:
- `/etc/postfix/virtual` alias entry presence
- Maildir existence and ownership consistency
- Prints remediation commands when issues are found

## Safety Notes

- These scripts can perform destructive actions (`DROP DATABASE`, table drops, bulk deletes/updates).
- Prefer running backups before destructive operations.
- Run first in staging where possible.
- Review selected database/prefix carefully before confirming.

## Troubleshooting

- `mysql: command not found`
  - Install MySQL client tools and/or set `MYSQL_BIN`/`MYSQLDUMP_BIN`.
- Permission errors on Nginx/Postfix/system files
  - Run with root/sudo as required.
- `wp` command not found in cron/update script
  - Install WP-CLI and ensure it is in `PATH`.
- No domains or sites detected in `wp-cron-master.sh`
  - Check Nginx config paths and `server_name`/`root` directives.

## Recommended Operational Flow

1. Use `db-manager.sh` for generic DB work.
2. Use `wp-manager.sh` for WordPress-specific DB tasks.
3. Use `wp-cron-master.sh updates` for controlled update runs on low-RAM hosts.
4. Use `nx-manager.sh` for Nginx vhost lifecycle operations.
