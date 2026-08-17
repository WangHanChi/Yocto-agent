#!/usr/bin/env bash
# build_loop.sh — run ONE iteration of the build-fix loop for a recipe.
#
# This does not loop by itself: the calling agent is the loop. Call this
# once per iteration, read the condensed output, edit the recipe, call
# again. See SKILL.md section 5.
#
# Usage: build_loop.sh <pn> <iteration_number> [--cleansstate]
#
# Exit codes:
#   0   build succeeded
#   1   build (or parse) failed — see condensed summary on stdout
#   2   usage / environment error (bitbake not found, etc.)
set -uo pipefail

PN="${1:-}"
ITER="${2:-}"
CLEAN="${3:-}"

if [[ -z "$PN" || -z "$ITER" ]]; then
  echo "usage: build_loop.sh <pn> <iteration_number> [--cleansstate]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Capture the invocation dir BEFORE sourcing the env — oe-init-build-env
# cd's into BUILDDIR, and we want logs to land somewhere predictable that
# the agent can find afterward.
INVOKE_DIR="$(pwd)"

# Source the project's Yocto + SDK environment first: this shell is fresh
# and won't have inherited any `source` done in an earlier tool call.
# shellcheck source=env_setup.sh
. "$SCRIPT_DIR/env_setup.sh"
yrg_source_env || {
  echo "[build_loop] ERROR: could not source the Yocto environment." >&2
  exit 2
}

command -v bitbake >/dev/null 2>&1 || {
  echo "[build_loop] ERROR: bitbake still not on PATH after sourcing the env." \
       "Check that ENV_SETUP points at a script that sources oe-init-build-env." >&2
  exit 2
}

LOG_DIR="${INVOKE_DIR}/yocto-recipe-gen-logs/${PN}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/iter-${ITER}.log"
# `bitbake -e` dumps the entire expanded environment — tens of thousands of
# lines, including the bodies of every shell function. Mixing that into the
# build log buries the handful of lines that actually explain a failure
# (measured: 22183 of 22266 lines, 99.6%), and feeds the summariser a huge
# amount of text whose generic phrases ("command not found", "WARNING:")
# can match failure patterns that have nothing to do with this build.
PARSE_LOG="${LOG_DIR}/iter-${ITER}.parse.log"

echo "[build_loop] iteration ${ITER} for ${PN}" | tee "$LOG_FILE"

# Fast path: parse-only check first. Cheap, and catches syntax/undefined
# variable errors without waiting on a real compile.
echo "[build_loop] step 1/2: bitbake -e ${PN} (parse-only check, log: ${PARSE_LOG})" \
  | tee -a "$LOG_FILE"
if ! bitbake -e "$PN" >"$PARSE_LOG" 2>&1; then
  echo "[build_loop] parse-only check FAILED (log: ${PARSE_LOG})" | tee -a "$LOG_FILE"
  python3 "$SCRIPT_DIR/parse_bitbake_log.py" "$PARSE_LOG"
  exit 1
fi

if [[ "$CLEAN" == "--cleansstate" ]]; then
  echo "[build_loop] step 2/3: bitbake -c cleansstate ${PN}" | tee -a "$LOG_FILE"
  bitbake -c cleansstate "$PN" >>"$LOG_FILE" 2>&1
fi

echo "[build_loop] step 2/2: bitbake ${PN}" | tee -a "$LOG_FILE"
if bitbake "$PN" >>"$LOG_FILE" 2>&1; then
  echo "[build_loop] SUCCESS — ${PN} built cleanly (log: ${LOG_FILE})"
  exit 0
else
  echo "[build_loop] BUILD FAILED (log: ${LOG_FILE})"
  python3 "$SCRIPT_DIR/parse_bitbake_log.py" "$LOG_FILE"
  exit 1
fi
