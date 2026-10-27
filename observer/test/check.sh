#!/usr/bin/env bash
# Validates the observer config with each component's own checker (needs docker).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
img() { grep -ohE "image: \S*$1\S*" "$here/stack.yml" "$here/hub-stack.yml" | head -1 | cut -d' ' -f2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cp -r "$here/config/." "$here/hub/." "$tmp/"
grep -rl '__[A-Z_]*__' "$tmp" | xargs sed -i \
    -e 's|__CLIENT__|test|g' -e 's|__STACK__|test|g' -e 's|__DB__|test|g' -e 's|__HUB__|hub.example.com|g' \
    -e 's|__URL__|https://hub.example.com|g' -e 's|__AM_SCHEME__|http|g' -e 's|__AM_HOST__|alertmanager:9093|g' \
    -e 's|__TELEGRAM_CHAT__|-1001234567890|g' -e 's|__HEARTBEAT_RECEIVER__|heartbeat|g'
mkdir -p "$tmp/prometheus/fleet"
echo "- {targets: ['erp.example.com:443'], labels: {client: example}}" > "$tmp/prometheus/fleet/federate.yml"
cp "$tmp/prometheus/fleet/federate.yml" "$tmp/prometheus/fleet/probe.yml"
echo secret > "$tmp/fleet_password"

docker run --rm --entrypoint promtool -v "$tmp/prometheus:/etc/prometheus:ro" \
    -v "$tmp/fleet_password:/etc/observer/fleet_password:ro" "$(img prometheus)" check config --lint-fatal /etc/prometheus/prometheus.yml
docker run --rm --entrypoint promtool -v "$here:/src:ro" -w /src/test "$(img prometheus)" test rules rules.test.yml
docker run --rm --entrypoint amtool -v "$tmp/alertmanager:/etc/alertmanager:ro" "$(img alertmanager)" \
    check-config /etc/alertmanager/alertmanager.yml
docker run --rm -e FLEET_PASSWORD=x -v "$tmp/loki:/etc/loki:ro" "$(img loki)" \
    -config.file=/etc/loki/loki.yml -config.expand-env=true -verify-config
docker run --rm -v "$tmp/alloy:/etc/alloy:ro" "$(img alloy)" fmt /etc/alloy/config.alloy > /dev/null
for f in "$tmp"/grafana/dashboards/*.json; do
    python3 -m json.tool "$f" > /dev/null || { echo "bad json: $f"; exit 1; }
done
echo "observer config OK"
