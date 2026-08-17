---
name: yocto-recipe-gen
description: Generate and iteratively repair Yocto/OpenEmbedded BitBake recipes (.bb / .bbappend) from arbitrary source input — a git URL, a tarball URL or local path, or an existing local source directory. Use this skill whenever the user asks to "write a Yocto recipe", "package X for Yocto/OpenEmbedded", "add a recipe to a meta-layer", "port this source into my BSP", or "fix a bitbake recipe that fails to build". Drives an automated build -> diagnose -> patch loop against a real bitbake build environment until the recipe builds cleanly or a retry budget is exhausted.
license: MIT
metadata:
  domain: yocto-bsp
  requires: bitbake, git, an initialized poky/OE build environment
---

# Yocto Recipe Generator + Build-Fix Loop

You are the executor of this skill, acting as a senior Yocto/OpenEmbedded BSP
engineer. Your job has two phases:
**(A) produce a correct, clean BitBake recipe from the source the user
provides**, and
**(B) use a real bitbake build as ground truth, looping build → read error →
fix recipe, until the build succeeds or a retry budget is exhausted.**

Never guess at bitbake's behavior — always defer to what actually happens when
you run it. Every conclusion must be backed by a build log.

## 0. Prerequisites (do this every time you start)

### 0a. Environment sourcing — the easiest thing to get wrong, handle it first

**Every Bash command you run is a fresh shell**; an environment you `source`d
in one command is gone by the next. So you must never "source once at the start
and assume later bitbake calls inherit it" — every place that actually invokes
bitbake has to source the environment itself. This skill already handles that
for you; you just need to configure it.

**If `.yocto-recipe-gen.conf` already exists, do not ask again.** Read it, tell
the user which script you're using in one line, and go straight to 0b — the
verification there is what decides whether it works, not another round of
questions. Only fall through to the question below when there is no config, or
when 0b fails against the configured script.

**Otherwise, MANDATORY FIRST STEP — ask before doing anything else.** Before you
run a single bitbake/recipetool/layer command, before you stage any source,
before any other action, you MUST ask the user this question and wait for the
answer:

> "Do you have your own environment setup script (one that sources
> `oe-init-build-env`, and possibly your SDK environment too)? If yes, please
> give me its exact path or filename. If no, I'll use the standard
> `oe-init-build-env`."

Then branch on the answer:

- **The user HAS their own script:** they MUST tell you its path or filename —
  do not guess it, do not proceed without it. If they say "yes" but don't give a
  path, ask again for the exact path/filename before continuing. Write that path
  into `ENV_SETUP` (see below). Such a script commonly also sources an SDK cross
  toolchain, which is exactly why we defer to it rather than calling
  `oe-init-build-env` ourselves.
- **The user does NOT have their own script:** use the standard
  `oe-init-build-env`. Ask for (or confirm) the poky path and the build dir, then
  set `ENV_SETUP` to point at a tiny wrapper you write for them whose body is
  `source /path/to/poky/oe-init-build-env /path/to/builddir`, or point `ENV_SETUP`
  directly at poky's `oe-init-build-env` (it is sourceable) with the build dir in
  `ENV_SETUP_ARGS`.

Write the result into `.yocto-recipe-gen.conf` in the **working directory**
(format: see `examples/yocto-recipe-gen.conf.example`):
   ```sh
   ENV_SETUP="/abs/path/to/the-users/setup-build-env.sh"
   # If that script needs arguments (e.g. a build dir name):
   # ENV_SETUP_ARGS="build"
   ```

**If the project is managed by kas / repo / west, `ENV_SETUP` must point at a
sourceable equivalent — not at the tool itself.** `kas shell project.yml` spawns
a *child* shell; there is no way for it to hand its environment back to the
caller, and `env_setup.sh` sources the script into the current one. The same
goes for anything else that wraps the build in a subprocess. Write a small
wrapper that sources the underlying pieces directly, e.g. for kas:

```sh
# setup-build-env.sh — sourceable, unlike `kas shell`
. /path/to/project/env.sh                                    # KAS_MACHINE, DL_DIR, SSTATE_DIR…
. /path/to/project/oe-core/oe-init-build-env /path/to/build
```

Watch for variables the tool would normally inject: if `DL_DIR`/`SSTATE_DIR`
only reach bitbake through the tool's environment passthrough, a wrapper that
forgets them silently re-downloads everything into `build/downloads`. Note also
that this path does *not* regenerate `local.conf`/`bblayers.conf` or re-align
layer checkouts, so after changing the tool's project file the user must run it
once (e.g. `kas shell project.yml -c true`) before your next build.

**Hard gate:** you may not take any recipe-related action until 0b confirms the
sourcing actually succeeded. If you cannot get a working sourced environment,
stop and tell the user — do not attempt to work around it.

From then on:

- **Run every one-off bitbake-family command** (`bitbake-layers`,
  `recipetool`, `bitbake -e`, `devtool`, `oe-pkgdata-util`, …) through
  `scripts/run_in_env.sh <command>`, e.g.
  `scripts/run_in_env.sh bitbake-layers show-layers`. That wrapper sources
  the configured environment script first, then runs the command.
- **`scripts/build_loop.sh` sources the environment on its own** (reading the
  same `.yocto-recipe-gen.conf`), so you do NOT wrap it in `run_in_env.sh` —
  call it directly.
- If the user insists "I'm already in a sourced interactive shell, just run
  bitbake directly" and the config is left empty, `run_in_env.sh` /
  `build_loop.sh` will print a warning and assume the environment is already
  present — but since each Bash command is a fresh shell this usually does
  NOT hold, so **by default always configure `.yocto-recipe-gen.conf`**.

### 0b. Verify the environment actually works (the gate that unlocks all other work)

You may NOT generate, edit, or build any recipe until both checks below pass.
This is the confirmation that "sourcing actually succeeded" required by 0a.

1. Run `scripts/run_in_env.sh bitbake --version` to confirm bitbake really is on
   PATH after sourcing.
   - If it fails, **stop** and tell the user. If they gave their own script,
     report that sourcing it did not put bitbake on PATH and ask them to
     double-check the path/filename or the script itself. If we're using the
     standard `oe-init-build-env`, ask them to confirm the poky path. Do NOT try
     to install or bootstrap a whole poky tree yourself — that is the user's
     environment to own, and do NOT proceed with any recipe work until this
     passes.
2. Run `scripts/run_in_env.sh bash -c 'echo $BUILDDIR; ls $BUILDDIR/conf/bblayers.conf'`
   to confirm `BUILDDIR` is set and `bblayers.conf` exists.

Only once both checks pass may you move on to 0c and the rest of the workflow.

### 0c. Pick the target layer

1. List the current layers with `scripts/run_in_env.sh bitbake-layers show-layers`
   and decide which layer the new recipe belongs in (remember: all bitbake-family
   commands go through `run_in_env.sh`, see 0a):
   - If the user named a layer, use it.
   - Otherwise prefer a custom layer whose name looks like `meta-<vendor>` /
     `meta-bsp` and that has its own `recipes-*` dirs. Do NOT drop the new recipe
     into upstream core layers like `meta` / `meta-poky` / `meta-yocto-bsp`.
   - If there is genuinely no suitable custom layer, create one with
     `scripts/run_in_env.sh bitbake-layers create-layer ../meta-<name>` and
     `scripts/run_in_env.sh bitbake-layers add-layer ...` — but **confirm the
     layer name with the user first** (this is their project's naming, don't
     invent it for them).
   - **If `bblayers.conf` is generated by a tool (kas, repo, west), do not use
     `add-layer`.** It appears to work and is silently reverted the next time
     the tool runs, surfacing much later as "recipe not found". Add the layer to
     that tool's project file instead and re-run it. For kas, a local layer that
     kas should not version-manage is a `repos:` entry with a path and no url:

     ```yaml
     repos:
       meta-<name>:
         path: meta-<name>
     ```

     Then confirm it took effect with `bitbake-layers show-layers`.
2. Confirm the new recipe's `PN` does not already exist
   (`scripts/run_in_env.sh bitbake-layers show-recipes <pn>`) to avoid a name
   collision with an existing recipe.

## 1. Classify the input

The user's input may be:

| Type | How to recognize it |
|---|---|
| Git URL | starts with `git://` / `git@`, or ends in `https?://...\.git`, or is a repo URL on a common host (github.com / gitlab.com / bitbucket.org …) |
| Archive (URL or local path) | extension `.tar.gz` `.tgz` `.tar.bz2` `.tar.xz` `.zip` |
| Local source path | an existing local directory |

Call `scripts/fetch_source.sh <input> [<ref>]`. It returns a parseable summary of
`key=value` lines (`SRC_TYPE=`, `STAGE_DIR=`, `RESOLVED_VERSION=`,
`SRC_URI_BB=`, `SRCREV=`, …). Stage the source into a scratch dir for analysis
first — **do not write anything into a layer yet**.

For a git input, pass the user's chosen version as `<ref>` (see the next
subsection). Called without it, the script stages the default branch HEAD and
reports `VERSION_PINNED=no` plus an `AVAILABLE_TAGS=` list — that is material
for asking the version question, **not** a version you may proceed with.

### For a git URL: ask which version to use before you act

When the input is a git URL, **before fetching or building anything you MUST ask
the user which version they want** — the specific tag / release / branch /
commit to pin (the "版號"). Do not silently default to the latest commit on the
default branch; a production BSP recipe must be pinned to a version the user
actually chose. Ask something like:

> "Which version of this repo should the recipe pin to — a specific tag/release,
> a branch, or a particular commit? (I'll pin `SRCREV`/`PV` to whatever you
> choose.)"

- If the user names a tag/branch/commit, check it out in the staged clone and
  derive `PV`/`SRCREV` from it (see section 2).
- Only if the user explicitly says "just use the latest" do you fall back to the
  default branch HEAD — and even then, still pin `SRCREV` to that exact commit
  hash (never leave it floating), and tell the user which commit you pinned.

### Two strategies for a local-path input — always confirm which one the user wants

A local directory input is common in BSP development, and there are two correct
approaches whose behavior differs a lot. **Default to externalsrc (dev mode),
but if the user's intent sounds like "I want an upstream, reproducible recipe",
use vendor-tarball mode instead; when unsure, just ask the user:**

- **externalsrc (dev mode, default):** `inherit externalsrc`,
  `EXTERNALSRC = "<absolute path>"`, no fetch/unpack, builds the user's working
  tree in place. Good for "I'm editing this code and want to bitbake as I go."
  **No version pinning, not reproducible** — only for local iteration.
- **vendor tarball (reproducible mode):** pack the local dir into
  `<pn>-<pv>.tar.gz` under the layer's `files/`, with
  `SRC_URI = "file://<pn>-<pv>.tar.gz"`. Good for "this code has no upstream
  repo, but I want a recipe that CI / other people can reproduce."

Look up the exact syntax for both in `references/src-uri-fetchers.md`.

## 2. Decide PN / PV

- Git: use `git describe --tags` or the latest tag for PV, and
  `git rev-parse HEAD` for SRCREV. **Do not use `SRCREV = "${AUTOREV}"`** unless
  the user explicitly asked for floating/dev usage — a production BSP recipe must
  pin to an explicit commit, and the reason should be stated in a recipe comment.
- Tarball: extract the version from the filename or from a bundled
  `configure.ac` (`AC_INIT`), `CMakeLists.txt` (`project(... VERSION ...)`),
  `Cargo.toml`, `pyproject.toml`/`setup.py`, or `package.json`.
- Derive PN from the repo/folder/project name, lowercased, underscores turned to
  hyphens (per recipe naming convention).

## 3. Check for an existing recipe first — don't reinvent the wheel

Once you know the likely `PN` (and any obvious aliases), **before drafting
anything, check whether a recipe already exists upstream or in the available
layers.** Writing a brand-new recipe for something oe-core or a well-known layer
already ships is wasted effort and diverges from what the ecosystem maintains.
Check, in order:

1. **Locally available layers.** Run
   `scripts/run_in_env.sh bitbake-layers show-recipes '*<name>*'` (and try
   obvious aliases, e.g. with/without a `lib` prefix, `-` vs `_`). Also try
   `scripts/run_in_env.sh oe-pkgdata-util lookup-recipe <name>` if available.
2. **The OpenEmbedded Layer Index** — the canonical registry of upstream recipes
   across all public layers. Search it for the package name (the web UI is at
   `https://layers.openembedded.org/layerindex/branch/master/recipes/`; use web
   search / WebFetch to query it). This catches recipes that live in a layer the
   user hasn't added yet.
3. **Upstream / meta-openembedded.** For common libraries and tools, check
   whether `meta-oe` or another standard layer already has it.

If you have no web access, do at least the local checks (step 1) and tell the
user you couldn't consult the online layer index, so they can double-check
before you write a duplicate.

Then decide with the user:

- **A recipe already exists in an added layer** → do NOT write a duplicate. Tell
  the user it exists and where; if they need changes, prefer a `.bbappend` in
  their own layer over a fresh recipe.
- **A recipe exists in a layer that isn't added yet** → tell the user the layer
  name and let them decide whether to add that layer (via `bitbake-layers
  add-layer`) instead of vendoring a private copy. Adding the maintained layer is
  usually better than reinventing it.
- **Nothing exists anywhere** → proceed to write a new recipe (sections 4–6).

Only skip this check when the source is clearly a private/in-house project with
no chance of an upstream recipe (e.g. a local-dir input for the user's own code).

## 4. Detect the build system

Run `scripts/detect_build_system.py <stage_dir>` to get JSON:
`{"build_system": "...", "confidence": "...", "hints": [...]}`. Cross-reference
`references/bbclasses.md` to decide which bbclass to `inherit` and the common
pitfalls of that class (see the table in that file).

## 5. Draft the recipe — start with recipetool, don't hand-write from scratch

`recipetool` is the automatic recipe generator built into openembedded-core,
living in the same poky checkout as you. Always get a baseline from it first and
then refine by hand, rather than writing a recipe from nothing:

```sh
scripts/run_in_env.sh recipetool create -o <pn>_<pv>.bb "<src_uri>"
```

`recipetool` is usually close on SRC_URI / build system / some license guesses,
but **you must re-check these four things yourself — recipetool frequently gets
them wrong or incomplete**:

1. `LICENSE` / `LIC_FILES_CHKSUM` — use `scripts/license_scan.py <stage_dir>` as
   a scanning aid, but the final call requires you to read the license file
   contents yourself (legal-compliance risk, see `references/license-guide.md`).
2. `SRCREV` (is it pinned to an explicit commit rather than a branch HEAD?).
3. `DEPENDS` (recipetool often misses build-time deps; these get filled in once
   the build loop runs, see section 6).
4. `do_install` (non-standard build systems often need a manual override).

Put the refined file at `<layer>/recipes-<category>/<pn>/<pn>_<pv>.bb`. For
`<category>`, follow the existing `recipes-*` naming convention in that layer;
if nothing fits, use `recipes-support`. The `templates/` dir has clean skeletons
per build system to cross-check against so you don't omit required fields.

## 6. Build-Fix Loop (this is the core of the skill)

**You yourself are the loop** — this is not a script that auto-retries. The flow
is: you call the build script once, understand the result, edit the recipe by
hand, and call again. Every iteration must follow:

1. Run `scripts/build_loop.sh <pn> <iteration_number>`. It will:
   - Run `bitbake -e <pn> >/dev/null` as a parse-only check first (fast, catches
     syntax/variable errors without waiting for a real compile).
   - Only if parse passes, run `bitbake <pn>`.
   - Save the build log to `./yocto-recipe-gen-logs/<pn>/iter-<n>.log` and the
     `bitbake -e` dump separately to `iter-<n>.parse.log` (that dump is tens of
     thousands of lines and would bury the build output), then pass the
     relevant one through `scripts/parse_bitbake_log.py` to produce a condensed
     error summary (category + the key few dozen lines), printed to stdout.
   - Report success/failure via exit code — don't reinvent the success check.
2. On success (exit 0): jump to section 7, finishing up.
3. On failure:
   - Read the condensed summary `build_loop.sh` printed, and cross-reference
     `references/error-fix-map.md` to map the symptom to its common cause and
     fix.
   - **Change only one thing at a time**, and keep a record (mentally, or in your
     explanation to the user) of "what I changed this round and why" to avoid
     re-trying the same ineffective fix.
   - If the layer is a git repo (recommend up front that the user keeps the layer
     under git), `git diff` your changes after each iteration for traceability;
     if a change made things worse, revert with git and try another direction —
     don't pile contradictory edits onto the same file.
   - Common fix mapping (details in error-fix-map.md):
     - `do_fetch` checksum mismatch → recompute `SRC_URI[sha256sum]`, or if the
       upstream tag moved → switch to an explicit-commit `SRCREV`.
     - `do_configure`/`do_compile` can't find a header/lib (`fatal error:
       foo.h`, `cannot find -lfoo`) → add the matching `DEPENDS` (first check
       whether a recipe for that lib already exists via `oe-pkgdata-util` or by
       searching existing layers; don't invent a dependency name).
     - `do_install`: "No files in ${D}" or the files to install can't be found →
       inspect the upstream Makefile/CMake install target, override `do_install`,
       and add `EXTRA_OEMAKE`/`EXTRA_OECMAKE` args if needed.
     - `QA Issue` (`insane.bbclass`) → these warnings usually mean packaging is
       genuinely wrong (rpath, already-stripped, buildpaths, …). **Fix the root
       cause first**; only consider `INSANE_SKIP` when you can clearly explain
       why it's safe, and leave a recipe comment stating the reason.
     - `LIC_FILES_CHKSUM` mismatch → re-`md5sum` the license file and update the
       value; if the license file content really changed, go back and confirm
       whether the `LICENSE` field should change too.
   - After fixing, return to step 1 with `iteration_number` incremented.
4. **Retry budget:** default max 8 iterations. Before ending each iteration,
   check you still have budget; if you're about to exceed the limit without
   success, **do not retry forever** — stop and give the user a clear diagnostic
   report (see section 8, failure wrap-up).

### Token-efficiency reminder

A bitbake log can be enormous. **Always judge from the condensed
`parse_bitbake_log.py` summary**, don't stuff the whole log into your context;
only when the condensed summary is insufficient to determine the root cause
should you use `grep`/`tail` to read specific sections of the raw log on
purpose.

## 7. Success wrap-up

1. After a successful build, additionally run
   `scripts/run_in_env.sh bitbake -c package_qa <pn>` (if the recipe goes through
   the package pipeline) to confirm no lingering QA warnings.
2. Use `git diff` (if the layer is under git) to compile the list of files added
   or modified this time.
3. Summarize for the user:
   - the recipe path
   - how many iterations it ultimately took
   - key decisions: the basis for the LICENSE call, how SRCREV / the version was
     pinned, which DEPENDS were added, and whether externalsrc dev mode was used
     (if so, remind the user this recipe is not yet reproducible and must be
     switched to tarball/git+SRCREV mode before productionizing).
   - explicitly list the items that are "my automatic judgment, please review
     manually" — the license field always goes on this list.

## 8. Failure wrap-up (retry budget exceeded)

Don't hide a failure. Report clearly:

- the current recipe contents and the list of fixes already attempted (so the
  user, or the next conversation round, doesn't repeat the same attempts).
- the condensed error summary from the last iteration, plus the full log path
  (`./yocto-recipe-gen-logs/<pn>/iter-<n>.log`).
- what you think the underlying blocker is, and if the work continues, what to
  investigate next (e.g. the user needs to confirm the correct recipe name for a
  private dependency, or the upstream build system has non-standard behavior that
  requires reading the upstream docs).

## Fixing an existing recipe (not generating from scratch)

If the user gives you the path to an existing `.bb`/`.bbappend` that fails to
build, skip sections 1–5 and start straight from the build-fix loop in
section 6.

## Helper tools

- `scripts/run_in_env.sh <cmd>` — source the project's Yocto+SDK environment,
  then run `<cmd>`; all one-off bitbake-family commands go through this (see 0a).
- `scripts/fetch_source.sh <input> [<ref>]` — classify and stage the source;
  pass the user's chosen tag/branch/commit as `<ref>` (see section 1).
- `scripts/build_loop.sh <pn> <n>` — run one build iteration (sources the
  environment itself), save the log, and print the condensed error summary.
- `scripts/env_setup.sh` — the shared environment-resolution logic used by the
  two above (sourceable, not executed directly).
- `.yocto-recipe-gen.conf` — the config file in the working dir; use
  `ENV_SETUP=` to point at the user's environment script.

## Reference material

- `references/recipe-syntax.md` — quick reference for common BitBake recipe variables
- `references/bbclasses.md` — build system → inherit-class mapping and each one's pitfalls
- `references/error-fix-map.md` — build-failure symptom → cause → fix
- `references/src-uri-fetchers.md` — SRC_URI fetcher syntax (git/wget/file/externalsrc…)
- `references/license-guide.md` — principles for writing LICENSE / LIC_FILES_CHKSUM
- `templates/*.bb.tmpl` — clean recipe skeletons per build system
