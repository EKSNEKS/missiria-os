#!/bin/bash
# orders-dedupe — find + delete duplicate / stale rows in pro_app_shark.orders
#
# Default: dry-run (shows what would be deleted, makes no changes).
# Use --apply to actually delete.
#
# Rules (cumulative when --rule=all):
#   sentinel : wp_id < 0          (re-keyed soft-deleted, our patch's sentinels)
#   softdel  : deleted_at IS NOT NULL  (any soft-deleted row, incl. sentinels)
#   livedup  : duplicate live rows per (client_email, total, day, site_id) — keep best
#   zero     : total=0 AND deleted_at IS NULL AND payment_date IS NULL  (free-test trash)
#
# Survivor for livedup: status rank paid(4) > pending(3) > waiting(2) > cancelled(1)
# then oldest id.

set -o pipefail

DB="pro_app_shark"
USER="missiria"
PASS='+R4toC+vIFW5tE4rhDFh+cXGvjpzaF2+'
LOG="/var/log/missiria-dedupe.log"

APPLY=0
SITE=""
RULE="all"

usage() {
    cat <<'USAGE'
Usage: orders-dedupe [--apply] [--site=CODE] [--rule=sentinel|softdel|livedup|zero|all]

Examples:
  orders-dedupe                                   # dry-run, all rules, all sites
  orders-dedupe --site=ipe                        # dry-run scoped to ipe
  orders-dedupe --rule=sentinel                   # dry-run just sentinels
  orders-dedupe --apply --rule=sentinel           # actually delete sentinels
  orders-dedupe --apply --site=ipe --rule=all     # delete everything for ipe

Log: /var/log/missiria-dedupe.log
USAGE
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --site=*) SITE="${arg#--site=}" ;;
        --rule=*) RULE="${arg#--rule=}" ;;
        -h|--help) usage ;;
        *) echo "Unknown arg: $arg"; usage ;;
    esac
done

case "$RULE" in
    sentinel|softdel|livedup|zero|all) ;;
    *) echo "Bad --rule: $RULE"; usage ;;
esac

# Resolve site_id from code if given
SITE_FILTER=""
if [ -n "$SITE" ]; then
    SID=$(mysql -u"$USER" -p"$PASS" "$DB" -sN -e "SELECT id FROM sites WHERE code='$SITE';" 2>/dev/null)
    if [ -z "$SID" ]; then echo "No site found with code='$SITE'"; exit 2; fi
    SITE_FILTER="AND site_id=$SID"
    echo "Scope: site=$SITE (id=$SID)"
fi

MODE="DRY-RUN"
[ "$APPLY" = "1" ] && MODE="APPLY"
TS="$(date '+%Y-%m-%d %H:%M:%S')"

log() {
    echo "[$TS] $MODE rule=$RULE site=${SITE:-all} :: $*" | tee -a "$LOG"
}

q_count() {
    mysql -u"$USER" -p"$PASS" "$DB" -sN -e "$1" 2>/dev/null
}
q_list() {
    mysql -u"$USER" -p"$PASS" "$DB" -e "$1" 2>/dev/null
}
q_exec() {
    mysql -u"$USER" -p"$PASS" "$DB" -e "$1" 2>/dev/null
}

# --- Build WHERE clauses per rule -------------------------------------------
SENTINEL_W="wp_id < 0 $SITE_FILTER"
SOFTDEL_W="deleted_at IS NOT NULL $SITE_FILTER"
ZERO_W="total = 0 AND deleted_at IS NULL AND payment_date IS NULL $SITE_FILTER"

# Live duplicate: rank within group, keep rnk=1
LIVEDUP_RANK_SQL="
SELECT id FROM (
  SELECT id,
    ROW_NUMBER() OVER (
      PARTITION BY client_email, total, DATE(created_at), site_id
      ORDER BY
        CASE LOWER(status)
          WHEN 'paid' THEN 4
          WHEN 'pending' THEN 3
          WHEN 'waiting' THEN 2
          WHEN 'cancelled' THEN 1
          ELSE 0
        END DESC,
        id ASC
    ) AS rnk
  FROM orders
  WHERE deleted_at IS NULL
    AND client_email != ''
    $SITE_FILTER
) r WHERE r.rnk > 1
"

echo "================================================="
echo " orders-dedupe  [$MODE]  rule=$RULE  site=${SITE:-all}"
echo "================================================="

run_rule_sentinel() {
    local n=$(q_count "SELECT COUNT(*) FROM orders WHERE $SENTINEL_W;")
    echo
    echo "▸ sentinel (wp_id < 0):  $n rows"
    [ "$n" = "0" ] && return
    q_list "SELECT id, site_id, wp_id, status, total, client_email, created_at, deleted_at FROM orders WHERE $SENTINEL_W ORDER BY site_id, id LIMIT 12;"
    [ "$n" -gt 12 ] && echo "  …(showing 12 of $n)"
    if [ "$APPLY" = "1" ]; then
        q_exec "DELETE FROM orders WHERE $SENTINEL_W;"
        log "deleted $n sentinel rows"
        echo "  → DELETED $n rows"
    else
        log "would delete $n sentinel rows"
    fi
}

run_rule_softdel() {
    local n=$(q_count "SELECT COUNT(*) FROM orders WHERE $SOFTDEL_W;")
    echo
    echo "▸ softdel (deleted_at NOT NULL): $n rows"
    [ "$n" = "0" ] && return
    q_list "SELECT id, site_id, wp_id, status, total, client_email, created_at, deleted_at FROM orders WHERE $SOFTDEL_W ORDER BY site_id, id LIMIT 12;"
    [ "$n" -gt 12 ] && echo "  …(showing 12 of $n)"
    if [ "$APPLY" = "1" ]; then
        q_exec "DELETE FROM orders WHERE $SOFTDEL_W;"
        log "deleted $n soft-deleted rows"
        echo "  → DELETED $n rows"
    else
        log "would delete $n soft-deleted rows"
    fi
}

run_rule_livedup() {
    local n=$(q_count "SELECT COUNT(*) FROM ($LIVEDUP_RANK_SQL) x;")
    echo
    echo "▸ livedup (redundant live rows per email+total+day+site): $n rows"
    [ "$n" = "0" ] && return
    q_list "
        SELECT o.id, o.site_id, o.wp_id, o.status, o.total, o.client_email, o.created_at
        FROM orders o
        WHERE o.id IN ($LIVEDUP_RANK_SQL)
        ORDER BY o.site_id, o.client_email, o.id
        LIMIT 15;
    "
    [ "$n" -gt 15 ] && echo "  …(showing 15 of $n)"
    if [ "$APPLY" = "1" ]; then
        q_exec "DELETE FROM orders WHERE id IN ($LIVEDUP_RANK_SQL);"
        log "deleted $n live-duplicate rows"
        echo "  → DELETED $n rows"
    else
        log "would delete $n live-duplicate rows"
    fi
}

run_rule_zero() {
    local n=$(q_count "SELECT COUNT(*) FROM orders WHERE $ZERO_W;")
    echo
    echo "▸ zero (total=0, live, no payment): $n rows"
    [ "$n" = "0" ] && return
    q_list "SELECT id, site_id, wp_id, status, total, client_email, created_at FROM orders WHERE $ZERO_W ORDER BY site_id, id LIMIT 12;"
    [ "$n" -gt 12 ] && echo "  …(showing 12 of $n)"
    if [ "$APPLY" = "1" ]; then
        q_exec "DELETE FROM orders WHERE $ZERO_W;"
        log "deleted $n zero-total rows"
        echo "  → DELETED $n rows"
    else
        log "would delete $n zero-total rows"
    fi
}

# --- Dispatch ---------------------------------------------------------------
case "$RULE" in
    sentinel) run_rule_sentinel ;;
    softdel)  run_rule_softdel ;;
    livedup)  run_rule_livedup ;;
    zero)     run_rule_zero ;;
    all)
        # Order matters: livedup first (operates on live rows), then zero,
        # then softdel (catches sentinels + any other soft-deleted rows).
        run_rule_livedup
        run_rule_zero
        run_rule_softdel
        ;;
esac

echo
echo "================================================="
if [ "$APPLY" = "1" ]; then
    echo "✅ APPLIED. See $LOG for audit trail."
else
    echo "ℹ️  Dry-run only. Re-run with --apply to delete."
fi
echo "================================================="
