# syntax=docker/dockerfile:1

FROM base AS rootfs
USER root

WORKDIR /rootfs
RUN grep -E '^(root|nonroot):' /etc/passwd > passwd &&\
    grep -E '^(root|nonroot):' /etc/group  > group


FROM scratch

# Minimal user/group database (root + nonroot only)
COPY --from=rootfs /rootfs/passwd /etc/passwd
COPY --from=rootfs /rootfs/group  /etc/group

# Writable /tmp with sticky bit
# COPY always creates destination dirs at 755; ADD with a tar is the only way
# to get non-default permissions into a scratch image without RUN.
ADD tmp.tar /

# TLS certificates
COPY --from=rootfs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENV HOME=/home/nonroot

# Timezone data
COPY --from=rootfs /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=rootfs /etc/localtime /etc/localtime

# Home directories
COPY --from=rootfs /root /root
COPY --chown=65532:65532 --from=rootfs /home/nonroot /home/nonroot

USER 65532
WORKDIR /home/nonroot

