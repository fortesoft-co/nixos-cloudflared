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
  user = cfg.user;
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
    inherit homeDir user;
  };

  fetchOrCreateTunnel = pkgs.replaceVars ../scripts/fetch-or-create-tunnel.sh {
    inherit tunnelName homeDir user accountIdPath emailPath apiPath curl jq bash ping;
  };

  cloudflareUpdateDNSScript = pkgs.replaceVars ../scripts/update-dns.sh {
    inherit tunnelName homeDir accountIdPath emailPath apiPath curl jq gawk bash ping;
    ingress_domains = concatStringsSep " " (
      builtins.attrNames config.services.cloudflared.tunnels.${tunnelName}.ingress
    );
  };

  createExecStartScript =
    let
      filterConfig = attrsets.filterAttrsRecursive (
        _: v:
        !builtins.elem v [
          null
          [ ]
          { }
        ]
      );

      filterIngressSet = filterAttrs (_: v: builtins.typeOf v == "set");
      filterIngressStr = filterAttrs (_: v: builtins.typeOf v == "string");

      ingressesSet = filterIngressSet config.services.cloudflared.tunnels.${tunnelName}.ingress;
      ingressesStr = filterIngressStr config.services.cloudflared.tunnels.${tunnelName}.ingress;

      fullConfig = filterConfig {
        tunnel = tunnelName;
        "credentials-file" = config.services.cloudflared.tunnels.${tunnelName}.credentialsFile;
        warp-routing = filterConfig config.services.cloudflared.tunnels.${tunnelName}.warp-routing;
        originRequest = filterConfig config.services.cloudflared.tunnels.${tunnelName}.originRequest;
        ingress =
          (map (
            key:
            {
              hostname = key;
            }
            // getAttr key (filterConfig (filterConfig ingressesSet))
          ) (attrNames ingressesSet))
          ++ (map (key: {
            hostname = key;
            service = getAttr key ingressesStr;
          }) (attrNames ingressesStr))
          ++ [ { service = config.services.cloudflared.tunnels.${tunnelName}.default; } ];
      };

      mkConfigFile = pkgs.writeText "cloudflared.yml" (builtins.toJSON fullConfig);
    in
    pkgs.replaceVars ../scripts/create-cloudflare-start-script.sh {
      inherit tunnelName homeDir user jq;
      cloudflared_package = config.services.cloudflared.package;
      config_file = mkConfigFile;
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
    {
      systemd.services."cloudflared-tunnel-setup-${tunnelName}" = {
        description = "Create or update Cloudflare tunnel ${tunnelName}";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        requires = [ "network-online.target" ];
        script = ''
          ${bash} ${createCloudflaredHome}
          ${bash} ${fetchOrCreateTunnel}
          ${bash} ${createExecStartScript}
        '';
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
      };
    }

    # ── DNS update service ───────────────────────────────────────────────────
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
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
      };
    }

    # ── Tunnel service ────────────────────────────────────────────────────────
    {
      systemd.services."cloudflared-tunnel-${tunnelName}" = {
        after = [
          "network-online.target"
          "cloudflared-tunnel-setup-${tunnelName}.service"
        ];
        requires = [ "cloudflared-tunnel-setup-${tunnelName}.service" ];
        serviceConfig = {
          Restart = "on-failure";
          ExecStart = mkForce "${homeDir}/${tunnelName}_tunnel.sh";
          User = user;
          Group = user;
          WorkingDirectory = homeDir;
          StandardOutput = "journal";
          StandardError = "journal";
          Environment = "HOME=${homeDir}";
        };
      };
    }

    # ── User and group ───────────────────────────────────────────────────────
    {
      users.users.${user} = {
        isSystemUser = true;
        group = user;
        home = homeDir;
      };

      users.groups.${user} = { };
    }

    # ── Upstream cloudflared service ──────────────────────────────────────────
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