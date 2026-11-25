#!/usr/bin/env bash
# Sandbox tests for autopilot.sh Nginx/SSL bootstrap (YITP-0268).
#
# Runs the real exec_nginx / exec_certbot / resume_ssl code against a
# throw-away nginx prefix and Let's Encrypt tree. Uses the real `nginx -t`
# (with -c <sandbox>/nginx.conf) and a stub certbot. It never reloads the
# live nginx and never touches /etc/nginx or /etc/letsencrypt.
#
#   bash batches/tests/autopilot-ssl-bootstrap.test.sh
#
# Run as root (autopilot.sh refuses otherwise).

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOPILOT="$HERE/../autopilot.sh"
SB="$(mktemp -d /tmp/autopilot-ssl-test.XXXXXX)"
SRC="source-site.test"
DST="autopilot-new-site.test"
PASS=0; FAILED=0
LIVE_USER_LINE="$(grep -m1 -E '^[[:space:]]*user[[:space:]]' /etc/nginx/nginx.conf 2>/dev/null || true)"
[[ -n "$LIVE_USER_LINE" ]] || LIVE_USER_LINE="user www-data;"
live_tmp_owners() { stat -c '%U %n' /var/lib/nginx/* 2>/dev/null || true; }
LIVE_TMP_OWNERS_BEFORE="$(live_tmp_owners)"

cleanup() {
    rm -rf "$SB"
    rm -f /var/log/nginx/"$DST"*.log /var/log/nginx/"$SRC"*.log
}
trap cleanup EXIT

t_ok()   { PASS=$((PASS+1));     printf '  \033[0;32mPASS\033[0m  %s\n' "$1"; }
t_fail() { FAILED=$((FAILED+1)); printf '  \033[0;31mFAIL\033[0m  %s\n' "$1"; }
check()  { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then t_ok "$desc"; else t_fail "$desc"; fi; }
check_not() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then t_fail "$desc"; else t_ok "$desc"; fi; }

export NGINX_DIR="$SB/nginx" NGINX_CONF="$SB/nginx/nginx.conf" LE_DIR="$SB/letsencrypt"
export CERTBOT_BIN="$SB/bin/certbot" AUTOPILOT_SKIP_DNS_CHECK=1
export STUB_LOG="$SB/certbot.calls" RELOAD_LOG="$SB/reload.calls"

make_cert() {  # make_cert <lineage-name> <san-domain>
    local name="$1" d="$2"
    mkdir -p "$LE_DIR/archive/$name" "$LE_DIR/live/$name" "$LE_DIR/renewal"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 90 \
        -subj "/CN=$d" -addext "subjectAltName=DNS:$d,DNS:www.$d" \
        -keyout "$LE_DIR/archive/$name/privkey1.pem" -out "$LE_DIR/archive/$name/fullchain1.pem" 2>/dev/null
    ln -sfn "../../archive/$name/privkey1.pem"   "$LE_DIR/live/$name/privkey.pem"
    ln -sfn "../../archive/$name/fullchain1.pem" "$LE_DIR/live/$name/fullchain.pem"
    echo "# stub" > "$LE_DIR/renewal/$name.conf"
}

reset_sandbox() {
    rm -rf "$SB/nginx" "$SB/letsencrypt" "$SB/bin" "$SB/www" "$STUB_LOG" "$RELOAD_LOG" "$SB/after-marker"
    mkdir -p "$NGINX_DIR/sites-available" "$NGINX_DIR/sites-enabled" "$NGINX_DIR/snippets" \
             "$LE_DIR/live" "$LE_DIR/renewal" "$LE_DIR/archive" "$SB/bin" "$SB/www/src" "$SB/www/dst"
    cp /etc/nginx/fastcgi_params /etc/nginx/fastcgi.conf /etc/nginx/mime.types "$NGINX_DIR/" 2>/dev/null
    cp /etc/nginx/snippets/fastcgi-php.conf "$NGINX_DIR/snippets/"
    : > "$NGINX_DIR/snippets/404-redirects-$SRC.conf"
    # IMPORTANT: `nginx -t` run as root creates AND chowns every temp path to
    # the configured user. Without the two guards below it re-owns the live
    # /var/lib/nginx/{body,fastcgi,proxy,...} to "nobody" and production
    # workers start failing with "Permission denied" on buffered responses.
    #   1. same `user` as the live server
    #   2. all temp paths inside the sandbox
    mkdir -p "$SB/tmp"
    cat > "$NGINX_CONF" <<EOF
$LIVE_USER_LINE
pid $SB/nginx.pid;
error_log $SB/nginx-error.log;
events {}
http {
    access_log off;
    client_body_temp_path $SB/tmp/body;
    fastcgi_temp_path     $SB/tmp/fastcgi;
    proxy_temp_path       $SB/tmp/proxy;
    scgi_temp_path        $SB/tmp/scgi;
    uwsgi_temp_path       $SB/tmp/uwsgi;
    include $NGINX_DIR/sites-enabled/*;
}
EOF
    # Source site: Varnish-fronted HTTPS vhost with a valid certificate,
    # Certbot-managed redirect blocks and a source-named include.
    make_cert "$SRC" "$SRC"
    cat > "$NGINX_DIR/sites-available/$SRC" <<EOF
server {
    listen 8080;
    server_name $SRC www.$SRC;
    root $SB/www/src;
    index index.php;
    access_log /var/log/nginx/$SRC-backend.access.log;
    location / { try_files \$uri \$uri/ /index.php?\$args; }
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
    }
    include $NGINX_DIR/snippets/404-redirects-$SRC.conf;
}
server {
    if (\$host = www.$SRC) {
        return 301 https://\$host\$request_uri;
    } # managed by Certbot
    if (\$host = $SRC) {
        return 301 https://\$host\$request_uri;
    } # managed by Certbot
    listen 80;
    listen [::]:80;
    server_name $SRC www.$SRC;
    return 301 https://\$host\$request_uri;
}
server {
    listen [::]:443 ssl;
    listen 443 ssl;
    server_name $SRC www.$SRC;
    ssl_certificate $LE_DIR/live/$SRC/fullchain.pem; # managed by Certbot
    ssl_certificate_key $LE_DIR/live/$SRC/privkey.pem; # managed by Certbot
    access_log /var/log/nginx/$SRC.access.log;
    location / {
        proxy_pass http://127.0.0.1:6081;
        proxy_set_header Host \$host;
    }
}
EOF
    ln -s "$NGINX_DIR/sites-available/$SRC" "$NGINX_DIR/sites-enabled/$SRC"

    # Stub certbot: STUB_MODE=ok issues a self-signed lineage, =fail exits 1.
    cat > "$CERTBOT_BIN" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
name=""; prev=""
for a in "$@"; do [[ "$prev" == "--cert-name" ]] && name="$a"; prev="$a"; done
if [[ "${STUB_MODE:-ok}" == "fail" ]]; then
    echo "stub certbot: Challenge failed for domain $name" >&2
    exit 1
fi
mkdir -p "$LE_DIR/archive/$name" "$LE_DIR/live/$name" "$LE_DIR/renewal"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 90 \
    -subj "/CN=$name" -addext "subjectAltName=DNS:$name,DNS:www.$name" \
    -keyout "$LE_DIR/archive/$name/privkey1.pem" -out "$LE_DIR/archive/$name/fullchain1.pem" 2>/dev/null
ln -sfn "../../archive/$name/privkey1.pem"   "$LE_DIR/live/$name/privkey.pem"
ln -sfn "../../archive/$name/fullchain1.pem" "$LE_DIR/live/$name/fullchain.pem"
echo "# stub" > "$LE_DIR/renewal/$name.conf"
echo "stub certbot: issued $name"
EOF
    chmod +x "$CERTBOT_BIN"
}

# run_flow <mode> [stub-mode] — runs steps 2+3 exactly like main() does,
# then drops a marker standing in for "later steps" (DB / email / Varnish).
run_flow() {
    local mode="$1" stub="${2:-ok}"
    (
        export STUB_MODE="$stub"
        # shellcheck disable=SC1090
        source "$AUTOPILOT"
        nginx_reload() { echo reload >> "$RELOAD_LOG"; }
        MODE="$mode"; DOMAIN="$DST"; WEB_ROOT="$SB/www/dst"
        SRC_DOMAIN="$SRC"; SRC_WEB_ROOT="$SB/www/src"; EMAIL_PREFIX="contact"
        exec_nginx
        exec_certbot
        echo ran > "$SB/after-marker"
    ) > "$SB/last.out" 2>&1
}

run_resume() {
    local stub="${1:-ok}"
    (
        export STUB_MODE="$stub"
        # shellcheck disable=SC1090
        source "$AUTOPILOT"
        nginx_reload() { echo reload >> "$RELOAD_LOG"; }
        main --resume-ssl "$DST"
    ) > "$SB/last.out" 2>&1
}

sb_nginx_ok() { nginx -t -c "$NGINX_CONF"; }
AV() { echo "$NGINX_DIR/sites-available/$DST"; }
EN() { echo "$NGINX_DIR/sites-enabled/$DST"; }
show_on_fail() { (( FAILED > ${1:-0} )) && sed 's/\x1b\[[0-9;]*m//g; s/^/      | /' "$SB/last.out"; return 0; }

echo ""; echo "── A. copy mode, fresh domain, no certificate ──"
reset_sandbox; f0=$FAILED
run_flow copy ok; rc=$?
check     "exit 0"                                              test "$rc" -eq 0
check     "HTTP bootstrap was announced explicitly"             grep -q "HTTP BOOTSTRAP" "$SB/last.out"
check     "certbot called once, certonly --nginx, pinned name"  grep -qE "^certonly --nginx --cert-name $DST " "$STUB_LOG"
check     "final vhost uses the new domain's own certificate"   grep -q "ssl_certificate $LE_DIR/live/$DST/fullchain.pem" "$(AV)"
check_not "no source certificate path in the new vhost"         grep -q "live/$SRC/" "$(AV)"
check     "source-named include disabled, not inherited"        grep -q "# \[autopilot\] source-site include not inherited: include .*404-redirects-$SRC.conf" "$(AV)"
check_not "no active reference to the source domain"            bash -c "grep -v 'autopilot\] source-site include' '$(AV)' | grep -q '$SRC'"
check_not "no source web root in the new vhost"                 grep -q "$SB/www/src" "$(AV)"
check     "new web root set"                                    grep -q "root $SB/www/dst;" "$(AV)"
check     "symlink enabled, points at sites-available"          test "$(readlink "$(EN)")" = "$(AV)"
check_not "parked .ssl-pending removed after activation"        test -e "$(AV).ssl-pending"
check     "whole sandbox config valid"                          sb_nginx_ok
check     "reloads happened only after passing tests (2)"       test "$(wc -l < "$RELOAD_LOG")" -eq 2
check     "later steps ran"                                     test -f "$SB/after-marker"
check     "source vhost untouched"                              grep -q "server_name $SRC www.$SRC;" "$NGINX_DIR/sites-available/$SRC"
show_on_fail "$f0"

echo ""; echo "── B. re-run with an existing valid certificate ──"
rm -f "$STUB_LOG" "$SB/after-marker"; f0=$FAILED
sum_before="$(sha256sum "$LE_DIR/archive/$DST/fullchain1.pem")"
run_flow copy ok; rc=$?
check     "exit 0"                                              test "$rc" -eq 0
check_not "certbot NOT called (no needless replacement)"        test -s "$STUB_LOG"
check     "certificate file unchanged"                          test "$sum_before" = "$(sha256sum "$LE_DIR/archive/$DST/fullchain1.pem")"
check_not "no bootstrap detour"                                 grep -q "HTTP BOOTSTRAP" "$SB/last.out"
check     "exactly one enabled entry for the domain"            test "$(ls "$NGINX_DIR/sites-enabled" | grep -c "^$DST")" -eq 1
check     "previous vhost backed up"                            bash -c "ls '$(AV)'.autopilot-bak.* "
check     "whole sandbox config valid"                          sb_nginx_ok
show_on_fail "$f0"

echo ""; echo "── C. issuance failure, then --resume-ssl ──"
reset_sandbox; f0=$FAILED
run_flow copy fail; rc=$?
check     "exit 21 (certificate stage)"                         test "$rc" -eq 21
check     "failed stage named"                                  grep -q "STAGE FAILED: CERTBOT (issuance)" "$SB/last.out"
check_not "later steps did NOT run"                             test -f "$SB/after-marker"
check     "shared config still valid"                           sb_nginx_ok
check     "domain left on HTTP bootstrap (no ssl directives)"   bash -c "! grep -q ssl_certificate '$(AV)'"
check     "bootstrap still enabled"                             test -L "$(EN)"
check     "HTTPS config kept parked for the retry"              test -f "$(AV).ssl-pending"
check_not "no lineage created by the failed attempt"            test -e "$LE_DIR/live/$DST"
show_on_fail "$f0"; f0=$FAILED
run_resume ok; rc=$?
check     "resume: exit 0"                                      test "$rc" -eq 0
check     "resume: HTTPS vhost active with own certificate"     grep -q "ssl_certificate $LE_DIR/live/$DST/fullchain.pem" "$(AV)"
check_not "resume: parked file consumed"                        test -e "$(AV).ssl-pending"
check     "resume: config valid"                                sb_nginx_ok
show_on_fail "$f0"

echo ""; echo "── D1. config-test failure, no previous vhost ──"
reset_sandbox; f0=$FAILED
make_cert "$DST" "$DST"
sed -i "0,/listen 8080;/s//listen 8080;\n    bogus_directive on;/" "$NGINX_DIR/sites-available/$SRC"
rm -f "$NGINX_DIR/sites-enabled/$SRC"          # keep the baseline valid; source file stays broken
run_flow copy ok; rc=$?
check     "exit 20 (nginx stage)"                               test "$rc" -eq 20
check     "failed stage named"                                  grep -q "STAGE FAILED: NGINX (config test)" "$SB/last.out"
check     "real nginx error shown"                              grep -q "bogus_directive" "$SB/last.out"
check_not "later steps did NOT run"                             test -f "$SB/after-marker"
check_not "rejected vhost removed again"                        test -e "$(AV)"
check_not "no symlink left behind"                              test -L "$(EN)"
check     "shared config valid"                                 sb_nginx_ok
check_not "nginx never reloaded"                                test -s "$RELOAD_LOG"
show_on_fail "$f0"

echo ""; echo "── D2. config-test failure, working vhost already present ──"
reset_sandbox; f0=$FAILED
make_cert "$DST" "$DST"
printf 'server {\n    listen 80;\n    server_name %s www.%s;\n    return 204;\n}\n' "$DST" "$DST" > "$(AV)"
ln -s "$(AV)" "$(EN)"
before="$(sha256sum < "$(AV)")"
sed -i "0,/listen 8080;/s//listen 8080;\n    bogus_directive on;/" "$NGINX_DIR/sites-available/$SRC"
rm -f "$NGINX_DIR/sites-enabled/$SRC"
run_flow copy ok; rc=$?
check     "exit 20"                                             test "$rc" -eq 20
check     "pre-existing vhost restored byte-for-byte"           test "$before" = "$(sha256sum < "$(AV)")"
check     "pre-existing symlink still in place"                 test "$(readlink "$(EN)")" = "$(AV)"
check     "shared config valid"                                 sb_nginx_ok
check_not "later steps did NOT run"                             test -f "$SB/after-marker"
show_on_fail "$f0"

echo ""; echo "── E. shared config already invalid before the run ──"
reset_sandbox; f0=$FAILED
echo "broken_before_run;" > "$NGINX_DIR/sites-enabled/zz-broken"
run_flow copy ok; rc=$?
check     "exit 20"                                             test "$rc" -eq 20
check     "baseline failure reported as pre-existing"           grep -q "STAGE FAILED: NGINX (baseline test)" "$SB/last.out"
check_not "nothing written for the new domain"                  bash -c "ls '$NGINX_DIR'/sites-available/ '$NGINX_DIR'/sites-enabled/ | grep -q '$DST'"
check_not "certbot not called"                                  test -s "$STUB_LOG"
show_on_fail "$f0"

echo ""; echo "── F. new mode, fresh domain ──"
reset_sandbox; f0=$FAILED
run_flow new ok; rc=$?
check     "exit 0"                                              test "$rc" -eq 0
check     "HTTPS vhost written with own certificate"            grep -q "ssl_certificate     $LE_DIR/live/$DST/fullchain.pem" "$(AV)"
check     "HTTP → HTTPS redirect present"                       grep -q 'return 301 https://$host$request_uri;' "$(AV)"
check     "listener form matches the fleet (ssl http2)"         grep -q "listen 443 ssl http2;" "$(AV)"
check     "config valid"                                        sb_nginx_ok
show_on_fail "$f0"

echo ""; echo "── G. legacy broken state (vhost → missing cert, symlink removed) ──"
reset_sandbox; f0=$FAILED
sed -e "s/$SRC/$DST/g" -e "/404-redirects/d" "$NGINX_DIR/sites-available/$SRC" > "$(AV)"   # what the old script left behind
check     "precondition: vhost references a missing certificate" bash -c "! test -e '$LE_DIR/live/$DST/fullchain.pem'"
run_resume ok; rc=$?
check     "resume: exit 0"                                      test "$rc" -eq 0
check     "resume: symlink recreated"                           test "$(readlink "$(EN)")" = "$(AV)"
check     "resume: HTTPS vhost active"                          grep -q "ssl_certificate $LE_DIR/live/$DST/fullchain.pem" "$(AV)"
check     "resume: config valid"                                sb_nginx_ok
show_on_fail "$f0"

echo ""; echo "── H. certificate under another lineage name ──"
reset_sandbox; f0=$FAILED
make_cert "$DST-0001" "$DST"
run_flow copy ok; rc=$?
check     "exit 21"                                             test "$rc" -eq 21
check     "foreign lineage reported"                            grep -q "foreign:.*$DST-0001" "$SB/last.out"
check_not "nothing written"                                     test -e "$(AV)"
check_not "certbot not called"                                  test -s "$STUB_LOG"
show_on_fail "$f0"

echo ""; echo "── I. dangling certificate links ──"
reset_sandbox; f0=$FAILED
mkdir -p "$LE_DIR/live/$DST"; ln -s ../../archive/gone/fullchain1.pem "$LE_DIR/live/$DST/fullchain.pem"
run_flow copy ok; rc=$?
check     "exit 21"                                             test "$rc" -eq 21
check     "broken link reported"                                grep -q "broken:.*dangling" "$SB/last.out"
check_not "certbot not called"                                  test -s "$STUB_LOG"
show_on_fail "$f0"

echo ""; echo "── J. DNS preflight (domain that does not resolve) ──"
reset_sandbox; f0=$FAILED
( export AUTOPILOT_SKIP_DNS_CHECK=0; run_flow copy ok ); rc=$?
check     "exit 21"                                             test "$rc" -eq 21
check     "DNS stage named"                                     grep -q "STAGE FAILED: CERTBOT (DNS preflight)" "$SB/last.out"
check_not "certbot not called (no wasted ACME attempt)"         test -s "$STUB_LOG"
check     "config valid, bootstrap in place"                    sb_nginx_ok
show_on_fail "$f0"

echo ""; echo "── Z. the test run left the live server alone ──"
check     "live nginx temp dirs keep their owner"               test "$LIVE_TMP_OWNERS_BEFORE" = "$(live_tmp_owners)"
check_not "nothing created in live sites-available/-enabled"    bash -c "ls /etc/nginx/sites-available /etc/nginx/sites-enabled | grep -q '$DST'"

echo ""
echo "════════════════════════════════════════"
echo "  passed: $PASS   failed: $FAILED"
echo "════════════════════════════════════════"
(( FAILED == 0 ))
