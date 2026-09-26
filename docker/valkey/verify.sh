#!/bin/sh
# Verifies the assembled valkey image. This is FROM scratch: no shell exists
# in the shipped image, so this script has to be run against a derived image
# that adds one, e.g.:
#   printf 'FROM %s\nCOPY --from=busybox:musl /bin /bin\n' <valkey-ref> | \
#     docker build -f - -t valkey-verify .
#   docker run --rm --env-file buildargs.conf -e TARGET=valkey \
#     -v $PWD/docker/valkey/verify.sh:/verify.sh:ro --entrypoint /bin/sh valkey-verify /verify.sh
#
# --entrypoint /bin/sh overrides the shipped image's fixed
# ENTRYPOINT=["valkey-server"] for this verification run only.

fails=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

check_user() {
	if [ "$(id -u)" = "$1" ]; then ok "runs as uid $1"; else bad "runs as uid $(id -u), want $1"; fi
}

check_workdir() {
	if [ "$(pwd)" = "$1" ]; then ok "workdir is $1"; else bad "workdir is $(pwd), want $1"; fi
}

check_file() {
	missing=
	for f in "$@"; do
		[ -e "$f" ] || missing="$missing $f"
	done
	if [ -z "$missing" ]; then ok "present: $*"; else bad "absent:$missing"; fi
}

# Starts valkey-server (the real shipped binary, not a wrapper) in the
# background against the shipped config and polls it with the real
# valkey-cli client.
serves_ping_and_set_get() {
	# The shipped image has no /tmp (scratch, and valkey itself never needs
	# one — dir is set to /data), so the verify log goes there instead.
	logfile=/data/valkey-verify.log
	valkey-server /etc/valkey/valkey.conf >"$logfile" 2>&1 &
	pid=$!
	i=0
	while [ "$i" -lt 10 ]; do
		valkey-cli PING >/dev/null 2>&1 && break
		i=$((i + 1))
		sleep 1
	done
	if ! valkey-cli PING 2>/dev/null | grep -qF PONG; then
		cat "$logfile" >&2
		kill "$pid" 2>/dev/null
		return 1
	fi
	valkey-cli SET verify-key verify-value >/dev/null
	if [ "$(valkey-cli GET verify-key)" != "verify-value" ]; then
		cat "$logfile" >&2
		kill "$pid" 2>/dev/null
		return 1
	fi
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	return 0
}

check_user 1001
check_workdir /data
check_file /etc/valkey/valkey.conf /etc/ssl/certs/ca-certificates.crt /usr/share/zoneinfo /etc/localtime /data /run/valkey

if command -v valkey-server >/dev/null 2>&1 && command -v valkey-cli >/dev/null 2>&1; then
	ok "on PATH: valkey-server valkey-cli"
else
	bad "on PATH: valkey-server valkey-cli"
fi

if serves_ping_and_set_get; then
	ok "serves PING and a real SET/GET round trip"
else
	bad "serves PING and a real SET/GET round trip"
fi

exit $((fails > 0))
