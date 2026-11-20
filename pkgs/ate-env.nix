{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule {
  pname = "ate-env";
  # agent-substrate/env has no tag after v0.0.10; this is main at the commit
  # that moved to the Substrate v0.6+ APIs, with the Substrate module bumped
  # to the v1.0.1 release by patch 0002.
  version = "0.0.10-unstable-2026-11-01";

  src = fetchFromGitHub {
    owner = "agent-substrate";
    repo = "env";
    rev = "56424de763f91daa6b6c38f6249bacef1d82e5e1";
    hash = "sha256-hJsBkObIULpyQpcut/a6I9JxhK97wVq8zHsk08w5vgo=";
  };

  patches = [
    ../patches/env/0001-pty-process-streams.patch
    ../patches/env/0002-substrate-v1.0.1.patch
    ../patches/env/0003-free-slot-before-exit.patch
    ../patches/env/0004-router-tls-rotation.patch
    ../patches/env/0005-resume-cut-process-streams.patch
  ];

  vendorHash = "sha256-fjhk1rLJSWpfF/IuHo1bpI9VtTKRGGbUFi1HVyUYfk4=";

  subPackages = [
    "cmd/ate-env"
    "cmd/ate-env-api"
    "cmd/ate-env-guest"
    "guest/process"
    "internal/apiservice"
    "internal/ate"
    "clients/go"
  ];

  env.CGO_ENABLED = 0;
  ldflags = [
    "-s"
    "-w"
  ];

  meta = {
    description = "Agent Substrate env with PTY streams, TLS rotation and stream recovery";
    homepage = "https://github.com/agent-substrate/env";
    license = lib.licenses.asl20;
    mainProgram = "ate-env";
  };
}
