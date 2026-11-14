# All non-component images required by the bundled local install. Exact manifest
# reference checks make source-pin changes fail rather than fall back to a registry.
# Writable directories are local Nix-built base layers, not fetched OCI bases.
# Deliberately omit image Volumes: pod volumes are explicit in the manifests.
{ pkgs, src, buildImage }:

let
  inherit (pkgs) lib;

  pkgsLinux = pkgs;

  postgresql = pkgsLinux.postgresql_18;
  # This pinned collector's Swiss map dependency explicitly supports Go <1.27.
  # Keep its supported runtime ABI rather than bypassing that build constraint.
  otelcolContrib = (pkgsLinux.opentelemetry-collector-releases.override {
    buildGoModule = pkgsLinux.buildGo126Module;
    go = pkgsLinux.go_1_26;
  }).otelcol-contrib;
  jaeger = import ./jaeger.nix { pkgs = pkgsLinux; };

  # Alpine's default PATH, which every upstream image here sets.
  path = "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

  # A build input of each image's root, so a failure stops the image: the patched manifest must
  # still name `upstream` (a Substrate update that pins a new digest would otherwise leave the map
  # entry matching nothing, and the install would pull the new image from its registry), and
  # `validate` runs with $manifest set. Never part of the image's closure.
  check = name: entry:
    pkgsLinux.runCommand "substrate-${name}-image-check" { nativeBuildInputs = [ pkgsLinux.yq-go ]; } ''
      manifest=${src}/${entry.manifest}
      if ! grep -qF -- ${lib.escapeShellArg entry.upstream} "$manifest"; then
        echo "${entry.manifest} no longer names ${entry.upstream}: update third-party-images.nix" >&2
        exit 1
      fi
      ${entry.validate or ""}
      touch "$out"
    '';

  # Directories with the owners, modes and links upstream's image gives them, which copyToRoot
  # cannot express (its directories are root-owned 0755): a base layer made under fakeroot,
  # uncompressed as buildImage's fromImage takes it. The image's root must not name these paths,
  # or its layer, applied on top, would reset them.
  baseLayer = name: commands:
    pkgsLinux.dockerTools.buildLayeredImage {
      name = "substrate-${name}-base";
      tag = "base";
      compressor = "none";
      fakeRootCommands = commands;
    };

  # Busybox's applets in /bin, as on Alpine and the busybox base, where the upstream images'
  # shells and tools come from.
  busyboxBin = ''
    mkdir -p "$out/bin"
    for applet in ${pkgsLinux.busybox}/bin/*; do
      ln -s "$applet" "$out/bin/"
    done
  '';

  # /etc/passwd, /etc/group and the name service order for the users an image knows.
  etcUsers = users: ''
    mkdir -p "$out/etc"
    printf '%s\n' ${lib.escapeShellArgs (map (u: "${u.name}:x:${toString u.uid}:${toString u.uid}:${u.name}:${u.home}:/bin/sh") users)} > "$out/etc/passwd"
    printf '%s\n' ${lib.escapeShellArgs (map (u: "${u.name}:x:${toString u.uid}:") users)} > "$out/etc/group"
    printf 'passwd: files\ngroup: files\nshadow: files\nhosts: files dns\n' > "$out/etc/nsswitch.conf"
  '';
  root = { name = "root"; uid = 0; home = "/root"; };

  caCertificates = ''
    mkdir -p "$out/etc/ssl/certs"
    ln -s ${pkgsLinux.cacert}/etc/ssl/certs/ca-bundle.crt "$out/etc/ssl/certs/ca-certificates.crt"
  '';

  # A path into a source tree, failing the build if a release moved it (ln -s would not).
  existing = file: ''
    test -e ${file} || { echo "${file} is missing" >&2; exit 1; }
  '';

  # The database's locale. Upstream initialises with LANG=en_US.utf8 under musl, whose collation
  # is byte order and whose character classes are Unicode's, and the databases record
  # datcollate/datctype en_US.utf8 (libc provider): every connection setlocale()s that name. glibc's
  # C locale source has the same semantics (codepoint_collation, i18n_ctype); compiled under that
  # name, it keeps the text indexes musl built in order. glibc's own en_US.UTF-8 collates
  # differently and would corrupt them.
  postgresLocale = pkgsLinux.runCommand "postgres-locale-en_US.utf8" { nativeBuildInputs = [ pkgsLinux.glibc.bin ]; } ''
    tar -xJf ${pkgsLinux.glibc.src} --strip-components=1 --wildcards '*/localedata/locales' '*/localedata/charmaps/UTF-8'
    mkdir -p "$out"
    I18NPATH="$PWD/localedata" localedef --no-archive -i localedata/locales/C -f localedata/charmaps/UTF-8 "$out/en_US.utf8"
    test -f "$out/en_US.utf8/LC_COLLATE"
  '';

  # The RustFS server binary alone: nixpkgs' output also holds rustfs-cli, as large again
  # (340 MB), which upstream's image does not ship and nothing here runs.
  rustfsServer = pkgsLinux.runCommand "rustfs-server-${pkgsLinux.rustfs.version}" { } ''
    install -D -m 0555 ${pkgsLinux.rustfs}/bin/rustfs "$out/bin/rustfs"
  '';

  # docker-library/postgres at the commit that built the pinned image (2026-07-07, PostgreSQL 18.4
  # on Alpine 3.24): byte-identical to the image's /usr/local/bin copies.
  dockerLibraryPostgres = "https://raw.githubusercontent.com/docker-library/postgres/4f9ced003ba58a854656ba150d146243d27ae3ac/18/alpine3.24";
  postgresEntrypoint = pkgsLinux.fetchurl {
    url = "${dockerLibraryPostgres}/docker-entrypoint.sh";
    hash = "sha256-nEQCma4EoKedVbi/AzBwNtiQpAl50vtpgHPJBQ1LIKU=";
  };
  postgresEnsureInitdb = pkgsLinux.fetchurl {
    url = "${dockerLibraryPostgres}/docker-ensure-initdb.sh";
    hash = "sha256-kireayOjEuZQIzSbNuhzdSsV/ziuTArkYddEUeEE8xI=";
  };

  # Each image: the reference it replaces, the manifest that names it, and the image, built with
  # its check as a root input.
  images = {
    # PostgreSQL 18.6 for 18.4: a minor release of the same major, which reads the data directory
    # as is.
    #
    # The entrypoint (bash, as root) creates and chowns PGDATA and the socket directory and
    # re-executes itself as postgres through gosu; on an empty PGDATA it runs initdb and a
    # socket-only temporary server, then execs postgres with the manifest's -c config_file. The
    # manifest's sidecar, postStart and probes call /bin/sh, nc -z, pg_isready, psql, createdb,
    # grep, sleep, sha256sum and date, and rely on server and clients agreeing on the socket
    # directory unconfigured. Upstream compiles it as /var/run/postgresql, nixpkgs as
    # /run/postgresql: the same directory once /var/run is Alpine's link to ../run.
    postgres = {
      upstream = "postgres:18-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15";
      manifest = "manifests/ate-install/postgres/postgres.yaml";
      image = rootCheck: buildImage {
        name = "postgres";
        resolvedByNix = true;
        fromImage = baseLayer "postgres" ''
          mkdir -p tmp run/postgresql var/lib/postgresql
          ln -s ../run var/run
          chown 70:70 run/postgresql var/lib/postgresql
          chmod 1777 tmp var/lib/postgresql
          chmod 3777 run/postgresql
        '';
        copyToRoot = pkgsLinux.runCommand "substrate-postgres-root" { inherit rootCheck; } (''
          ${busyboxBin}
          ln -sf ${pkgsLinux.bash}/bin/bash "$out/bin/bash"
          mkdir -p "$out/usr/bin" "$out/usr/local/bin" "$out/usr/local/share/postgresql" \
            "$out/usr/lib/locale" "$out/docker-entrypoint-initdb.d"
          # The entrypoint's interpreter is `/usr/bin/env bash`.
          ln -s ${pkgsLinux.busybox}/bin/env "$out/usr/bin/env"
          ln -s ${pkgsLinux.glibc.getent}/bin/getent "$out/usr/bin/getent"
          # PostgreSQL finds its share and module directories relative to the path it was started
          # by, links unresolved (nixpkgs' relative-to-symlinks patch): upstream's
          # /usr/local/{bin,share/postgresql,lib}.
          for program in ${postgresql}/bin/*; do
            ln -s "$program" "$out/usr/local/bin/"
          done
          ln -s ${postgresql}/lib "$out/usr/local/lib"
          for entry in ${postgresql}/share/postgresql/*; do
            ln -s "$entry" "$out/usr/local/share/postgresql/"
          done
          # As upstream's Dockerfile: a new cluster listens on every address.
          rm "$out/usr/local/share/postgresql/postgresql.conf.sample"
          sed -r "s!^#?(listen_addresses)\s*=\s*\S+.*!\1 = '*'!" \
            ${postgresql}/share/postgresql/postgresql.conf.sample \
            > "$out/usr/local/share/postgresql/postgresql.conf.sample"
          grep -F "listen_addresses = '*'" "$out/usr/local/share/postgresql/postgresql.conf.sample"
          install -m 0755 ${postgresEntrypoint} "$out/usr/local/bin/docker-entrypoint.sh"
          install -m 0755 ${postgresEnsureInitdb} "$out/usr/local/bin/docker-ensure-initdb.sh"
          ln -s docker-ensure-initdb.sh "$out/usr/local/bin/docker-enforce-initdb.sh"
          ln -s ${pkgsLinux.gosu}/bin/gosu "$out/usr/local/bin/gosu"
          ln -s ${postgresLocale}/en_US.utf8 "$out/usr/lib/locale/en_US.utf8"
        '' + etcUsers [
          root
          { name = "postgres"; uid = 70; home = "/var/lib/postgresql"; }
          { name = "nobody"; uid = 65534; home = "/"; }
        ]);
        config = {
          Entrypoint = [ "docker-entrypoint.sh" ];
          Cmd = [ "postgres" ];
          Env = [
            path
            "LANG=en_US.utf8"
            # Where glibc finds the locale above.
            "LOCPATH=/usr/lib/locale"
            "PG_MAJOR=18"
            "PG_VERSION=${postgresql.version}"
            "PGDATA=/var/lib/postgresql/18/docker"
          ];
          ExposedPorts."5432/tcp" = { };
          WorkingDir = "/";
          StopSignal = "SIGINT";
        };
      };
    };

    # RustFS 1.0.3, the upstream image's release, built by nixpkgs from source where upstream's
    # Dockerfile installs the release's musl binary; its entrypoint comes from the same tag,
    # byte-identical to the image's /entrypoint.sh.
    #
    # The entrypoint (busybox sh, as rustfs: the manifest's runAsUser 10001) normalises the command
    # to /usr/bin/rustfs, checks the credentials it is given, creates missing data and log
    # directories and appends the data volumes.
    rustfs = {
      upstream = "rustfs/rustfs:1.0.3@sha256:9ca9559533b537d10482fe923288b676ad08f92a7069d9a17327fbae3cab688b";
      manifest = "manifests/ate-install/kind/rustfs.yaml";
      image = rootCheck: buildImage {
        name = "rustfs";
        resolvedByNix = true;
        fromImage = baseLayer "rustfs" ''
          mkdir -p tmp data/.rustfs/events data/.rustfs/audit logs opt/rustfs
          ln -s /data/.rustfs/events opt/rustfs/events
          ln -s /data/.rustfs/audit opt/rustfs/audit
          chown -R 10001:10001 data logs
          chmod 0750 data logs
          chmod 1777 tmp
        '';
        copyToRoot = pkgsLinux.runCommand "substrate-rustfs-root" { inherit rootCheck; } (''
          ${busyboxBin}
          mkdir -p "$out/usr/bin" "$out/usr/share"
          ln -s ${rustfsServer}/bin/rustfs "$out/usr/bin/rustfs"
          install -m 0755 ${pkgsLinux.rustfs.src}/entrypoint.sh "$out/entrypoint.sh"
          ln -s ${pkgsLinux.tzdata}/share/zoneinfo "$out/usr/share/zoneinfo"
          ${caCertificates}
        '' + etcUsers [
          root
          { name = "rustfs"; uid = 10001; home = "/home/rustfs"; }
        ]);
        config = {
          User = "rustfs";
          Entrypoint = [ "/entrypoint.sh" ];
          Cmd = [ "rustfs" ];
          Env = [
            path
            "RUSTFS_CONSOLE_CORS_ALLOWED_ORIGINS=*"
            "RUSTFS_VOLUMES=/data"
            "RUSTFS_OBS_LOGGER_LEVEL=warn"
            "RUSTFS_OBS_LOG_DIRECTORY=/logs"
            "RUSTFS_OBS_ENVIRONMENT=production"
          ];
          ExposedPorts = {
            "9000/tcp" = { };
            "9001/tcp" = { };
          };
          WorkingDir = "/";
        };
      };
    };

    # AWS CLI 2.36.31 for 2.38.5: the bucket Job, a /bin/sh script run as root, calls only
    # `aws s3api head-bucket` and `create-bucket` against AWS_ENDPOINT_URL, besides seq and sleep.
    aws-cli = {
      upstream = "amazon/aws-cli:2.38.5@sha256:c8156a0e74e13929a42d7e60f0d4e14e7d28d980cd21822505d4bff80e5460c1";
      manifest = "manifests/ate-install/kind/rustfs.yaml";
      image = rootCheck: buildImage {
        name = "aws-cli";
        resolvedByNix = true;
        fromImage = baseLayer "aws-cli" ''
          mkdir -p tmp root
          chmod 1777 tmp
          chmod 0700 root
        '';
        copyToRoot = pkgsLinux.runCommand "substrate-aws-cli-root" { inherit rootCheck; } (''
          ${busyboxBin}
          mkdir -p "$out/usr/local/bin" "$out/aws"
          ln -s ${pkgsLinux.awscli2}/bin/aws "$out/usr/local/bin/aws"
          ${caCertificates}
        '' + etcUsers [ root ]);
        config = {
          Entrypoint = [ "/usr/local/bin/aws" ];
          Env = [ path ];
          WorkingDir = "/aws";
        };
      };
    };

    # Nixpkgs supplies the binary; validate the actual manifest configuration.
    prometheus = {
      upstream = "prom/prometheus:v3.15.1@sha256:fa3302279710be2f21a8301ec17a8b4f2301fd829bd113839b3b6b02b6f191a2";
      manifest = "manifests/ate-install/kind/prometheus.yaml";
      validate = ''
        yq 'select(.kind == "ConfigMap" and .metadata.name == "prometheus-config") | .data."prometheus.yml"' \
          "$manifest" > prometheus.yml
        ${pkgsLinux.prometheus.cli}/bin/promtool check config prometheus.yml
      '';
      image = rootCheck: buildImage {
        name = "prometheus";
        resolvedByNix = true;
        fromImage = baseLayer "prometheus" ''
          mkdir -p tmp prometheus
          chown 65534:65534 prometheus
          chmod 0775 prometheus
          chmod 1777 tmp
        '';
        copyToRoot = pkgsLinux.runCommand "substrate-prometheus-root" { inherit rootCheck; } (''
          ${busyboxBin}
          mkdir -p "$out/etc/prometheus"
          ln -s ${pkgsLinux.prometheus}/bin/prometheus "$out/bin/prometheus"
          ln -s ${pkgsLinux.prometheus.cli}/bin/promtool "$out/bin/promtool"
          ${existing "${pkgsLinux.prometheus.src}/documentation/examples/prometheus.yml"}
          ln -s ${pkgsLinux.prometheus.src}/documentation/examples/prometheus.yml "$out/etc/prometheus/prometheus.yml"
        '' + etcUsers [
          root
          { name = "nobody"; uid = 65534; home = "/home"; }
        ]);
        config = {
          User = "nobody";
          Entrypoint = [ "/bin/prometheus" ];
          Cmd = [
            "--config.file=/etc/prometheus/prometheus.yml"
            "--storage.tsdb.path=/prometheus"
          ];
          Env = [ path ];
          ExposedPorts."9090/tcp" = { };
          WorkingDir = "/prometheus";
        };
      };
    };

    # Validate every collector component/key the pinned manifest requires.
    otelcol-contrib = {
      upstream = "otel/opentelemetry-collector-contrib:0.163.2@sha256:7f22d2a6748110ffb6a59bc0df448bccbf501cdb667d610ede4c61d3863d5849";
      manifest = "manifests/ate-install/kind/otel-collector.yaml";
      validate = ''
        yq 'select(.kind == "ConfigMap" and .metadata.name == "opentelemetry-collector-config") | .data."otel-collector-config.yaml"' \
          "$manifest" > config.yaml
        ${otelcolContrib}/bin/otelcol-contrib validate --config=config.yaml
      '';
      image = rootCheck: buildImage {
        name = "opentelemetry-collector-contrib";
        resolvedByNix = true;
        copyToRoot = pkgsLinux.runCommand "substrate-otelcol-contrib-root" { inherit rootCheck; } ''
          mkdir -p "$out/etc/otelcol-contrib"
          ln -s ${otelcolContrib}/bin/otelcol-contrib "$out/otelcol-contrib"
          ${existing "${otelcolContrib.releasesSrc}/distributions/otelcol-contrib/config.yaml"}
          ln -s ${otelcolContrib.releasesSrc}/distributions/otelcol-contrib/config.yaml "$out/etc/otelcol-contrib/config.yaml"
          ${caCertificates}
        '';
        config = {
          User = "10001:10001";
          Entrypoint = [ "/otelcol-contrib" ];
          Cmd = [
            "--config"
            "/etc/otelcol-contrib/config.yaml"
          ];
          Env = [ path ];
          ExposedPorts = {
            "4317/tcp" = { };
            "4318/tcp" = { };
            "55679/tcp" = { };
          };
          WorkingDir = "/";
        };
      };
    };

    # Jaeger 2.22.0, built from source (jaeger.nix; nixpkgs has no Jaeger): the collector-based
    # Jaeger v2, run without arguments, so with its embedded all-in-one configuration (memory
    # storage, the embedded UI) and the image's JAEGER_LISTEN_HOST=0.0.0.0, which binds OTLP to
    # every address instead of localhost. jaeger.nix's check validates that configuration, runs it
    # and exercises the health, OTLP, query/UI and sampling ports. The manifest must keep running
    # the image so: no command or arguments, and only container ports the check exercised.
    jaeger = {
      upstream = "jaegertracing/jaeger:2.22.0@sha256:836b967b5abcf1f7758066aa6b348619267a2f1459f72d472840570f9bd88a17";
      manifest = "manifests/ate-install/kind/otel-collector.yaml";
      validate = ''
        test -e ${jaeger.check}
        yq -o=json 'select(.kind == "Deployment" and .metadata.name == "jaeger") | .spec.template.spec.containers[] | select(.name == "jaeger")' \
          "$manifest" > container.json
        if [ ! -s container.json ]; then
          echo "$manifest has no jaeger container in the jaeger Deployment" >&2
          exit 1
        fi
        if [ "$(yq '[.command, .args] | map(select(. != null)) | length' container.json)" != 0 ]; then
          echo "the jaeger container must run the image's entrypoint without command or args" >&2
          exit 1
        fi
        for port in $(yq '.ports[].containerPort' container.json); do
          case " ${toString jaeger.checkedPorts} " in
            *" $port "*) ;;
            *) echo "the jaeger container names port $port, which jaeger.nix's check does not exercise" >&2; exit 1 ;;
          esac
        done
      '';
      image = rootCheck: buildImage {
        name = "jaeger";
        resolvedByNix = true;
        fromImage = baseLayer "jaeger" ''
          mkdir -p tmp
          chmod 1777 tmp
        '';
        copyToRoot = pkgsLinux.runCommand "substrate-jaeger-root" { inherit rootCheck; } ''
          mkdir -p "$out/cmd/jaeger" "$out/etc"
          ln -s ${jaeger.jaeger}/bin/jaeger-linux "$out/cmd/jaeger/jaeger-linux"
          ln -s ${jaeger.samplingStrategies} "$out/cmd/jaeger/sampling-strategies.json"
          ln -s ${pkgsLinux.mailcap}/etc/mime.types "$out/etc/mime.types"
          ${caCertificates}
        '';
        config = {
          User = "10001";
          Entrypoint = [ "/cmd/jaeger/jaeger-linux" ];
          Env = [
            path
            "JAEGER_LISTEN_HOST=0.0.0.0"
          ];
          ExposedPorts = lib.genAttrs [
            "4317/tcp"
            "4318/tcp"
            "5778/tcp"
            "5779/tcp"
            "9411/tcp"
            "13132/tcp"
            "13133/tcp"
            "14250/tcp"
            "14268/tcp"
            "16686/tcp"
          ] (_: { });
          WorkingDir = "/";
        };
      };
    };
  };
in
{
  # name -> nix-snapshotter image
  nixImages = lib.mapAttrs (name: entry: entry.image (check name entry)) images;
  # name -> the upstream reference its image replaces
  references = lib.mapAttrs (_: entry: entry.upstream) images;
}
