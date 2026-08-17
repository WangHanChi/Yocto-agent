#!/usr/bin/env python3
"""Regression tests for scripts/license_scan.py.

Run: python3 tests/test_license_scan.py

Each fixture below captures a real misdetection that shipped at some point,
so they are deliberately minimal excerpts rather than full license texts —
what matters is the phrasing that used to break the matcher.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))

from license_scan import scan_licenses  # noqa: E402

# The comma variant. Xilinx bootgen's LICENSE reads "Licensed under the
# Apache License, Version 2.0" and used to be reported as BSD-2-Clause,
# because the Apache pattern required no comma and the fall-through hit a
# BSD notice belonging to a bundled component further down the file.
APACHE_COMMA = """
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
"""

# SPDX's own BSD-3-Clause reference text has no clause numbers, so a
# pattern requiring "3. Neither the name" matched nothing at all.
BSD3_UNNUMBERED = """
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice.
Redistributions in binary form must reproduce the above copyright notice.
Neither the name of the ORGANIZATION nor the names of its contributors
may be used to endorse or promote products derived from this software.
"""

BSD3_NUMBERED = """
Redistribution and use in source and binary forms are permitted provided
that the following conditions are met:
1. Redistributions of source code must retain the above copyright notice.
2. Redistributions in binary form must reproduce the above copyright notice.
3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products.
"""

# The LGPL and the MPL both quote the GPL inside their own text. That is a
# cross-reference, not dual licensing, and used to produce a bogus
# composite result whose `guess` was plain GPL.
LGPL21_REFERENCING_GPL = """
GNU LESSER GENERAL PUBLIC LICENSE
Version 2.1, February 1999

This license, the Lesser General Public License, applies to some specially
designated software packages. You may opt to apply the terms of the
ordinary GNU GENERAL PUBLIC LICENSE Version 2 instead of this License.
"""

MPL2_REFERENCING_GPL = """
Mozilla Public License Version 2.0

1.12. "Secondary License" means either the GNU GENERAL PUBLIC LICENSE
Version 2, the GNU Lesser General Public License, Version 2.1, or any
later versions of those licenses.
"""

# A genuinely composite file: several vendored components, each with its
# own notice. This must be flagged so the agent stops and reads it.
COMPOSITE = APACHE_COMMA + "\n\n" + ("filler\n" * 40) + BSD3_NUMBERED

CASES = [
    ("Apache-2.0 with comma", APACHE_COMMA, "Apache-2.0", False),
    ("BSD-3-Clause unnumbered", BSD3_UNNUMBERED, "BSD-3-Clause", False),
    ("BSD-3-Clause numbered", BSD3_NUMBERED, "BSD-3-Clause", False),
    ("LGPL-2.1 referencing GPL", LGPL21_REFERENCING_GPL, "LGPL-2.1-only", False),
    ("MPL-2.0 referencing GPL", MPL2_REFERENCING_GPL, "MPL-2.0", False),
    ("composite Apache + BSD", COMPOSITE, "Apache-2.0", True),
]


def main():
    failures = 0
    for name, text, want_guess, want_composite in CASES:
        matches, composite = scan_licenses(text)
        guess = matches[0] if matches else None
        ok = guess == want_guess and composite == want_composite
        if not ok:
            failures += 1
        print(f"{'PASS' if ok else 'FAIL'}  {name}")
        if not ok:
            print(f"      want guess={want_guess} composite={want_composite}")
            print(f"      got  guess={guess} composite={composite} "
                  f"matches={matches}")

    print(f"\n{len(CASES) - failures}/{len(CASES)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
