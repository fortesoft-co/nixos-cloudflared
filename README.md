# nixos-cloudflared

A NixOS module that wraps the upstream [`services.cloudflared`](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/networking/cloudflared.nix) module from nixpkgs with:

- **Automated tunnel setup** — creates or fetches an existing Cloudflare tunnel at boot using the Cloudflare API
- **Age secrets** — Cloudflare account ID, API key, and email are stored in age-encrypted files, decrypted at runtime, never in the Nix store
- **DNS management** — automatically creates and updates CNAME records for all ingress domains
- **No dedicated user** — the upstream module uses `DynamicUser` with `LoadCredential`; this module only adds setup and DNS services that run as root with systemd hardening

## Usage

This module requires the [agenix](https://github.com/ryantm/agenix) module for secret management (Cloudflare account ID, API key, and email are stored as age-encrypted files).

Add both flakes to your inputs:

```nix
inputs.agenix.url = "github:ryantm/agenix";
inputs.nixos-cloudflared.url = "github:fortesoft-co/nixos-cloudflared";
```

Import both modules:

```nix
{
  inputs,
  ...
}:
{
  imports = [
    inputs.agenix.nixosModules.default
    inputs.nixos-cloudflared.nixosModules.default
  ];
}
```

Configure:

```nix
cfg.cloudflared = {
  enable = true;
  tunnelName = "my-tunnel";
  homeDir = "/var/lib/cloudflared";

  accountIdAgePath = ./secrets/cf_account_id.age;
  apiAgePath = ./secrets/cf_account_api.age;
  emailAgePath = ./secrets/cf_account_email.age;
};
```

Other modules can add ingress entries via the upstream `services.cloudflared` options:

```nix
services.cloudflared.tunnels."my-tunnel".ingress."app.example.com" =
  "http://localhost:8080";
```

The module automatically fetches tunnel credentials via the API, writes them to the credentials file, and updates DNS CNAME records for all ingress domains. The upstream nixpkgs module handles the tunnel service itself using `DynamicUser` and `LoadCredential`.

## Options

### `cfg.cloudflared.enable`
Enable the Cloudflare tunnel module. Requires the [agenix](https://github.com/ryantm/agenix) module to be imported.

### `cfg.cloudflared.tunnelName`
Name of the Cloudflare tunnel. Used as the systemd service name suffix and the tunnel identifier in the Cloudflare API.

### `cfg.cloudflared.homeDir`
Directory for storing tunnel credentials. Created and owned by root. The credentials JSON file is written here by the setup service and loaded by the upstream cloudflared service via systemd `LoadCredential`. Defaults to `/var/lib/cloudflared`.

### `cfg.cloudflared.accountIdAgePath`
Age-encrypted file containing the Cloudflare account ID.

### `cfg.cloudflared.apiAgePath`
Age-encrypted file containing the Cloudflare API key.

### `cfg.cloudflared.emailAgePath`
Age-encrypted file containing the Cloudflare account email.

## How it works

The module creates two systemd services per tunnel:

1. **`cloudflared-tunnel-setup-<name>`** — runs at boot as root, creates the home directory, fetches or creates the tunnel via the Cloudflare API, and writes the credentials JSON file with restrictive permissions (`umask 077`)
2. **`cloudflared-update-dns-<name>`** — runs after the tunnel service starts, creates or updates CNAME records for all ingress domains pointing to the tunnel's `cfargotunnel.com` address

The upstream `services.cloudflared` module from nixpkgs handles the tunnel service itself using `DynamicUser = true` and `LoadCredential`. This module just adds a dependency so the tunnel service waits for the setup service to complete.

## Security

- **API keys are not visible in process arguments** — curl auth headers are passed via `--config` with a temporary file (mode 600), not via `-H` command-line flags
- **Credentials file has no race condition** — written with `umask 077` so it's never world-readable, even briefly
- **Tunnel name injection prevented** — `jq --arg` is used for all variable interpolation in jq filters and JSON payloads
- **Setup and DNS services are hardened** — `PrivateTmp`, `ProtectHome`, `ProtectSystem`, `NoNewPrivileges`, and other systemd hardening options
- **No dedicated service user** — the upstream module's `DynamicUser` creates an ephemeral user for the tunnel service; setup and DNS services run as root with sandboxing

## Used by

- [nixos-litellm](https://github.com/fortesoft-co/nixos-litellm) — uses this module for the `domain` (cloudflared ingress) feature