# Three images that exist in no public cache, for kind/private-cache.sh. They
# differ only in a tag, and the nonce makes every run build new store paths.
{
  nonce,
  flake ? builtins.getFlake (toString ../.),
  system ? builtins.currentSystem,
}:
let
  pkgs = import flake.inputs.nixpkgs {
    inherit system;
    overlays = [ flake.overlays.default ];
  };
  image =
    tag:
    pkgs.ateNixImage {
      name = "ate-private-${tag}";
      paths = [
        pkgs.busybox
        (pkgs.writeTextFile {
          name = "ate-private-www-${tag}";
          destination = "/www/cgi-bin/info";
          executable = true;
          text = ''
            #!/bin/sh
            echo "Content-Type: text/plain"
            echo
            echo "${tag} ${nonce}"
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
in
{
  signed = image "signed";
  unsigned = image "unsigned";
  rogue = image "rogue";
}
