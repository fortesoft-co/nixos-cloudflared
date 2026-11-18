#!@bash@
set -euo pipefail

# Parameters substituted by Nix
JQ="@jq@"
STATE_DIR="@stateDir@"
TUNNEL_NAME="@tunnelName@"
source "@cfApi@"

echo "Setting up tunnel: $TUNNEL_NAME"
wait_for_api

TUNNEL_ID=$(cf GET "/accounts/$ACCOUNT_ID/cfd_tunnel?is_deleted=false" \
  | "$JQ" -r --arg name "$TUNNEL_NAME" \
    'first(.result[] | select(.name == $name and .deleted_at == null) | .id) // empty')

if [ -z "$TUNNEL_ID" ]; then
  echo "Creating tunnel: $TUNNEL_NAME"
  TUNNEL_ID=$(cf POST "/accounts/$ACCOUNT_ID/cfd_tunnel" \
    -H "Content-Type: application/json" \
    --data "$("$JQ" -n --arg name "$TUNNEL_NAME" '{name: $name, config_src: "local"}')" \
    | "$JQ" -r '.result.id // empty')
  if [ -z "$TUNNEL_ID" ]; then
    echo "ERROR: could not create tunnel $TUNNEL_NAME" >&2
    exit 1
  fi
  echo "Created tunnel $TUNNEL_ID"
else
  echo "Found tunnel $TUNNEL_ID"
fi

ACCOUNT_TAG=$(cf GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID" | "$JQ" -r '.result.account_tag // empty')
TUNNEL_TOKEN=$(cf GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token" | "$JQ" -r '.result // empty')
if [ -z "$ACCOUNT_TAG" ] || [ -z "$TUNNEL_TOKEN" ]; then
  echo "ERROR: could not fetch the token of tunnel $TUNNEL_ID" >&2
  exit 1
fi

# Root-only files: the token for the daemon (handed over as a systemd
# credential), and the tunnel's credentials file, which also records its ID.
(
  umask 077
  mkdir -p "$STATE_DIR"
  "$JQ" -n --arg tag "$ACCOUNT_TAG" --arg secret "$TUNNEL_TOKEN" --arg id "$TUNNEL_ID" \
    '{AccountTag: $tag, TunnelSecret: $secret, TunnelID: $id}' \
    > "$STATE_DIR/.$TUNNEL_NAME.json"
  printf '%s' "$TUNNEL_TOKEN" > "$STATE_DIR/.$TUNNEL_NAME.token"
)

echo "Tunnel $TUNNEL_NAME ready"
