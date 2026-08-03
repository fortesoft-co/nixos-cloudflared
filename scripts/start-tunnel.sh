#!@bash@
set -euo pipefail

# Parameters substituted by Nix
CLOUDFLARED_PACKAGE="@cloudflared_package@"

# $CREDENTIALS_DIRECTORY is set by systemd when LoadCredential is used.
TOKEN_FILE="${CREDENTIALS_DIRECTORY:-/run/credentials}/tunnel-token"

exec "$CLOUDFLARED_PACKAGE/bin/cloudflared" tunnel \
  --config="@config_file@" \
  --no-autoupdate \
  run \
  --token-file "$TOKEN_FILE"
