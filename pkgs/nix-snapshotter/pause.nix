# Kubernetes' own PID-1/pause program, not a registry carrier image.
{ pkgs, buildImage }:
let
  pause = pkgs.kubernetes.pause;
in
buildImage {
  name = "ate-pause";
  resolvedByNix = true;
  copyToRoot = pause;
  config = {
    Entrypoint = [ "/bin/pause" ];
    User = "65535:65535";
  };
}
