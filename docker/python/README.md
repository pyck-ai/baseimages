# Python Images

Python development images with [uv](https://github.com/astral-sh/uv) for package management and [Ruff](https://github.com/astral-sh/ruff) for linting and formatting.

## Variants

| Variant | Tag | Based on |
|---------|-----|----------|
| Alpine | `python:alpine` | our [base](../base/README.md) (Alpine) + musl-managed CPython |
| Debian | `python:debian` | our [base](../base/README.md) (Debian) + glibc-managed CPython |

Both variants install the same uv-managed CPython via [python-build-standalone](https://github.com/astral-sh/python-build-standalone); the Alpine variant uses a musl build, the Debian variant a glibc build.

Current versions are pinned in [`buildargs.conf`](../../buildargs.conf) (`PYTHON_VERSION`, `UV_VERSION`, `RUFF_VERSION`).

## Tags

### Alpine tags

| Tag | Description |
|-----|-------------|
| `python:latest` | Most recent build (Alpine) |
| `python:alpine` | Most recent build (Alpine) |
| `python:<major>` | Major-version alias |
| `python:<major>.<minor>` | Minor-version alias |
| `python:<major>-alpine` | Major-version alias, explicit suffix |
| `python:<major>.<minor>-alpine` | Minor-version alias, explicit suffix |

### Debian tags

| Tag | Description |
|-----|-------------|
| `python:debian` | Most recent build (Debian) |
| `python:<major>-debian` | Major-version alias |
| `python:<major>.<minor>-debian` | Minor-version alias |

## What is included

### Python

Python is installed via `uv python install` using [python-build-standalone](https://github.com/astral-sh/python-build-standalone) distributions. The install is self-contained under `UV_PYTHON_INSTALL_DIR` - no system Python is involved.

The following binaries are symlinked into `/usr/local/bin`:

| Binary | Alpine | Debian | Description |
|--------|--------|--------|-------------|
| `python<major>.<minor>` | ✅ | ✅ | Versioned Python interpreter |
| `python3` | ✅ | ✅ | Alias for the versioned interpreter |
| `python` | ✅ | ✅ | Alias for `python3` |
| `pip<major>.<minor>` | ✅ | ✅ | Versioned pip |
| `pip3` | ✅ | ✅ | Alias for the versioned pip |
| `pip` | ✅ | ✅ | Alias for `pip3` |
| `pydoc<major>.<minor>` | ✅ | ✅ | Versioned pydoc |
| `pydoc3` | ✅ | ✅ | Alias for the versioned pydoc |
| `pydoc` | ✅ | ✅ | Alias for `pydoc3` |

### Tools

| Tool | Binary | Alpine | Debian | Source |
|------|--------|--------|--------|--------|
| [uv](https://github.com/astral-sh/uv) | `uv` | ✅ | ✅ | GitHub release, `UV_VERSION` |
| [uv](https://github.com/astral-sh/uv) | `uvx` | ✅ | ✅ | symlink to `uv` (`uv tool run`) |
| [Ruff](https://github.com/astral-sh/ruff) | `ruff` | ✅ | ✅ | GitHub release, `RUFF_VERSION` |

### Environment

| Variable | Value | Description |
|----------|-------|--------------|
| `UV_PYTHON_INSTALL_DIR` | `/usr/local/python` | Where uv installs managed Python versions |
| `UV_PYTHON_PREFERENCE` | `only-managed` | Always use the uv-managed Python, never the system one |
| `PYTHONDONTWRITEBYTECODE` | `1` | Suppress `.pyc` file generation |
| `PYTHONUNBUFFERED` | `1` | Force unbuffered stdout/stderr for clean container logs |

The Debian variant also inherits `DEBIAN_FRONTEND` from [base](../base/README.md).

### Default user

**Build image, not a hardened runtime base** — if you `FROM` this for a deployment image, set `USER` in your final stage (same as the official `golang`/`python` images).

Runs as **root (uid 0) by default**. A `nonroot` account (uid/gid 65532) still exists, and `/usr/local/python` is nonroot-owned, so `uv python install` of an additional version also works under `--user 65532`. `WORKDIR` is `/app`.

## Usage

### Run a script

```sh
docker run --rm \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/python:latest \
  python script.py
```

Run unprivileged instead of the root default:

```sh
docker run --rm --user 65532 ghcr.io/pyck-ai/baseimages/python:latest python --version
```

### Install dependencies with uv

```sh
docker run --rm \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/python:latest \
  uv sync
```

### As a build stage

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/python:latest AS build
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev
COPY . .
```

## Build

```sh
task build -- python          # build both alpine and debian variants
task build -- python-alpine   # alpine only
task build -- python-debian   # debian only
```
