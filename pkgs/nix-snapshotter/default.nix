# Upstream v0.4.0's builder requires globset, which nixpkgs does not supply.
# Both fixed hashes come from that release's pinned source inputs.
{ pkgs }:
let
  source = builtins.fetchTarball {
    url = "https://github.com/pdtpartners/nix-snapshotter/archive/v0.4.0.tar.gz";
    sha256 = "sha256-uPdgkgNV4nOKeGRH2Ucy0XlR0pVgfxvi7w55GfBVo3A=";
  };
  globset = builtins.fetchTarball {
    url = "https://github.com/pdtpartners/globset/archive/eb9d9e64b7ab0a64c34ba4a5a990b66506401c35.tar.gz";
    sha256 = "sha256-nBkQx23jgpGPk3aU2KcqJCoYvzjsKEjWBePmc2z8N3k=";
  };
in
pkgs.callPackage "${source}/package.nix" {
  globset.lib = import globset { inherit (pkgs) lib; };
  buildGoModule = args: pkgs.buildGoModule (args // {
    version = "0.4.0";
    patches = (args.patches or [ ]) ++ [
      ../../patches/nix-snapshotter/nix-snapshotter-183-store-path-mount-type.patch
      ../../patches/nix-snapshotter/nix-snapshotter-builder-error-output.patch
    ];
  });
}
