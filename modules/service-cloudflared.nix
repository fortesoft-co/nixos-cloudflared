# Cloudflare tunnel, set up through the Cloudflare API.
#
# Three units per tunnel:
#   cloudflared-tunnel-setup-<name>  finds or creates the tunnel and stores its
#                                    token (root-only, in stateDir)
#   cloudflared-tunnel-<name>        the daemon (nixpkgs' services.cloudflared),
#                                    authenticating with that token
#   cloudflared-update-dns-<name>    a proxied CNAME per ingress hostname
#
# The token outlives a failed setup: the daemon and the DNS unit only need
# the files the last successful setup left in stateDir, so an API problem at
# boot (an outage, a missing permission, no network yet) leaves the setup
# unit failed, visibly, but the tunnel up. Only the very first setup has to
# succeed.
#
# Ingress entries come from nixpkgs' options: any module can add
# services.cloudflared.tunnels.<name>.ingress."<hostname>".
#
# Secrets: the API credentials reach the two API units as systemd
# credentials (LoadCredential), so no other user or service can read them,
# and the scripts pass them to curl through a config file in the unit's
# private /tmp — never on a command line or in the environment.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.services.cloudflared-tunnel;
  inherit (cfg) name stateDir;
  tunnel = config.services.cloudflared.tunnels.${name};

  bash = "${pkgs.bash}/bin/bash";
  jq = "${pkgs.jq}/bin/jq";

  cfApi = pkgs.replaceVars ../scripts/cf-api.sh {
    curl = "${pkgs.curl}/bin/curl";
    inherit (cfg) apiUrl;
  };

  setupScript = pkgs.replaceVars ../scripts/fetch-or-create-tunnel.sh {
    inherit bash jq stateDir cfApi;
    tunnelName = name;
  };

  dnsScript = pkgs.replaceVars ../scripts/update-dns.sh {
    inherit bash jq stateDir cfApi;
    tunnelName = name;
    ingressHostnames = concatStringsSep " " (attrNames tunnel.ingress);
  };

  # The cloudflared config, generated from nixpkgs' tunnel options. The
  # daemon authenticates with --token-file (see start-tunnel.sh), not a
  # credentials file.
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
      ingressSets = filterAttrs (_: v: builtins.typeOf v == "set") tunnel.ingress;
      ingressStrs = filterAttrs (_: v: builtins.typeOf v == "string") tunnel.ingress;
    in
    pkgs.writeText "cloudflared-${name}.yml" (
      builtins.toJSON (filterConfig {
        tunnel = name;
        warp-routing = filterConfig tunnel.warp-routing;
        originRequest = filterConfig tunnel.originRequest;
        ingress =
          mapAttrsToList (hostname: v: { inherit hostname; } // filterConfig (filterConfig v)) ingressSets
          ++ mapAttrsToList (hostname: service: { inherit hostname service; }) ingressStrs
          ++ [ { service = tunnel.default; } ];
      })
    );

  startScript = pkgs.replaceVars ../scripts/start-tunnel.sh {
    inherit bash;
    cloudflared_package = config.services.cloudflared.package;
    config_file = tunnelConfig;
  };

  # API credentials, by credential name.
  apiCredentials = {
    account-id = cfg.accountIdFile;
  }
  // (
    if cfg.apiTokenFile != null then
      { api-token = cfg.apiTokenFile; }
    else
      {
        api-key = cfg.apiKeyFile;
        email = cfg.emailFile;
      }
  );

  hardening = {
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
    UMask = "0077";
    LoadCredential = mapAttrsToList (n: p: "${n}:${p}") apiCredentials;
  };
in
{
  imports = [ ./options.nix ];

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.apiTokenFile != null) != (cfg.apiKeyFile != null || cfg.emailFile != null);
        message = "services.cloudflared-tunnel: set apiTokenFile, or apiKeyFile and emailFile — exactly one way to authenticate.";
      }
      {
        assertion = cfg.apiTokenFile != null || (cfg.apiKeyFile != null && cfg.emailFile != null);
        message = "services.cloudflared-tunnel: apiKeyFile needs emailFile (and the other way around).";
      }
    ];

    systemd.tmpfiles.rules = [ "d ${stateDir} 0700 root root -" ];

    systemd.services."cloudflared-tunnel-setup-${name}" = {
      description = "Find or create Cloudflare tunnel ${name}";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = hardening // {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${bash} ${setupScript}";
        ReadWritePaths = [ stateDir ];
        # Don't hold the daemon back for long: it can start from the stored
        # token, and it retries its own connection.
        TimeoutStartSec = "2min";
      };
    };

    systemd.services."cloudflared-update-dns-${name}" = mkIf cfg.dns.enable {
      description = "DNS records for the ingress hostnames of Cloudflare tunnel ${name}";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
        "cloudflared-tunnel-setup-${name}.service"
      ];
      after = [
        "network-online.target"
        "cloudflared-tunnel-setup-${name}.service"
      ];
      unitConfig.ConditionPathExists = "${stateDir}/.${name}.json";
      serviceConfig = hardening // {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${bash} ${dnsScript}";
        ReadOnlyPaths = [ stateDir ];
      };
    };

    # nixpkgs' daemon unit, started with the token the setup unit stored —
    # fresh when setup succeeded, the previous one when it didn't.
    systemd.services."cloudflared-tunnel-${name}" = {
      wants = [ "cloudflared-tunnel-setup-${name}.service" ];
      after = [ "cloudflared-tunnel-setup-${name}.service" ];
      unitConfig.ConditionPathExists = "${stateDir}/.${name}.token";
      serviceConfig = {
        LoadCredential = mkForce [ "tunnel-token:${stateDir}/.${name}.token" ];
        ExecStart = mkForce "${bash} ${startScript}";
      };
    };

    services.cloudflared = {
      enable = true;
      tunnels.${name} = {
        credentialsFile = "${stateDir}/.${name}.json";
        default = mkDefault "http_status:404";
      };
    };
  };
}
