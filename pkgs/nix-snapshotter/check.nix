# A real containerd CRI container, signed binary-cache substitution, and no
# registry egress. No Kubernetes cluster or host container runtime is needed.
{ pkgs }:
let
  snapshotter = import ./. { inherit pkgs; };
  marker = pkgs.writeText "ate-snapshotter-file" "closure-file-mounted\n";
  root = pkgs.buildEnv {
    name = "ate-snapshotter-probe-root";
    paths = [
      pkgs.busybox
      (pkgs.writeTextDir "etc/passwd" "probe:x:10001:10001:probe:/:/bin/sh\n")
      (pkgs.writeTextDir "etc/group" "probe:x:10001:\nadditional:x:10002:probe\n")
      (pkgs.writeTextDir "etc/probe-file" "${marker}\n")
    ];
  };
  image = snapshotter.buildImage {
    name = "ate-snapshotter-probe";
    resolvedByNix = true;
    copyToRoot = root;
    config = {
      User = "probe";
      Entrypoint = [ "/bin/sh" ];
      Cmd = [ "-c" "test \"$(id -u)\" = 10001 && id -G | grep -w 10002 && cat $(cat /etc/probe-file)" ];
    };
  };
  unsigned = snapshotter.buildImage {
    name = "ate-snapshotter-unsigned";
    resolvedByNix = true;
    copyToRoot = root;
    config = { User = "probe"; Env = [ "UNSIGNED_TEST=1" ]; };
  };
in
pkgs.testers.runNixOSTest {
  name = "ate-registry-free-node";
  includeTestScriptReferences = false;
  nodes = {
    cache = {
      system.extraDependencies = [ image unsigned ];
      services.nginx = {
        enable = true;
        virtualHosts.cache = {
          default = true;
          root = "/srv/cache";
          extraConfig = "access_log /var/log/nginx/cache-access.log;";
        };
      };
      networking.firewall.allowedTCPPorts = [ 80 ];
      environment.systemPackages = [ pkgs.nix ];
      nix.settings.experimental-features = [ "nix-command" ];
      virtualisation.diskSize = 2048;
    };
    node = { config, ... }: {
      imports = [ ../../modules/nix-snapshotter.nix ];
      services.ate-node.snapshotter.enable = true;
      nix.settings.substituters = pkgs.lib.mkForce [ "http://cache" ];
      environment.systemPackages = [ pkgs.jq ];
      virtualisation = {
        memorySize = 2048;
        diskSize = 4096;
        # The default shared test store includes cache-only dependencies.
        # Boot a separate disk containing only this node's system closure so
        # image absence and signed substitution are real runtime properties.
        useNixStoreImage = pkgs.lib.mkForce false;
        writableStore = pkgs.lib.mkForce false;
        useBootLoader = true;
        useEFIBoot = true;
        fileSystems."/".autoResize = true;
      };
      boot.loader.systemd-boot.enable = true;
      boot.loader.efi.canTouchEfiVariables = true;
      boot.growPartition = true;
      # Only the test cache may serve HTTP. All registry HTTPS is refused.
      networking.firewall.extraCommands = ''
        iptables -A OUTPUT -p tcp -d cache --dport 80 -j ACCEPT
        iptables -A OUTPUT -p tcp -m multiport --dports 80,443 -j REJECT
      '';
    };
  };
  testScript = ''
    import json
    import shlex

    start_all()
    cache.wait_for_unit("nginx.service")
    cache.succeed("mkdir -p /srv/cache && nix-store --generate-binary-cache-key ate-nix-test-1 /run/cache.sec /run/cache.pub")
    cache.succeed("nix copy --to 'file:///srv/cache?compression=zstd&secret-key=/run/cache.sec' ${image}")
    cache.succeed("nix copy --to file:///srv/cache ${unsigned}")
    key = cache.succeed("cat /run/cache.pub").strip()
    node.wait_for_unit("containerd.service")
    node.wait_for_unit("ate-pause-image.service")
    node.succeed("cp /etc/nix/nix.conf /run/nix.conf && printf '\\nextra-trusted-public-keys = %s\\n' " + shlex.quote(key) + " >> /run/nix.conf && cp --remove-destination /run/nix.conf /etc/nix/nix.conf && systemctl restart nix-daemon.service")
    node.wait_until_succeeds("crictl images", timeout=120)
    node.fail("test -e ${image}")
    node.fail("test -e ${marker}")
    node.fail("test -e ${unsigned}")
    node.succeed("crictl pull ${image.image}")
    node.succeed("test -f ${image} && test -f ${marker}")
    cache.succeed("grep -F '${builtins.substring 0 32 (baseNameOf image)}.narinfo' /var/log/nginx/cache-access.log")

    pod = {"metadata": {"name": "probe", "namespace": "default", "uid": "probe"}, "log_directory": "/tmp/probe", "linux": {"security_context": {"namespace_options": {"network": 2}}}}
    container = {"metadata": {"name": "probe"}, "image": {"image": "${image.image}"}, "log_path": "probe.log"}
    node.succeed("mkdir -p /tmp/probe")
    for path, value in (("/tmp/pod.json", pod), ("/tmp/container.json", container)):
        node.succeed("printf %s " + shlex.quote(json.dumps(value)) + " > " + path)
    sandbox = node.succeed("crictl runp /tmp/pod.json").strip()
    cid = node.succeed("crictl create " + sandbox + " /tmp/container.json /tmp/pod.json").strip()
    node.succeed("crictl start " + cid)
    node.wait_until_succeeds("crictl inspect " + cid + " | jq -e '.status.state == \"CONTAINER_EXITED\" and .status.exitCode == 0'")
    node.succeed("crictl logs " + cid + " | grep -F closure-file-mounted")
    # This creation checks /etc/passwd and supplementary /etc/group through
    # containerd's fsview; a mistaken last-store-path root cannot resolve probe.
    node.succeed("crictl logs " + cid + " | grep -w 10002")
    node.fail("crictl pull ${unsigned.image}")
    node.fail("test -e ${unsigned}")
    node.succeed("find /var/lib/containerd/io.containerd.snapshotter.v1.nix/gcroots -type l | grep .")
    node.succeed("crictl rm " + cid)
    node.succeed("crictl stopp " + sandbox + " && crictl rmp " + sandbox)
  '';
}
