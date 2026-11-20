# Native Linux package set. The caller supplies the same patched Substrate
# derivation used for ate-setup; there is deliberately no second source pin.
{ pkgs, substrate, snapshotter ? import ../nix-snapshotter { inherit pkgs; } }:
let
  inherit (pkgs) lib;
  inherit (snapshotter) buildImage;
  src = substrate.patchedSrc;
  components = import ./images.nix {
    inherit pkgs src buildImage;
    inherit (substrate) version;
  };
  envoy = import ./envoy-dataplane.nix { inherit pkgs src buildImage; };
  thirdParty = import ./third-party-images.nix { inherit pkgs src buildImage; };
  pauseImage = import ../nix-snapshotter/pause.nix { inherit pkgs buildImage; };
  podImages = lib.filterAttrs (name: _: !(builtins.hasAttr name actorRoots)) components.nixImages
    // thirdParty.nixImages
    // { envoy-dataplane = envoy.nixImage; pause = pauseImage; };
  # Filtering by the actual component inventory also handles nested demo paths.
  actorRoots = lib.listToAttrs (map (component: {
    name = baseNameOf component;
    value = components.roots.${baseNameOf component};
  }) components.actorComponents);
  namedReferences = components.references // { envoy-dataplane = envoy.nixImage.image; };
  thirdPartyReferences = lib.mapAttrs (name: _: thirdParty.nixImages.${name}.image) thirdParty.references;
  imageMap = pkgs.writeText "ate-substrate-image-map" (
    lib.concatStrings (lib.mapAttrsToList (name: ref: "${name} ${ref}\n") namedReferences)
    + lib.concatStrings (lib.mapAttrsToList (name: upstream: "${upstream} ${thirdPartyReferences.${name}}\n") thirdParty.references)
  );
  closureBundle = pkgs.linkFarm "ate-substrate-nix-bundle" (
    [ { name = "image-map"; path = imageMap; } ]
    ++ lib.mapAttrsToList (name: path: { name = "pods/${name}.tar"; inherit path; }) podImages
    ++ lib.mapAttrsToList (name: path: { name = "actors/${name}"; inherit path; }) actorRoots
  );
  imageMapCheck = pkgs.runCommand "ate-substrate-image-map-check" {
    nativeBuildInputs = [ pkgs.go_1_27 ];
  } ''
    cp -R ${src}/. source
    chmod -R u+w source
    cd source
    # Substrate's go.mod suggests a newer patch toolchain than nixpkgs has. Use
    # the pinned compiler, as buildGoModule does; the `go` line is the minimum.
    export HOME="$TMPDIR" GOCACHE="$TMPDIR/go-cache" GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
    export CGO_ENABLED=0 GOFLAGS=-mod=vendor ATE_TEST_IMAGE_MAP=${imageMap}
    go test ./cmd/ate-setup/internal/images > "$out" 2>&1 || {
      cat "$out" >&2
      exit 1
    }
  '';
  # The release-publishing regression needs a real committed source snapshot.
  # Run the full changed modules, with the same setup as ate-substrate's check.
  installerTests = pkgs.writeShellApplication {
    name = "ate-substrate-installer-tests";
    runtimeInputs = [ pkgs.go_1_27 pkgs.git pkgs.bashInteractive pkgs.kubectl pkgs.kustomize pkgs.kind ];
    text = ''
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      cp -R ${src}/. "$work/"
      chmod -R u+w "$work"
      cd "$work"
      export CGO_ENABLED=0 GOCACHE="$work/go-cache" GOPROXY=off GOSUMDB=off GOFLAGS=-mod=vendor GOTOOLCHAIN=local
      export ATE_TEST_IMAGE_MAP=${imageMap}
      git init --initial-branch=build
      git add --force --all
      git -c user.name="ate-nix build" -c user.email="build@localhost" \
        -c commit.gpgSign=false commit --quiet -m "Patched Substrate test source"
      go test ./cmd/ate-setup/internal/images ./cmd/ate-setup/internal/config ./cmd/ate-setup/internal/steps
    '';
  };
in
assert pkgs.stdenv.hostPlatform.isLinux;
{
  inherit src snapshotter components envoy thirdParty pauseImage podImages actorRoots;
  inherit namedReferences thirdPartyReferences imageMap closureBundle imageMapCheck installerTests;
}
