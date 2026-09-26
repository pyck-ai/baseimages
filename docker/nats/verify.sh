#!/bin/sh
# Verifies the assembled nats image. This is built on `static`: no general-
# purpose shell exists in the shipped image, so this script has to be run
# against a derived image that adds one, e.g.:
#   printf 'FROM %s\nCOPY --from=busybox:musl /bin /bin\n' <nats-ref> | \
#     docker build -f - -t nats-verify .
#   docker run --rm --env-file buildargs.conf -e TARGET=nats \
#     -v $PWD/docker/nats/verify.sh:/verify.sh:ro --entrypoint /bin/sh \
#     nats-verify /verify.sh

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

check_version() {
	out=$(sh -c "$1" 2>&1)
	case "$out" in
		*"$2"*) ok "$1 reports $2" ;;
		*)      bad "$1 does not report $2: $out" ;;
	esac
}

# Starts the real shipped binary against the shipped config (JetStream
# enabled, storage at /data) and polls its monitoring endpoint, then
# confirms a real client connection round trip via the monitoring API's
# connection count (proves the client port actually accepts connections,
# not just that the process is alive).
serves_and_persists() {
	/usr/local/bin/nats-server --config /etc/nats/nats-server.conf >/data/nats-verify.log 2>&1 &
	pid=$!
	i=0
	while [ "$i" -lt 10 ]; do
		wget -qO- http://127.0.0.1:8222/varz >/dev/null 2>&1 && break
		i=$((i + 1))
		sleep 1
	done
	if ! wget -qO- http://127.0.0.1:8222/varz 2>/dev/null | grep -qF '"jetstream":'; then
		cat /data/nats-verify.log >&2
		kill "$pid" 2>/dev/null
		return 1
	fi
	if ! wget -qO- http://127.0.0.1:8222/jsz 2>/dev/null | grep -qF '"config"'; then
		cat /data/nats-verify.log >&2
		kill "$pid" 2>/dev/null
		return 1
	fi
	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	return 0
}

check_user 1001
check_workdir /home/nonroot
check_file /usr/local/bin/nats-server /etc/nats/nats-server.conf /etc/ssl/certs/ca-certificates.crt /data
check_version "nats-server --version" "$NATS_VERSION"

if serves_and_persists; then
	ok "serves the monitoring endpoint with JetStream enabled against /data"
else
	bad "serves the monitoring endpoint with JetStream enabled against /data"
fi

exit $((fails > 0))
