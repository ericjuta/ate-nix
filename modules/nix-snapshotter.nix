# Standalone upstream snapshotter for the ordinary NixOS containerd service.
# Does not register a second plugin inside RKE2's embedded containerd.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.ate-node.snapshotter;
  format = pkgs.formats.toml { };
  snapshotterConfig = format.generate "ate-nix-snapshotter.toml" {
    address = cfg.address;
    root = cfg.root;
    image_service = {
      enable = true;
      containerd_address = cfg.containerdAddress;
    };
  };
in
{
  options.services.ate-node.snapshotter = {
    enable = lib.mkEnableOption "registry-free Nix images for Kubernetes pods";
    package = lib.mkOption {
      type = lib.types.package;
      default = import ../pkgs/nix-snapshotter { inherit pkgs; };
      description = "Standalone nix-snapshotter with the matching archive builder and fixes.";
    };
    address = lib.mkOption {
      type = lib.types.str;
      default = "/run/nix-snapshotter/nix-snapshotter.sock";
      description = "Unix socket for both the proxy snapshotter and CRI image service.";
    };
    root = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/containerd/io.containerd.snapshotter.v1.nix";
      description = "Persistent snapshot and Nix GC-root state; never put this in /run.";
    };
    containerdAddress = lib.mkOption {
      type = lib.types.str;
      default = "/run/containerd/containerd.sock";
      description = "The standalone containerd CRI runtime socket.";
    };
    sandboxImage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = import ../pkgs/nix-snapshotter/pause.nix {
        inherit pkgs;
        inherit (cfg.package) buildImage;
      };
      description = "Closure-backed pause archive preloaded before kubelet. Null keeps the operator's existing sandbox image.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(config.services.rke2.enable or false);
        message = "ate-node.snapshotter configures standalone containerd, not RKE2's embedded containerd. Do not register proxy_plugins.nix over a compiled-in nix plugin.";
      }
      {
        assertion = !(config.services.k3s.enable or false);
        message = "ate-node.snapshotter configures standalone containerd; K3s-managed containerd needs its own explicit integration.";
      }
      {
        assertion = config.virtualisation.containerd.configFile == null;
        message = "ate-node.snapshotter needs virtualisation.containerd.settings; a separate configFile would discard its proxy plugin settings.";
      }
    ];
    nix.settings = {
      require-sigs = true;
      max-jobs = 0;
      # nix-remote-build.nix contributes null when remote builds are disabled;
      # override it rather than merging unlike free-form setting value types.
      builders = lib.mkForce [ ];
    };
    virtualisation.containerd = {
      enable = true;
      settings = {
        # The NixOS containerd module uses config v2. Containerd 2 migrates it
        # to its split CRI plugins; retaining v2 also supports containerd 1.7.
        grpc.address = cfg.containerdAddress;
        plugins."io.containerd.grpc.v1.cri" = {
          containerd = {
            snapshotter = "nix";
            disable_snapshot_annotations = false;
            # Containerd 2's v2 -> v3 CRI-images migration returns before
            # copying these two settings if the runtimes table is absent.
            # Declare the normal runtime explicitly, including on a bare
            # standalone node without the Kubernetes module's defaults.
            runtimes.runc.runtime_type = lib.mkDefault "io.containerd.runc.v2";
          };
        } // lib.optionalAttrs (cfg.sandboxImage != null) {
          sandbox_image = cfg.sandboxImage.image;
        };
        plugins."io.containerd.transfer.v1.local".unpack_config = [ {
          platform = "linux/${pkgs.go.GOARCH}";
          snapshotter = "nix";
        } ];
        proxy_plugins.nix = {
          type = "snapshot";
          address = cfg.address;
        };
      };
    };
    environment.systemPackages = [ cfg.package pkgs.cri-tools ];
    environment.etc."crictl.yaml".text = ''
      runtime-endpoint: unix://${cfg.containerdAddress}
      image-endpoint: unix://${cfg.address}
    '';
    systemd.services.nix-snapshotter = {
      description = "Nix closure snapshotter and CRI image service";
      wantedBy = [ "multi-user.target" ];
      after = [ "nix-daemon.socket" "network.target" ];
      requires = [ "nix-daemon.socket" ];
      before = [ "containerd.service" ];
      path = [ config.nix.package ];
      environment.NIX_REMOTE = "daemon";
      serviceConfig = {
        Type = "notify";
        ExecStart = "${cfg.package}/bin/nix-snapshotter --config ${snapshotterConfig}";
        Restart = "always";
        RestartSec = 2;
        Delegate = true;
        KillMode = "mixed";
        RuntimeDirectory = "nix-snapshotter";
        RuntimeDirectoryPreserve = true;
      };
    };
    systemd.services.containerd = {
      requires = [ "nix-snapshotter.service" ];
      after = [ "nix-snapshotter.service" ];
    };
    # Sandbox pulls happen inside containerd, not through kubelet's image
    # endpoint. Preloading avoids an otherwise unavoidable registry pull.
    systemd.services.ate-pause-image = lib.mkIf (cfg.sandboxImage != null) {
      description = "Preload the Nix-backed Kubernetes sandbox image";
      wantedBy = [ "multi-user.target" ];
      requires = [ "containerd.service" ];
      after = [ "containerd.service" ];
      before = [ "kubelet.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${cfg.package}/bin/nix2container --address ${cfg.containerdAddress} --namespace k8s.io load ${cfg.sandboxImage}";
      };
    };
    systemd.services.kubelet = lib.mkIf (config.services.kubernetes.kubelet.enable or false) {
      requires = lib.optional (cfg.sandboxImage != null) "ate-pause-image.service";
      after = [ "nix-snapshotter.service" ] ++ lib.optional (cfg.sandboxImage != null) "ate-pause-image.service";
    };
    services.kubernetes.kubelet.containerRuntimeEndpoint = lib.mkIf (config.services.kubernetes.kubelet.enable or false)
      (lib.mkDefault "unix://${cfg.containerdAddress}");
    services.kubernetes.kubelet.extraOpts = lib.mkIf (config.services.kubernetes.kubelet.enable or false)
      "--image-service-endpoint=unix://${cfg.address}";
  };
}
