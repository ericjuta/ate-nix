# Jaeger 2.22.0, which Agent Substrate's kind overlay runs as
# jaegertracing/jaeger:2.22.0@sha256:836b967b5abcf1f7758066aa6b348619267a2f1459f72d472840570f9bd88a17
# and nixpkgs does not package. Built from the tag the way upstream builds that image's
# /cmd/jaeger/jaeger-linux:
# - scripts/makefiles/BuildBinaries.mk `build-jaeger`: `CGO_ENABLED=0 go build -trimpath` of
#   ./cmd/jaeger with BUILD_INFO's three `-X` ldflags into internal/version, nothing else (no tags:
#   GO_TAGS is set nowhere; no `-s -w`, no strip; GOBUILD's `installsuffix=cgo` is an environment
#   assignment Go ignores). cmd/jaeger/Dockerfile copies jaeger-linux-$TARGETARCH to
#   /cmd/jaeger/jaeger-linux.
# - `build-ui`: the UI build output copied into
#   cmd/jaeger/internal/extension/jaegerquery/internal/ui/actual, every file but .gitignore gzipped
#   with `gzip --no-name`. That package embeds `actual/*` unconditionally (assets.go) and serves it
#   decompressed through internal/gzipfs once actual/index.html.gz exists; without it the binary
#   serves placeholder/index.html. The target's closing `touch` of index.html.gz is moot: embed.FS
#   records no modification times.
# - scripts/build/rebuild-ui.sh, which produces that UI build output: when the jaeger-ui
#   submodule's HEAD is exactly a vX.Y.Z tag, it extracts packages/jaeger-ui/build/ from that
#   jaeger-ui release's assets.tar.gz instead of building with pnpm. v2.22.0 pins jaeger-ui at
#   f538c58b20fab5ba3973269dcb3f458e84605da3, which is the jaeger-ui tag v2.22.0, so the release
#   build took the tarball.
#
# Where this differs from the published binary (go1.27.1 by its `go version -m`): the pin's Go
# 1.27.3 (go.mod asks for `go 1.27.0` and names no toolchain), modules vendored under a fixed hash
# instead of read from the module cache, and buildGoModule's empty build ID (`-buildid=`). The
# rest of `go version -m` matches: -trimpath=true, CGO_ENABLED=0, GOAMD64=v1 and the same 329
# module versions, without the vcs.* stamps and the main module's pseudo-version (the fetched
# tree has no .git, so `(devel)`) and module sums (vendored).
{ pkgs }:

let
  inherit (pkgs) lib;

  version = "2.22.0";
  # The Makefile's GIT_SHA (`git rev-parse HEAD`) and DATE (`TZ=UTC0 git show --quiet
  # --date='format-local:%Y-%m-%dT%H:%M:%SZ' --format=%cd`, the committer date) at the tag, a
  # lightweight tag on the release commit; GIT_CLOSEST_TAG (scripts/utils/compute-version.sh) is
  # v2.22.0. The published binary's `version` prints exactly these three.
  commit = "462bb49fcff9af4be9556bf0206d07f5171bd8d7";
  commitDate = "2026-10-06T11:44:34Z";
  uiVersion = "2.22.0";
  versionPackage = "github.com/jaegertracing/jaeger/internal/version";

  # Without submodules: idl/ only feeds code generation, whose output is committed, and the
  # jaeger-ui/ build output comes from `uiAssets`.
  src = pkgs.fetchFromGitHub {
    owner = "jaegertracing";
    repo = "jaeger";
    rev = "v${version}";
    hash = "sha256-amzjPBeMAUwzrN1jtPM1NNoeOw4mnwrQZAZWhyzv2QY=";
  };

  # The tarball scripts/build/rebuild-ui.sh downloads for the pinned jaeger-ui tag. The release
  # publishes no digest; this hash pins the bytes first fetched.
  uiAssets = pkgs.fetchurl {
    url = "https://github.com/jaegertracing/jaeger-ui/releases/download/v${uiVersion}/assets.tar.gz";
    hash = "sha256-GNneuKrxm6ml+XCUF/iufKcdmZN+poFAqGbZ1wPaPWo=";
  };

  jaeger = pkgs.buildGo127Module {
    pname = "jaeger";
    inherit version src;
    vendorHash = "sha256-7cLRgjEl4Bs58h2DxI4cs2U2PWxvjBDpQWtmiAFQV6M=";
    subPackages = [ "cmd/jaeger" ];
    # buildGoModule adds `-trimpath` to GOFLAGS and `-buildid=` to these.
    ldflags = [
      "-X ${versionPackage}.commitSHA=${commit}"
      "-X ${versionPackage}.latestVersion=v${version}"
      "-X ${versionPackage}.date=${commitDate}"
    ];
    env.CGO_ENABLED = 0;
    # Makefile `build-ui` fed with rebuild-ui.sh's release output. postConfigure, not preBuild:
    # the vendored-modules derivation inherits preBuild and has no use for the UI.
    postConfigure = ''
      mkdir "$TMPDIR/jaeger-ui"
      tar -xzf ${uiAssets} -C "$TMPDIR/jaeger-ui" packages/jaeger-ui/build/
      ui=cmd/jaeger/internal/extension/jaegerquery/internal/ui/actual
      # As upstream's `rm -rf .../actual/*`: the glob spares actual/.gitignore.
      rm -rf "$ui"/*
      cp -r "$TMPDIR"/jaeger-ui/packages/jaeger-ui/build/* "$ui"/
      find "$ui" -type f | grep -v .gitignore | xargs gzip --no-name
      test -f "$ui/index.html.gz"
    '';
    # cmd/jaeger has no tests of its own, and upstream's image test
    # (cmd/jaeger/internal/all_in_one_test.go) probes an already running binary and skips unless
    # TEST_MODE=integration; `check` runs the binary instead.
    doCheck = false;
    # Upstream's binary keeps its symbol table and DWARF.
    dontStrip = true;
    postInstall = ''
      mv "$out/bin/jaeger" "$out/bin/jaeger-linux"
    '';
    # Static (CGO_ENABLED=0) and -trimpath, so no libc and no Go toolchain. What remains is the
    # data nixpkgs' Go patches into the standard library: tzdata and mailcap's mime.types, read
    # ahead of /usr/share/zoneinfo and /etc/mime.types, and iana-etc, read instead of
    # /etc/services and /etc/protocols. So the closure brings what upstream's image gets from its
    # alpine base (services, protocols) and the mime.types it copies in (for the UI's content
    # types); tzdata is extra.
    allowedReferences = [
      pkgs.tzdata
      pkgs.mailcap
      pkgs.iana-etc
    ];
    meta = {
      mainProgram = "jaeger-linux";
      # The upstream binary name says linux; the image is the only consumer.
      platforms = lib.platforms.linux;
    };
  };

  # cmd/jaeger/sampling-strategies.json, which the Dockerfile copies to
  # /cmd/jaeger/sampling-strategies.json. The embedded configuration does not read it (its
  # remote_sampling file path is empty, so every service samples at
  # default_sampling_probability 1). A store file of its own, so an image holding it does not
  # hold the whole source tree.
  samplingStrategies =
    pkgs.runCommand "jaeger-${version}-sampling-strategies.json" { allowedReferences = [ ]; } ''
      cp ${src}/cmd/jaeger/sampling-strategies.json "$out"
    '';

  # The ports `check` exercises, each listening on the wildcard address; third-party-images.nix
  # requires every container port the manifest names to be one of them.
  checkedPorts = [
    4317
    4318
    5778
    13133
    16686
  ];

  # Runs the binary in the build sandbox the way the image does: no arguments, so the embedded
  # cmd/jaeger/internal/all-in-one.yaml (memory storage), with the image's JAEGER_LISTEN_HOST. It
  # first validates that configuration with the collector's `validate` subcommand (every
  # component it names is built in, every key is known), then asserts what the cluster relies on:
  # the ldflags build info; healthcheckv2 on 13133; every port in `checkedPorts` listening on the
  # wildcard address (the Service routes to the pod IP; JAEGER_LISTEN_HOST's default, localhost,
  # would leave OTLP on 4317 and 4318 unreachable); the embedded UI on 16686 (upstream's image
  # test, all_in_one_test.go checkWebUI: the jaeger-ui root element and the favicon it
  # references, plus the title the placeholder lacks); OTLP gRPC on 4317 answering
  # TraceService/Export with grpc-status 0 (otel-collector's export path); a span exported over
  # OTLP HTTP on 4318 read back through the query API on 16686 (the path from the collector to the
  # UI); and the default sampling strategy on 5778 (verifyGetSamplingStrategyAPI). Every wait is
  # bounded. $out keeps the evidence lines.
  check =
    pkgs.runCommand "jaeger-${version}-check"
      {
        nativeBuildInputs = [
          pkgs.curl
          pkgs.jq
        ];
      }
      ''
        set -euo pipefail
        bin=${lib.getExe jaeger}
        evidence() { echo "jaeger-check: $*" | tee -a "$out"; }
        fail() {
          echo "jaeger-check: FAIL: $*" >&2
          if [ -f jaeger.log ]; then cat jaeger.log >&2; fi
          exit 1
        }

        build_info=$("$bin" version 2>/dev/null)
        for want in \
          '"gitCommit":"${commit}"' \
          '"gitVersion":"v${version}"' \
          '"buildDate":"${commitDate}"'; do
          grep -qF "$want" <<<"$build_info" || fail "version: $want missing from $build_info"
        done
        evidence "version $build_info"

        # The image's environment.
        export JAEGER_LISTEN_HOST=0.0.0.0

        "$bin" validate --config=${src}/cmd/jaeger/internal/all-in-one.yaml >validate.log 2>&1 ||
          { cat validate.log >&2; fail "validate cmd/jaeger/internal/all-in-one.yaml"; }
        evidence "validate cmd/jaeger/internal/all-in-one.yaml: ok"

        "$bin" >jaeger.log 2>&1 &
        pid=$!
        trap 'kill -KILL "$pid" 2>/dev/null || true' EXIT

        # healthcheckv2 answers 200 once every component reports OK.
        health=
        for _ in $(seq 120); do
          if health=$(curl -fsS --max-time 1 http://127.0.0.1:13133/status 2>/dev/null); then break; fi
          health=
          kill -0 "$pid" 2>/dev/null || fail "jaeger exited during startup"
          sleep 0.5
        done
        [ -n "$health" ] || fail "healthcheckv2 :13133/status not healthy within 60 s"
        jq -e '.healthy == true' <<<"$health" >/dev/null || fail "healthcheckv2: $health"
        evidence "healthcheckv2 :13133/status $(jq -c '{healthy, status}' <<<"$health")"

        grep -qF "No '--config' flags detected, using default All-in-One configuration" jaeger.log ||
          fail "the binary did not fall back to its embedded all-in-one configuration"
        evidence "config: the embedded all-in-one configuration"

        # A LISTEN socket (st 0A) on the port with an all-zero local address: 0.0.0.0, or ::
        # (Go listens dual-stack for 0.0.0.0 where IPv6 is available).
        listens_on_wildcard() {
          awk -v port="$(printf '%04X' "$1")" '
            $4 == "0A" { split($2, a, ":"); if (a[2] == port && a[1] ~ /^0+$/) found = 1 }
            END { exit !found }' /proc/net/tcp /proc/net/tcp6
        }
        for port in ${toString checkedPorts}; do
          listens_on_wildcard "$port" || fail "nothing listens on the wildcard address at :$port"
        done
        evidence "${toString checkedPorts} listen on the wildcard address"

        index=$(curl -fsS --max-time 5 http://127.0.0.1:16686/) || fail "GET :16686/"
        grep -qF '<title>Jaeger UI</title>' <<<"$index" ||
          fail "UI index lacks the Jaeger UI title (placeholder page?): $index"
        grep -qF '<div id="jaeger-ui-root"></div>' <<<"$index" ||
          fail "UI index lacks the jaeger-ui root element: $index"
        evidence "ui :16686/ $(grep -oE '<title>[^<]*</title>|<div id="jaeger-ui-root"></div>|static/index-[A-Za-z0-9_-]+\.js' <<<"$index" | tr '\n' ' ')"
        favicon=$(grep -oE '<link rel="shortcut icon"[^<]+href="[^"]+"' <<<"$index" | sed -E 's/.*href="([^"]+)"/\1/') ||
          fail "UI index references no favicon: $index"
        favicon_get=$(curl -fsS --max-time 5 -o /dev/null -w '%{http_code} %{content_type} %{size_download} bytes' \
          "http://127.0.0.1:16686/$favicon") || fail "GET the UI favicon $favicon"
        evidence "ui :16686/$favicon $favicon_get"

        # One uncompressed gRPC message frame of length 0: an empty ExportTraceServiceRequest.
        head -c 5 /dev/zero >empty-export
        grpc=$(curl -sS --max-time 5 --http2-prior-knowledge -o /dev/null -D - \
          -H 'content-type: application/grpc' -H 'te: trailers' --data-binary @empty-export \
          http://127.0.0.1:4317/opentelemetry.proto.collector.trace.v1.TraceService/Export) ||
          fail "OTLP gRPC Export on :4317"
        grpc=$(tr -d '\r' <<<"$grpc")
        grep -qi '^grpc-status: 0$' <<<"$grpc" || fail "OTLP gRPC Export on :4317: $grpc"
        evidence "otlp grpc :4317 TraceService/Export $(grep -iE '^(HTTP/2|content-type|grpc-status)' <<<"$grpc" | tr '\n' ' ')"

        trace_id=5b8efff798038103d269b633813fc60c
        now=$(date +%s%N)
        span=$(jq -cn --arg trace "$trace_id" --arg start "$now" --arg end "$((now + 1000000))" '
          { resourceSpans: [ {
              resource: { attributes: [ { key: "service.name", value: { stringValue: "substrate-jaeger-check" } } ] },
              scopeSpans: [ { spans: [ {
                traceId: $trace, spanId: "eee19b7ec3c1b174", name: "check", kind: 1,
                startTimeUnixNano: $start, endTimeUnixNano: $end } ] } ] } ] }')
        otlp_http=$(curl -fsS --max-time 5 -H 'content-type: application/json' -d "$span" \
          http://127.0.0.1:4318/v1/traces) || fail "OTLP HTTP POST :4318/v1/traces"
        evidence "otlp http :4318/v1/traces $otlp_http"
        trace=
        for _ in $(seq 40); do
          if trace=$(curl -fsS --max-time 1 "http://127.0.0.1:16686/api/traces/$trace_id" 2>/dev/null) &&
            jq -e '.data[0].spans | length == 1' <<<"$trace" >/dev/null 2>&1; then
            break
          fi
          trace=
          sleep 0.5
        done
        [ -n "$trace" ] || fail "span exported to :4318 not readable at :16686/api/traces/$trace_id within 20 s"
        evidence "query :16686/api/traces/$trace_id $(jq -c '.data[0] | {traceID, spans: [.spans[] | {operationName}], services: [.processes[].serviceName]}' <<<"$trace")"

        sampling=$(curl -fsS --max-time 5 'http://127.0.0.1:5778/api/sampling?service=whatever') ||
          fail "GET :5778/api/sampling"
        jq -e '.probabilisticSampling.samplingRate == 1' <<<"$sampling" >/dev/null ||
          fail "sampling strategy: $sampling"
        evidence "sampling :5778/api/sampling $(jq -c . <<<"$sampling")"

        # Where each server says it listens: the console log's message and its listen-address
        # fields.
        awk -F '\t' 'NF >= 5 { print $4 "\t" $5 }' jaeger.log |
          while IFS=$'\t' read -r msg fields; do
            at=$(jq -c 'with_entries(select(.key | test("^(endpoint|addr|http_addr|grpc_addr)$")))' \
              <<<"$fields" 2>/dev/null) || continue
            if [ "$at" != "{}" ]; then evidence "log $msg $at"; fi
          done

        kill -TERM "$pid"
        for _ in $(seq 60); do
          kill -0 "$pid" 2>/dev/null || break
          sleep 0.5
        done
        if kill -0 "$pid" 2>/dev/null; then
          evidence "SIGTERM: still running after 30 s, sending SIGKILL"
          kill -KILL "$pid"
        fi
        status=0
        wait "$pid" || status=$?
        trap - EXIT
        evidence "SIGTERM: exited $status"
      '';
in
{
  inherit jaeger samplingStrategies checkedPorts check;
}
