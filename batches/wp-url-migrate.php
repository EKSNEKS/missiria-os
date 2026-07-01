<?php
/**
 * wp-url-migrate.php — Serialized-safe URL replacer for WordPress databases.
 *
 * Walks every text column of every table in the target DB. For each value
 * that contains the old URL:
 *   - if the value is PHP-serialized, unserialize → deep-replace → re-serialize
 *     (preserves s:N:"…" length markers)
 *   - otherwise, plain str_replace.
 *
 * Usage:
 *   php wp-url-migrate.php --db=<dbname> --prefix=<wp_> --old=<URL> --new=<URL> \
 *       [--user=<u>] [--pass=<p>] [--host=<h>] [--dry-run] [--all-tables]
 *
 * Defaults: --host=localhost --user=root --pass="" --prefix derives from --table-scan.
 * --all-tables: scan every table in the DB (not just tables matching prefix).
 *
 * Exit codes:
 *   0 success · 1 bad args · 2 connect fail · 3 DB error
 */

$opts = getopt('', [
    'db:', 'prefix::', 'old:', 'new:',
    'user::', 'pass::', 'host::',
    'dry-run', 'all-tables', 'verbose',
]);

foreach (['db', 'old', 'new'] as $req) {
    if (empty($opts[$req])) {
        fwrite(STDERR, "Missing --$req\n");
        fwrite(STDERR, "Usage: php wp-url-migrate.php --db=<db> --old=<URL> --new=<URL> [--prefix=wp_] [--user=root] [--pass=] [--host=localhost] [--dry-run] [--all-tables] [--verbose]\n");
        exit(1);
    }
}

$db      = $opts['db'];
$prefix  = $opts['prefix']  ?? '';
$old     = $opts['old'];
$new     = $opts['new'];
$user    = $opts['user']    ?? 'root';
$pass    = $opts['pass']    ?? '';
$host    = $opts['host']    ?? 'localhost';
$dry     = isset($opts['dry-run']);
$all     = isset($opts['all-tables']);
$verbose = isset($opts['verbose']);

if ($old === $new) {
    fwrite(STDERR, "old == new; nothing to do\n");
    exit(0);
}

$mysqli = @new mysqli($host, $user, $pass, $db);
if ($mysqli->connect_errno) {
    fwrite(STDERR, "Connect failed: {$mysqli->connect_error}\n");
    exit(2);
}
$mysqli->set_charset('utf8mb4');

/** Recursively replace $old → $new inside arrays/objects/strings. */
function deep_replace($value, string $old, string $new) {
    if (is_string($value)) {
        return str_replace($old, $new, $value);
    }
    if (is_array($value)) {
        foreach ($value as $k => $v) {
            $value[$k] = deep_replace($v, $old, $new);
        }
        return $value;
    }
    if (is_object($value)) {
        // __PHP_Incomplete_Class — unserialized without class def. Cannot mutate
        // safely; signal up so the row gets skipped.
        if ($value instanceof __PHP_Incomplete_Class) {
            throw new RuntimeException('incomplete-class');
        }
        foreach (get_object_vars($value) as $k => $v) {
            $value->$k = deep_replace($v, $old, $new);
        }
        return $value;
    }
    return $value;
}

/**
 * Process one cell value.
 * Returns the replacement string, or null if no change is needed.
 */
function process_value(?string $raw, string $old, string $new): ?string {
    if ($raw === null || $raw === '' || strpos($raw, $old) === false) {
        return null;
    }
    // Try unserialize — suppress warnings for non-serialized strings.
    $err = null;
    set_error_handler(function ($n, $m) use (&$err) { $err = $m; return true; });
    $tmp = @unserialize($raw, ['allowed_classes' => false]);
    restore_error_handler();

    $is_serialized = ($tmp !== false) || $raw === 'b:0;';
    if ($is_serialized) {
        try {
            $rebuilt = deep_replace($tmp, $old, $new);
        } catch (RuntimeException $e) {
            // Serialized object whose class isn't loaded — skip to avoid corruption.
            return null;
        }
        return serialize($rebuilt);
    }
    return str_replace($old, $new, $raw);
}

$db_esc = $mysqli->real_escape_string($db);
$tables = [];

if ($all || $prefix === '') {
    $res = $mysqli->query("SHOW TABLES FROM `{$db}`");
} else {
    $like = $mysqli->real_escape_string($prefix) . '%';
    $res = $mysqli->query("SHOW TABLES FROM `{$db}` LIKE '{$like}'");
}
if (!$res) { fwrite(STDERR, "SHOW TABLES failed: {$mysqli->error}\n"); exit(3); }
while ($r = $res->fetch_array()) $tables[] = $r[0];

$grand_rows = 0;
$grand_cells = 0;
$updated_tables = [];

foreach ($tables as $table) {
    // Find primary key.
    $pkres = $mysqli->query("SHOW KEYS FROM `{$table}` WHERE Key_name='PRIMARY'");
    if (!$pkres || $pkres->num_rows === 0) {
        if ($verbose) fprintf(STDERR, "skip $table (no primary key)\n");
        continue;
    }
    $pk_cols = [];
    while ($k = $pkres->fetch_assoc()) $pk_cols[] = $k['Column_name'];

    // Find text-ish columns.
    $cres = $mysqli->query("
        SELECT COLUMN_NAME FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA='{$db_esc}' AND TABLE_NAME='" . $mysqli->real_escape_string($table) . "'
          AND DATA_TYPE IN ('char','varchar','tinytext','text','mediumtext','longtext')
    ");
    $cols = [];
    while ($c = $cres->fetch_assoc()) $cols[] = $c['COLUMN_NAME'];
    if (!$cols) continue;

    $pk_list  = implode(',', array_map(fn($c) => "`{$c}`", $pk_cols));
    $col_list = implode(',', array_map(fn($c) => "`{$c}`", $cols));

    // Stream rows that *might* contain the old URL using a single OR-LIKE query.
    $likes = [];
    $old_like = '%' . $mysqli->real_escape_string($old) . '%';
    foreach ($cols as $c) $likes[] = "`{$c}` LIKE '{$old_like}'";
    $where = implode(' OR ', $likes);

    // Buffer rows (STORE_RESULT) so we can issue UPDATEs inside the loop.
    $rres = $mysqli->query("SELECT {$pk_list}, {$col_list} FROM `{$table}` WHERE {$where}");
    if (!$rres) {
        if ($verbose) fprintf(STDERR, "skip $table (query error: {$mysqli->error})\n");
        continue;
    }

    $table_rows = 0;
    $table_cells = 0;
    while ($row = $rres->fetch_assoc()) {
        $sets = [];
        $cells_changed = 0;
        foreach ($cols as $col) {
            $new_val = process_value($row[$col] ?? null, $old, $new);
            if ($new_val !== null && $new_val !== ($row[$col] ?? '')) {
                $sets[] = "`{$col}`='" . $mysqli->real_escape_string($new_val) . "'";
                $cells_changed++;
            }
        }
        if (!$sets) continue;

        $whereParts = [];
        foreach ($pk_cols as $pkc) {
            $whereParts[] = "`{$pkc}`='" . $mysqli->real_escape_string($row[$pkc]) . "'";
        }
        $sql = "UPDATE `{$table}` SET " . implode(',', $sets) . " WHERE " . implode(' AND ', $whereParts) . " LIMIT 1";

        if ($dry) {
            if ($verbose) echo "DRY  $table: row [" . implode(',', array_map(fn($c) => $row[$c], $pk_cols)) . "] — {$cells_changed} cell(s)\n";
        } else {
            if (!$mysqli->query($sql)) {
                fprintf(STDERR, "UPDATE failed on $table: {$mysqli->error}\n");
                continue;
            }
        }
        $table_rows++;
        $table_cells += $cells_changed;
    }
    $rres->close();

    if ($table_rows > 0) {
        $updated_tables[$table] = ['rows' => $table_rows, 'cells' => $table_cells];
        $grand_rows  += $table_rows;
        $grand_cells += $table_cells;
    }
}

echo ($dry ? "[DRY-RUN] " : "") . "URL migration: {$old}  →  {$new}\n";
foreach ($updated_tables as $t => $s) {
    printf("  %-40s %5d row(s) / %d cell(s)\n", $t, $s['rows'], $s['cells']);
}
echo "Total: {$grand_rows} row(s) / {$grand_cells} cell(s)" . ($dry ? "  [no writes performed]" : "") . "\n";
$mysqli->close();
exit(0);
