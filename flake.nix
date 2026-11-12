{
  description = "Agent Substrate env (ate.dev) with Sam Huber's PTY patch stack, as a Nix overlay";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };
    in
    {
      overlays.default = final: _prev: {
        ate-env = final.callPackage ./pkgs/ate-env.nix { };
      };

      packages = nixpkgs.lib.genAttrs systems (system: rec {
        inherit (pkgsFor system) ate-env;
        default = ate-env;
      });
    };
}
