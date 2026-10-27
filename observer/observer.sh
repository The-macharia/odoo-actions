#!/usr/bin/env bash
# Deploys (or removes) swarm stack "observer" next to the Odoo stack $STACK. All input comes from
# the environment set in action.yml. The server whose DOMAIN is the HUB also runs Alertmanager,
# federates every server in FLEET_FILE and serves Grafana at the hub domain's root.
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OBS=$PROJECT_DIR/observer
NGINX_SVC=${STACK}_nginx
hub=false
[ "$DOMAIN" = "$HUB" ] && hub=true

die() { echo "::error::$*"; exit 1; }
running() { docker ps -q -f "label=com.docker.swarm.service.name=$1" | head -1; }
mount_src() {
    docker service inspect "$1" \
        --format "{{range .Spec.TaskTemplate.ContainerSpec.Mounts}}{{if eq .Target \"$2\"}}{{.Source}}{{end}}{{end}}"
}
nginx_reload() {
    local ctr
    ctr=$(running "$NGINX_SVC")
    [ -n "$ctr" ] || { echo "::warning::$NGINX_SVC is not running; it reads the files on its next start"; return 0; }
    docker exec "$ctr" nginx -t && docker exec "$ctr" nginx -s reload
}

conf=$(mount_src "$NGINX_SVC" /etc/nginx/conf.d)
[ -n "$conf" ] || die "$NGINX_SVC mounts nothing at /etc/nginx/conf.d"

if [ "$ACTION" = down ]; then
    docker stack rm observer
    rm -rf "$conf/monitor" "$conf/monitor-hub.conf"
    nginx_reload
    exit 0
fi

[ -n "$MONITOR_PASSWORD" ] || die "secret MONITOR_PASSWORD is not set"
[ -n "$FLEET_PASSWORD" ] || die "secret MONITOR_FLEET_PASSWORD is not set"
if $hub; then
    [ -n "$TELEGRAM_BOT_TOKEN" ] || die "secret MONITOR_TELEGRAM_BOT_TOKEN is not set"
    [[ $TELEGRAM_CHAT_ID =~ ^-?[0-9]+$ ]] || die "variable MONITOR_TELEGRAM_CHAT_ID must be the numeric chat id"
    [ -n "$HEARTBEAT_URL" ] \
        || echo "::warning::secret MONITOR_HEARTBEAT_URL is not set, so nothing reports the hub itself going down"
    [ -f "$FLEET_FILE" ] || die "$FLEET_FILE is missing from the repo"
fi
db_ctr=$(running "${STACK}_db")
[ -n "$db_ctr" ] || die "no running ${STACK}_db container"

# --- config ---------------------------------------------------------------------------------
mkdir -p "$OBS/etc" "$OBS/secrets"
chmod 700 "$OBS/secrets"
cp -r "$SRC/config/." "$OBS/etc/"
cp "$SRC/stack.yml" "$SRC/hub-stack.yml" "$OBS/"

if $hub; then
    url=https://$HUB am_scheme=http am_host=alertmanager:9093 sub_path=false home=fleet
    cp -r "$SRC/hub/." "$OBS/etc/"
    mkdir -p "$OBS/etc/prometheus/fleet"
    federate=$OBS/etc/prometheus/fleet/federate.yml
    probe=$OBS/etc/prometheus/fleet/probe.yml
    sources=$OBS/etc/grafana/provisioning/datasources/fleet.yml
    : > "$federate"
    : > "$probe"
    printf 'apiVersion: 1\n\ndatasources:\n' > "$sources"
    # "<client> <domain> [probe]": probe-only lines are checked from outside but not federated
    while read -r client domain kind _; do
        [[ -z $client || $client == \#* ]] && continue
        echo "- {targets: ['$domain'], labels: {client: '$client'}}" >> "$probe"
        [ "$kind" = probe ] && continue
        echo "- {targets: ['$domain:443'], labels: {client: '$client'}}" >> "$federate"
        cat >> "$sources" <<EOF
  - {name: '$client', uid: 'fleet-$client-prom', type: prometheus, url: 'https://$domain/monitor/prometheus',
     basicAuth: true, basicAuthUser: fleet, jsonData: {timeInterval: 30s},
     secureJsonData: {basicAuthPassword: \$FLEET_PASSWORD}}
  - {name: '$client logs', uid: 'fleet-$client-loki', type: loki, url: 'https://$domain/monitor/loki',
     basicAuth: true, basicAuthUser: fleet, jsonData: {maxLines: 5000},
     secureJsonData: {basicAuthPassword: \$FLEET_PASSWORD}}
EOF
    done < "$FLEET_FILE"
else
    url=https://$DOMAIN/monitor am_scheme=https am_host=$HUB:443 sub_path=true home=server
fi

{ grep -rl '__[A-Z_]*__' "$OBS/etc" || true; } | xargs -r sed -i \
    -e "s|__CLIENT__|$CLIENT|g" -e "s|__STACK__|$STACK|g" -e "s|__DB__|$DB|g" -e "s|__HUB__|$HUB|g" \
    -e "s|__URL__|$url|g" -e "s|__AM_SCHEME__|$am_scheme|g" -e "s|__AM_HOST__|$am_host|g" \
    -e "s|__TELEGRAM_CHAT__|${TELEGRAM_CHAT_ID:-0}|g" \
    -e "s|__HEARTBEAT_RECEIVER__|$([ -n "$HEARTBEAT_URL" ] && echo heartbeat || echo discard)|g"

# --- secrets: files, because Prometheus and Alertmanager only read secrets from files ---------
[ -s "$OBS/secrets/db_password" ] \
    || python3 -c 'import secrets; print(secrets.token_hex(16), end="")' > "$OBS/secrets/db_password"
DB_PASSWORD=$(cat "$OBS/secrets/db_password")
printf %s "$FLEET_PASSWORD" > "$OBS/secrets/fleet_password"
if $hub; then
    printf %s "$TELEGRAM_BOT_TOKEN" > "$OBS/secrets/telegram_token"
    printf %s "$HEARTBEAT_URL" > "$OBS/secrets/heartbeat_url"
fi
# containers run as other uids; the 700 directory keeps other host users out
chmod 644 "$OBS/secrets/"*

# --- database: read-only monitoring role that may use the reserved connection slots ----------
docker exec -i -e PW="$DB_PASSWORD" -e DB="$DB" "$db_ctr" \
    sh -c 'exec psql -X -q -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d postgres -v pw="$PW" -v db="$DB"' <<'SQL'
SELECT 'CREATE ROLE observer' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'observer') \gexec
ALTER ROLE observer WITH LOGIN PASSWORD :'pw' CONNECTION LIMIT 6;
-- monitoring must never queue behind the locks it is there to report
ALTER ROLE observer SET lock_timeout = '2s';
ALTER ROLE observer SET statement_timeout = '20s';
GRANT pg_monitor, pg_use_reserved_connections TO observer;
\connect :"db"
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
settings=$(docker exec -i "$db_ctr" sh -c 'exec psql -XAtq -U "${POSTGRES_USER:-postgres}" -d postgres' <<'SQL'
SELECT current_setting('shared_preload_libraries') || ' ' || current_setting('reserved_connections');
SQL
)
[[ $settings == *pg_stat_statements* ]] \
    || echo "::warning::pg_stat_statements is not preloaded; deploy the app with the observer db flags"
[[ $settings != *" 0" ]] \
    || echo "::warning::reserved_connections is 0; monitoring cannot connect while Postgres is full"

# --- hub certificate (renewed afterwards by the ssl-renew action) ----------------------------
if $hub; then
    le=$(mount_src "$NGINX_SVC" /etc/letsencrypt)
    [ -n "$le" ] || die "$NGINX_SVC mounts no /etc/letsencrypt"
    # live/ is root-only, so look from inside a container
    if ! docker run --rm --entrypoint test -v "$le:/etc/letsencrypt:ro" certbot/certbot \
        -e "/etc/letsencrypt/live/$HUB/fullchain.pem"; then
        docker run --rm -v "$le:/etc/letsencrypt" -v "${le%/etc/letsencrypt}/var/lib/letsencrypt:/var/lib/letsencrypt" \
            -p 80:80 certbot/certbot certonly --standalone -n --agree-tos --register-unsafely-without-email -d "$HUB"
    fi
fi

# --- stack ------------------------------------------------------------------------------------
files=(-c stack.yml)
$hub && files+=(-c hub-stack.yml)
cd "$OBS"
export STACK DB HUB NETWORK BACKUP_DIR MONITOR_PASSWORD FLEET_PASSWORD DB_PASSWORD
export MONITOR_URL=$url GF_SUB_PATH=$sub_path HOME_DASHBOARD=$home
timeout 10m docker stack deploy "${files[@]}" --prune --detach=false observer
# config lives in bind mounts, so a config-only change leaves every service spec as it was
for svc in $(docker stack services observer --format '{{.Name}}'); do
    docker service update --force --detach=true -q "$svc" >/dev/null
done

# --- nginx ------------------------------------------------------------------------------------
mkdir -p "$conf/monitor"
python3 -c 'import base64, hashlib, os
salt = os.urandom(8)
digest = hashlib.sha1(os.environ["FLEET_PASSWORD"].encode() + salt).digest()
print("fleet:{SSHA}" + base64.b64encode(digest + salt).decode())' > "$conf/monitor/htpasswd"
if $hub; then
    cp "$OBS/etc/nginx/monitor-hub.conf" "$conf/monitor-hub.conf"
else
    cp "$OBS/etc/nginx/monitor.locations" "$conf/monitor/"
    grep -qs 'conf.d/monitor/\*.locations' "$conf"/*.conf \
        || echo "::warning::no server{} includes /etc/nginx/conf.d/monitor/*.locations, so /monitor is not served"
fi
if ! nginx_reload; then
    rm -rf "$conf/monitor" "$conf/monitor-hub.conf"
    nginx_reload || true
    die "nginx rejected the monitor config, removed it again"
fi

# GF_SECURITY_ADMIN_PASSWORD only applies to a fresh Grafana database
for _ in $(seq 24); do
    ctr=$(running observer_grafana)
    if [ -n "$ctr" ] && printf %s "$MONITOR_PASSWORD" \
        | docker exec -i "$ctr" grafana cli admin reset-admin-password --password-from-stdin >/dev/null 2>&1; then
        synced=1
        break
    fi
    sleep 5
done
[ -n "${synced:-}" ] || echo "::warning::could not set the Grafana admin password; it keeps its previous value"

echo "Grafana: $url/ (user admin)"
