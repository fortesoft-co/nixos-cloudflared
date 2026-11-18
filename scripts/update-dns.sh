#!@bash@
set -euo pipefail

# Parameters substituted by Nix
JQ="@jq@"
STATE_DIR="@stateDir@"
TUNNEL_NAME="@tunnelName@"
INGRESS_HOSTNAMES="@ingressHostnames@"
source "@cfApi@"

# The zone holding a hostname: the longest suffix of it that is a zone in
# this account (so sub.example.co.uk finds example.co.uk, and a delegated
# sub-zone wins over its parent).
zone_id_for() {
  local name=$1 id
  while [[ "$name" == *.* ]]; do
    id=$(cf GET "/zones?name=$name" | "$JQ" -r '.result[0].id // empty')
    if [ -n "$id" ]; then
      echo "$id"
      return 0
    fi
    name=${name#*.}
  done
  return 1
}

echo "Updating DNS records for: $INGRESS_HOSTNAMES"
wait_for_api

TUNNEL_ID=$("$JQ" -r '.TunnelID' "$STATE_DIR/.$TUNNEL_NAME.json")
TARGET="$TUNNEL_ID.cfargotunnel.com"

failed=0
for hostname in $INGRESS_HOSTNAMES; do
  if ! zone_id=$(zone_id_for "$hostname"); then
    echo "ERROR: no zone in this account holds $hostname" >&2
    failed=1
    continue
  fi
  payload=$("$JQ" -n --arg name "$hostname" --arg content "$TARGET" \
    '{type: "CNAME", name: $name, content: $content, ttl: 1, proxied: true}')
  record_id=$(cf GET "/zones/$zone_id/dns_records?type=CNAME&name=$hostname" | "$JQ" -r '.result[0].id // empty')
  if [ -n "$record_id" ]; then
    cf PUT "/zones/$zone_id/dns_records/$record_id" -H "Content-Type: application/json" --data "$payload" > /dev/null
    echo "$hostname: CNAME updated"
  else
    cf POST "/zones/$zone_id/dns_records" -H "Content-Type: application/json" --data "$payload" > /dev/null
    echo "$hostname: CNAME created"
  fi
done

exit $failed
