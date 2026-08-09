#!/bin/sh

set -u

output_dir=/output
server_log="$output_dir/server-console.log"
timeout_seconds="${CC_CODEX_TIMEOUT_SECONDS:-180}"

now_ms() {
    value="$(date +%s%3N 2>/dev/null || true)"
    case "$value" in
        ''|*N*) value="$(($(date +%s) * 1000))" ;;
    esac
    printf '%s' "$value"
}

runtime_started_ms="$(now_ms)"

mkdir -p "$output_dir"

console_pipe="/tmp/cc-codex-runtime-console.$$"
mkfifo "$console_pipe"
server_pid=''
watcher_pid=''
cleanup() {
    if [ -n "$watcher_pid" ]; then kill "$watcher_pid" 2>/dev/null || true; fi
    if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
    exec 3>&- 2>/dev/null || true
    rm -f "$console_pipe"
}
trap cleanup EXIT INT TERM

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
watcher_pid=''
exec 3>&-
server_pid=''
rm -f "$console_pipe"
trap - EXIT INT TERM
set -e

runtime_finished_ms="$(now_ms)"
runtime_elapsed_ms=$((runtime_finished_ms - runtime_started_ms))
printf '{"schema":1,"container_elapsed_ms":%s}\n' "$runtime_elapsed_ms" > "$output_dir/container-timing.json"

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
    echo "Minecraft runtime integration timed out after ${timeout_seconds}s." >&2
    exit 124
fi

if [ ! -f "$output_dir/cc-summary.json" ]; then
    echo "The CC test did not persist ci/summary.json." >&2
    exit 1
fi

status_path="$(dirname "$summary_path")/status.txt"
if [ ! -f "$status_path" ] || [ "$(tr -d '\r\n' < "$status_path")" != "passed" ]; then
    echo "The CC runtime test reported failure:" >&2
    cat "$output_dir/cc-summary.json" >&2
    exit 1
fi

if [ "$server_exit" -ne 0 ]; then
    echo "Minecraft exited with status $server_exit after reporting a passing CC test." >&2
    exit "$server_exit"
fi

echo "CC Codex runtime integration passed."
