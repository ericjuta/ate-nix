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
                  echo "canary=$(cat /share/ate-proof/canary 2>/dev/null)"
                  echo "store_paths=$(ls /nix/store | wc -l)"
                  ls /nix/store | sed 's/^/store_path=/'
                '';
              })
              # A store file for /cgi-bin/tamper to attack. The view hard-links
              # it to the node's copy, so a write that got through would change
              # the node's store and every other actor that uses this path.
              (pkgs.writeTextDir "share/ate-proof/canary" "original\n")
              (pkgs.writeTextFile {
                name = "ate-proof-tamper";
                destination = "/www/cgi-bin/tamper";
                executable = true;
                text = ''
                  #!/bin/sh
                  echo "Content-Type: text/plain"
                  echo
                  canary=$(readlink -f /share/ate-proof/canary)
                  try() {
                    name=$1
                    shift
                    if "$@" 2>/dev/null; then echo "$name=done"; else echo "$name=refused"; fi
                  }
                  try append sh -c "echo tampered >> $canary"
                  try replace sh -c "rm -f $canary && echo tampered > $canary"
                  try create sh -c "echo tampered > /nix/store/ate-proof-tamper"
                  echo "uid=$(id -u)"
                  echo "canary_path=$canary"
                  echo "canary=$(cat /share/ate-proof/canary 2>/dev/null)"
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

      # `nix flake check` builds these for the current system. Building a
      # package applies its patches and runs the Go tests it enables.
      checks = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = pkgsFor system;
        in
        self.packages.${system}
        // {
          kind-scripts =
            pkgs.runCommand "ate-nix-kind-scripts"
              {
                nativeBuildInputs = [
                  pkgs.shellcheck
                  pkgs.jq
                ];
              }
              ''
                cd ${./kind}
                sh -n node-setup.sh
                bash -n prove.sh private-cache.sh
                shellcheck --severity=warning node-setup.sh prove.sh private-cache.sh
                jq empty atelet-nix.patch.json
                touch $out
              '';
        }
        // nixpkgs.lib.optionalAttrs (nixpkgs.lib.hasSuffix "-linux" system) {
          # The NixOS module evaluates in a minimal system, none of its
          # assertions fail, and the node's Nix configuration comes out with
          # the signature rule and the given cache and key.
          nixos-module =
            let
              nixos = nixpkgs.lib.nixosSystem {
                inherit system;
                modules = [
                  self.nixosModules.ate-node
                  {
                    services.ate-node.nixImages = {
                      enable = true;
                      substituters = [ "https://cache.example.com" ];
                      trustedPublicKeys = [ "example-1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ];
                    };
                    boot.loader.grub.enable = false;
                    fileSystems."/" = {
                      device = "none";
                      fsType = "tmpfs";
                    };
                    system.stateVersion = "25.11";
                  }
                ];
              };
              inherit (nixos) config;
              failed = builtins.filter (a: !a.assertion) config.assertions;
              bind = config.fileSystems."/var/lib/ate/nix-views";
            in
            assert failed == [ ];
            assert bind.device == "/nix/var/ate/views" && builtins.elem "bind" bind.options;
            pkgs.runCommand "ate-nix-nixos-module" { } ''
              conf=${config.environment.etc."nix/nix.conf".source}
              grep -qx 'require-sigs = true' $conf
              grep -q '^substituters = .*https://cache.example.com' $conf
              grep -q '^trusted-public-keys = .*example-1:' $conf
              touch $out
            '';
        }
      );
    };
}
