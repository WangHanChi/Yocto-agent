#!/usr/bin/env python3
"""license_scan.py — find likely license files in a staged source tree and
compute the md5 checksum bitbake's LIC_FILES_CHKSUM expects.

Usage: license_scan.py <source_dir>
Prints one JSON object per candidate file found (JSON Lines), e.g.:
  {"file": "COPYING", "md5": "...", "guess": "GPL-2.0-only", "lines": 339}

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

# Ordered rough keyword -> SPDX guess. First match wins; deliberately
# conservative (keeps "-only" off unless text look unambiguous).
KEYWORD_GUESSES = [
    (r"GNU GENERAL PUBLIC LICENSE\s*\n?\s*Version 3", "GPL-3.0-only"),
    (r"GNU GENERAL PUBLIC LICENSE\s*\n?\s*Version 2", "GPL-2.0-only"),
    (r"GNU LESSER GENERAL PUBLIC LICENSE\s*\n?\s*Version 3", "LGPL-3.0-only"),
    (r"GNU LESSER GENERAL PUBLIC LICENSE\s*\n?\s*Version 2\.1", "LGPL-2.1-only"),
    (r"Apache License\s*\n?\s*Version 2\.0", "Apache-2.0"),
    # MIT license text order varies (header before or after the permission
    # sentence), so match the two phrases independently via lookahead
    # instead of requiring a fixed order.
    (r"(?=.*\bMIT\b)(?=.*Permission is hereby granted, free of charge)", "MIT"),
    (r"Redistribution and use in source and binary forms.*3\. Neither the name", "BSD-3-Clause"),
    (r"Redistribution and use in source and binary forms.*2\. Redistributions in binary", "BSD-2-Clause"),
    (r"Mozilla Public License Version 2\.0", "MPL-2.0"),
    (r"THE UNLICENSE", "Unlicense"),
    (r"ISC License", "ISC"),
]


def guess_spdx(text):
    for pattern, spdx in KEYWORD_GUESSES:
        if re.search(pattern, text, re.IGNORECASE | re.DOTALL):
            return spdx
    return None


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
            guess = guess_spdx(text)
            rel = os.path.relpath(full, root)
            print(json.dumps({
                "file": rel,
                "md5": md5,
                "guess": guess,
                "lines": text.count("\n") + 1,
            }))
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
