# AWS Image

Alpine base with the [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-welcome.html) pre-installed. Kept as a separate image because aws-cli pulls in Python and its full dependency tree (~650 MB), which would bloat every base image consumer that doesn't need it.

## Based on

Our [alpine base image](../slim/README.md).

## Tags

| Tag | Description |
|-----|-------------|
| `aws:latest` | Latest aws-cli for the pinned Alpine version |

The aws-cli version tracks the Alpine package repository for the `ALPINE_VERSION` pinned in [`buildargs.conf`](../../buildargs.conf).

## What is included

| Binary | Path | Description |
|--------|------|-------------|
| `aws` | `/usr/local/bin/aws` | AWS CLI v2 |

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
task build -- aws
```
