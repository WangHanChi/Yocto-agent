#!/usr/bin/env bash
# run_in_env.sh — source the project's Yocto + SDK environment, then run a
# command inside it.
#
# Every one-off bitbake-family command the skill runs should go through this
# wrapper, because each agent tool call is a fresh shell with no memory of a
# previously sourced environment. Examples:
#
#   scripts/run_in_env.sh bitbake-layers show-layers
#   scripts/run_in_env.sh recipetool create -o foo_1.0.bb "git://..."
#   scripts/run_in_env.sh bitbake -e foo
#   scripts/run_in_env.sh devtool add foo "git://..."
#
# (build_loop.sh sources the environment on its own, so you do NOT need to
# wrap it — call it directly.)
#
# The setup script to source is resolved by env_setup.sh — see that file and
# .yocto-recipe-gen.conf for how to point it at your project's script.
set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "usage: run_in_env.sh <command> [args...]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env_setup.sh
. "$SCRIPT_DIR/env_setup.sh"

yrg_source_env || {
  echo "run_in_env: failed to source the Yocto environment; aborting." >&2
  exit 2
}

# Sourcing oe-init-build-env typically cd's into BUILDDIR, which is exactly
# where bitbake wants to run from — so we intentionally do NOT cd back.
exec "$@"
