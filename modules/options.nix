{
  config,
  lib,
  ...
}:
with lib;
{
  options.cfg.cloudflared = {
    enable = mkEnableOption "Cloudflare tunnel with automated setup and DNS management";

    homeDir = mkOption {
      type = types.path;
      default = "/var/lib/cloudflared";
      description = ''
        Directory for storing tunnel credentials.  Created and owned by root.
        The credentials JSON file is written here by the setup service and
        loaded by the upstream cloudflared service via systemd LoadCredential.
      '';
    };

    tunnelName = mkOption {
      type = types.str;
      description = ''
        Name of the Cloudflare tunnel.  Used as the systemd service name suffix
        and the tunnel identifier in the Cloudflare API.
      '';
    };

    accountIdAgePath = mkOption {
      type = types.path;
      description = ''
        Age-encrypted file containing the Cloudflare account ID.
        Required — the module always uses agenix for Cloudflare credentials.
      '';
    };

    apiAgePath = mkOption {
      type = types.path;
      description = ''
        Age-encrypted file containing the Cloudflare API key.
        Required — the module always uses agenix for Cloudflare credentials.
      '';
    };

    emailAgePath = mkOption {
      type = types.path;
      description = ''
        Age-encrypted file containing the Cloudflare account email.
        Required — the module always uses agenix for Cloudflare credentials.
      '';
    };
  };
}