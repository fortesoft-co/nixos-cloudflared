# nixos-cloudflared

A NixOS module that wraps the upstream [`services.cloudflared`](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/networking/cloudflared.nix) module from nixpkgs with:

- **Automated tunnel setup** — creates or fetches an existing Cloudflare tunnel at boot using the Cloudflare API
- **Age secrets** — Cloudflare account ID, API key, and email are stored in age-encrypted files, decrypted at runtime, never in the Nix store
- **DNS management** — automatically creates and updates CNAME records for all ingress domains
- **Per-tunnel configuration** — supports multiple tunnels with independent credentials and ingress rules

## Usage

Add to your flake inputs:

```nix
inputs.nixos-cloudflared.url = "github:fortesoft-co/nixos-cloudflared";
```

Import the module:

```nix
{
  inputs,
  ...
}:
{
  imports = [ inputs.nixos-cloudflared.nixosModules.default ];
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

The module automatically generates the tunnel config, creates the start script, fetches tunnel credentials via the API, and updates DNS CNAME records for all ingress domains.

## Options

### `cfg.cloudflared.enable`
Enable the Cloudflare tunnel module. Requires the [agenix](https://github.com/ryantm/agenix) module to be imported.

### `cfg.cloudflared.tunnelName`
Name of the Cloudflare tunnel. Used as the systemd service name suffix and the tunnel identifier in the Cloudflare API.

### `cfg.cloudflared.homeDir`
Home directory for the cloudflared user. Stores tunnel credentials and the generated tunnel start script. Defaults to `/var/lib/cloudflared`.

### `cfg.cloudflared.user`
System user for the cloudflared service. Defaults to `"cloudflared"`.

### `cfg.cloudflared.accountIdAgePath`
Age-encrypted file containing the Cloudflare account ID.

### `cfg.cloudflared.apiAgePath`
Age-encrypted file containing the Cloudflare API key.

### `cfg.cloudflared.emailAgePath`
Age-encrypted file containing the Cloudflare account email.

## How it works

The module creates three systemd services per tunnel:

1. **`cloudflared-tunnel-setup-<name>`** — runs at boot, creates the home directory, fetches or creates the tunnel via the Cloudflare API, and generates the tunnel start script
2. **`cloudflared-update-dns-<name>`** — runs after setup, creates or updates CNAME records for all ingress domains pointing to the tunnel's `cfargotunnel.com` address
3. **`cloudflared-tunnel-<name>`** — runs the tunnel itself, starts after setup completes

The upstream `services.cloudflared` module from nixpkgs is enabled with the tunnel credentials file pointing to the API-fetched credentials.

## Used by

- [nixos-litellm](https://github.com/fortesoft-co/nixos-litellm) — uses this module for the `domain` (cloudflared ingress) feature