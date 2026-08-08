#!/bin/sh

set -u

output_dir=/output
server_log="$output_dir/server-console.log"
timeout_seconds="${CC_CODEX_TIMEOUT_SECONDS:-180}"

mkdir -p "$output_dir"
rm -rf "$output_dir/computer-fs"
rm -rf "$output_dir/world-debug"
rm -f "$output_dir/cc-summary.json" "$output_dir/server-latest.log"

if [ -f /input/anomaly.jar ]; then
    cp /input/anomaly.jar /server/mods/anomaly.jar
fi

if [ "${REQUIRE_ATMONS:-0}" = "1" ] && [ ! -f /server/mods/anomaly.jar ]; then
    echo "ATMons jar was required but was not mounted at /input/anomaly.jar." >&2
    exit 2
fi

console_pipe="/tmp/cc-codex-runtime-console.$$"
mkfifo "$console_pipe"
trap 'rm -f "$console_pipe"' EXIT

set +e
timeout --foreground "$timeout_seconds" /server/run.sh --nogui <"$console_pipe" >"$server_log" 2>&1 &
server_pid=$!
exec 3>"$console_pipe"

(
    while kill -0 "$server_pid" 2>/dev/null; do
        summary_path="$(find /server/world -type f -path '*/ci/summary.json' -print -quit 2>/dev/null || true)"
        if [ -n "$summary_path" ]; then
            printf 'stop\n' >&3
            exit 0
        fi
        sleep 1
    done
) &
watcher_pid=$!

wait "$server_pid"
server_exit=$?
kill "$watcher_pid" 2>/dev/null || true
exec 3>&-
rm -f "$console_pipe"
trap - EXIT
set -e

if [ -f /server/logs/latest.log ]; then
    cp /server/logs/latest.log "$output_dir/server-latest.log"
fi

if [ "$server_exit" -ne 0 ] && [ -d /server/world ]; then
    cp -R /server/world "$output_dir/world-debug"
fi

summary_path="$(find /server/world -type f -path '*/ci/summary.json' -print -quit 2>/dev/null || true)"
if [ -n "$summary_path" ]; then
    computer_root="$(dirname "$(dirname "$summary_path")")"
    cp -R "$computer_root" "$output_dir/computer-fs"
    cp "$summary_path" "$output_dir/cc-summary.json"
fi

if [ "$server_exit" -eq 124 ]; then
    echo "Minecraft runtime smoke timed out after ${timeout_seconds}s." >&2
    exit 124
fi

if [ ! -f "$output_dir/cc-summary.json" ]; then
    echo "The CC test did not persist ci/summary.json." >&2
    exit 1
fi

if ! grep -Eq '"status"[[:space:]]*:[[:space:]]*"passed"' "$output_dir/cc-summary.json"; then
    echo "The CC runtime test reported failure:" >&2
    cat "$output_dir/cc-summary.json" >&2
    exit 1
fi

if [ "$server_exit" -ne 0 ]; then
    echo "Minecraft exited with status $server_exit after reporting a passing CC test." >&2
    exit "$server_exit"
fi

echo "CC Codex runtime smoke passed."
