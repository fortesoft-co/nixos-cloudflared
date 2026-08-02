{
  config,
  lib,
  pkgs,
  options,
  ...
}:
with lib;
let
  cfg = config.cfg.cloudflared;

  # Whether the agenix module is imported.
  hasAgenix = builtins.hasAttr "age" options;

  homeDir = cfg.homeDir;
  tunnelName = cfg.tunnelName;

  # Decrypted secret paths (derived from age.secrets declarations).
  accountIdPath = config.age.secrets.cf_account_id.path;
  apiPath = config.age.secrets.cf_account_api.path;
  emailPath = config.age.secrets.cf_account_email.path;

  # Age-encrypted file paths (user-provided).
  accountIdAgePath = cfg.accountIdAgePath;
  apiAgePath = cfg.apiAgePath;
  emailAgePath = cfg.emailAgePath;

  curl = "${pkgs.curl}/bin/curl";
  jq = "${pkgs.jq}/bin/jq";
  gawk = "${pkgs.gawk}/bin/awk";
  bash = "${pkgs.bash}/bin/bash";
  ping = "${pkgs.iputils}/bin/ping";

  createCloudflaredHome = pkgs.replaceVars ../scripts/create-cloudflared-home.sh {
    inherit homeDir;
  };

  fetchOrCreateTunnel = pkgs.replaceVars ../scripts/fetch-or-create-tunnel.sh {
    inherit tunnelName homeDir accountIdPath emailPath apiPath curl jq bash ping;
  };

  cloudflareUpdateDNSScript = pkgs.replaceVars ../scripts/update-dns.sh {
    inherit tunnelName homeDir accountIdPath emailPath apiPath curl jq gawk bash ping;
    ingress_domains = concatStringsSep " " (
      builtins.attrNames config.services.cloudflared.tunnels.${tunnelName}.ingress
    );
  };
in
{
  imports = [ ./options.nix ];

  config = mkIf cfg.enable (mkMerge [
    # ── Assertions ────────────────────────────────────────────────────────────
    {
      assertions = [
        {
          assertion = hasAgenix;
          message = ''
            cfg.cloudflared requires the agenix module to be imported.
            Add agenix to your flake inputs and import agenix.nixosModules.default
            in your system configuration.
          '';
        }
      ];
    }

    # ── Age secrets ──────────────────────────────────────────────────────────
    {
      age.secrets = {
        cf_account_id.file = accountIdAgePath;
        cf_account_email.file = emailAgePath;
        cf_account_api.file = apiAgePath;
      };
    }

    # ── Tunnel setup service ─────────────────────────────────────────────────
    # Runs as root (needed to read age secrets and write credentials).
    # Fetches or creates the tunnel via the Cloudflare API and writes the
    # credentials JSON file that the upstream tunnel service loads via
    # systemd LoadCredential.
    {
      systemd.services."cloudflared-tunnel-setup-${tunnelName}" = {
        description = "Create or update Cloudflare tunnel ${tunnelName}";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        requires = [ "network-online.target" ];
        script = ''
          ${bash} ${createCloudflaredHome}
          ${bash} ${fetchOrCreateTunnel}
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # Hardening
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ homeDir ];
          NoNewPrivileges = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectControlGroups = true;
          RestrictNamespaces = true;
          RestrictRealtime = true;
          SystemCallArchitectures = "native";
        };
      };
    }

    # ── DNS update service ───────────────────────────────────────────────────
    # Runs as root (needed to read age secrets).  Creates or updates CNAME
    # records for all ingress domains.
    {
      systemd.services."cloudflared-update-dns-${tunnelName}" = {
        description = "Update DNS records for cloudflare tunnel ${tunnelName} domains";
        wantedBy = [ "multi-user.target" ];
        after = [
          "network-online.target"
          "cloudflared-tunnel-${tunnelName}.service"
        ];
        requires = [ "network-online.target" ];
        script = ''
          ${bash} ${cloudflareUpdateDNSScript}
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          # Hardening
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          NoNewPrivileges = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectControlGroups = true;
          RestrictNamespaces = true;
          RestrictRealtime = true;
          SystemCallArchitectures = "native";
        };
      };
    }

    # ── Tunnel service dependency ─────────────────────────────────────────────
    # The upstream nixpkgs module creates the tunnel service with DynamicUser
    # and LoadCredential.  We just need to add a dependency on our setup service
    # so the credentials file exists before the tunnel starts.
    {
      systemd.services."cloudflared-tunnel-${tunnelName}" = {
        after = [ "cloudflared-tunnel-setup-${tunnelName}.service" ];
        requires = [ "cloudflared-tunnel-setup-${tunnelName}.service" ];
      };
    }

    # ── Upstream cloudflared service ──────────────────────────────────────────
    # The upstream module handles the tunnel service with DynamicUser=true and
    # LoadCredential.  We just set the credentials file path — the upstream
    # module loads it and makes it available to the dynamic user.
    {
      services.cloudflared = {
        enable = true;
        tunnels.${tunnelName} = {
          credentialsFile = "${homeDir}/.${tunnelName}.json";
          default = "http_status:404";
        };
      };
    }
  ]);
}