#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# Smoke test the freshly built artifacts on the host architecture.
#
# Extracts the host (linux amd64, musl) tarball produced by goreleaser, starts
# the broker and performs a publish/subscribe round trip using the bundled
# mosquitto_sub / mosquitto_pub clients. This validates that the statically
# linked broker + clients actually run, and (with TLS) that OpenSSL is wired up.
# -----------------------------------------------------------------------------

SOURCE_PATH="dist-musl"
PACKAGE_NAME="tedge-mosquitto"
LIBC="musl"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --path) SOURCE_PATH="$2"; shift ;;
        --name) PACKAGE_NAME="$2"; shift ;;
        --libc) LIBC="$2"; shift ;;
        --help|-h)
            echo "Usage: $0 [--path <dist_dir>] [--name <package_name>] [--libc musl|gnu]"
            exit 0
            ;;
        *) echo "Unrecognized argument: $1" >&2; exit 1 ;;
    esac
    shift
done

# Pick the host (amd64, non-upx) tarball for the requested libc flavor. Both
# flavors carry an explicit -musl/-gnu suffix; the musl -upx variant is excluded.
tarball=$(find "$SOURCE_PATH" -maxdepth 1 -name "${PACKAGE_NAME}-${LIBC}_*_linux_amd64.tar.gz" ! -name '*-upx*' | head -n1)
if [ -z "$tarball" ]; then
    echo "ERROR: could not find host tarball ${PACKAGE_NAME}-${LIBC}_*_linux_amd64.tar.gz under $SOURCE_PATH" >&2
    ls -la "$SOURCE_PATH" >&2 || true
    exit 1
fi
echo "Using tarball: $tarball"

WORKDIR=$(mktemp -d)
cleanup() {
    [ -n "${BROKER_PID:-}" ] && kill "$BROKER_PID" 2>/dev/null || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

tar -xzf "$tarball" -C "$WORKDIR"
BIN="$WORKDIR"
[ -x "$BIN/mosquitto" ] || { echo "ERROR: mosquitto binary not found in tarball" >&2; ls -la "$WORKDIR" >&2; exit 1; }

echo "=== mosquitto version ==="
"$BIN/mosquitto" --help | head -n1

PORT=18883
cat > "$WORKDIR/mosquitto.conf" <<EOF
listener $PORT 127.0.0.1
allow_anonymous true
persistence false
log_dest stdout
EOF

echo "=== starting broker on 127.0.0.1:$PORT ==="
"$BIN/mosquitto" -c "$WORKDIR/mosquitto.conf" >"$WORKDIR/broker.log" 2>&1 &
BROKER_PID=$!

# Wait for the broker to accept connections.
for _ in $(seq 1 30); do
    if "$BIN/mosquitto_sub" -h 127.0.0.1 -p "$PORT" -t '$SYS/#' -C 1 -W 1 >/dev/null 2>&1; then
        break
    fi
    if ! kill -0 "$BROKER_PID" 2>/dev/null; then
        echo "ERROR: broker exited early" >&2
        cat "$WORKDIR/broker.log" >&2
        exit 1
    fi
    sleep 0.5
done

echo "=== publish/subscribe round trip ==="
MESSAGE="hello-from-smoke-test-$$"
"$BIN/mosquitto_sub" -h 127.0.0.1 -p "$PORT" -t "smoke/test" -C 1 -W 10 > "$WORKDIR/received.txt" &
SUB_PID=$!
sleep 1
"$BIN/mosquitto_pub" -h 127.0.0.1 -p "$PORT" -t "smoke/test" -m "$MESSAGE"
wait "$SUB_PID"

received=$(cat "$WORKDIR/received.txt")
if [ "$received" != "$MESSAGE" ]; then
    echo "ERROR: expected '$MESSAGE' but received '$received'" >&2
    cat "$WORKDIR/broker.log" >&2
    exit 1
fi

echo "OK: round trip succeeded (received: $received)"
