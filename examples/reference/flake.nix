{
  description = "Reference project for ate-nix: one lock file gives the dev shell, the checks, the app and both actor images";

  # In your own repository, use the published flake instead:
  #   inputs.ate-nix.url = "github:<owner>/ate-nix";
  inputs.ate-nix.url = "path:../..";
  inputs.nixpkgs.follows = "ate-nix/nixpkgs";

  outputs =
    {
      self,
      nixpkgs,
      ate-nix,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      project =
        system:
        import ./project.nix {
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ ate-nix.overlays.default ];
          };
        };
      forAll = f: nixpkgs.lib.genAttrs systems (system: f (project system));
    in
    {
      packages = forAll (p: {
        inherit (p) app agent-image runtime-image;
        default = p.app;
      });
      devShells = forAll (p: {
        default = p.devShell;
      });
      checks = forAll (p: p.checks);
    };
}
