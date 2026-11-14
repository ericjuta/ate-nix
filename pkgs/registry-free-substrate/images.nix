# Same ko component inventory and layout, without downloading any OCI base.
{ pkgs, src, version, buildImage }:
let
  inherit (pkgs) lib;
  components = [
    "cmd/ate-idp-server"
    "cmd/ateapi"
    "cmd/atecontroller"
    "cmd/atelet"
    "cmd/atenet"
    "cmd/ateworker-gvisor"
    "cmd/ateworker-microvm"
    "cmd/benchmarking/isolate/fake-atelet"
    "cmd/benchmarking/isolate/fake-workersync"
    "cmd/credential-provider/kubernetes-secrets"
    "cmd/objectstore-plugin"
    "cmd/podcertcontroller"
    "demos/counter"
    "demos/egress"
    "demos/multi-template/fspersist"
    "demos/sandbox"
  ];
  actorComponents = builtins.filter (lib.hasPrefix "demos/") components;
  forComponents = f: lib.listToAttrs (map (component: {
    name = baseNameOf component;
    value = f component;
  }) components);
  binaries = pkgs.buildGo127Module {
    pname = "ate-substrate-components";
    inherit version src;
    vendorHash = null;
    subPackages = components;
    env.CGO_ENABLED = 0;
    ldflags = [ "-s" "-w" ];
    doCheck = false;
    meta.platforms = lib.platforms.linux;
  };
  config = component: {
    Entrypoint = [ "/ko-app/${baseNameOf component}" ];
    User = if component == "cmd/atelet" || lib.elem component actorComponents then "0:0" else "65532:65532";
    Env = [
      "PATH=/bin:/usr/bin"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt"
    ] ++ lib.optional (component == "cmd/ateworker-gvisor") "KO_DATA_PATH=/var/run/ko";
    WorkingDir = "/";
  };
  roots = forComponents (component: pkgs.runCommand "ate-${baseNameOf component}-root" { } (''
    mkdir -p "$out/ko-app" "$out/etc/ssl/certs"
    cp ${binaries}/bin/${baseNameOf component} "$out/ko-app/${baseNameOf component}"
    chmod 0555 "$out/ko-app/${baseNameOf component}"
    ln -s ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt "$out/etc/ssl/certs/ca-certificates.crt"
    printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' 'nonroot:x:65532:65532:nonroot:/home/nonroot:/sbin/nologin' > "$out/etc/passwd"
    printf '%s\n' 'root:x:0:' 'nonroot:x:65532:' > "$out/etc/group"
    printf 'passwd: files\ngroup: files\nhosts: files dns\n' > "$out/etc/nsswitch.conf"
    cat > "$out/ate-image-config.json" <<'EOF'
    ${builtins.toJSON (config component)}
    EOF
  '' + (if component == "cmd/ateworker-gvisor" then ''
    mkdir -p "$out/var/run/ko"
    cp -r ${src}/${component}/kodata/. "$out/var/run/ko/"
  '' else ''
    if [ -e ${src}/${component}/kodata ]; then
      echo '${component}: add its kodata to the component image definition' >&2
      exit 1
    fi
  '') + lib.optionalString (component == "demos/sandbox") ''
    mkdir -p "$out/bin"
    for applet in ${pkgs.busybox}/bin/*; do ln -s "$applet" "$out/bin/"; done
  '' + lib.optionalString (component == "cmd/atelet") ''
    # The credential-provider executable mounted from the node may be dynamic.
    mkdir -p "$out/lib" "$out/lib64"
    for library in ${pkgs.glibc}/lib/*.so*; do
      ln -s "$library" "$out/lib/"
      ln -s "$library" "$out/lib64/"
    done
  ''));
  writableBase = pkgs.dockerTools.buildLayeredImage {
    name = "ate-component-directories";
    tag = "base";
    compressor = "none";
    fakeRootCommands = ''
      mkdir -p tmp
      chmod 1777 tmp
    '';
  };
  nixImages = forComponents (component: buildImage {
    name = baseNameOf component;
    resolvedByNix = true;
    fromImage = writableBase;
    copyToRoot = roots.${baseNameOf component};
    config = config component;
  });
  # workerImage becomes a Kubernetes Deployment's image, not an actor root.
  # Demo ActorTemplates are the only consumers of the independent nix:/ API.
  references = forComponents (component:
    if lib.elem component actorComponents then "nix:${roots.${baseNameOf component}}"
    else nixImages.${baseNameOf component}.image);
in
assert pkgs.stdenv.hostPlatform.isLinux;
{
  inherit components actorComponents binaries roots nixImages references;
}
