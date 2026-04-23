# AWS Image

[AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-welcome.html) pre-installed on top of our base images. Kept as a separate image because aws-cli pulls in Python and its full dependency tree (~650 MB), which would bloat every base image consumer that doesn't need it.

## Variants

| Image | Based on | Tags |
|-------|----------|------|
| Alpine | our [alpine base](../slim/README.md) | see below |
| Debian | our [debian base](../slim/README.md) | see below |

The aws-cli version tracks the respective package repository for the pinned base image version.

### Alpine tags

| Tag | Description |
|-----|-------------|
| `aws:latest` | Latest aws-cli on Alpine |
| `aws:alpine` | Latest aws-cli on Alpine |

### Debian tags

| Tag | Description |
|-----|-------------|
| `aws:debian` | Latest aws-cli on Debian |

## What is included

| Binary | Path | Description |
|--------|------|-------------|
| `aws` | `/usr/bin/aws` | AWS CLI |

### Default user

Runs as `nonroot` (UID/GID 65532). `WORKDIR` is `/app`.

## Usage

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/aws:latest
RUN aws s3 cp s3://my-bucket/config.json /app/config.json
```

Or as a step in a multi-stage build:

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/aws:latest AS fetch
RUN aws s3 cp s3://my-bucket/data.tar.gz /tmp/data.tar.gz

FROM ghcr.io/pyck-ai/baseimages/slim:alpine
COPY --from=fetch /tmp/data.tar.gz /tmp/
```

## Build

```sh
task build -- aws           # both alpine and debian variants
task build -- aws-alpine    # alpine only
task build -- aws-debian    # debian only
```
