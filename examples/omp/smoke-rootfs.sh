#!/usr/bin/env bash
# Exercise the built Linux image without a cluster or provider credentials.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ( $# -eq 2 && $2 != --tui ) ]]; then
  echo "usage: $0 /nix/store/<omp-image-root> [--tui]" >&2
  exit 2
fi
if [[ $(uname -s) != Linux ]]; then
  echo "This smoke requires Linux, bubblewrap, jq, and enabled user namespaces." >&2
  exit 2
fi

image=$(realpath -- "$1")
entrypoint=$(jq -er '.Entrypoint[0]' "$image/ate-image-config.json")
test -x "$image$entrypoint"
test -x "$image/bin/omp"
mapfile -t image_env < <(jq -er '.Env[]' "$image/ate-image-config.json")

workspace=$(mktemp -d -t ate-omp-rootfs.XXXXXXXX)
trap 'rm -rf -- "$workspace"' EXIT

# A fresh root and HOME: no host configuration, auth, or working tree is
# imported. The whole store is visible for loader paths, so this is a runtime
# smoke, not a proof of closure isolation or a security sandbox audit.
sandbox=(
  bwrap
  --die-with-parent
  --unshare-all
  --uid 0
  --gid 0
  --cap-add CAP_NET_BIND_SERVICE
  --tmpfs /
  --ro-bind "$image/bin" /bin
  --ro-bind /nix/store /nix/store
  --dev /dev
  --dev-bind /dev/pts /dev/pts
  --proc /proc
  --tmpfs /tmp
  --dir /etc
  --bind "$workspace" /workspace
  --chdir /workspace
  /bin/env -i "${image_env[@]}"
)

if [[ ${2:-} == --tui ]]; then
  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "--tui requires a terminal; use Expect to drive it in automation." >&2
    exit 2
  fi
  # No network namespace access, credentials, ambient extensions, or sessions.
  # This checks the real terminal UI; it intentionally cannot verify inference.
  "${sandbox[@]}" /bin/omp --no-extensions --no-session
else
  "${sandbox[@]}" /bin/bash -euo pipefail -s -- "$entrypoint" <<'SANDBOX_SMOKE'
    version=$(omp --version < /dev/null)
    printf "%s\n" "$version"
    [[ $version == *18.20.2* ]]
    native=$(omp --smoke-test < /dev/null)
    printf "%s\n" "$native"
    grep -Fq "smoke-test: ok" <<< "$native"

    "$1" < /dev/null > /tmp/guest.log 2>&1 &
    guest=$!
    cleanup_guest() {
      kill "$guest" 2>/dev/null || true
      wait "$guest" 2>/dev/null || true
    }
    trap cleanup_guest EXIT
    for ((attempt = 0; attempt < 100; attempt++)); do
      if ! kill -0 "$guest" 2>/dev/null; then
        cat /tmp/guest.log >&2
        echo "env guest exited before readiness" >&2
        exit 1
      fi
      if curl --fail --silent http://127.0.0.1:80/readyz > /tmp/ready; then
        [[ $(cat /tmp/ready) == ok ]]
        test -d "$OMP_SESSION_DIR"
        test -d "$HOME/.config"
        echo "OMP image native/guest rootfs smoke passed; no model request was made."
        exit 0
      fi
      sleep 0.1
    done
    cat /tmp/guest.log >&2
    echo "env guest did not become ready" >&2
    exit 1
SANDBOX_SMOKE
fi
