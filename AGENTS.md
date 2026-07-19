# Agent Instructions

## Image categories

Images fall into a few kinds:

- **`base`** — a hardened Alpine + Debian foundation with common tooling. Other images **may** build on it, but single-purpose images are not required to; `base` is an option, not a mandatory parent.
- **Developer tooling** — single-purpose language toolchains, package managers, and coding-agent CLIs (`golang`, `typescript`, `python`, `rover`, `agent`). These are bundled together into the [`all-in-one`](docker/all-in-one/README.md) image.
- **`all-in-one`** — the complete developer-tooling set in one image, intended for local development, **not** for CI (size and attack surface).
- **Runtime / deployment images** — `nginx` (web server), `flutter` (application SDK/runtime), and `static` (scratch base for static binaries). These run or serve an application rather than build one; they are consumed standalone and are **intentionally excluded from `all-in-one`**. Do not wire them into it.

Whenever a developer-tooling image is added, removed, or renamed, adjust `all-in-one` to match — it must bundle every developer-tooling image, and only the runtime / deployment images above are exempt.

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

**When an image is added**, create a README in the new image's directory following the style of the existing ones, then add a row to the matching image-kind table and the dependency graph in the root [`README.md`](README.md).

**When an image is removed**, delete its README and remove its row from the matching image-kind table and the dependency graph in the root [`README.md`](README.md).

**When an image is renamed** (tag or directory), update all references in the root [`README.md`](README.md) and any cross-links between image READMEs.

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
