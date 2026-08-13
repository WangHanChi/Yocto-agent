#!/usr/bin/env python3
"""detect_build_system.py — heuristically identify the upstream build system
of a staged source tree so yocto-recipe-gen can pick the right bitbake class.

Usage: detect_build_system.py <source_dir>
Prints a single JSON object to stdout:
  {"build_system": "...", "confidence": "high|medium|low", "hints": [...]}

This is a heuristic aid, not authoritative — always sanity-check against
what `recipetool create` itself infers, and against references/bbclasses.md.
"""
import json
import os
import sys

# (build_system, marker_glob_or_name, weight) — first strong match wins,
# but we collect all hits so ambiguous trees are still reported honestly.
MARKERS = [
    ("cargo",            "Cargo.toml",           3),
    ("meson",            "meson.build",          3),
    ("cmake",            "CMakeLists.txt",       3),
    ("autotools",        "configure.ac",         3),
    ("autotools",        "configure.in",         2),
    ("python3",          "pyproject.toml",       3),
    ("python3",          "setup.py",             2),
    ("qmake5",           None,                   0),  # handled via extension scan below
    ("npm",              "package.json",         2),
    ("kernel-module",    "Kbuild",               2),
]


def has_extension(root, ext):
    for _, _, files in os.walk(root):
        for f in files:
            if f.endswith(ext):
                return True
    return False


def looks_like_kernel_module(root):
    for dirpath, _, files in os.walk(root):
        if "Makefile" in files:
            try:
                with open(os.path.join(dirpath, "Makefile"), errors="ignore") as fh:
                    content = fh.read()
                if "obj-m" in content or "$(KERNEL_SRC)" in content or "KDIR" in content:
                    return True
            except OSError:
                continue
    return False


def main():
    if len(sys.argv) != 2:
        print("usage: detect_build_system.py <source_dir>", file=sys.stderr)
        sys.exit(2)
    root = sys.argv[1]
    if not os.path.isdir(root):
        print(f"ERROR: not a directory: {root}", file=sys.stderr)
        sys.exit(1)

    entries = set(os.listdir(root))
    hits = []

    for build_system, marker, weight in MARKERS:
        if marker and marker in entries:
            hits.append((build_system, weight, f"found {marker}"))

    if has_extension(root, ".pro") and not any(h[0] == "qmake5" for h in hits):
        hits.append(("qmake5", 2, "found *.pro qmake project file"))

    if looks_like_kernel_module(root):
        hits.append(("kernel-module", 3, "Makefile references obj-m/KERNEL_SRC/KDIR"))

    # Plain Makefile with none of the above -> generic make, needs manual
    # do_compile/do_install.
    if "Makefile" in entries and not hits:
        hits.append(("generic-makefile", 1, "only a bare Makefile found"))

    if not hits:
        print(json.dumps({
            "build_system": "unknown",
            "confidence": "low",
            "hints": ["no recognizable build system marker files found; inspect manually"],
        }))
        return

    hits.sort(key=lambda h: h[1], reverse=True)
    best = hits[0]
    confidence = "high" if best[1] >= 3 and len(hits) == 1 else \
                 "medium" if best[1] >= 2 else "low"
    if len(hits) > 1 and hits[1][1] == best[1]:
        confidence = "low"  # genuine tie, e.g. autotools + cmake both present

    print(json.dumps({
        "build_system": best[0],
        "confidence": confidence,
        "hints": [f"{bs}: {reason}" for bs, _, reason in hits],
    }))


if __name__ == "__main__":
    main()
