# Container images of the patched binaries that run as cluster workloads, laid out like the
# upstream ko images (/ko-app/<name>) so they drop into the upstream manifests
# by changing only the image reference.
#
# The binaries are static and are copied into the image, not referenced from
# /nix/store: the atelet pod mounts the node's /nix over the image's, which
# would hide anything the image kept there.
{
  lib,
  dockerTools,
  cacert,
  ate-substrate,
  ate-env,
}:

let
  mkImage =
    {
      package,
      binary,
      # Image name below ate-nix/.
      name ? binary,
      # uid:gid the container runs as. atelet's manifest pins root itself.
      user,
    }:
    dockerTools.buildLayeredImage {
      name = "ate-nix/${name}";
      tag = package.version;

      extraCommands = ''
        mkdir -p ko-app etc/ssl/certs tmp
        chmod 1777 tmp
        cp ${package}/bin/${binary} ko-app/${binary}
        cp ${cacert}/etc/ssl/certs/ca-bundle.crt etc/ssl/certs/ca-certificates.crt
        cat > etc/passwd <<EOF
        root:x:0:0:root:/root:/sbin/nologin
        nonroot:x:65532:65532:nonroot:/home/nonroot:/sbin/nologin
        EOF
        cat > etc/group <<EOF
        root:x:0:
        nonroot:x:65532:
        EOF
      '';

      config = {
        Entrypoint = [ "/ko-app/${binary}" ];
        User = user;
        Env = [ "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt" ];
      };
    };
in
{
  inherit mkImage;

  atelet = mkImage {
    package = ate-substrate;
    binary = "atelet";
    user = "0:0";
  };
  ateapi = mkImage {
    package = ate-substrate;
    binary = "ateapi";
    user = "65532:65532";
  };
  # The env API server, for `ate-env manifest --api-image`.
  ate-env-api = mkImage {
    package = ate-env;
    binary = "ate-env-api";
    user = "65532:65532";
  };
}
