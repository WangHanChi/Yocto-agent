# Principles for Writing LICENSE / LIC_FILES_CHKSUM

This is the **only field in the whole recipe with legal-compliance risk**, and
getting it wrong costs far more than a build failure (it can cause licensing
compliance problems after the product ships). `scripts/license_scan.py` is only
an aid — the final call must always involve a human (the agent, or ideally the
user) actually reading the license text.

## Workflow

1. Run `scripts/license_scan.py <stage_dir>` to get the candidate license files,
   each one's md5, and a keyword-based SPDX guess.
2. **Open and actually read the files** to confirm whether the keyword guess is
   right — pay special attention to:
   - The license **version** (GPL-2.0 vs GPL-2.0-only vs GPL-2.0-or-later mean
     different things: `-only` means only that version, `-or-later` means that
     version or any later one; the upstream license file's wording usually makes
     clear which — don't guess by feel).
   - Whether it's **dual-licensed** or **multiple files under different
     licenses** (common when a library uses one license for code and another for
     docs/examples).
   - Whether individual source files have **per-file header notices** that
     disagree with the top-level LICENSE file (common for vendored third-party
     files).
3. `recipetool create` also guesses the license itself — cross-check it against
   `license_scan.py`'s result; when the two disagree, be more careful and don't
   just pick one.
4. If no standalone license file is found, check the header comments of the main
   source files (the first 20-30 lines commonly have a
   `SPDX-License-Identifier: ...` line or the full license notice text).

## LICENSE field format

- Use an SPDX identifier, in the modern form (`GPL-2.0-only`, not the legacy
  `GPL-2.0`).
- Multiple licenses:
  - `LICENSE = "MIT & BSD-3-Clause"` — AND, meaning the whole is bound by both
    licenses (e.g. the code is MIT and an embedded third-party file is
    BSD-3-Clause; you must comply with both).
  - `LICENSE = "GPL-2.0-only | Commercial"` — OR, the user may comply with
    either (common for projects offered under both open-source and commercial
    licenses).
- No recognizable license at all, or internal proprietary code:
  `LICENSE = "CLOSED"`, with a recipe comment explaining the basis.

## LIC_FILES_CHKSUM format

```
LIC_FILES_CHKSUM = "file://COPYING;md5=<hash>"
```

- Multiple files: space-separate multiple `file://...;md5=...` entries.
- A line range only (when the notice is in a source file header):
  `file://src/main.c;beginline=1;endline=20;md5=<hash>`
- The md5 must be the **actual md5sum of that file (or that line range)** — never
  a guess. `license_scan.py` computes the whole-file md5; for a line range,
  recompute the range's md5 yourself, e.g. `sed -n '1,20p' file | md5sum`.

## Reminder to give the user (always include in the final summary)

No matter how confident you are, **always explicitly list the basis for the
LICENSE call in the success summary for the user to review** — including which
file you referenced, what keywords you saw, and the SPDX value you settled on.
This is not a part this skill can fully automate and disclaim.
