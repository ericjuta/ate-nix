#!/bin/sh
# Makes a node ready for Nix images. Run as root on the node (for kind:
# `docker exec -i <node> sh < kind/node-setup.sh`). Expects /nix to hold a Nix
# installation with the default profile; installs nothing itself.
#
# It does what modules/ate-node.nix does on NixOS: a Nix daemon with a signed
# substituter, a non-recursive /nix alias for atelet, the view directory beside
# the store, and that directory bind-mounted under /var/lib/ate for workers.
set -eu

NIX_BIN=/nix/var/nix/profiles/default/bin
SUBSTITUTERS="${SUBSTITUTERS:-https://cache.nixos.org}"
TRUSTED_PUBLIC_KEYS="${TRUSTED_PUBLIC_KEYS:-cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=}"

mkdir -p /etc/nix /nix/var/ate/views /var/lib/ate/nix-views /var/lib/ate-nix

# The daemon only substitutes on these nodes, it never builds, so it needs no
# build users.
cat > /etc/nix/nix.conf.new <<EOF
build-users-group =
substituters = ${SUBSTITUTERS}
trusted-public-keys = ${TRUSTED_PUBLIC_KEYS}
require-sigs = true
EOF
# The daemon reads its configuration once, at start.
if ! cmp -s /etc/nix/nix.conf.new /etc/nix/nix.conf; then
  mv /etc/nix/nix.conf.new /etc/nix/nix.conf
  systemctl stop nix-daemon 2>/dev/null || true
fi
rm -f /etc/nix/nix.conf.new

# Do not use --rbind: NixOS's read-only /nix/store child mount makes hard links
# into /nix/var/ate/views fail with EXDEV, despite the shared underlying disk.
# Making the alias private also prevents later child mounts propagating in.
mountpoint -q /var/lib/ate-nix ||
  mount --bind /nix /var/lib/ate-nix
mount --make-private /var/lib/ate-nix

mountpoint -q /var/lib/ate/nix-views ||
  mount --bind /nix/var/ate/views /var/lib/ate/nix-views

systemctl is-active -q nix-daemon ||
  systemd-run --unit=nix-daemon \
    -E NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    "${NIX_BIN}/nix-daemon"

# The socket file outlives a stopped daemon, so ask the daemon something.
ask() {
  NIX_REMOTE=daemon "${NIX_BIN}/nix-store" --query --hash "$(readlink -f "${NIX_BIN}/nix-store" | cut -d/ -f1-4)" >/dev/null 2>&1
}
for _ in 1 2 3 4 5 6 7 8 9 10; do
  ask && break
  sleep 1
done
ask || { echo "nix-daemon does not answer" >&2; exit 1; }
echo "node ready: nix-daemon up, atelet store at /var/lib/ate-nix, views at /nix/var/ate/views -> /var/lib/ate/nix-views"
