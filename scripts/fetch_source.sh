#!/usr/bin/env bash
# fetch_source.sh — classify and stage a source input for yocto-recipe-gen.
#
# Usage: fetch_source.sh <input>
#   <input> is one of:
#     - a git URL (git://, git@, or https URL ending in .git, or a
#       github.com/gitlab.com/bitbucket.org repo URL)
#     - an archive URL or local path (.tar.gz/.tgz/.tar.bz2/.tar.xz/.zip)
#     - a local directory path
#
# Stages the source under ./.yocto-recipe-gen-scratch/<name>-<ts>/ and
# prints a block of KEY=VALUE lines the calling agent can parse. Does NOT
# write anything into a Yocto layer — that's the agent's job after review.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

INPUT="${1:-}"
[[ -n "$INPUT" ]] || die "usage: fetch_source.sh <git-url|archive-url|archive-path|local-dir>"

SCRATCH_ROOT="$(pwd)/.yocto-recipe-gen-scratch"
mkdir -p "$SCRATCH_ROOT"
TS="$(date +%Y%m%d%H%M%S)"

is_git_url() {
  case "$1" in
    git://*|git@*) return 0 ;;
    *.git) return 0 ;;
    https://github.com/*|https://gitlab.com/*|https://bitbucket.org/*)
      # bare repo URL without explicit .git suffix, e.g. https://github.com/org/repo
      [[ "$1" =~ ^https://[^/]+/[^/]+/[^/]+/?$ ]] && return 0
      return 1 ;;
    *) return 1 ;;
  esac
}

is_archive() {
  case "$1" in
    *.tar.gz|*.tgz|*.tar.bz2|*.tar.xz|*.zip) return 0 ;;
    *) return 1 ;;
  esac
}

if is_git_url "$INPUT"; then
  NAME="$(basename "$INPUT" .git)"
  STAGE_DIR="$SCRATCH_ROOT/${NAME}-${TS}"
  git clone --quiet "$INPUT" "$STAGE_DIR" \
    || die "git clone failed for $INPUT"
  cd "$STAGE_DIR"
  SRCREV="$(git rev-parse HEAD)"
  TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo master)"
  # Normalize to bitbake's git fetcher URL form (protocol=... required for
  # non-git:// transports).
  case "$INPUT" in
    https://*) BB_URL="git://${INPUT#https://};protocol=https;branch=${BRANCH}" ;;
    http://*)  BB_URL="git://${INPUT#http://};protocol=http;branch=${BRANCH}" ;;
    git@*)     BB_URL="git://${INPUT#git@};protocol=ssh;branch=${BRANCH}" ;;
    *)         BB_URL="${INPUT};branch=${BRANCH}" ;;
  esac
  BB_URL="${BB_URL%.git;*};$(echo "$BB_URL" | sed 's/^[^;]*;//')"
  echo "SRC_TYPE=git"
  echo "STAGE_DIR=$STAGE_DIR"
  echo "PN_HINT=$NAME"
  echo "RESOLVED_VERSION=${TAG:-untagged}"
  echo "SRCREV=$SRCREV"
  echo "SRC_URI_BB=$BB_URL"
  echo "NOTE=Pin SRCREV to the exact commit above unless the user asked for AUTOREV."
  exit 0
fi

if is_archive "$INPUT"; then
  ARCHIVE_PATH="$INPUT"
  if [[ "$INPUT" =~ ^https?:// ]]; then
    ARCHIVE_PATH="$SCRATCH_ROOT/$(basename "$INPUT")"
    curl -fsSL -o "$ARCHIVE_PATH" "$INPUT" || die "download failed for $INPUT"
  fi
  [[ -f "$ARCHIVE_PATH" ]] || die "archive not found: $ARCHIVE_PATH"

  NAME="$(basename "$ARCHIVE_PATH")"
  NAME="${NAME%.tar.gz}"; NAME="${NAME%.tgz}"; NAME="${NAME%.tar.bz2}"
  NAME="${NAME%.tar.xz}"; NAME="${NAME%.zip}"
  STAGE_DIR="$SCRATCH_ROOT/${NAME}-${TS}"
  mkdir -p "$STAGE_DIR"

  case "$ARCHIVE_PATH" in
    *.zip) unzip -q "$ARCHIVE_PATH" -d "$STAGE_DIR" ;;
    *)     tar -xf "$ARCHIVE_PATH" -C "$STAGE_DIR" ;;
  esac
  SHA256="$(sha256sum "$ARCHIVE_PATH" | awk '{print $1}')"

  # If the archive is not a URL, SRC_URI must still be a fetchable
  # location — a purely local archive should be copied into the layer's
  # files/ dir (see references/src-uri-fetchers.md) and referenced with
  # file://. Flag that explicitly here rather than guessing a URL.
  if [[ "$INPUT" =~ ^https?:// ]]; then
    BB_URL="$INPUT"
  else
    BB_URL="file://$(basename "$ARCHIVE_PATH")  # copy this archive into <layer>/recipes-*/<pn>/files/ first"
  fi

  echo "SRC_TYPE=archive"
  echo "STAGE_DIR=$STAGE_DIR"
  echo "ARCHIVE_PATH=$ARCHIVE_PATH"
  echo "PN_HINT=$NAME"
  echo "SHA256=$SHA256"
  echo "SRC_URI_BB=$BB_URL"
  echo "NOTE=Set SRC_URI[sha256sum] = \"$SHA256\" if SRC_URI is a remote URL."
  exit 0
fi

if [[ -d "$INPUT" ]]; then
  ABS_PATH="$(cd "$INPUT" && pwd)"
  NAME="$(basename "$ABS_PATH")"
  if [[ -d "$ABS_PATH/.git" ]]; then
    (cd "$ABS_PATH" && is_git_dirty=$(git status --porcelain))
    echo "SRC_TYPE=local-git"
    echo "STAGE_DIR=$ABS_PATH"
    echo "PN_HINT=$NAME"
    echo "SRCREV=$(cd "$ABS_PATH" && git rev-parse HEAD)"
    echo "NOTE=Local dir is itself a git checkout; treat like SRC_TYPE=git for a reproducible recipe, or use externalsrc for dev-mode."
  else
    echo "SRC_TYPE=local-dir"
    echo "STAGE_DIR=$ABS_PATH"
    echo "PN_HINT=$NAME"
    echo "NOTE=No .git found. Ask the user: externalsrc (dev-mode, in-place, not reproducible) or vendor tarball (reproducible, copy into layer files/) — see SKILL.md section 1."
  fi
  exit 0
fi

die "could not classify input as a git URL, archive, or local directory: $INPUT"
