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

  hasAgenix = builtins.hasAttr "age" options;

  homeDir = cfg.homeDir;
  tunnelName = cfg.tunnelName;

  accountIdPath = config.age.secrets.cf_account_id.path;
  apiPath = config.age.secrets.cf_account_api.path;
  emailPath = config.age.secrets.cf_account_email.path;

  accountIdAgePath = cfg.accountIdAgePath;
  apiAgePath = cfg.apiAgePath;
  emailAgePath = cfg.emailAgePath;

  curl = "${pkgs.curl}/bin/curl";
  jq = "${pkgs.jq}/bin/jq";
  gawk = "${pkgs.gawk}/bin/awk";
  bash = "${pkgs.bash}/bin/bash";
  ping = "${pkgs.iputils}/bin/ping";

  createCloudflaredHome = pkgs.replaceVars ../scripts/create-cloudflared-home.sh {
    inherit homeDir bash;
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

  # Generate the cloudflared config file from the upstream tunnel options.
  # Authentication is handled via --token (see startScript), not
  # credentials-file, because the Cloudflare API provides a JWT.
  tunnelConfig =
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
    in
    pkgs.writeText "cloudflared-${tunnelName}.yml" (builtins.toJSON fullConfig);

  # Start script that reads the tunnel token from systemd's credentials
  # directory and passes it via --token.
  startScript = pkgs.replaceVars ../scripts/start-tunnel.sh {
    inherit bash;
    cloudflared_package = config.services.cloudflared.package;
    config_file = tunnelConfig;
  };
in
{
  imports = [ ./options.nix ];

  config = mkIf cfg.enable (mkMerge [
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

    {
      age.secrets = {
        cf_account_id.file = accountIdAgePath;
        cf_account_email.file = emailAgePath;
        cf_account_api.file = apiAgePath;
      };
    }

    # ── Tunnel setup ───────────────────────────────────────────────────────────
    # Fetches or creates the tunnel via the Cloudflare API at boot.
    # Writes .<tunnelName>.token (JWT for --token) and .<tunnelName>.json
    # (credentials for inspection) to homeDir with umask 077.
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

    # ── DNS update ──────────────────────────────────────────────────────────────
    # Creates or updates CNAME records for all ingress domains.
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

    # ── Tunnel service ──────────────────────────────────────────────────────────
    # Authenticates via --token with the JWT fetched by the setup service.
    # The token is loaded through LoadCredential so it's available to the
    # DynamicUser without direct file access.
    {
      systemd.services."cloudflared-tunnel-${tunnelName}" = {
        after = [ "cloudflared-tunnel-setup-${tunnelName}.service" ];
        requires = [ "cloudflared-tunnel-setup-${tunnelName}.service" ];
        serviceConfig = {
          LoadCredential = mkForce [ "tunnel-token:${homeDir}/.${tunnelName}.token" ];
          ExecStart = mkForce startScript;
        };
      };
    }

    # ── Upstream cloudflared options ────────────────────────────────────────────
    # Enables the upstream module for its tunnel/ingress options.  The tunnel
    # service's ExecStart and LoadCredential are overridden above.
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
