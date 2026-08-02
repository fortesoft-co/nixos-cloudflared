# nixos-cloudflared

A NixOS module for Cloudflare tunnel setup with automated API-based tunnel management, DNS record management, and age-encrypted credentials.

## Features

- **Automated tunnel setup** — creates or fetches an existing Cloudflare tunnel at boot using the Cloudflare API
- **Age secrets** — Cloudflare account ID, API key, and email are stored as age-encrypted files, decrypted at runtime, never in the Nix store
- **DNS management** — automatically creates and updates CNAME records for all ingress domains
- **Token-based authentication** — authenticates via `--token` with the JWT from the Cloudflare API, loaded through systemd `LoadCredential`
- **Systemd hardening** — setup and DNS services run with `ProtectSystem`, `NoNewPrivileges`, and other sandboxing options

## Usage

This module requires the [agenix](https://github.com/ryantm/agenix) module for secret management.

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

Other modules can add ingress entries via the `services.cloudflared` options:

```nix
services.cloudflared.tunnels."my-tunnel".ingress."app.example.com" =
  "http://localhost:8080";
```

## Options

### `cfg.cloudflared.enable`
Enable the Cloudflare tunnel module. Requires the [agenix](https://github.com/ryantm/agenix) module to be imported.

### `cfg.cloudflared.tunnelName`
Name of the Cloudflare tunnel. Used as the systemd service name suffix and the tunnel identifier in the Cloudflare API.

### `cfg.cloudflared.homeDir`
Directory for storing tunnel credentials and token. Created and owned by root. Defaults to `/var/lib/cloudflared`.

### `cfg.cloudflared.accountIdAgePath`
Age-encrypted file containing the Cloudflare account ID.

### `cfg.cloudflared.apiAgePath`
Age-encrypted file containing the Cloudflare API key.

### `cfg.cloudflared.emailAgePath`
Age-encrypted file containing the Cloudflare account email.

## How it works

The module creates two systemd services per tunnel:

1. **`cloudflared-tunnel-setup-<name>`** — runs at boot, creates the home directory, fetches or creates the tunnel via the Cloudflare API, and writes the token and credentials files with `umask 077`
2. **`cloudflared-update-dns-<name>`** — runs after the tunnel service starts, creates or updates CNAME records for all ingress domains

The tunnel service authenticates via `--token` with the JWT loaded through `LoadCredential`. The token file is read by systemd as root before the dynamic user starts, so the tunnel process never has direct file access.

## Used by

- [nixos-litellm](https://github.com/fortesoft-co/nixos-litellm) — uses this module for the `domain` (cloudflared ingress) feature