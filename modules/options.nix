{
  config,
  lib,
  ...
}:
with lib;
let
  # A runtime path: absolute and outside the world-readable Nix store, so a
  # secret can't be copied there by passing a path literal.
  secretPath = types.addCheck types.str (
    s: hasPrefix "/" s && !hasPrefix "${builtins.storeDir}/" s
  ) // {
    name = "secretPath";
    description = "absolute runtime path outside the Nix store";
  };
in
{
  options.services.cloudflared-tunnel = {
    enable = mkEnableOption ''
      a Cloudflare tunnel that is created through the Cloudflare API at boot,
      with a proxied DNS record for every ingress hostname'';

    name = mkOption {
      type = types.str;
      default = config.networking.hostName;
      defaultText = literalExpression "config.networking.hostName";
      description = ''
        Tunnel name in Cloudflare, and the key of the tunnel in
        services.cloudflared.tunnels: other modules add ingress entries under
        services.cloudflared.tunnels.<name>.ingress. An existing tunnel with
        this name is reused; otherwise one is created.
      '';
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/cloudflared";
      description = ''
        Directory, owned by root, where the setup unit keeps the tunnel's
        token (mode 0600). The tunnel daemon gets it as a systemd credential.
      '';
    };

    accountIdFile = mkOption {
      type = secretPath;
      example = "/run/secrets/cloudflare-account-id";
      description = ''
        Runtime path to a file holding the Cloudflare account ID, readable
        by root.
      '';
    };

    apiTokenFile = mkOption {
      type = types.nullOr secretPath;
      default = null;
      example = "/run/secrets/cloudflare-api-token";
      description = ''
        Runtime path to a file holding a Cloudflare API token, readable by
        root. Preferred over the global API key: a token can be limited to
        what this module needs, namely
        Account › Cloudflare Tunnel › Edit, Zone › DNS › Edit and
        Zone › Zone › Read (for the zones your ingress hostnames are in).
        Set this, or apiKeyFile and emailFile.
      '';
    };

    apiKeyFile = mkOption {
      type = types.nullOr secretPath;
      default = null;
      description = ''
        Runtime path to a file holding the account's global API key, readable
        by root; needs emailFile too. The global key can do anything on the
        account, so prefer apiTokenFile.
      '';
    };

    emailFile = mkOption {
      type = types.nullOr secretPath;
      default = null;
      description = "Runtime path to a file holding the account email, for apiKeyFile.";
    };

    dns.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Keep a proxied CNAME record (<hostname> → <tunnel-id>.cfargotunnel.com)
        for every ingress hostname, in whichever of the account's zones holds
        it. Existing CNAME records with those names are updated in place.
      '';
    };

    apiUrl = mkOption {
      type = types.str;
      default = "https://api.cloudflare.com/client/v4";
      description = "Cloudflare API base URL. Only worth changing for tests or an API proxy.";
    };
  };
}
