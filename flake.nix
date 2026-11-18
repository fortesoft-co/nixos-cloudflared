{
  description = "NixOS module for Cloudflare tunnels: the tunnel and its DNS records set up through the Cloudflare API, credentials as systemd credentials";

  # Only for checks (NixOS VM tests); the module uses the host's nixpkgs.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    {
      nixosModules = {
        default = ./modules/service-cloudflared.nix;
        cloudflared = self.nixosModules.default;
      };

      checks.x86_64-linux.tunnel = import ./tests/tunnel.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        inherit self;
      };
    };
}
