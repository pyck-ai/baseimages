# Agent Instructions

## Image categories

Images fall into a few kinds:

- **`base`** — a hardened Alpine + Debian foundation with common tooling. Other images **may** build on it, but single-purpose images are not required to; `base` is an option, not a mandatory parent.
- **Developer tooling** — single-purpose language toolchains, package managers, and coding-agent CLIs (`golang`, `typescript`, `python`, `rover`, `agent`). These are bundled together into the [`all-in-one`](docker/all-in-one/README.md) image.
- **`all-in-one`** — the complete developer-tooling set in one image, intended for local development, **not** for CI (size and attack surface).
- **Runtime / deployment images** — `nginx` (web server) and `static` (scratch base for static binaries). These run or serve an application rather than build one; they are consumed standalone and are **intentionally excluded from `all-in-one`**. Do not wire them into it.

Whenever a developer-tooling image is added, removed, or renamed, adjust `all-in-one` to match — it must bundle every developer-tooling image, and only the runtime / deployment images above are exempt.

## Default user

Default `USER` follows the image's role: build-substrate or build-toolchain images (`base` + the developer-tooling set + `all-in-one`) default to **root** and keep a `nonroot` account (uid/gid 1001) reachable via `--user 1001`; run-this-artifact (runtime/deploy) images (`nginx`, `static`) default to **nonroot**. New images must classify accordingly — see the root [`README.md`](README.md) "Conventions" section for the rationale (GitHub Actions job-container compatibility).

## README maintenance

README files in this repository document what each Docker image contains. Keep them accurate and up to date.

**After every change** — regardless of how small — check whether any README is affected and update it before finishing. This is a required final step, not optional cleanup.

### Rules

**When a Dockerfile changes**, update the README in that image's directory:

- Package added or removed: update the package table in the README.
- Tool added, removed, or renamed: update the tools table and any relevant ENV/usage sections.
- Base image changed (e.g. Alpine version bump, Debian release change): update the "Based on" section.
- New environment variable added or an existing one changed: update the ENV table.
- Default user or WORKDIR changed: update the "Default user" section.

**When an image is added**, create a README in the new image's directory following the style of the existing ones, add its checks to [`.imgverify.yaml`](.imgverify.yaml), then add a row to the matching image-kind table and the dependency graph in the root [`README.md`](README.md).

**When an image is removed**, delete its README and its target from [`.imgverify.yaml`](.imgverify.yaml), and remove its row from the matching image-kind table and the dependency graph in the root [`README.md`](README.md).

**When an image is renamed** (tag or directory), update all references in the root [`README.md`](README.md) and any cross-links between image READMEs.

## Image verification

Verification lives in [`.imgverify.yaml`](.imgverify.yaml) at the repo root: a per-target
list of checks against the **assembled** image — default user, `WORKDIR`, `ENV`, tool
versions against `buildargs.conf`, directory writability, and a smoke test of what the
image is for.

CI runs it against the exact digest the build pushed, before any tag moves: the build
stage pushes every target **by digest with no tags**, the verify step resolves each
target to `<repo>@<digest>` and pulls it, and a separate publish step applies the tags
only after that passes. A failed check means the tags never move.

This is not the same as `download.sh --verify`, which checks a tool inside the stage
that installed it. A missing binary, a root-owned cache directory, or a typo'd `USER`
all build green and only surface once the image is run — that class of bug is what
`.imgverify.yaml` exists to catch.

**When a Dockerfile changes**, update `.imgverify.yaml` — not a per-image script:

- Tool added, removed, or renamed: update the version/command checks for that target.
- New environment variable, or a changed value: update the `ENV` checks.
- Default user or WORKDIR changed: update the user/workdir checks.
- A new directory the image must write to at runtime: add a writability check for it.

Ground every check in the Dockerfile. Do not assert something the image does not
actually promise, and prefer a check that exercises real behaviour (`go build`) over one
that only asserts a variable is set.

### What belongs in the READMEs

- **Base image**: exact image name/tag used in the `FROM` line (or "our X base" for internal bases).
- **Packages**: every package installed by `apt-get install` or `apk add`.
- **Tools**: every third-party binary installed via `download.sh`, with a link to the upstream project.
- **ENV variables**: every `ENV` instruction, with its value and a brief description.
- **Default user**: UID, GID, username, and home directory.
- **WORKDIR**: the final working directory.
- **Usage examples**: at least one practical example showing how to consume the image.

Do not include specific version numbers pinned in `buildargs.conf` — those are managed by Renovate and will drift out of date. Reference `buildargs.conf` instead when describing current versions.

### What does NOT belong in the READMEs

- Internal implementation details of `download.sh`.
- Intermediate build stage names or multi-stage build mechanics.
- CI pipeline specifics (those live in `.github/workflows/`).
