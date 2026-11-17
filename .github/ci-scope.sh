#!/usr/bin/env bash
# Decides whether this run has to build anything. Writes "nix=true" or
# "nix=false" to $GITHUB_OUTPUT.
#
# nix=false only when the paths that changed since a revision known to be
# green all appear in the inert list below. Every other case builds: an event
# this script does not know, a base it cannot find or reach, a diff that
# fails. Inputs: EVENT, BASE_SHA (pull requests), GH_TOKEN, GITHUB_*.
#
# A path is inert when no derivation reads it. The list was checked by
# comparing every derivation CI builds before and after changing each listed
# file: docs/maintaining.md describes how to repeat that check. kind/ is
# not inert, because the kind-scripts check copies the whole directory.
set -euo pipefail

inert() {
  case $1 in
    kind/*) return 1 ;;
    *.md | LICENSE | NOTICE | .gitignore) return 0 ;;
    *) return 1 ;;
  esac
}

out=${GITHUB_OUTPUT:-/dev/stdout}
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

decide() {
  echo "nix=$1" >>"$out"
  echo "Scope: $2" | tee -a "$summary"
  exit 0
}

base=
case ${EVENT:-} in
  pull_request)
    base=${BASE_SHA:-}
    ;;
  push)
    if [ "${GITHUB_REF:-}" = refs/heads/main ]; then
      # The last main run that passed, so that a run which was cancelled or
      # failed is never hidden behind a documentation-only commit.
      base=$(gh run list --repo "$GITHUB_REPOSITORY" --workflow ci.yml --branch main \
        --event push --status success --limit 1 --json headSha --jq '.[0].headSha // empty' || true)
    fi
    ;;
esac

[ -n "$base" ] || decide true "no known-good base for this event, building everything."
git cat-file -e "$base^{commit}" 2>/dev/null || decide true "base $base is not in the history, building everything."
git merge-base --is-ancestor "$base" HEAD 2>/dev/null || decide true "base $base is not an ancestor, building everything."

changed=$(git diff --name-only --no-renames "$base" HEAD) || decide true "git diff failed, building everything."
[ -n "$changed" ] || decide false "nothing changed since ${base:0:7}."
mapfile -t paths <<<"$changed"

for path in "${paths[@]}"; do
  inert "$path" || decide true "$path changed since ${base:0:7}, building everything."
done

decide false "only documentation and licence files changed since ${base:0:7}; no derivation reads them, so the build is skipped:
$(printf '  %s\n' "${paths[@]}")"
