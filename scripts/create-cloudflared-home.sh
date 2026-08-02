set -euo pipefail

# Parameters substituted by Nix
CLOUDFLARED_HOME_DIR="@homeDir@"

echo "Creating cloudflared home directory: $CLOUDFLARED_HOME_DIR"

mkdir -p "$CLOUDFLARED_HOME_DIR"

echo "Cloudflared home directory created successfully"
exit 0