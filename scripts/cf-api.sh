# Sourced by the setup and DNS scripts; parameters substituted by Nix.
#
# Secrets come from the unit's systemd credentials ($CREDENTIALS_DIRECTORY),
# never from argv or the environment: the auth headers go into a curl config
# file in the unit's private /tmp.

CURL="@curl@"
API="@apiUrl@"
CREDS="${CREDENTIALS_DIRECTORY:?expected systemd credentials (LoadCredential)}"

ACCOUNT_ID=$(cat "$CREDS/account-id")

AUTH_CONFIG=$(mktemp)
chmod 600 "$AUTH_CONFIG"
trap 'rm -f "$AUTH_CONFIG"' EXIT
if [ -e "$CREDS/api-token" ]; then
  printf 'header = "Authorization: Bearer %s"\n' "$(cat "$CREDS/api-token")" > "$AUTH_CONFIG"
else
  {
    printf 'header = "X-Auth-Email: %s"\n' "$(cat "$CREDS/email")"
    printf 'header = "X-Auth-Key: %s"\n' "$(cat "$CREDS/api-key")"
  } > "$AUTH_CONFIG"
fi

# cf METHOD PATH [curl args...] — fails on HTTP errors, printing the body.
cf() {
  local method=$1 path=$2
  shift 2
  "$CURL" -sS --fail-with-body --config "$AUTH_CONFIG" -X "$method" "$API$path" "$@"
}

# Wait until the API answers at all (any HTTP status will do).
wait_for_api() {
  until "$CURL" -sS -o /dev/null --max-time 10 "$API/"; do
    echo "Waiting for $API..."
    sleep 5
  done
}
