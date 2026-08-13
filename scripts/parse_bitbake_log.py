#!/usr/bin/env python3
"""parse_bitbake_log.py — condense a bitbake log into a short, classified
summary so the calling agent doesn't have to load the whole (often huge)
log into its context window.

Usage: parse_bitbake_log.py <logfile>
Exit code mirrors whether a failure signature was found (0 = log looks
clean, 1 = at least one known failure category matched).
"""
import re
import sys

# (category, regex, human hint) — order matters, first match per line wins.
PATTERNS = [
    ("fetch-checksum-mismatch",
     r"Fetcher failure.*[Cc]hecksum mismatch|SRC_URI\[.*sum\] mismatch",
     "SRC_URI checksum does not match the downloaded artifact — recompute "
     "sha256sum, or the upstream tag moved so pin SRCREV instead."),
    ("fetch-failure",
     r"ERROR:.*Fetcher failure|Unable to fetch URL",
     "Source could not be fetched — check SRC_URI syntax, network reachability, "
     "or whether BB_NO_NETWORK is set."),
    ("configure-missing-tool",
     r"configure: error:|No package .* found|command not found",
     "do_configure failed, often a missing native/host tool or -dev package — "
     "check DEPENDS for the missing tool/library."),
    ("compile-missing-header",
     r"fatal error: .*\.h.*No such file or directory",
     "Missing header at compile time — add the providing recipe to DEPENDS."),
    ("link-missing-lib",
     r"cannot find -l\w+|undefined reference to",
     "Linker can't find a library/symbol — add the providing recipe to DEPENDS, "
     "or check that PACKAGECONFIG enables it."),
    ("install-no-files",
     r"No files in (the )?['\"]?\$\{D\}|QA Issue: .*Files/directories were "
     r"installed but not shipped",
     "do_install did not put anything into ${D}, or FILES:${PN} doesn't cover "
     "them — check the upstream install target / override do_install."),
    ("qa-issue",
     r"ERROR: QA Issue:|WARNING: QA Issue:",
     "insane.bbclass QA check failed — read the specific QA message; usually "
     "a packaging problem (rpath, stripping, buildpaths, .la files, etc)."),
    ("license-checksum-mismatch",
     r"LIC_FILES_CHKSUM.*does not match|md5 data is not matching",
     "LIC_FILES_CHKSUM does not match the actual license file content — "
     "recompute md5sum and update, and double check LICENSE is still correct."),
    ("recipe-name-collision",
     r"Multiple .bb files .* are due to be built",
     "PN collision with a recipe in another layer — rename PN or raise "
     "BBFILE_PRIORITY for your layer."),
    ("parse-error",
     r"ParseError|Unable to parse|ERROR: .*\.bb: ",
     "The recipe failed to parse — syntax error or an undefined variable/"
     "function reference; run `bitbake -e <pn>` for the fastest repro."),
    ("ptest-failure",
     r"FAIL: |ptest-runner.*FAIL",
     "A packaged test suite (ptest) failed — inspect the specific test name."),
    ("task-failed",
     r"ERROR: Task \(.*\) failed with exit code",
     "A specific bitbake task failed — see the task name in this line for "
     "which do_* step to focus on."),
]

CONTEXT_LINES = 6


def main():
    if len(sys.argv) != 2:
        print("usage: parse_bitbake_log.py <logfile>", file=sys.stderr)
        sys.exit(2)

    path = sys.argv[1]
    try:
        with open(path, errors="ignore") as fh:
            lines = fh.readlines()
    except OSError as exc:
        print(f"ERROR: cannot read {path}: {exc}", file=sys.stderr)
        sys.exit(2)

    compiled = [(cat, re.compile(pat), hint) for cat, pat, hint in PATTERNS]
    matches = []  # (line_no, category, hint, line_text)

    for i, line in enumerate(lines):
        for cat, rx, hint in compiled:
            if rx.search(line):
                matches.append((i, cat, hint, line.rstrip()))
                break  # one category per line is enough

    if not matches:
        print(f"[parse_bitbake_log] no known failure signature found in {path}")
        print("Log looks clean, or the failure mode isn't in the known pattern "
              "list yet — tail the raw log manually near the last ERROR: line.")
        sys.exit(0)

    seen_categories = {}
    for i, cat, hint, text in matches:
        seen_categories.setdefault(cat, []).append((i, text))

    print(f"[parse_bitbake_log] {len(matches)} matches, "
          f"{len(seen_categories)} categories, in {path}\n")

    for cat, occurrences in seen_categories.items():
        hint = next(h for c, _, h in PATTERNS if c == cat)
        print(f"=== {cat} ({len(occurrences)} hit(s)) ===")
        print(f"hint: {hint}")
        # show context around the *last* occurrence — usually the most
        # relevant one after retries within the same log.
        last_line_no, _ = occurrences[-1]
        start = max(0, last_line_no - 1)
        end = min(len(lines), last_line_no + CONTEXT_LINES)
        print(f"--- log context (lines {start + 1}-{end}) ---")
        for ln in lines[start:end]:
            print("    " + ln.rstrip())
        print()

    sys.exit(1)


if __name__ == "__main__":
    main()
