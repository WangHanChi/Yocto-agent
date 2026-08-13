# BitBake Recipe Variable Quick Reference

For the agent to cross-check while writing/editing recipes. Not a replacement
for the full BitBake manual — the authoritative sources are always the
`bitbake-user-manual` and `dev-manual` (docs.yoctoproject.org).

## Required metadata

```
SUMMARY = "one-line short description, no trailing period"
DESCRIPTION = "longer description; optional but recommended"
HOMEPAGE = "https://upstream-project-homepage"
LICENSE = "MIT"                                  # SPDX format, see license-guide.md
LIC_FILES_CHKSUM = "file://COPYING;md5=<32-hex>"
```

- For multiple licenses, `LICENSE` uses `&` (AND — the whole package is bound by
  both licenses) or `|` (OR — the user may pick either), e.g.
  `LICENSE = "MIT & BSD-3-Clause"`.
- `LIC_FILES_CHKSUM` may list multiple files, space-separated; it can also take
  just a line range of a file:
  `file://src/main.c;beginline=1;endline=20;md5=...` (common when the license
  notice lives in a source file header).

## Version and source

```
PV = "1.2.3"          # version; git sources often use "1.2.3+git${SRCPV}" or the tag directly
PR = "r0"             # recipe revision; bump when recipe logic changes but upstream version doesn't
SRC_URI = "git://github.com/org/repo.git;protocol=https;branch=main"
SRCREV = "abcdef0123456789..."   # explicit commit hash; always pin for production
S = "${WORKDIR}/git"    # root of source after unpack/checkout; the git fetcher defaults to this
```

Tarball source:

```
SRC_URI = "https://example.com/foo-${PV}.tar.gz"
SRC_URI[sha256sum] = "<64-hex>"
S = "${WORKDIR}/foo-${PV}"   # adjust to the actual unpacked top-level dir name
```

Patch files (placed in a `files/` subdir next to the recipe):

```
SRC_URI += "file://0001-fix-cross-compile.patch"
```

## Dependencies

```
DEPENDS = "zlib openssl"          # build-time deps (host/target depending on the class)
RDEPENDS:${PN} = "bash"           # runtime deps; note the PACKAGE override uses ':' (modern bitbake)
DEPENDS += "foo-native"           # explicitly require the native (host-side) build of foo
```

## Build behavior

```
inherit cmake            # or autotools / meson / cargo / setuptools3 / module ...

EXTRA_OECMAKE = "-DBUILD_TESTS=OFF"
EXTRA_OECONF = "--disable-doc"     # autotools
EXTRA_OEMAKE = "CC='${CC}'"        # manual make style

do_install:append() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/foo ${D}${bindir}/foo
}
```

- Override a task with `do_xxx() { ... }`; append/prepend behavior with
  `do_xxx:append()` / `do_xxx:prepend()`. Don't wholesale-override the class's
  default implementation when you can append instead — prefer append over
  override.

## Packaging

```
FILES:${PN} += "${libdir}/foo/*.so"
FILES:${PN}-dev += "${includedir}/foo"
PACKAGES =+ "${PN}-tools"
```

## PACKAGECONFIG (make an upstream optional feature toggleable from distro/local.conf)

```
PACKAGECONFIG ??= "ssl"
PACKAGECONFIG[ssl] = "--with-ssl,--without-ssl,openssl"
```
Format: `<flag>[<config>] = "<configure args when enabled>,<args when disabled>,<extra DEPENDS>,<extra RDEPENDS>"`.
