#!/bin/sh
# Verifies the assembled postgresql image. The shipped image deliberately
# carries only the busybox applets its own entrypoint needs (sh, id, mktemp,
# rm) — not a general-purpose shell environment — so this script needs a
# derived image with a fuller busybox layered on top, the same technique
# docker/static and docker/valkey use to verify their own minimal images:
#   printf 'FROM %s\nCOPY --from=busybox:musl /bin /bin\n' <postgresql-ref> | \
#     docker build -f - -t postgresql-verify .
#   docker run --rm --env-file buildargs.conf -e TARGET=postgresql \
#     -v $PWD/docker/postgresql/verify.sh:/verify.sh:ro --entrypoint /bin/sh \
#     postgresql-verify /verify.sh

fails=0
ok()  { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

check_user() {
	if [ "$(id -u)" = "$1" ]; then ok "runs as uid $1"; else bad "runs as uid $(id -u), want $1"; fi
}

check_workdir() {
	if [ "$(pwd)" = "$1" ]; then ok "workdir is $1"; else bad "workdir is $(pwd), want $1"; fi
}

check_env() {
	if [ "$(printenv "$1")" = "$2" ]; then ok "$1=$2"; else bad "$1=$(printenv "$1"), want $2"; fi
}

check_cmd() {
	missing=
	for c in "$@"; do
		command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
	done
	if [ -z "$missing" ]; then ok "on PATH: $*"; else bad "not on PATH:$missing"; fi
}

# Real end-to-end check: runs the actual entrypoint against a fresh, empty
# PGDATA (forcing the initdb path), waits for it to accept connections, then
# runs a real query over TCP with the password it was initialized with.
initializes_and_serves() {
	export POSTGRES_PASSWORD=verify
	export POSTGRES_DB=verifydb

	# No /tmp in this scratch-based image (never provisioned — nothing in the
	# entrypoint needs one), so the verify log goes next to PGDATA instead.
	logfile=/var/lib/postgresql/pg-verify.log

	/usr/local/bin/docker-entrypoint.sh postgres >"$logfile" 2>&1 &
	pid=$!

	i=0
	while [ "$i" -lt 20 ]; do
		if pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then
			break
		fi
		i=$((i + 1))
		sleep 1
	done

	if ! pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then
		cat "$logfile" >&2
		kill "$pid" 2>/dev/null
		return 1
	fi

	if ! PGPASSWORD=verify psql -h 127.0.0.1 -U postgres -d verifydb -tAc 'select 1' 2>>"$logfile" | grep -qF 1; then
		cat "$logfile" >&2
		kill "$pid" 2>/dev/null
		return 1
	fi

	kill "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null
	return 0
}

check_user 1001
check_workdir /var/lib/postgresql
check_env PGDATA /var/lib/postgresql/data
check_cmd postgres initdb pg_ctl pg_isready psql pg_dump

if initializes_and_serves; then
	ok "initializes PGDATA and accepts a real query over TCP"
else
	bad "initializes PGDATA and accepts a real query over TCP"
fi

exit $((fails > 0))
