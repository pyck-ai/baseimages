#!/bin/sh
# Minimal, always-non-root entrypoint for the postgresql base image.
#
# Unlike the official docker.io/library/postgres image, this never runs as
# root and therefore never needs a gosu/chown-then-drop-privileges dance:
# the image's default user (uid 1001) already owns $PGDATA. It borrows two
# ideas from Bitnami/Chainguard's non-root Postgres images instead:
#
#   - nss_wrapper, so the container also works under an arbitrary uid that
#     has no /etc/passwd entry (e.g. Kubernetes `runAsUser: <random>`) —
#     postgres calls getpwuid() on its own uid and refuses to start if that
#     lookup fails.
#   - POSTGRES_USER/POSTGRES_PASSWORD/POSTGRES_DB env vars and a
#     /docker-entrypoint-initdb.d/ hook, matching the official image's
#     first-boot initialization contract (a subset of it — this is a
#     simplified reimplementation, not a byte-for-byte port).

set -eu

PGDATA="${PGDATA:-/var/lib/postgresql/data}"

if ! id -un >/dev/null 2>&1; then
	export NSS_WRAPPER_PASSWD
	export NSS_WRAPPER_GROUP
	NSS_WRAPPER_PASSWD="$(mktemp)"
	NSS_WRAPPER_GROUP="$(mktemp)"
	uid="$(id -u)"
	gid="$(id -g)"
	echo "postgres:x:${uid}:${gid}:postgres:${PGDATA}:/bin/sh" > "$NSS_WRAPPER_PASSWD"
	echo "postgres:x:${gid}:" > "$NSS_WRAPPER_GROUP"
	export LD_PRELOAD=libnss_wrapper.so
fi

should_initialize() {
	[ ! -s "$PGDATA/PG_VERSION" ]
}

run_initdb() {
	: "${POSTGRES_USER:=postgres}"
	: "${POSTGRES_DB:=$POSTGRES_USER}"
	export POSTGRES_USER POSTGRES_DB

	if [ -z "${POSTGRES_PASSWORD:-}" ] && [ "${POSTGRES_HOST_AUTH_METHOD:-}" != "trust" ]; then
		echo "Error: POSTGRES_PASSWORD is unset and POSTGRES_HOST_AUTH_METHOD is not 'trust'." >&2
		echo "       Set POSTGRES_PASSWORD, or explicitly opt into trust auth (insecure)" >&2
		echo "       via POSTGRES_HOST_AUTH_METHOD=trust." >&2
		exit 1
	fi

	pwfile="$(mktemp)"
	printf '%s' "${POSTGRES_PASSWORD:-}" > "$pwfile"

	initdb \
		--pgdata="$PGDATA" \
		--username="$POSTGRES_USER" \
		--pwfile="$pwfile" \
		--auth-host="${POSTGRES_HOST_AUTH_METHOD:-scram-sha-256}" \
		--auth-local=trust \
		--no-instructions

	rm -f "$pwfile"

	echo "listen_addresses = '*'" >> "$PGDATA/postgresql.conf"
}

run_init_scripts_and_extra_db() {
	pg_ctl -D "$PGDATA" -o "-c listen_addresses=''" -w start >/dev/null

	if [ "$POSTGRES_DB" != "$POSTGRES_USER" ]; then
		psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "CREATE DATABASE \"$POSTGRES_DB\";"
	fi

	for f in /docker-entrypoint-initdb.d/*; do
		[ -e "$f" ] || continue
		case "$f" in
			*.sh)
				echo "Running $f"
				# shellcheck disable=SC1090
				. "$f"
				;;
			*.sql)
				echo "Running $f"
				psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f "$f"
				;;
			*)
				echo "Ignoring $f (not .sh or .sql)"
				;;
		esac
	done

	pg_ctl -D "$PGDATA" -m fast -w stop >/dev/null
}

if [ "${1:-}" = "postgres" ] && should_initialize; then
	run_initdb
	run_init_scripts_and_extra_db
fi

exec "$@"
