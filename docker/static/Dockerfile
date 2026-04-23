# syntax=docker/dockerfile:1

FROM alpine AS rootfs
USER 0

WORKDIR /rootfs
RUN grep -E '^(root|nonroot):' /etc/passwd > passwd &&\
    grep -E '^(root|nonroot):' /etc/group  > group

FROM scratch
USER 0

# Minimal user/group database (root + nonroot only)
COPY --from=rootfs /rootfs/passwd /etc/passwd
COPY --from=rootfs /rootfs/group  /etc/group

# Writable /tmp with sticky bit
# COPY always creates destination dirs at 755; ADD with a tar is the only way
# to get non-default permissions into a scratch image without RUN.
ADD tmp.tar /

# TLS certificates
COPY --from=alpine /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

# Timezone data
COPY --from=alpine /usr/share/zoneinfo /usr/share/zoneinfo
COPY --from=alpine /etc/localtime /etc/localtime

# Home directories
COPY --from=alpine /root /root
COPY --chown=65532:65532 --from=alpine /home/nonroot /home/nonroot

USER nonroot
WORKDIR /home/nonroot
ENV HOME=/home/nonroot

