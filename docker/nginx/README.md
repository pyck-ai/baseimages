# Nginx Image

A hardened, unprivileged nginx image pre-configured for serving Single Page Applications (SPAs) with OpenTelemetry tracing support.

## Based on

[`nginxinc/nginx-unprivileged`](https://github.com/nginxinc/docker-nginx-unprivileged) — the official unprivileged nginx image, `-otel` variant (includes the OpenTelemetry module).

Current versions are defined in [`buildargs.conf`](../../buildargs.conf).

## Tags

| Tag | Description |
|-----|-------------|
| `nginx:latest` | Most recent build |
| `nginx:<major>` | Major-version alias, e.g. `nginx:1` |
| `nginx:<major.minor>` | Minor-version alias, e.g. `nginx:1.27` |
| `nginx:<version>` | Exact pinned version, e.g. `nginx:1.27.3` |

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

### Default user

Runs as `nginx` (the unprivileged user from the base image). `WORKDIR` is `/app`.

### OpenTelemetry

The OTel module (`ngx_otel_module.so`) is loaded but tracing is off by default (`otel_trace off`). To enable, configure an OTel Collector endpoint in `conf.d/otel.conf` or provide your own override and set `otel_trace on`.

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
