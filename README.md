# nixos-cloudflared

A NixOS module for Cloudflare tunnels that sets itself up. Give it API
credentials and a list of hostnames. At boot it finds or creates the tunnel,
starts the daemon with the tunnel's token, and points a proxied DNS record at
the tunnel for every hostname. You never open the Cloudflare dashboard, open an
inbound port or forward a router port.

## What it does

Three units per tunnel:

1. **`cloudflared-tunnel-setup-<name>`** finds the tunnel named `<name>` in your
   account through the Cloudflare API, or creates it. It then stores the
   tunnel's token in `stateDir`, readable by root only.
2. **`cloudflared-tunnel-<name>`** is nixpkgs' cloudflared daemon. It runs as a
   throwaway user and receives the token as a systemd credential.
3. **`cloudflared-update-dns-<name>`** keeps a proxied CNAME
   (`<hostname>` → `<tunnel-id>.cfargotunnel.com`) for every ingress hostname.
   For each one it looks up the zone that actually holds it, so
   `app.example.co.uk` and delegated sub-zones land in the right place.
   Existing CNAMEs with those names are updated in place.

Ingress uses nixpkgs' own options, so any module can add a hostname:

```nix
services.cloudflared.tunnels.${config.services.cloudflared-tunnel.name}.ingress = {
  "app.example.com" = "http://127.0.0.1:8080";
  "auth.example.com" = {
    service = "https://127.0.0.1:443";
    originRequest.originServerName = "auth.example.com";
  };
};
```

The tunnel name defaults to the host name. Modules that write to
`services.cloudflared.tunnels.${config.networking.hostName}` work without
knowing about this module.

## Secrets

Credentials are runtime paths to root-only files, from agenix, sops-nix or
anywhere else. The module never asks for a particular secrets tool:

- **Nothing in the Nix store.** The options reject paths inside it.
- **Nothing on a command line or in the environment.** Each API unit gets the
  credentials as systemd credentials (`LoadCredential=`), and the scripts hand
  them to curl through a config file in the unit's private `/tmp`.
- **Only the units that call the API can read them.** The daemon only ever sees
  the tunnel token.

## Usage

```nix
inputs.nixos-cloudflared.url = "github:fortesoft-co/nixos-cloudflared";
```

```nix
{ config, nixos-cloudflared, ... }:
{
  imports = [ nixos-cloudflared.nixosModules.default ];

  services.cloudflared-tunnel = {
    enable = true;
    accountIdFile = "/run/secrets/cloudflare-account-id";
    apiTokenFile = "/run/secrets/cloudflare-api-token";
  };
}
```

### Credentials

- **Account ID:** on your account's overview page in the Cloudflare dashboard.
- **An API token (recommended).** Create one under *My Profile → API Tokens*
  with these permissions:
  - Account › Cloudflare Tunnel › Edit
  - Zone › DNS › Edit
  - Zone › Zone › Read

  Limit the zone permissions to the zones your hostnames are in.
- **Or the global API key** (`apiKeyFile`) together with the account email
  (`emailFile`). It works, but the global key can do anything on the account.

## Options

All options live under `services.cloudflared-tunnel`.

| Option | Default | |
|---|---|---|
| `enable` | `false` | Turn the module on. |
| `name` | `networking.hostName` | Tunnel name in Cloudflare, and its key in `services.cloudflared.tunnels`. An existing tunnel with this name is reused. |
| `stateDir` | `/var/lib/cloudflared` | Root-only directory for the tunnel token. |
| `accountIdFile` | | File holding the account ID. |
| `apiTokenFile` | `null` | File holding a scoped API token. |
| `apiKeyFile`, `emailFile` | `null` | Global API key and account email, instead of a token. |
| `dns.enable` | `true` | Manage the CNAME records. |
| `apiUrl` | Cloudflare's | API base URL, for tests or a proxy. |

## Migrating from `cfg.cloudflared`

The options moved to `services.cloudflared-tunnel`, and the `*AgePath` options
are gone. Declare the secrets yourself and pass their runtime paths:

```nix
age.secrets.cf-account-id.file = ./secrets/cf_account_id.age;
age.secrets.cf-api-key.file = ./secrets/cf_account_api.age;
age.secrets.cf-email.file = ./secrets/cf_account_email.age;

services.cloudflared-tunnel = {
  enable = true;
  name = "my-tunnel";               # was tunnelName; defaults to the host name
  stateDir = "/var/lib/cloudflared"; # was homeDir
  accountIdFile = config.age.secrets.cf-account-id.path;
  apiKeyFile = config.age.secrets.cf-api-key.path;
  emailFile = config.age.secrets.cf-email.path;
};
```

Setting any old `cfg.cloudflared` option fails evaluation with these
instructions.

## Tests

```sh
nix flake check
```

`tunnel` boots a VM against a stub of the Cloudflare API and checks that:

- the tunnel is created once and reused;
- its token is stored root-only;
- every hostname gets a proxied CNAME in its own zone, including a
  multi-label suffix;
- the API token appears only as a request header, never in the process table
  or the journal.

## Used by

- [nixos-swag](https://github.com/fortesoft-co/nixos-swag): the public
  Authentik login through a tunnel.

## License

[AGPL-3.0](LICENSE).
