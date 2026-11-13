# Everything the project builds, from one package set.
{ pkgs }:

let
  inherit (pkgs) lib;

  # One list for the dev shell and for the agent's actor: a person and an
  # agent work with the same tools at the same versions.
  tools = with pkgs; [
    go
    git
    bashInteractive
    coreutils
    findutils
    gnugrep
    gnused
  ];

  app = pkgs.buildGoModule {
    pname = "reference-app";
    version = "0.1.0";
    src = ./app;
    vendorHash = null;
    env.CGO_ENABLED = 0;
    meta.mainProgram = "reference-app";
  };

  # Starts the guest daemon of the patched env build. The image holds no
  # /work, and the guest does not create its workspace: without it every
  # command fails to start.
  guest = pkgs.writeShellScriptBin "agent-guest" ''
    mkdir -p /work
    exec ${pkgs.ate-env}/bin/ate-env-guest -listen :80 -workspace /work
  '';

  # Where the agent works: the tools, plus the env guest daemon that runs
  # commands and serves files inside the actor.
  agent-image = pkgs.ateNixImage {
    name = "reference-agent-image";
    paths = tools ++ [ guest ];
    config = {
      Entrypoint = [ "/bin/agent-guest" ];
      Env = [
        "PATH=/bin"
        "HOME=/work"
        "CGO_ENABLED=0"
      ];
    };
  };

  # What ships: the app and nothing else.
  runtime-image = pkgs.ateNixImage {
    name = "reference-runtime-image";
    paths = [ app ];
    config = {
      Entrypoint = [ "/bin/reference-app" ];
      Env = [ "PORT=80" ];
    };
  };

  # atelet starts Entrypoint[0] from the image; a typo there shows up only
  # when the actor fails to boot.
  entrypointExists =
    image:
    pkgs.runCommand "${image.name}-entrypoint" { nativeBuildInputs = [ pkgs.jq ]; } ''
      entrypoint=$(jq -er '.Entrypoint[0]' ${image}/ate-image-config.json)
      test -x "${image}$entrypoint" || { echo "$entrypoint is not an executable in ${image.name}"; exit 1; }
      touch $out
    '';
in
{
  inherit app agent-image runtime-image;

  devShell = pkgs.mkShell {
    packages = tools ++ [ pkgs.ate-env ];
  };

  checks = {
    # Building the app runs its Go tests.
    inherit app agent-image runtime-image;

    agent-image-entrypoint = entrypointExists agent-image;
    runtime-image-entrypoint = entrypointExists runtime-image;

    # The built binary answers over HTTP.
    app-serves = pkgs.runCommand "reference-app-serves" { nativeBuildInputs = [ pkgs.curl ]; } ''
      PORT=18080 ${lib.getExe app} > server.log 2>&1 &
      server=$!
      for _ in $(seq 50); do
        if curl -fsS http://127.0.0.1:18080/ > response; then break; fi
        sleep 0.1
      done
      # A server left running would keep the build's log open, and the build
      # would never end.
      kill $server
      grep -q '"service":"reference-app"' response || { cat server.log; exit 1; }
      touch $out
    '';

    # The runtime image must not carry the toolchain: nodes download its
    # whole closure.
    runtime-image-has-no-toolchain = pkgs.runCommand "runtime-image-has-no-toolchain" { } ''
      if grep -E -- '-(go|git)-[0-9]' ${pkgs.closureInfo { rootPaths = [ runtime-image ]; }}/store-paths; then
        echo "the runtime image closure contains the toolchain"
        exit 1
      fi
      touch $out
    '';
  };
}
