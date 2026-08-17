#!/usr/bin/env bash
# fetch_source.sh — classify and stage a source input for yocto-recipe-gen.
#
# Usage: fetch_source.sh <input> [<ref>]
#   <input> is one of:
#     - a git URL (git://, git@, or https URL ending in .git, or a
#       github.com/gitlab.com/bitbucket.org repo URL)
#     - an archive URL or local path (.tar.gz/.tgz/.tar.bz2/.tar.xz/.zip)
#     - a local directory path
#   <ref> (git input only, optional) is the tag/branch/commit to check out.
#     SKILL.md section 1 requires the agent to ask the user which version to
#     pin BEFORE staging, so pass their answer here. Without it this script
#     stages the default branch HEAD and says so loudly — it does not decide
#     a version on the user's behalf.
#
# Stages the source under ./.yocto-recipe-gen-scratch/<name>-<ts>/ and
# prints a block of KEY=VALUE lines the calling agent can parse. Does NOT
# write anything into a Yocto layer — that's the agent's job after review.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

INPUT="${1:-}"
REF="${2:-}"
[[ -n "$INPUT" ]] || die "usage: fetch_source.sh <git-url|archive-url|archive-path|local-dir> [<ref>]"

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

  # Shallow by default: recipe drafting only ever looks at one tree, and a
  # full clone of a large upstream is a slow way to learn nothing extra.
  if [[ -n "$REF" ]]; then
    # --branch takes tags as well as branches. Fall back to a full clone
    # for a raw commit sha, which --branch cannot express.
    if ! git clone --quiet --depth 1 --branch "$REF" "$INPUT" "$STAGE_DIR" 2>/dev/null; then
      git clone --quiet "$INPUT" "$STAGE_DIR" || die "git clone failed for $INPUT"
      git -C "$STAGE_DIR" checkout --quiet "$REF" \
        || die "ref not found in $INPUT: $REF"
    fi
  else
    git clone --quiet --depth 1 "$INPUT" "$STAGE_DIR" \
      || die "git clone failed for $INPUT"
  fi

  cd "$STAGE_DIR"
  SRCREV="$(git rev-parse HEAD)"
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo master)"
  [[ "$BRANCH" == "HEAD" ]] && BRANCH=""

  # Normalize to bitbake's git fetcher URL form. Build the bare base first
  # and strip any .git suffix from it, then append the fetcher parameters
  # exactly once — appending them to a string that may or may not already
  # carry them is how they used to get duplicated.
  case "$INPUT" in
    https://*) BB_BASE="git://${INPUT#https://}"; BB_PROTO="https" ;;
    http://*)  BB_BASE="git://${INPUT#http://}";  BB_PROTO="http" ;;
    git@*)     BB_BASE="git://${INPUT#git@}";     BB_PROTO="ssh" ;;
    *)         BB_BASE="${INPUT}";                BB_PROTO="" ;;
  esac
  BB_BASE="${BB_BASE%.git}"
  BB_URL="$BB_BASE"
  [[ -n "$BB_PROTO" ]] && BB_URL="${BB_URL};protocol=${BB_PROTO}"
  if [[ -n "$BRANCH" ]]; then
    BB_URL="${BB_URL};branch=${BRANCH}"
  else
    BB_URL="${BB_URL};nobranch=1"
  fi

  echo "SRC_TYPE=git"
  echo "STAGE_DIR=$STAGE_DIR"
  echo "PN_HINT=$NAME"
  echo "SRCREV=$SRCREV"
  echo "SRC_URI_BB=$BB_URL"

  if [[ -n "$REF" ]]; then
    echo "RESOLVED_VERSION=$REF"
    echo "VERSION_PINNED=yes"
    echo "NOTE=Staged at the requested ref '$REF'. Pin SRCREV to the commit above."
  else
    echo "RESOLVED_VERSION=unpinned-default-branch-head"
    echo "VERSION_PINNED=no"
    # Offer the agent concrete choices so it can ask the version question
    # from SKILL.md section 1 with real options instead of a blank prompt.
    TAGS="$(git ls-remote --tags --refs "$INPUT" 2>/dev/null \
            | sed 's#.*refs/tags/##' | tail -10 | tr '\n' ' ' || true)"
    [[ -n "$TAGS" ]] && echo "AVAILABLE_TAGS=$TAGS"
    echo "NOTE=NO VERSION WAS REQUESTED — this is the default branch HEAD, not a user-chosen version. SKILL.md section 1 requires you to ask the user which tag/branch/commit to pin, then re-run: fetch_source.sh <url> <ref>"
  fi
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
    # Whether the tree is dirty decides whether a SRCREV-pinned recipe can
    # reproduce what is actually on disk, so report it instead of throwing
    # it away in a subshell.
    if [[ -n "$(cd "$ABS_PATH" && git status --porcelain)" ]]; then
      IS_DIRTY=yes
    else
      IS_DIRTY=no
    fi
    echo "SRC_TYPE=local-git"
    echo "STAGE_DIR=$ABS_PATH"
    echo "PN_HINT=$NAME"
    echo "SRCREV=$(cd "$ABS_PATH" && git rev-parse HEAD)"
    echo "IS_DIRTY=$IS_DIRTY"
    if [[ "$IS_DIRTY" == "yes" ]]; then
      echo "NOTE=Working tree has uncommitted changes: a SRCREV-pinned recipe would NOT build what is on disk. Either commit first, or use externalsrc dev-mode and tell the user it is not reproducible."
    else
      echo "NOTE=Local dir is itself a clean git checkout; treat like SRC_TYPE=git for a reproducible recipe, or use externalsrc for dev-mode."
    fi
  else
    echo "SRC_TYPE=local-dir"
    echo "STAGE_DIR=$ABS_PATH"
    echo "PN_HINT=$NAME"
    echo "NOTE=No .git found. Ask the user: externalsrc (dev-mode, in-place, not reproducible) or vendor tarball (reproducible, copy into layer files/) — see SKILL.md section 1."
  fi
  exit 0
fi

die "could not classify input as a git URL, archive, or local directory: $INPUT"
