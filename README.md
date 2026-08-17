# yocto-recipe-gen

**English** | [繁體中文](README.zh-TW.md)

An [Agent Skill](https://agentskills.io) for [OpenCode](https://opencode.ai)
that lets Qwen (or any model you configure) generate a Yocto/OpenEmbedded
BitBake recipe from source you point it at — a git URL, a tar.gz (URL or local
path), or a local directory — and then run a "build → read error → fix recipe"
loop using real `bitbake` builds as ground truth, until the build succeeds or a
retry budget is hit.

The skill itself is just a set of instructions for the LLM (`SKILL.md`) plus a
few helper scripts. **Running it still requires you to already have an
initialized Yocto/poky build environment** (something you can `source`); the
skill will not bootstrap a whole poky tree for you.

## What the skill does

1. **Classifies the input**: git URL / archive (URL or local path) / local
   directory, fetching the source accordingly. For a git URL it first asks which
   version (tag / branch / commit) to pin. A local directory prompts a choice
   between "dev mode" (`externalsrc`, fast but not reproducible) and "vendor
   tarball" (packed into the layer, reproducible).
2. **Checks for an existing recipe first** — searches the available layers and
   the OpenEmbedded Layer Index so it doesn't reinvent a recipe upstream already
   maintains, preferring a `.bbappend` or adding the maintained layer when one
   exists.
3. **Detects the build system** (autotools / cmake / meson / cargo / python3 /
   kernel module / qmake / plain Makefile) and maps it to the right bitbake
   class.
4. **Gets a baseline from `recipetool create`**, then the agent refines the
   spots `recipetool` commonly gets wrong: LICENSE / `LIC_FILES_CHKSUM`, the
   `SRCREV` pin, `DEPENDS`, and `do_install`.
5. **Build-fix loop**: repeatedly runs `bitbake <recipe>`, condenses the
   (often huge) build log into a categorized error summary, and edits the
   recipe along a built-in symptom → cause → fix map, until success or the
   retry budget (default 8 iterations), keeping each iteration's full log and a
   record of changes.
6. Can also point at an **existing recipe that fails to build**, skipping
   generation and going straight into the build-fix loop.

## Project layout

```
SKILL.md                  the full workflow the agent follows (the core file)
scripts/
  fetch_source.sh          classify the input and stage the source
  detect_build_system.py   scan the source tree to guess the build system
  license_scan.py          find license files, compute md5, roughly guess SPDX (aid, not authoritative)
  parse_bitbake_log.py     condense a bitbake log into a categorized error summary
  build_loop.sh            run one build iteration (parse-only check + real build), save the log
  run_in_env.sh            source the project's Yocto+SDK env, then run a bitbake-family command
  env_setup.sh             shared env-resolution logic (sourced by the two scripts above)
references/                background: recipe syntax, bbclass mapping, error-fix map, etc.
templates/                 clean .bb skeletons per build system
examples/
  opencode.json.example              example provider/agent config (Qwen + suggested bash permissions)
  yocto-recipe-gen.conf.example      example env-config file
```

## Install

This skill uses the open [`SKILL.md`](https://agentskills.io) standard, so it
installs the same way in both OpenCode and Claude Code: it's a folder named after
the skill dropped into a `skills/` directory the tool scans. **The folder name
must equal the `name` in the `SKILL.md` frontmatter (`yocto-recipe-gen`)**,
independent of this GitHub repo's own name — so specify the target folder name
when you clone.

### OpenCode

OpenCode walks up from the current directory looking for
`.opencode/skills/<name>/SKILL.md`, `.claude/skills/<name>/SKILL.md`,
`.agents/skills/<name>/SKILL.md`, or the global
`~/.config/opencode/skills/<name>/SKILL.md`.

```sh
# Global install (available to all projects)
git clone git@github.com:WangHanChi/Yocto-agent.git ~/.config/opencode/skills/yocto-recipe-gen

# Or install into one BSP project only
git clone git@github.com:WangHanChi/Yocto-agent.git /path/to/your/bsp-project/.opencode/skills/yocto-recipe-gen
```

### Claude Code

Claude Code loads skills from `~/.claude/skills/<name>/SKILL.md` (personal, all
projects) or `.claude/skills/<name>/SKILL.md` inside a project.

```sh
# Personal install (available to all projects)
git clone git@github.com:WangHanChi/Yocto-agent.git ~/.claude/skills/yocto-recipe-gen

# Or install into one BSP project only
git clone git@github.com:WangHanChi/Yocto-agent.git /path/to/your/bsp-project/.claude/skills/yocto-recipe-gen
```

Then in a Claude Code session run `/skills` (or just ask for a Yocto recipe) and
the skill is picked up automatically. The build-environment configuration below
(`.yocto-recipe-gen.conf`) applies to both tools identically.

> **Note on the model.** The Qwen provider setup below is OpenCode-specific.
> Claude Code runs the skill on whatever model Claude Code is configured to use;
> the skill's logic (recipe generation + build-fix loop) is model-agnostic and
> works either way.

## Configure the Qwen model (OpenCode)

See `examples/opencode.json.example` and merge it into your `opencode.json` (or
`~/.config/opencode/opencode.json`), adjusting `baseURL` / `apiKey` / model name
for whichever Qwen provider you actually use (DashScope / Alibaba Cloud, a local
Ollama, or another OpenAI-compatible endpoint). The example sets common bitbake
commands to `allow`, `rm -rf /*` to `deny`, and everything else to `ask` — tune
to your trust level.

## Configure your build environment (important)

Because **each agent tool call runs in a fresh shell**, an environment you
`source`d in one command is gone by the next. So the skill re-sources your
environment before every bitbake command. You point it at your environment
script via a config file.

As a hard rule, before doing anything the agent first asks whether you have your
own setup script. If you do, you must give it the exact path/filename; if you
don't, it falls back to the standard `oe-init-build-env`. Either way it will not
start any recipe work until it has confirmed the environment sources
successfully.

Create `.yocto-recipe-gen.conf` in the directory you run the agent from (where
you would normally `source` your env), based on
`examples/yocto-recipe-gen.conf.example`:

```sh
# Absolute path to the script that does `source oe-init-build-env` AND
# sources your SDK environment (cross toolchain), if you have one.
ENV_SETUP="/home/you/yocto/setup-build-env.sh"
# Optional args for that script, e.g. a build dir name:
# ENV_SETUP_ARGS="build"
```

- All one-off bitbake-family commands run through `scripts/run_in_env.sh <cmd>`,
  which sources `ENV_SETUP` first.
- `scripts/build_loop.sh` sources it on its own, so you don't wrap that one.
- If you only use the standard `oe-init-build-env` with no SDK, point
  `ENV_SETUP` at a one-line wrapper (`source /path/to/poky/oe-init-build-env
  /path/to/builddir`) or directly at poky's `oe-init-build-env`.

### If your project is managed by kas, repo, or west

`ENV_SETUP` has to be **sourceable**. `kas shell project.yml` is not: it spawns
a child shell, so it cannot hand its environment back to the caller. Point
`ENV_SETUP` at a small wrapper that sources the underlying pieces instead:

```sh
# setup-build-env.sh
. /path/to/project/env.sh                                    # KAS_MACHINE, DL_DIR, SSTATE_DIR…
. /path/to/project/oe-core/oe-init-build-env /path/to/build
```

Include whatever variables the tool would normally inject — if `DL_DIR` and
`SSTATE_DIR` only reach bitbake through its environment passthrough, a wrapper
that omits them quietly re-downloads everything into `build/downloads`.

Two further consequences worth knowing:

- This path does not regenerate `local.conf` / `bblayers.conf` or re-align layer
  checkouts. After editing the tool's project file, run it once (e.g. `kas shell
  project.yml -c true`) before the next build.
- **Do not add layers with `bitbake-layers add-layer`** — a generated
  `bblayers.conf` is rewritten on the tool's next run and your layer disappears,
  usually surfacing much later as "recipe not found". Add it to the project file
  instead; for kas, a local layer is a `repos:` entry with a path and no url:

  ```yaml
  repos:
    meta-yourlayer:
      path: meta-yourlayer
  ```

### Runtime artifacts

The scripts create two directories in the directory you run the agent from.
Neither belongs in version control, so add them to your project's `.gitignore`:

```gitignore
yocto-recipe-gen-logs/       # per-iteration build logs
.yocto-recipe-gen-scratch/   # staged sources for analysis
.yocto-recipe-gen.conf       # points at a local path; keep it untracked
```

## Usage

In a Yocto project directory (one whose environment you can source), open
OpenCode and just describe what you want, e.g.:

```
Make a Yocto recipe from the repo https://github.com/example/foo, put it in
meta-mylayer, and make sure it builds.
```

Or fix an existing failing recipe:

```
The recipe meta-mylayer/recipes-support/foo/foo_1.0.bb fails to build, fix it.
```

The agent follows the `SKILL.md` workflow through the whole
"generate → build → read error → fix → rebuild" loop, and at the end (success or
failure) gives you a clear summary of the key decisions it made — especially
LICENSE, **which you must review manually**.

## Limitations & notes

- **Requires a real bitbake environment**: the skill will not (and should not)
  install or initialize a whole poky tree; it assumes you're in a directory where
  bitbake can run.
- **The LICENSE call is an aid, not authoritative**: `license_scan.py` is only
  keyword matching; any auto-detected license field needs manual review before
  production use. `SKILL.md` / `references/license-guide.md` require the agent to
  surface this in every summary.
- **cargo / npm / qmake5 need extra layers or tools** (`meta-nodejs`,
  `meta-qt5`, `cargo-bitbake`): the skill will flag what's missing but won't add
  layers or install tools for you.
- Keep the meta-layer you're modifying under git; the build-fix loop recommends
  `git diff`/`git checkout` each iteration to track and revert changes.

## Roadmap

- Integrate the `devtool` workflow (`devtool add`/`devtool build` to replace some
  manual steps).
- Auto-invoke `cargo-bitbake`, replacing the currently-manual crate SRC_URI list.
- Batch mode: handle multiple interdependent recipes at once (e.g. an upstream
  mono-repo split into several packages).
- Dedicated ptest failure diagnosis and repair flow.

## License

MIT, see [LICENSE](LICENSE).
