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
        ateImages = final.callPackage ./pkgs/ate-images.nix { };
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

        # The actor kind/prove.sh starts: an HTTP server whose /cgi-bin/info
        # reports what the actor sees of the store, with a counter kept in
        # the actor's writable layer.
        proof-image =
          let
            pkgs = pkgsFor system;
          in
          pkgs.ateNixImage {
            name = "ate-proof-image";
            paths = [
              pkgs.busybox
              (pkgs.writeTextFile {
                name = "ate-proof-www";
                destination = "/www/cgi-bin/info";
                executable = true;
                text = ''
                  #!/bin/sh
                  n=$(cat /tmp/count 2>/dev/null || echo 0)
                  n=$((n + 1))
                  echo "$n" > /tmp/count
                  echo "Content-Type: text/plain"
                  echo
                  echo "count=$n"
                  echo "sh=$(readlink -f /bin/sh)"
                  echo "store_paths=$(ls /nix/store | wc -l)"
                  ls /nix/store | sed 's/^/store_path=/'
                '';
              })
            ];
            config = {
              Entrypoint = [
                "/bin/httpd"
                "-f"
                "-p"
                "80"
                "-h"
                "/www"
              ];
              Env = [ "PATH=/bin" ];
            };
          };
      }
      // nixpkgs.lib.optionalAttrs (nixpkgs.lib.hasSuffix "-linux" system) {
        # Container images of the patched binaries, as `docker load` tarballs.
        atelet-image = (pkgsFor system).ateImages.atelet;
        ateapi-image = (pkgsFor system).ateImages.ateapi;
      });
    };
}
