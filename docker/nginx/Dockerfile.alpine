# syntax=docker/dockerfile:1

ARG NGINX_VERSION=1
ARG ALPINE_VERSION=3

FROM nginxinc/nginx-unprivileged:${NGINX_VERSION}-alpine${ALPINE_VERSION}-otel

EXPOSE 8080

USER root
COPY nginx.conf /etc/nginx/nginx.conf
COPY conf.d/ /etc/nginx/conf.d/

USER nginx
WORKDIR /app
COPY index.html /app/
