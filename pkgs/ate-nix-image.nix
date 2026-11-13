# Builds the root store path of a Nix image for Agent Substrate: the paths
# merged into one tree, plus the optional image config. Reference the result
# from an ActorTemplate as `image: nix:${result}`.
{
  lib,
  buildEnv,
  writeTextDir,
}:

{
  name,
  # Packages whose bin/, etc/, lib/, ... make up the actor's root.
  paths,
  # OCI image config fields: Entrypoint, Cmd, Env, WorkingDir, User.
  config ? { },
}:

buildEnv {
  inherit name;
  paths =
    paths
    ++ lib.optional (config != { }) (writeTextDir "ate-image-config.json" (builtins.toJSON config));
}
