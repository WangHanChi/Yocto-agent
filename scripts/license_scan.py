#!/usr/bin/env python3
"""license_scan.py — find likely license files in a staged source tree and
compute the md5 checksum bitbake's LIC_FILES_CHKSUM expects.

Usage: license_scan.py <source_dir>
Prints one JSON object per candidate file found (JSON Lines), e.g.:
  {"file": "COPYING", "md5": "...", "guess": "GPL-2.0-only",
   "matches": ["GPL-2.0-only"], "composite": false, "lines": 339}

`matches` lists EVERY license whose signature was found in the file, and
`composite` is true when more than one distinct license matched — which
means the file bundles several components (very common for projects that
vendor generated parsers, hash implementations, etc). `guess` is kept as
the single highest-priority match for convenience, but on a composite file
it is NOT the answer on its own.

This is a heuristic AID ONLY. The agent (and ideally the user) must
still read the file and confirm the SPDX identifier before writing
LICENSE/LIC_FILES_CHKSUM into the recipe — see references/license-guide.md.
Keyword matching cannot distinguish license *versions* or dual-licensing
reliably.
"""
import hashlib
import json
import os
import re
import sys

CANDIDATE_NAMES = re.compile(
    r"^(COPYING(\..*)?|LICEN[CS]E(\..*)?|LICENSE-[A-Z0-9.\-]+|MIT-LICENSE|UNLICENSE)$",
    re.IGNORECASE,
)

# Ordered rough keyword -> SPDX guess. Order defines priority for the
# convenience `guess` field; every pattern is still evaluated so that
# `matches` is complete.
#
# Patterns must tolerate the punctuation variants that appear in the wild:
# "Apache License, Version 2.0" (comma) is at least as common as the
# comma-less form, and missing it silently mislabels the file.
KEYWORD_GUESSES = [
    # The LESSER and MPL entries come before the plain GPL ones: both of
    # those license texts quote the GPL, so whichever is listed first wins
    # the `guess` slot if the shadowing table below ever misses a case.
    (r"GNU LESSER GENERAL PUBLIC LICENSE,?\s*\n?\s*Version 3", "LGPL-3.0-only"),
    (r"GNU LESSER GENERAL PUBLIC LICENSE,?\s*\n?\s*Version 2\.1", "LGPL-2.1-only"),
    (r"Mozilla Public License,?\s*\n?\s*Version 2\.0", "MPL-2.0"),
    (r"GNU GENERAL PUBLIC LICENSE,?\s*\n?\s*Version 3", "GPL-3.0-only"),
    (r"GNU GENERAL PUBLIC LICENSE,?\s*\n?\s*Version 2", "GPL-2.0-only"),
    (r"Apache License,?\s*\n?\s*Version 2\.0", "Apache-2.0"),
    # MIT license text order varies (header before or after the permission
    # sentence), so match the two phrases independently via lookahead.
    # The window scan below keeps this from pairing an unrelated "MIT"
    # mention with a permission sentence far away in the file.
    (r"(?=.*\bMIT\b)(?=.*Permission is hereby granted, free of charge)", "MIT"),
    # The BSD condition lists appear both numbered ("3. Neither the name")
    # and as bare paragraphs (SPDX's own reference text is unnumbered), so
    # the clause number must not be required. The distinguishing feature of
    # BSD-3 over BSD-2 is the "Neither the name" non-endorsement clause.
    (r"Redistribution and use in source and binary forms.*Neither the name",
     "BSD-3-Clause"),
    (r"Redistribution and use in source and binary forms.*Redistributions in binary",
     "BSD-2-Clause"),
    (r"THE UNLICENSE", "Unlicense"),
    (r"ISC License", "ISC"),
]

# When the key license is detected, the listed ones are dropped as noise.
# Two distinct reasons, both of which would otherwise flag ordinary
# single-license files as "composite" and stall the agent on a pointless
# question:
#
#   * strict supersets — BSD-3-Clause contains the whole of BSD-2-Clause's
#     clause list, so a BSD-3 file always matches the BSD-2 pattern too;
#   * incidental cross-references — the LGPL and the MPL both quote or
#     reference the GPL inside their own text without being dual-licensed
#     under it.
SHADOWS = {
    "BSD-3-Clause": ["BSD-2-Clause"],
    "GPL-3.0-only": ["GPL-2.0-only"],
    "LGPL-2.1-only": ["GPL-2.0-only", "GPL-3.0-only"],
    "LGPL-3.0-only": ["GPL-2.0-only", "GPL-3.0-only", "LGPL-2.1-only"],
    "MPL-2.0": ["GPL-2.0-only", "GPL-3.0-only",
                "LGPL-2.1-only", "LGPL-3.0-only"],
}

# Patterns are evaluated against overlapping windows rather than the whole
# file. With re.DOTALL an unbounded `.*` would happily pair a phrase in the
# first component's notice with one from a completely unrelated component
# hundreds of lines later, inventing a license that is not in the file.
# Overlapping (step = half a window) keeps a signature that straddles a
# boundary from being missed.
WINDOW = 4000
STEP = WINDOW // 2


def scan_licenses(text):
    """Return (ordered list of matched SPDX ids, composite flag)."""
    found = set()
    span = max(len(text), 1)
    for start in range(0, span, STEP):
        chunk = text[start:start + WINDOW]
        if not chunk:
            break
        for pattern, spdx in KEYWORD_GUESSES:
            if spdx in found:
                continue
            if re.search(pattern, chunk, re.IGNORECASE | re.DOTALL):
                found.add(spdx)

    # Collect every removal against the ORIGINAL match set before applying
    # any of them, so a shadowing entry can't be dropped before it has had
    # a chance to shadow others (LGPL-3.0 shadows LGPL-2.1 shadows GPL-2.0).
    shadowed = set()
    for key, noise in SHADOWS.items():
        if key in found:
            shadowed.update(noise)
    found.difference_update(shadowed)

    # Preserve KEYWORD_GUESSES order so `guess` is deterministic.
    ordered = [spdx for _, spdx in KEYWORD_GUESSES if spdx in found]
    return ordered, len(ordered) > 1


def main():
    if len(sys.argv) != 2:
        print("usage: license_scan.py <source_dir>", file=sys.stderr)
        sys.exit(2)
    root = sys.argv[1]
    if not os.path.isdir(root):
        print(f"ERROR: not a directory: {root}", file=sys.stderr)
        sys.exit(1)

    found_any = False
    # Only scan the top two directory levels — license files buried deep
    # in vendored subdirs are usually third-party, not the project's own.
    for dirpath, dirnames, filenames in os.walk(root):
        depth = dirpath[len(root):].count(os.sep)
        if depth >= 2:
            dirnames[:] = []
            continue
        for fname in filenames:
            if not CANDIDATE_NAMES.match(fname):
                continue
            full = os.path.join(dirpath, fname)
            try:
                with open(full, "rb") as fh:
                    data = fh.read()
            except OSError:
                continue
            md5 = hashlib.md5(data).hexdigest()
            text = data.decode("utf-8", errors="ignore")
            matches, composite = scan_licenses(text)
            rel = os.path.relpath(full, root)
            record = {
                "file": rel,
                "md5": md5,
                "guess": matches[0] if matches else None,
                "matches": matches,
                "composite": composite,
                "lines": text.count("\n") + 1,
            }
            if composite:
                record["note"] = (
                    "multiple distinct licenses matched — this file bundles "
                    "several components. Read it and decide the effective "
                    "LICENSE yourself; do not copy `guess` into the recipe."
                )
            print(json.dumps(record))
            found_any = True

    if not found_any:
        print(json.dumps({
            "file": None,
            "note": "no standalone license file found at top 2 levels; "
                     "check source file headers manually (e.g. head -c 2000 "
                     "of the main source files) before setting LICENSE.",
        }))


if __name__ == "__main__":
    main()
