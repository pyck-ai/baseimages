# Nginx Image

A hardened, unprivileged nginx image pre-configured for serving Single Page Applications (SPAs) with OpenTelemetry tracing support.

## Based on

[`nginxinc/nginx-unprivileged`](https://github.com/nginxinc/docker-nginx-unprivileged) — the official unprivileged nginx image, `-otel` variant (includes the OpenTelemetry module).

Current versions are defined in [`buildargs.conf`](../../buildargs.conf).

## Tags

| Tag | Description |
|-----|-------------|
| `nginx:latest` | Most recent build |
| `nginx:<major>.<minor>` | Minor-version alias |
| `nginx:<major>` | Major-version alias |

`NGINX_VERSION` tracks the upstream `nginxinc/nginx-unprivileged` image at `<major>.<minor>` granularity, so there is no three-part `nginx:<major>.<minor>.<patch>` tag.

## What is included

### Configuration

| File | Destination | Purpose |
|------|-------------|---------|
| `nginx.conf` | `/etc/nginx/nginx.conf` | Main nginx config — temp paths in `/tmp`, JSON + plain access logs, OTel module loaded, gzip enabled |
| `conf.d/default.conf` | `/etc/nginx/conf.d/default.conf` | SPA server block — listens on 8080, security headers, static asset caching, SPA fallback routing |
| `conf.d/otel.conf` | `/etc/nginx/conf.d/otel.conf` | OpenTelemetry config — exporter endpoint, trace sampling |
| `index.html` | `/app/index.html` | Placeholder page shown when no SPA is mounted |

### Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 8080 | TCP | HTTP |

### OpenTelemetry

The OTel module (`ngx_otel_module.so`) is loaded but tracing is off by default (`otel_trace off`). To enable, configure an OTel Collector endpoint in `conf.d/otel.conf` or provide your own override and set `otel_trace on`.

### Default user

Runs as `nginx` (the unprivileged user from the base image) by default. `WORKDIR` is `/app`. Run with `--user 0` for a root shell to install packages or use the image as a build environment (see the "Override the nginx config" example below, which does this via `USER root`/`USER nginx` in a derived Dockerfile).

## Usage

### Serve a SPA build

Mount your build output to `/app`:

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/nginx:latest
COPY --from=build /dist /app
```

Or at runtime:

```sh
docker run -p 8080:8080 -v ./dist:/app ghcr.io/pyck-ai/baseimages/nginx:latest
```

### Override the nginx config

```dockerfile
FROM ghcr.io/pyck-ai/baseimages/nginx:latest
USER root
COPY my-site.conf /etc/nginx/conf.d/default.conf
USER nginx
```

Replace only `default.conf` — avoid replacing `nginx.conf` unless absolutely necessary, as it carries the temp-path and OTel setup.

## Build

```sh
task build -- nginx
```
