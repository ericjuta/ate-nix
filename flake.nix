{
  description = "Agent Substrate (ate.dev) with Sam Huber's patch stack as a Nix overlay: PTY streams in env, Nix store path images in atelet";

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
        ate-substrate = final.callPackage ./pkgs/ate-substrate.nix { };
        ateNixImage = final.callPackage ./pkgs/ate-nix-image.nix { };
      };

      nixosModules.ate-node = ./modules/ate-node.nix;

      packages = nixpkgs.lib.genAttrs systems (system: rec {
        inherit (pkgsFor system) ate-env ate-substrate;
        default = ate-env;

        # A small Nix image, to try the image source with:
        # `image: nix:$(nix build --print-out-paths .#example-image)`.
        example-image = (pkgsFor system).ateNixImage {
          name = "ate-example-image";
          paths = with pkgsFor system; [
            bashInteractive
            coreutils
          ];
          config = {
            Entrypoint = [ "/bin/bash" ];
            Env = [ "PATH=/bin" ];
          };
        };
      });
    };
}
