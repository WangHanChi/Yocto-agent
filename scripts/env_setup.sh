# env_setup.sh — sourceable helper that locates and sources the project's
# Yocto environment setup script.
#
# NOT meant to be executed directly — other scripts `source` this file and
# call `yrg_source_env`. It exists because every bitbake/recipetool/devtool
# command the skill runs happens in a FRESH shell (the agent's each tool
# call starts a new process), so an environment sourced in one command does
# NOT survive to the next. Anything that runs bitbake must re-source first.
#
# This is where your project's "source oe-init-build-env AND source the SDK
# environment" wrapper script gets hooked in.
#
# Resolution order for the setup script to source:
#   1. $YOCTO_ENV_SETUP        (absolute path, wins if set)
#   2. ENV_SETUP=... assigned in the config file (default:
#      ./.yocto-recipe-gen.conf, override via $YOCTO_GEN_CONF)
# Optional arguments passed to that setup script:
#   $YOCTO_ENV_SETUP_ARGS, or ENV_SETUP_ARGS=... in the config file.

_yrg_resolve_env() {
  _yrg_setup="${YOCTO_ENV_SETUP:-}"
  _yrg_args="${YOCTO_ENV_SETUP_ARGS:-}"
  local conf="${YOCTO_GEN_CONF:-.yocto-recipe-gen.conf}"
  if [ -z "$_yrg_setup" ] && [ -f "$conf" ]; then
    # The config file is plain shell: `ENV_SETUP="/path/to/script"` etc.
    # shellcheck disable=SC1090
    . "$conf"
    _yrg_setup="${ENV_SETUP:-}"
    [ -n "${ENV_SETUP_ARGS:-}" ] && _yrg_args="${ENV_SETUP_ARGS}"
  fi
}

# yrg_source_env: source the configured setup script into the CURRENT shell.
# Returns 0 on success (or when nothing is configured and we assume the env
# is already present), non-zero only when a configured script is missing or
# fails.
yrg_source_env() {
  _yrg_resolve_env

  if [ -z "${_yrg_setup:-}" ]; then
    echo "[env_setup] no ENV_SETUP configured (set \$YOCTO_ENV_SETUP or create" \
         ".yocto-recipe-gen.conf) — assuming this shell already has the" \
         "Yocto + SDK environment sourced." >&2
    return 0
  fi

  if [ ! -f "$_yrg_setup" ]; then
    echo "[env_setup] ERROR: configured ENV_SETUP does not exist: $_yrg_setup" >&2
    return 1
  fi

  echo "[env_setup] sourcing: $_yrg_setup $_yrg_args" >&2

  # oe-init-build-env and SDK environment-setup scripts are not written for
  # strict mode (they touch unbound vars, may return non-zero benignly), so
  # relax -e/-u across the source and restore the caller's flags afterward.
  local _flags="$-"
  set +eu
  # shellcheck disable=SC1090
  . "$_yrg_setup" $_yrg_args
  local _rc=$?
  case "$_flags" in *e*) set -e ;; esac
  case "$_flags" in *u*) set -u ;; esac

  if [ "$_rc" -ne 0 ]; then
    echo "[env_setup] WARNING: setup script returned exit code $_rc" \
         "(often benign for oe-init-build-env); continuing." >&2
  fi
  return 0
}
