set -euo pipefail

# Parameters substituted by Nix
CLOUDFLARED_PACKAGE="@cloudflared_package@"
JQ="@jq@"

# $CREDENTIALS_DIRECTORY is set by systemd when LoadCredential is used.
# This allows the script to work with DynamicUser — the credential is
# loaded by systemd (as root) before dropping privileges.
TOKEN_FILE="${CREDENTIALS_DIRECTORY:-/run/credentials}/tunnel-token"

exec "$CLOUDFLARED_PACKAGE/bin/cloudflared" tunnel \
  --config="@config_file@" \
  --no-autoupdate \
  run \
  --token "$(cat "$TOKEN_FILE")"