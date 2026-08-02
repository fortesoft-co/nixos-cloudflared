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

  # ── Tunnel config and start script ──────────────────────────────────────────
  # The upstream nixpkgs module uses credentials-file in the config, which
  # expects a standard credentials JSON with a raw TunnelSecret.  But we
  # fetch the tunnel token (a JWT) from the Cloudflare API, which is not
  # compatible with credentials-file.  We use --token instead, which
  # requires our own config file (without credentials-file) and start script.

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
        # No credentials-file — we authenticate via --token with the JWT
        # from the Cloudflare API's /token endpoint.
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
  # directory and passes it via --token.  Works with DynamicUser because
  # systemd loads the credential as root before dropping privileges.
  startScript = pkgs.replaceVars ../scripts/start-tunnel.sh {
    cloudflared_package = config.services.cloudflared.package;
    config_file = tunnelConfig;
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
    # Fetches or creates the tunnel via the Cloudflare API and writes:
    #   - .<tunnelName>.json  — credentials JSON (for debugging/inspection)
    #   - .<tunnelName>.token — raw JWT token (loaded by the tunnel service
    #     via LoadCredential and passed to cloudflared via --token)
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

    # ── Tunnel service ─────────────────────────────────────────────────────────
    # Overrides the upstream module's tunnel service to use --token with the
    # JWT from the Cloudflare API.  The upstream module uses credentials-file,
    # which expects a raw TunnelSecret — but the API only provides a JWT,
    # so --token is required.
    #
    # DynamicUser and other upstream settings are preserved; we only override
    # ExecStart and LoadCredential.  The token file is loaded by systemd as
    # root before dropping to the dynamic user, so the script can read it
    # from $CREDENTIALS_DIRECTORY.
    {
      systemd.services."cloudflared-tunnel-${tunnelName}" = {
        after = [ "cloudflared-tunnel-setup-${tunnelName}.service" ];
        requires = [ "cloudflared-tunnel-setup-${tunnelName}.service" ];
        serviceConfig = {
          # Load the token file as a credential — systemd reads it as root
          # and makes it available at $CREDENTIALS_DIRECTORY/tunnel-token
          # to the dynamic user.
          LoadCredential = mkForce [ "tunnel-token:${homeDir}/.${tunnelName}.token" ];
          # Use our start script that passes --token instead of the upstream's
          # ExecStart which relies on credentials-file in the config.
          ExecStart = mkForce startScript;
        };
      };
    }

    # ── Upstream cloudflared service ──────────────────────────────────────────
    # Enable the upstream module so its options (ingress, originRequest, etc.)
    # are available.  We override the tunnel service's ExecStart and
    # LoadCredential above, but the upstream module still provides the
    # DynamicUser, RuntimeDirectory, and other service settings.
    {
      services.cloudflared = {
        enable = true;
        tunnels.${tunnelName} = {
          # The upstream module uses this for LoadCredential — we override
          # LoadCredential above, so this is just to satisfy the option.
          credentialsFile = "${homeDir}/.${tunnelName}.json";
          default = "http_status:404";
        };
      };
    }
  ]);
}