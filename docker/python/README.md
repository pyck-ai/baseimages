# Python Image

Python development image with [uv](https://github.com/astral-sh/uv) for package management and [Ruff](https://github.com/astral-sh/ruff) for linting and formatting.

## Variants

| Image | Based on | Tags |
|-------|----------|------|
| Alpine | our [alpine base](../base/README.md) | see below |
| Debian | our [debian base](../base/README.md) | see below |

Both variants install the same uv-managed CPython. uv now ships musl [python-build-standalone](https://github.com/astral-sh/python-build-standalone) builds (astral-sh/uv#6890, resolved), so the Alpine variant uses a musl CPython and the Debian variant a glibc one.

Current versions are defined in [`buildargs.conf`](../../buildargs.conf).

## Tags

| Tag | Description |
|-----|-------------|
| `python:latest`, `python:alpine` | Most recent build (Alpine) |
| `python:<major>`, `python:<major.minor>` | Alpine version aliases, e.g. `python:3`, `python:3.14` |
| `python:<major>-alpine`, `python:<major.minor>-alpine` | Alpine version aliases with explicit suffix |
| `python:debian` | Most recent build (Debian) |
| `python:<major>-debian`, `python:<major.minor>-debian` | Debian version aliases, e.g. `python:3-debian`, `python:3.14-debian` |

## What is included

### Python

Python is installed via `uv python install` using [python-build-standalone](https://github.com/astral-sh/python-build-standalone) distributions. The install is self-contained under `UV_PYTHON_INSTALL_DIR` — no system Python is involved.

The following binaries are symlinked into `/usr/local/bin`:

| Binary | Alpine | Debian | Description |
|--------|--------|--------|-------------|
| `python<major.minor>` | ✅ | ✅ | Versioned Python interpreter, e.g. `python3.13` |
| `python3` | ✅ | ✅ | Alias for the versioned interpreter |
| `python` | ✅ | ✅ | Alias for `python3` |
| `pip<major.minor>` | ✅ | ✅ | Versioned pip, e.g. `pip3.13` |
| `pip3` | ✅ | ✅ | Alias for the versioned pip |
| `pip` | ✅ | ✅ | Alias for `pip3` |
| `pydoc<major.minor>` | ✅ | ✅ | Versioned pydoc, e.g. `pydoc3.13` |
| `pydoc3` | ✅ | ✅ | Alias for the versioned pydoc |
| `pydoc` | ✅ | ✅ | Alias for `pydoc3` |

### uv

| Binary | Path | Alpine | Debian | Description |
|--------|------|--------|--------|-------------|
| `uv` | `/usr/local/bin/uv` | ✅ | ✅ | Python package and project manager |
| `uvx` | `/usr/local/bin/uvx` | ✅ | ✅ | Run tools from PyPI without installing (`uv tool run`) |

### Ruff

| Binary | Path | Alpine | Debian | Description |
|--------|------|--------|--------|-------------|
| `ruff` | `/usr/local/bin/ruff` | ✅ | ✅ | Python linter and formatter |

### Environment

| Variable | Value | Description |
|----------|-------|-------------|
| `UV_PYTHON_INSTALL_DIR` | `/usr/local/python` | Where uv installs managed Python versions |
| `UV_PYTHON_PREFERENCE` | `only-managed` | Always use the uv-managed Python, never the system one |
| `PYTHONDONTWRITEBYTECODE` | `1` | Suppress `.pyc` file generation |
| `PYTHONUNBUFFERED` | `1` | Force unbuffered stdout/stderr for clean container logs |

### Default user

Runs as `nonroot` (UID/GID 65532). `WORKDIR` is `/app`.

## Usage

### Run a script

```sh
docker run --rm \
  -v $(pwd):/app \
  ghcr.io/pyck-ai/baseimages/python:latest \
  python script.py
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
task build -- python
```
