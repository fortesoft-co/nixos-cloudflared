#!@bash@
set -euo pipefail

# Parameters substituted by Nix
CF_ACCOUNT_API="@apiPath@"
CF_ACCOUNT_EMAIL="@emailPath@"
CF_ACCOUNT_ID="@accountIdPath@"
CLOUDFLARED_HOME_DIR="@homeDir@"
CURL="@curl@"
JQ="@jq@"
PING="@ping@"
TUNNEL_NAME="@tunnelName@"

# Read secrets from files at runtime
ACCOUNT_ID_CONTENT=$(cat "$CF_ACCOUNT_ID")
ACCOUNT_EMAIL_CONTENT=$(cat "$CF_ACCOUNT_EMAIL")
ACCOUNT_API_CONTENT=$(cat "$CF_ACCOUNT_API")

# Create a temporary curl config file with auth headers
# to avoid exposing secrets in process arguments.
AUTH_CONFIG=$(mktemp)
chmod 600 "$AUTH_CONFIG"
trap 'rm -f "$AUTH_CONFIG"' EXIT
{
  printf 'header = "X-Auth-Email: %s"\n' "$ACCOUNT_EMAIL_CONTENT"
  printf 'header = "X-Auth-Key: %s"\n' "$ACCOUNT_API_CONTENT"
} > "$AUTH_CONFIG"

echo "Setting up tunnel: $TUNNEL_NAME"

# Wait for network connectivity
until $PING -c1 api.cloudflare.com; do
  echo "Waiting for network connectivity..."
  sleep 5
done

# Fetch existing tunnel
echo "Fetching tunnel id for $TUNNEL_NAME"

TUNNEL_ID=$($CURL -s --config "$AUTH_CONFIG" -X GET \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID_CONTENT/cfd_tunnel" \
  | $JQ -r --arg name "$TUNNEL_NAME" \
    '.result[] | select(.name == $name and .deleted_at == null) | .id')

# Validate TUNNEL_ID or create new tunnel
if [ -z "$TUNNEL_ID" ] || [ "$TUNNEL_ID" = "null" ]; then
  echo "Creating new tunnel: $TUNNEL_NAME"
  TUNNEL_ID=$($CURL -s --config "$AUTH_CONFIG" -X POST \
    "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID_CONTENT/cfd_tunnel" \
    -H "Content-Type: application/json" \
    --data "$($JQ -n --arg name "$TUNNEL_NAME" '{name: $name, config: {}}')" \
    | $JQ -r '.result.id')

  if [ -z "$TUNNEL_ID" ] || [ "$TUNNEL_ID" = "null" ]; then
    echo "ERROR: Failed to fetch tunnel id for $TUNNEL_NAME"
    exit 1
  fi
  echo "Created tunnel with ID: $TUNNEL_ID"
else
  echo "Found existing tunnel: $TUNNEL_ID"
fi

# Fetch account tag
echo "Fetching account tag for $TUNNEL_ID"

ACCOUNT_TAG=$($CURL -s --config "$AUTH_CONFIG" -X GET \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID_CONTENT/cfd_tunnel/$TUNNEL_ID" \
  | $JQ -r '.result.account_tag')

if [ -z "$ACCOUNT_TAG" ] || [ "$ACCOUNT_TAG" = "null" ]; then
  echo "ERROR: Failed to fetch account tag for tunnel $TUNNEL_ID"
  exit 1
fi

# Fetch tunnel secret/token
echo "Fetching tunnel secret for $TUNNEL_ID"

TUNNEL_RESPONSE=$($CURL -s --config "$AUTH_CONFIG" -X GET \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID_CONTENT/cfd_tunnel/$TUNNEL_ID/token")

TUNNEL_SECRET=$(echo "$TUNNEL_RESPONSE" | $JQ -r '.result')

if [ -z "$TUNNEL_SECRET" ] || [ "$TUNNEL_SECRET" = "null" ]; then
  echo "ERROR: Failed to fetch tunnel secret for tunnel $TUNNEL_ID"
  exit 1
fi

# Create home directory if it doesn't exist
mkdir -p "$CLOUDFLARED_HOME_DIR"

# Write credentials and token with umask 077 (mode 600).
(
  umask 077
  $JQ -n \
    --arg tag "$ACCOUNT_TAG" \
    --arg secret "$TUNNEL_SECRET" \
    --arg id "$TUNNEL_ID" \
    '{AccountTag: $tag, TunnelSecret: $secret, TunnelID: $id}' \
    > "$CLOUDFLARED_HOME_DIR/.$TUNNEL_NAME.json"
  # Raw token file loaded by the tunnel service via LoadCredential.
  printf '%s' "$TUNNEL_SECRET" > "$CLOUDFLARED_HOME_DIR/.$TUNNEL_NAME.token"
)

echo "Tunnel configuration successfully created"
exit 0