# Build System → bbclass Mapping

The `build_system` value produced by `scripts/detect_build_system.py` maps to
the table below. The agent uses this to decide which class to `inherit`, and to
watch for each class's common pitfalls.

| build_system | inherit | Common pitfalls |
|---|---|---|
| `autotools` | `autotools` | If upstream doesn't support out-of-tree builds (`./configure` only runs in the source dir), use `inherit autotools-brokensep` instead. Cross-compilation often gets stuck on a stale `config.sub`/`config.guess` → `inherit autotools` usually refreshes them automatically; if not, do it via `EXTRA_AUTORECONF`. |
| `cmake` | `cmake` | The default generator is Ninja. If upstream hardcodes `find_package` to search system paths, cross-compilation may pick up the host's libraries — verify the upstream CMake correctly uses `CMAKE_FIND_ROOT_PATH` (OE's toolchain file sets it, but you still get bitten when the upstream CMakeLists.txt logic is wrong). Add extra `-D` args via `EXTRA_OECMAKE`. |
| `meson` | `meson` | Same cross-compile find traps as cmake; add args via `EXTRA_OEMESON`; meson options use `-Dfoo=enabled/disabled` rather than autotools' `--enable-foo`. |
| `cargo` | `cargo` | **Needs an extra tool:** use `cargo-bitbake` (a standalone tool, NOT bundled in poky) to generate the full crate SRC_URI list from the project's `Cargo.lock` — hand-listing crates is basically infeasible. When offline (`BB_NO_NETWORK`), ensure every crate is listed in SRC_URI and cached; you can't rely on fetching from crates.io at build time. |
| `python3` | `python_setuptools_build_meta` / `python_hatchling` / `python_flit_core` (depending on the `[build-system].build-backend` in `pyproject.toml`), or the older `setuptools3` (only when there's just a `setup.py` and no `pyproject.toml`) | Read the `build-backend` string in `pyproject.toml` before choosing the class; a wrong choice fails in do_compile complaining it can't find the backend. Runtime python deps must be added separately via `RDEPENDS:${PN}` — setuptools won't add them for you. |
| `npm` | needs the `node-npm`/`npm` bbclass from the `meta-nodejs` layer (not in oe-core) | First confirm whether the target has `meta-nodejs` pulled in; if not, confirm with the user whether to add that layer rather than pretending oe-core supports it natively. |
| `kernel-module` | `module` (the `module.bbclass` from `meta`/oe-core) | Must have `inherit module`, and must be able to locate the target kernel's `KERNEL_SRC`/staging (usually via a `virtual/kernel` already built in the same build). Set `KERNEL_MODULE_AUTOLOAD`/`KERNEL_MODULE_PROBECONF` if you want the module auto-loaded at boot. |
| `qmake5` | `qmake5` | Requires the target to already have `meta-qt5` (Qt is no longer in oe-core); confirm the layer exists first. |
| `generic-makefile` | inherit nothing; hand-write `do_compile`/`do_install` | The easiest kind to omit things from: CFLAGS/LDFLAGS cross-compile flags must be threaded into make yourself via `TARGET_CC_ARCH`/`${CC}`; don't assume the upstream Makefile handles the cross-compile prefix correctly. `do_install` must manually `install -d`/`install -m` the artifacts into `${D}` — the class won't do it for you. |
| `unknown` | — | When `detect_build_system.py` isn't confident, first see what class `recipetool create` itself infers — usually more accurate than pure rule-based detection. If still unsure, open the source tree and look for hidden build scripts (`build.sh`, `bootstrap.sh`, …). |

## General rules

- If a standard class fits, don't hand-write `do_compile`/`do_install` — standard
  classes already handle cross-compile flags, parallel make, staging, etc., and
  hand-rolling tends to drop those details.
- Only `generic-makefile` or genuinely unusual upstream build flows need a full
  task override.
