{
  description = "NixOS module for Cloudflare tunnel setup with age secrets and DNS management";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs, ... }: {
    nixosModules = {
      default = import ./modules/service-cloudflared.nix;
      cloudflared = self.nixosModules.default;
    };
  };
}