#!/usr/bin/env bash
# Capture machine state as a single JSON object on stdout. Used by
# scripts/ab_runner.sh before and after each measured run so the
# downstream comparator can flag thermal drift, swap pressure, or
# governor changes.
#
# Stdlib only — uses /proc on Linux, sysctl on macOS, gracefully
# degrades on BSD or any other host. No external packages.

set -uo pipefail

emit_kv() {
    # $1=key, $2=value (already JSON-quoted/escaped if string)
    printf '  "%s": %s' "$1" "$2"
}

# Quote an arbitrary string for inclusion in JSON. Handles backslashes,
# double-quotes, and control characters at the level we need.
json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '"%s"' "$s"
}

# Detect platform.
uname_s=$(uname -s 2>/dev/null || echo "unknown")
uname_a=$(uname -a 2>/dev/null || echo "unknown")
arch=$(uname -m 2>/dev/null || echo "unknown")
hostname_val=$(hostname 2>/dev/null || echo "unknown")

cpu_model="unknown"
core_count=0
mem_total_kb=0
loadavg="0 0 0"
governor="unknown"

case "$uname_s" in
    Linux)
        if [[ -r /proc/cpuinfo ]]; then
            cpu_model=$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "unknown")
            core_count=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 0)
        fi
        if [[ -r /proc/meminfo ]]; then
            mem_total_kb=$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
        fi
        if [[ -r /proc/loadavg ]]; then
            loadavg=$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null || echo "0 0 0")
        fi
        if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
            governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
        fi
        ;;
    Darwin)
        cpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
        core_count=$(sysctl -n hw.ncpu 2>/dev/null || echo 0)
        mem_total_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
        if [[ "$mem_total_bytes" =~ ^[0-9]+$ ]] && [[ "$mem_total_bytes" -gt 0 ]]; then
            mem_total_kb=$((mem_total_bytes / 1024))
        fi
        # macOS loadavg via uptime
        loadavg=$(uptime 2>/dev/null | awk -F'load averages?: ' '{print $2}' | awk '{print $1, $2, $3}' || echo "0 0 0")
        # Strip trailing comma if present (Linux-style uptime output).
        loadavg=${loadavg//,/}
        governor="not-applicable-on-darwin"
        ;;
    *)
        # BSD or other Unix — best-effort sysctl.
        cpu_model=$(sysctl -n hw.model 2>/dev/null || echo "unknown")
        core_count=$(sysctl -n hw.ncpu 2>/dev/null || echo 0)
        ;;
esac

# Optionally inherit git_sha so the bench JSON records can stamp the
# correct ref. Used by ab_runner.sh, which exports BENCH_GIT_SHA.
git_sha=${BENCH_GIT_SHA:-unknown}

# Convert loadavg string into JSON list.
load_json="[$(printf '%s' "$loadavg" | awk '{printf "%s, %s, %s", $1, $2, $3}')]"

printf '{\n'
emit_kv "captured_at_unix" "$(date -u +%s)"; printf ',\n'
emit_kv "uname" "$(json_escape "$uname_a")"; printf ',\n'
emit_kv "uname_s" "$(json_escape "$uname_s")"; printf ',\n'
emit_kv "arch" "$(json_escape "$arch")"; printf ',\n'
emit_kv "hostname" "$(json_escape "$hostname_val")"; printf ',\n'
emit_kv "cpu_model" "$(json_escape "$cpu_model")"; printf ',\n'
emit_kv "core_count" "$core_count"; printf ',\n'
emit_kv "mem_total_kb" "$mem_total_kb"; printf ',\n'
emit_kv "loadavg" "$load_json"; printf ',\n'
emit_kv "scaling_governor" "$(json_escape "$governor")"; printf ',\n'
emit_kv "git_sha" "$(json_escape "$git_sha")"
printf '\n}\n'
