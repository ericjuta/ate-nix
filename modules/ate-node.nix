# Node side of the Nix image source: the view directory atelet hard-links
# closures into, exposed to the worker pods through the /var/lib/ate mount
# they already have. A non-recursive /nix alias keeps NixOS's read-only
# /nix/store child mount out of atelet's hard-linking view.
# See docs/operating.md, "Prepare each node".
{ config, lib, ... }:

let
  cfg = config.services.ate-node.nixImages;
in
{
  options.services.ate-node.nixImages = {
    enable = lib.mkEnableOption "the directories atelet needs to run actors from Nix store paths";

    viewDir = lib.mkOption {
      type = lib.types.path;
      default = "/nix/var/ate/views";
      description = ''
        Where atelet builds closure views (`--nix-view-dir`). It must be on
        the same underlying filesystem as /nix/store, because views are made
        of hard links. Atelet sees both through the non-recursive /nix alias
        at /var/lib/ate-nix, mounted in its container as /nix.
      '';
    };

    mountDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/ate/nix-views";
      description = ''
        Where the views are bind-mounted for the worker pods
        (`--nix-view-mount-dir`). It must be under /var/lib/ate.
      '';
    };

    substituters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Binary caches the node substitutes actor closures from.";
    };

    trustedPublicKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Keys whose signatures the node accepts on substituted paths.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/nix/" cfg.viewDir && !lib.hasPrefix "/nix/store/" cfg.viewDir;
        message = "services.ate-node.nixImages.viewDir must be under /nix, outside /nix/store.";
      }
      {
        assertion = lib.hasPrefix "/var/lib/ate/" cfg.mountDir;
        message = "services.ate-node.nixImages.mountDir must be under /var/lib/ate.";
      }
    ];

    systemd.tmpfiles.rules = [
      "d /var/lib/ate-nix 0755 root root -"
      "d ${cfg.viewDir} 0755 root root -"
      "d ${cfg.mountDir} 0755 root root -"
    ];

    # "bind", not "rbind": copying /nix/store's read-only child mount would
    # leave store files and the view directory on different mount objects,
    # making link(2) fail with EXDEV. Keep this alias private so later child
    # mounts under the source cannot propagate into it either.
    fileSystems."/var/lib/ate-nix" = {
      device = "/nix";
      fsType = "none";
      options = [
        "bind"
        "private"
      ];
    };

    fileSystems.${cfg.mountDir} = {
      device = cfg.viewDir;
      fsType = "none";
      options = [ "bind" ];
    };

    nix.settings = {
      require-sigs = true;
      substituters = cfg.substituters;
      trusted-public-keys = cfg.trustedPublicKeys;
    };
  };
}
