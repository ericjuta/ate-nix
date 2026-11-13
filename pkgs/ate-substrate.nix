{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule {
  pname = "ate-substrate";
  version = "1.0.0";

  src = fetchFromGitHub {
    owner = "agent-substrate";
    repo = "substrate";
    rev = "b34fbee742906494b5eb4f1f36987176bf8770a4"; # v1.0.0
    hash = "sha256-smq4+HxT7vaqhomfTGCIa3ndq1UqsfMKON4DVhTl/o0=";
  };

  patches = [
    ../patches/substrate/0001-atelet-nix-image-source.patch
  ];

  # Upstream commits its vendor directory.
  vendorHash = null;

  # The two binaries the patch changes: atelet builds the closure views, and
  # ateapi accepts "nix:/nix/store/..." as a pinned image reference. The other
  # Substrate components run unpatched from the upstream release.
  subPackages = [
    "cmd/atelet"
    "cmd/ateapi"
  ];

  env.CGO_ENABLED = 0;
  ldflags = [
    "-s"
    "-w"
  ];

  # Tests of the code the patch adds or changes. The full cmd/atelet suite
  # needs mount privileges the build sandbox lacks.
  checkPhase = ''
    runHook preCheck
    go test ./internal/niximage/... ./internal/nixref/... ./internal/resources/...
    runHook postCheck
  '';

  meta = {
    description = "Agent Substrate atelet and ateapi with a Nix store path image source";
    homepage = "https://github.com/agent-substrate/substrate";
    license = lib.licenses.asl20;
    mainProgram = "atelet";
  };
}
