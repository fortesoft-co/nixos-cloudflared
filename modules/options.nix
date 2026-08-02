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
        Home directory for the cloudflared user.  Stores tunnel credentials
        and the generated tunnel start script.
      '';
    };

    tunnelName = mkOption {
      type = types.str;
      description = ''
        Name of the Cloudflare tunnel.  Used as the systemd service name suffix
        and the tunnel identifier in the Cloudflare API.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "cloudflared";
      description = "System user for the cloudflared service.";
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