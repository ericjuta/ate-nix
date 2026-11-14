# A Nix-store actor root, not an OCI archive. The flake supplies the pinned,
# unmodified upstream OMP package, including its native-addon runtime closure.
{
  lib,
  stdenv,
  buildEnv,
  writeShellScriptBin,
  ateNixImage,
  ate-env,
  omp,
  bashInteractive,
  cacert,
  coreutils,
  curl,
  diffutils,
  findutils,
  git,
  gnugrep,
  gnused,
  jq,
  nodejs_24,
  openssh,
  python3,
}:

assert lib.assertMsg stdenv.hostPlatform.isLinux "OMP actor images must be built for a Linux worker";

let
  guest = writeShellScriptBin "omp-env-guest" ''
    set -euo pipefail
    umask 077

    export HOME="''${HOME:-/workspace}"
    export WORKSPACE_PATH="''${WORKSPACE_PATH:-/workspace}"
    export OMP_SESSION_DIR="''${OMP_SESSION_DIR:-$HOME/.omp/sessions}"

    # Only the store is supplied by the image. Writable state belongs to the
    # actor's private layer and is created before the guest accepts requests.
    mkdir -p "$WORKSPACE_PATH" "$HOME/.cache" "$HOME/.config" \
      "$HOME/.local/state" "$OMP_SESSION_DIR" /tmp
    chmod 1777 /tmp
    cd "$WORKSPACE_PATH"

    exec ${ate-env}/bin/ate-env-guest -listen :80 -workspace "$WORKSPACE_PATH" "$@"
  '';

  tools = buildEnv {
    name = "omp-actor-tools";
    paths = [
      bashInteractive
      coreutils
      curl
      diffutils
      findutils
      git
      gnugrep
      gnused
      jq
      nodejs_24
      openssh
      python3
      omp
      guest
    ];
    # Do not make /etc a store symlink: the worker writes resolv.conf there.
    # Runtime libraries remain reachable through the tools' store references.
    pathsToLink = [ "/bin" ];
  };
in
ateNixImage {
  name = "omp-actor-image-${omp.version}";
  paths = [ tools ];
  config = {
    Entrypoint = [ "/bin/omp-env-guest" ];
    Env = [
      "PATH=/bin"
      "HOME=/workspace"
      "WORKSPACE_PATH=/workspace"
      "OMP_SESSION_DIR=/workspace/.omp/sessions"
      "TMPDIR=/tmp"
      "TERM=xterm-256color"
      "COLORTERM=truecolor"
      "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
      "GIT_SSL_CAINFO=${cacert}/etc/ssl/certs/ca-bundle.crt"
    ];
  };
}
