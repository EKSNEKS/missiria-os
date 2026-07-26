#!/usr/bin/env bash
# migrate-mail.sh — migrate a domain's mailboxes from the old VPS onto paradiso.
#
#   sudo ./migrate-mail.sh <domain> [--source root@81.17.98.31] [--skip-roundcube] [--dry-run]
#
# Old VPS  : Dovecot passwd-file (/etc/dovecot/users, SHA512-CRYPT) + per-home
#            Maildir + Roundcube DB + postfix hash aliases (/etc/postfix/virtual).
# Paradiso : Dovecot+MariaDB (mailserver.virtual_users) + /var/mail/vhosts/%d/%n
#            + Roundcube DB.
#
# Per mailbox:
#   1. account   — virtual_users row, ORIGINAL password preserved ({CRYPT}$6$…)   [robust]
#   2. Maildir   — rsync every message  <home>/Maildir/ → /var/mail/vhosts/…       [robust]
#   3. aliases   — postfix/virtual → virtual_aliases                               [robust]
#   4. roundcube — identities + contacts (+ preferences), user_id remapped     [best-effort]
#
# Old VPS is read-only. Prereq: this host's SSH key authorised on <source>.
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
require_root

MAILDB="mailserver"; RCDB="roundcube"; VHOSTS="/var/mail/vhosts"

usage() { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
DOMAIN="${1:-}"; [[ -n "$DOMAIN" && "$DOMAIN" != -* ]] || usage; shift
SOURCE="root@81.17.98.31"; SKIP_RC=0; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE="${2:?}"; shift 2 ;;
    --skip-roundcube) SKIP_RC=1; shift ;;
    --dry-run) DRY=1; shift ;;
    *) err "unknown option: $1"; usage ;;
  esac
done
DOMAIN="${DOMAIN,,}"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new $SOURCE"
Q()   { mariadb "$MAILDB" -N -e "$1"; }
esc() { printf '%s' "$1" | sed "s/'/''/g"; }

# Best-effort per-user Roundcube table copy with user_id remap (drops the PK so
# it re-autoincrements). Column list read from the LOCAL schema; the row-to-INSERT
# generator runs on the source and its output is piped into the local DB.
migrate_rc_table() {
  local tbl="$1" old="$2" new="$3" pk collist valexpr gen
  pk="$(mariadb "$RCDB" -N -e "SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$RCDB' AND TABLE_NAME='$tbl' AND EXTRA LIKE '%auto_increment%' LIMIT 1")"
  collist="$(mariadb "$RCDB" -N -e "SET SESSION group_concat_max_len=100000; SELECT GROUP_CONCAT(CONCAT('\`',COLUMN_NAME,'\`') ORDER BY ORDINAL_POSITION SEPARATOR ',') FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$RCDB' AND TABLE_NAME='$tbl' AND COLUMN_NAME<>'$pk'")"
  valexpr="$(mariadb "$RCDB" -N -e "SET SESSION group_concat_max_len=100000; SELECT GROUP_CONCAT(CASE WHEN COLUMN_NAME='user_id' THEN '$new' ELSE CONCAT('COALESCE(QUOTE(\`',COLUMN_NAME,'\`),''NULL'')') END ORDER BY ORDINAL_POSITION SEPARATOR ',') FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='$RCDB' AND TABLE_NAME='$tbl' AND COLUMN_NAME<>'$pk'")"
  [[ -n "$collist" && -n "$valexpr" ]] || return 1
  gen="SET SESSION group_concat_max_len=1000000; SELECT CONCAT('INSERT INTO \`$tbl\` ($collist) VALUES (', CONCAT_WS(',', $valexpr), ');') FROM \`$tbl\` WHERE user_id=$old"
  $SSH "mysql $RCDB -N -e $(printf '%q' "$gen")" | mariadb "$RCDB"
}

section "Migrate mail: $DOMAIN  (source: $SOURCE)"
$SSH true 2>/dev/null || die "cannot SSH $SOURCE — authorise this host's key there first"

USERS="$($SSH "grep -iE '^[^:]*@$(esc "$DOMAIN"):' /etc/dovecot/users || true")"
[[ -n "$USERS" ]] || die "no mailboxes for @$DOMAIN in $SOURCE:/etc/dovecot/users"
log "$(printf '%s\n' "$USERS" | grep -c '@') mailbox(es) for @$DOMAIN"

if [[ $DRY -eq 1 ]]; then
  section "DRY RUN"
  printf '%s\n' "$USERS" | while IFS=: read -r email _h _u _g _ge home _; do
    log "  $email   maildir=$home/Maildir$([[ $SKIP_RC -eq 0 ]] && echo '   +roundcube')"
  done
  log "aliases: $($SSH "grep -ic '@$(esc "$DOMAIN")' /etc/postfix/virtual 2>/dev/null || echo 0")"
  exit 0
fi

Q "INSERT INTO virtual_domains(name) VALUES('$(esc "$DOMAIN")') ON DUPLICATE KEY UPDATE name=name;"

printf '%s\n' "$USERS" | while IFS=: read -r email hash _u _g _ge home _; do
  [[ -n "$email" && -n "$hash" ]] || continue
  local_part="${email%@*}"
  section "· $email"

  # 1. account (preserve hash)
  Q "INSERT INTO virtual_users(domain_id,email,password)
       SELECT id,'$(esc "$email")','$(esc "{CRYPT}$hash")' FROM virtual_domains WHERE name='$(esc "$DOMAIN")'
       ON DUPLICATE KEY UPDATE password=VALUES(password);"
  ok "account (password preserved)"

  # 2. Maildir
  dest="$VHOSTS/$DOMAIN/$local_part"
  install -d -o vmail -g vmail -m 0700 "$dest"
  if $SSH "test -d '$home/Maildir'"; then
    rsync -a -e "ssh -o BatchMode=yes" "$SOURCE:$home/Maildir/" "$dest/" 2>/dev/null || warn "rsync warnings"
    chown -R vmail:vmail "$dest"
    ok "Maildir synced ($(find "$dest" -type f 2>/dev/null | wc -l) files)"
  else
    warn "no Maildir at $home/Maildir — empty mailbox"
  fi

  # 3. roundcube identities + contacts + preferences (best-effort, non-fatal)
  if [[ $SKIP_RC -eq 0 ]]; then
    OLD_UID="$($SSH "mysql $RCDB -N -e \"SELECT user_id FROM users WHERE username='$(esc "$email")' LIMIT 1\"" 2>/dev/null || true)"
    if [[ -n "${OLD_UID:-}" ]]; then
      mariadb "$RCDB" -e "INSERT INTO users(username,mail_host,created) VALUES('$(esc "$email")','localhost',NOW()) ON DUPLICATE KEY UPDATE username=VALUES(username);"
      NEW_UID="$(mariadb "$RCDB" -N -e "SELECT user_id FROM users WHERE username='$(esc "$email")' LIMIT 1")"
      # reset prior migrated rows for idempotency
      mariadb "$RCDB" -e "DELETE FROM identities WHERE user_id=$NEW_UID; DELETE FROM contacts WHERE user_id=$NEW_UID;" 2>/dev/null || true
      if migrate_rc_table identities "$OLD_UID" "$NEW_UID" 2>/dev/null && migrate_rc_table contacts "$OLD_UID" "$NEW_UID" 2>/dev/null; then
        # preferences/language
        PREFS="$($SSH "mysql $RCDB -N -e \"SELECT CONCAT('UPDATE users SET preferences=',COALESCE(QUOTE(preferences),'NULL'),', language=',COALESCE(QUOTE(language),'NULL'),' WHERE user_id=$NEW_UID;') FROM users WHERE user_id=$OLD_UID\"" 2>/dev/null || true)"
        [[ -n "$PREFS" ]] && printf '%s' "$PREFS" | mariadb "$RCDB" 2>/dev/null || true
        ok "roundcube data migrated (uid $OLD_UID→$NEW_UID)"
      else
        warn "roundcube data copy skipped for $email (schema mismatch?) — mail + login unaffected"
      fi
    else
      log "no roundcube profile for $email"
    fi
  fi
done

# aliases
section "Aliases"
ALIASES="$($SSH "grep -iE '@$(esc "$DOMAIN")' /etc/postfix/virtual 2>/dev/null || true")"
if [[ -n "$ALIASES" ]]; then
  printf '%s\n' "$ALIASES" | while read -r src dst _; do
    [[ "$src" == *@* && -n "$dst" ]] || continue
    Q "INSERT INTO virtual_aliases(domain_id,source,destination)
         SELECT id,'$(esc "$src")','$(esc "$dst")' FROM virtual_domains WHERE name='$(esc "$DOMAIN")'
         ON DUPLICATE KEY UPDATE destination=VALUES(destination);" 2>/dev/null || true
  done
  ok "aliases migrated"
else
  log "no aliases for @$DOMAIN"
fi

systemctl reload dovecot 2>/dev/null || true
section "Done — mail for $DOMAIN migrated"
log "Login test: https://mail.paradiso34.com  as <user>@$DOMAIN (original password)."
log "For inbound delivery after cutover: point the domain MX → mail.paradiso34.com (+ SPF/DKIM)."
