# Agent Instructions

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

**When an image is added**, create a README in the new image's directory following the style of the existing ones, then add a row to the table and the dependency graph in the root [`README.md`](README.md).

**When an image is removed**, delete its README and remove its row from the root [`README.md`](README.md) table and dependency graph.

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
