#!/usr/bin/env bash
#
# diagnostic.sh - Containerised Linux diagnostic CLI.
#
# Usage:
#   diagnostic system            show system information
#   diagnostic network <host>    resolve and check a host (optional: [port])
#   diagnostic disk              show disk usage
#   diagnostic help              show this help
#
# Exit codes:
#   0  success
#   1  operational/runtime failure (host unreachable, tool failed)
#   2  invalid command or input

set -uo pipefail

TIMEOUT_SECS=5
PROG="diagnostic"

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

usage() {
    cat <<USAGE
Usage: $PROG <command> [arguments]

Commands:
  system              Display hostname, OS, kernel, uptime, CPU, memory and load.
  network <host> [port]
                      Validate and resolve <host>, ping it, optionally test a TCP
                      port (1-65535) and list local network interfaces.
  disk                Display disk usage for mounted filesystems.
  help                Show this message.

Exit codes:
  0  success
  1  operational failure (for example the host could not be resolved or reached)
  2  invalid command or input
USAGE
}

invalid() {
    printf 'Error: %s\n\n' "$1" >&2
    usage >&2
    exit 2
}

section() {
    printf '\n--- %s ---\n' "$1"
}

print_row() {
    printf '%-20s %s\n' "$1:" "$2"
}

with_timeout() {
    # Run a command with a time limit; falls back to a watchdog when timeout(1) is absent.
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
        return $?
    fi
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    local watchdog=$!
    wait "$pid" 2>/dev/null
    local rc=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    return "$rc"
}

# ---------------------------------------------------------------------------
# system
# ---------------------------------------------------------------------------

get_os() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        ( . /etc/os-release && printf '%s\n' "${PRETTY_NAME:-${NAME:-Linux}}" )
    elif command -v sw_vers >/dev/null 2>&1; then
        printf '%s %s\n' "$(sw_vers -productName)" "$(sw_vers -productVersion)"
    else
        uname -s
    fi
}

get_uptime() {
    if [[ -r /proc/uptime ]]; then
        local secs
        secs=$(cut -d. -f1 /proc/uptime)
        printf '%d days, %d hours, %d minutes\n' \
            $((secs / 86400)) $((secs % 86400 / 3600)) $((secs % 3600 / 60))
    elif uptime -p >/dev/null 2>&1; then
        uptime -p
    else
        uptime | sed -E 's/^.* up +//; s/,[^,]*(user|load).*$//'
    fi
}

get_load_average() {
    if [[ -r /proc/loadavg ]]; then
        awk '{print $1", "$2", "$3" (1, 5, 15 min)"}' /proc/loadavg
    else
        uptime | sed -E 's/.*load averages?: *//'
    fi
}

get_cpu_model() {
    local model=""
    [[ -r /proc/cpuinfo ]] && \
        model=$(awk -F': *' '/^(model name|Model|Hardware)[[:space:]]*:/ {print $2; exit}' /proc/cpuinfo)
    [[ -z "$model" ]] && command -v lscpu >/dev/null 2>&1 && \
        model=$(lscpu 2>/dev/null | awk -F': *' '/^Model name/ {print $2; exit}')
    [[ -z "$model" ]] && command -v sysctl >/dev/null 2>&1 && \
        model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
    printf '%s\n' "${model:-unknown}"
}

get_cpu_count() {
    nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo unknown
}

get_memory() {
    if [[ -r /proc/meminfo ]]; then
        awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2}
             END {printf "total %.1f GiB, used %.1f GiB, available %.1f GiB\n",
                  t/1048576, (t-a)/1048576, a/1048576}' /proc/meminfo
    elif command -v free >/dev/null 2>&1; then
        free -m | awk '/^Mem:/ {printf "total %d MiB, used %d MiB, free %d MiB\n", $2, $3, $4}'
    elif command -v sysctl >/dev/null 2>&1; then
        sysctl -n hw.memsize 2>/dev/null | awk '{printf "total %.1f GiB\n", $1/1073741824}'
    else
        echo unknown
    fi
}

cmd_system() {
    [[ $# -eq 0 ]] || invalid "'system' does not take arguments"
    echo "System information"
    echo "=================="
    print_row "Hostname"         "$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || uname -n)"
    print_row "Current user"     "$(id -un 2>/dev/null || echo "${USER:-unknown}")"
    print_row "Date/time"        "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    print_row "Operating system" "$(get_os)"
    print_row "Kernel version"   "$(uname -r)"
    print_row "Architecture"     "$(uname -m)"
    print_row "Uptime"           "$(get_uptime)"
    print_row "Load average"     "$(get_load_average)"
    print_row "CPU model"        "$(get_cpu_model)"
    print_row "CPU cores"        "$(get_cpu_count)"
    print_row "Memory"           "$(get_memory)"
    print_row "Working directory" "$(pwd)"
    if [[ -f /.dockerenv ]] || grep -qsE 'docker|containerd|kubepods' /proc/1/cgroup 2>/dev/null; then
        print_row "Environment" "container"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# disk
# ---------------------------------------------------------------------------

cmd_disk() {
    [[ $# -eq 0 ]] || invalid "'disk' does not take arguments"
    local output
    if ! output=$(df -P 2>/dev/null) || [[ -z "$output" ]]; then
        echo "Error: df failed to report disk usage" >&2
        return 1
    fi
    echo "Disk usage (real filesystems)"
    echo "============================="
    printf '%-28s %10s %10s %10s %6s  %s\n' "Filesystem" "Size(MiB)" "Used(MiB)" "Avail(MiB)" "Use%" "Mounted on"
    # Skip pseudo filesystems so the report focuses on storage that can actually fill up.
    printf '%s\n' "$output" | awk 'NR > 1 && $1 !~ /^(tmpfs|devtmpfs|udev|shm|proc|sysfs|cgroup|devfs|map|none)$/ {
        printf "%-28s %10d %10d %10d %6s  %s\n", $1, $2/1024, $3/1024, $4/1024, $5, $6 }'
    echo
    local root_usage
    root_usage=$(printf '%s\n' "$output" | awk '$6 == "/" {print $5}' | tr -d '%')
    if [[ "$root_usage" =~ ^[0-9]+$ ]]; then
        print_row "Root filesystem usage" "${root_usage}%"
        (( root_usage >= 90 )) && echo "WARNING: root filesystem is ${root_usage}% full"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# network
# ---------------------------------------------------------------------------

valid_host() {
    local host="$1"
    [[ ${#host} -le 253 ]] || return 1
    [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && return 0
    [[ "$host" =~ ^[0-9A-Fa-f:]+$ && "$host" == *:* ]] && return 0
    return 1
}

resolve_host() {
    # Print one address (IPv4 preferred). The system resolver is authoritative when present.
    local host="$1" addr=""
    if command -v getent >/dev/null 2>&1; then
        addr=$(with_timeout "$TIMEOUT_SECS" getent ahosts "$host" 2>/dev/null \
               | awk '$1 ~ /^[0-9.]+$/ && !v4 {v4=$1} NR==1 {first=$1} END {print (v4 != "" ? v4 : first)}')
    elif command -v dscacheutil >/dev/null 2>&1; then
        addr=$(with_timeout "$TIMEOUT_SECS" dscacheutil -q host -a name "$host" 2>/dev/null \
               | awk '/^ip_address:/ {v4=$2} /^ipv6_address:/ {v6=$2} END {print (v4 != "" ? v4 : v6)}')
    elif command -v dig >/dev/null 2>&1; then
        addr=$(dig +short +time=3 +tries=1 "$host" A 2>/dev/null | grep -E '^[0-9.]+$' | head -n 1)
    elif command -v python3 >/dev/null 2>&1; then
        addr=$(with_timeout "$TIMEOUT_SECS" python3 -c \
               'import socket, sys; print(socket.getaddrinfo(sys.argv[1], None)[0][4][0])' "$host" 2>/dev/null)
    fi
    [[ -n "$addr" ]] && printf '%s\n' "$addr"
}

ping_host() {
    local host="$1"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        ping -c 2 -t "$TIMEOUT_SECS" "$host"
    else
        ping -c 2 -W "$TIMEOUT_SECS" "$host"
    fi
}

tcp_check() {
    local addr="$1" port="$2"
    # shellcheck disable=SC2016  # $0/$1 are expanded by the inner bash, on purpose
    with_timeout "$TIMEOUT_SECS" bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$addr" "$port" 2>/dev/null
}

show_interfaces() {
    if command -v ip >/dev/null 2>&1; then
        ip -brief address 2>/dev/null || ip address 2>/dev/null
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | grep -E '^[A-Za-z0-9]+:|^[[:space:]]+inet6? '
    elif [[ -d /sys/class/net ]]; then
        ls /sys/class/net
    else
        echo "No interface listing tool (ip/ifconfig) available"
    fi
}

cmd_network() {
    [[ $# -ge 1 ]] || invalid "'network' requires a host argument"
    [[ $# -le 2 ]] || invalid "'network' accepts at most a host and a port"
    local host="$1" port="${2:-}" status=0

    valid_host "$host" || invalid "'$host' is not a valid hostname or IP address"
    if [[ -n "$port" ]]; then
        [[ "$port" =~ ^[0-9]+$ ]] || invalid "port '$port' is not a whole number"
        port=$((10#$port))
        (( port >= 1 && port <= 65535 )) || invalid "port must be between 1 and 65535 (got $port)"
    fi

    echo "Network check for: $host${port:+ (port $port)}"

    section "Name resolution"
    local addr
    if addr=$(resolve_host "$host") && [[ -n "$addr" ]]; then
        echo "Resolved $host -> $addr"
    else
        echo "Could not resolve '$host'" >&2
        section "Network interfaces"
        show_interfaces
        echo
        echo "RESULT: FAILED (name resolution)"
        return 1
    fi

    section "Connectivity (ICMP ping)"
    if ! command -v ping >/dev/null 2>&1; then
        echo "ping is not installed; skipping ICMP check"
    elif ping_host "$host" >/dev/null 2>&1; then
        echo "Ping to $host ($addr) succeeded"
    else
        echo "Ping to $host ($addr) failed (host down or ICMP filtered)"
        [[ -n "$port" ]] || status=1
    fi

    if [[ -n "$port" ]]; then
        section "TCP connectivity"
        if tcp_check "$addr" "$port"; then
            echo "TCP port $port on $host is OPEN"
        else
            echo "TCP port $port on $host is CLOSED or unreachable"
            status=1
        fi
    fi

    section "Network interfaces"
    show_interfaces

    echo
    if (( status == 0 )); then
        echo "RESULT: OK"
    else
        echo "RESULT: FAILED (connectivity)"
    fi
    return "$status"
}

# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------

main() {
    [[ $# -ge 1 ]] || invalid "no command given"
    local command="$1"
    shift
    case "$command" in
        system)         cmd_system "$@" ;;
        network)        cmd_network "$@" ;;
        disk)           cmd_disk "$@" ;;
        help|-h|--help) usage ;;
        *)              invalid "unknown command '$command'" ;;
    esac
}

main "$@"
