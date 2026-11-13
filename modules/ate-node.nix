# Node side of the Nix image source: the view directory atelet hard-links
# closures into, exposed to the worker pods through the /var/lib/ate mount
# they already have. See docs/operating.md, "Prepare each node".
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
        the same mount as /nix/store, because views are made of hard links.
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
      "d ${cfg.viewDir} 0755 root root -"
      "d ${cfg.mountDir} 0755 root root -"
    ];

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
