# Build-Failure Symptom → Cause → Fix

The categories emitted by `scripts/parse_bitbake_log.py` map to the table below.
When a build-fix loop iteration fails, look at the category first, then act
along the direction here — don't re-analyze the log from scratch every time.

| category | Common cause | Fix |
|---|---|---|
| `fetch-checksum-mismatch` | `SRC_URI[sha256sum]` is wrong; or the tarball URL points at something whose contents can change (e.g. GitHub's auto-generated tarballs sometimes differ for the same tag); or you're fetching git via `SRCREV` but the hash is wrong | Recompute the correct value with `sha256sum <the downloaded file>` and update it; for git sources use the actual value of `git rev-parse HEAD`. |
| `fetch-failure` | SRC_URI syntax error (missing `protocol=https`, wrong branch name); the URL itself is dead; or `BB_NO_NETWORK=1` is set but the source isn't pre-cached in `DL_DIR` | Check SRC_URI syntax against `references/src-uri-fetchers.md`; for offline environments confirm the file is already in `DL_DIR`. |
| `configure-missing-tool` | A host-side tool that `do_configure` calls (e.g. `pkg-config`, `autoconf`, some `*-native` package) is missing | Add the recipe for that tool to `DEPENDS`, usually `<pkg>-native`; confirm the correct recipe name with `bitbake-layers show-recipes <pkg>`. |
| `compile-missing-header` | Missing the `-dev` package that provides the header | Find which upstream library the header belongs to and add its recipe to `DEPENDS` (e.g. `zlib.h` → `DEPENDS += "zlib"`). |
| `link-missing-lib` | Same as above but at the link stage; or `PACKAGECONFIG` didn't enable the needed feature | Add `DEPENDS`; check whether `PACKAGECONFIG` needs adjusting. |
| `install-no-files` | The upstream build system's install target puts files somewhere other than expected, so `do_install` doesn't populate `${D}`; or `FILES:${PN}` doesn't cover the actual install paths | First manually run the upstream install command against the staged dir to confirm the real output paths, then adjust `do_install` or `FILES:${PN}` accordingly. |
| `qa-issue` | insane.bbclass detected a packaging problem: rpath pointing into the build dir, a binary upstream stripped itself, buildpaths leaking, leftover `.la` files, etc. | Fix the root cause first (e.g. `EXTRA_OECONF = "--disable-static"` to drop `.la`, or disable upstream's own strip). Only use an exception like `INSANE_SKIP:${PN} += "already-stripped"` when you can clearly justify it as safe, and leave a recipe comment explaining why. |
| `license-checksum-mismatch` | The license file contents don't match the md5 in the recipe | Recompute with `md5sum <license file>` and update; also confirm whether the `LICENSE` field needs to change (changed license text may mean the license itself changed). |
| `recipe-name-collision` | The new recipe's `PN` collides with an existing recipe in another layer | Pick a more specific `PN`, or use `BBFILE_PRIORITY` to adjust your layer's priority (only the latter when you deliberately intend to override another layer). |
| `parse-error` | Recipe syntax error, a mistyped variable name, or `inherit` of a nonexistent class | Run `bitbake -e <pn>` to see the full expanded error message, which usually points at the exact line. |
| `ptest-failure` | The package's own test logic failed, possibly related to the cross-compile environment (tests assume host == target) | First confirm whether it's a known upstream cross-compile test limitation; if so, exclude the specific test in the recipe rather than disabling ptest entirely. |
| `task-failed` (fallback when no finer category matched) | Generic message; the real cause is in the lines just before this one for that task | For the `do_xxx` task named in the message, read more context above it; if needed, read the full `${WORKDIR}/temp/log.do_xxx`. |

## General principles

1. **Change only one thing at a time**, then rerun immediately, so you know
   whether that change actually solved the problem.
2. If the same error appears a second time but you've already changed the
   corresponding item → your assumption is probably wrong; look at the log from a
   different angle rather than re-applying the same fix.
3. QA-category errors (`qa-issue`) almost always mean packaging is genuinely
   wrong — don't abuse `INSANE_SKIP` just to make the build pass.
