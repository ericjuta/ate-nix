# Match Substrate's Envoy release and Cargo.lock SDK without an OCI base.
{ pkgs, src, buildImage }:
let
  inherit (pkgs) lib;
  version = "1.39.5";
  platform = {
    x86_64-linux = {
      arch = "x86_64";
      sha256 = "2057b6e3c2e18738eee1e42edd35dfbdfc615e873a2d060677ff178c5d1238f5";
    };
    aarch64-linux = {
      arch = "aarch_64";
      sha256 = "7cee1608c96399ed720cdd9fdb4d84d89a7da773b1b3723f3a5c3b7a44d00a2c";
    };
  }.${pkgs.stdenv.hostPlatform.system} or (throw "Substrate Envoy requires x86_64-linux or aarch64-linux");
  # Digests are the upstream release asset digests, not invented FOD hashes:
  # https://api.github.com/repos/envoyproxy/envoy/releases/tags/v1.39.5
  envoy = pkgs.stdenvNoCC.mkDerivation {
    pname = "ate-envoy";
    inherit version;
    src = pkgs.fetchurl {
      url = "https://github.com/envoyproxy/envoy/releases/download/v${version}/envoy-${version}-linux-${platform.arch}";
      inherit (platform) sha256;
    };
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib ];
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      install -D -m 0555 "$src" "$out/bin/envoy"
    '';
    meta = {
      license = lib.licenses.asl20;
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
      platforms = [ "x86_64-linux" "aarch64-linux" ];
    };
  };
  module = pkgs.rustPlatform.buildRustPackage {
    pname = "substrate-envoy-egress-policy";
    version = "0.1.0";
    src = "${src}/cmd/dataplane/envoy/dynamic-modules";
    cargoHash = "sha256-Ss/gAKPStr+XSGEYMCKAsBmHQHGBb0xWuRrXNPoWl4M=";
    nativeBuildInputs = [ pkgs.rustPlatform.bindgenHook ];
    # Both the binary and module use this package set's runtime libraries;
    # unlike an Ubuntu OCI base, their store RUNPATHs must be retained.
    doCheck = true;
  };
  moduleConfig = {
    dynamic_module_config.name = "envoy_substrate_egress_policy";
  };
  checkConfig = pkgs.writeText "envoy-substrate-module-check.json" (builtins.toJSON {
    static_resources.listeners = [ {
      name = "module-check";
      address.socket_address = { address = "127.0.0.1"; port_value = 10000; };
      listener_filters = [ {
        name = "envoy.filters.listener.dynamic_modules";
        typed_config = moduleConfig // {
          "@type" = "type.googleapis.com/envoy.extensions.filters.listener.dynamic_modules.v3.DynamicModuleListenerFilter";
          filter_name = "envoy_substrate_egress_policy";
        };
      } ];
      filter_chains = [ {
        filters = [ {
          name = "envoy.filters.network.http_connection_manager";
          typed_config = {
            "@type" = "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager";
            stat_prefix = "module-check";
            route_config = { name = "empty"; virtual_hosts = [ ]; };
            http_filters = [
              {
                name = "envoy.filters.http.dynamic_modules";
                typed_config = moduleConfig // {
                  "@type" = "type.googleapis.com/envoy.extensions.filters.http.dynamic_modules.v3.DynamicModuleFilter";
                  filter_name = "envoy_substrate_egress_policy_store";
                };
              }
              {
                name = "envoy.filters.http.router";
                typed_config."@type" = "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router";
              }
            ];
          };
        } ];
      } ];
    } ];
  });
  check = pkgs.runCommand "ate-envoy-module-check" { } ''
    export ENVOY_DYNAMIC_MODULES_SEARCH_PATH=${module}/lib
    ${envoy}/bin/envoy --mode validate -c ${checkConfig} > "$out" 2>&1 || {
      cat "$out" >&2
      exit 1
    }
  '';
  root = pkgs.runCommand "ate-envoy-dataplane-root" { inherit check; } ''
    mkdir -p "$out/usr/local/bin" "$out/usr/local/lib" "$out/bin" "$out/etc/ssl/certs"
    ln -s ${envoy}/bin/envoy "$out/usr/local/bin/envoy"
    ln -s ${module}/lib/libenvoy_substrate_egress_policy.so "$out/usr/local/lib/libenvoy_substrate_egress_policy.so"
    for applet in ${pkgs.busybox}/bin/*; do ln -s "$applet" "$out/bin/"; done
    ln -s ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt "$out/etc/ssl/certs/ca-certificates.crt"
  '';
  nixImage = buildImage {
    name = "envoy-dataplane";
    resolvedByNix = true;
    copyToRoot = root;
    config = {
      Entrypoint = [ "/usr/local/bin/envoy" ];
      Cmd = [ "-c" "/etc/envoy/envoy.yaml" ];
      User = "0:0";
      Env = [
        "PATH=/usr/local/bin:/bin"
        "ENVOY_DYNAMIC_MODULES_SEARCH_PATH=/usr/local/lib"
      ];
      ExposedPorts."10000/tcp" = { };
    };
  };
in
{
  inherit envoy module check root nixImage;
}
