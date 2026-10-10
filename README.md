# Assignment 2 – Dockerized Diagnostic CLI

`diagnostic` is a Bash command-line tool packaged as a small Docker image. It reports
system information, disk usage and basic network reachability from inside a container,
using consistent exit codes so it can be scripted.

```
diagnostic system            show system information
diagnostic network <host>    resolve and check a host (an optional TCP port may follow)
diagnostic disk              show disk usage
diagnostic help              show usage
```

## Project layout

| Path | Purpose |
|------|---------|
| `app/diagnostic.sh` | The CLI: argument validation, command dispatch, `system`/`network`/`disk`/`help` |
| `app/health-check.sh` | Verifies required tools and the CLI itself; run during the image build |
| `Dockerfile` | Alpine-based image with only `bash` and `iproute2` added; runs as a non-root user |
| `compose.yaml` | Docker Compose service `diagnostic` for local runs |
| `.dockerignore` | Keeps `.git`, logs, editor files and non-runtime files out of the build context |
| `test.sh` | Functional test suite that builds the image and checks every command |
| `grade.sh` | Official local grader supplied with the assignment (unmodified) |

## Requirements

- Docker Engine 20.10+ with the Compose plugin (`docker compose`).
- To run the scripts directly on the host instead of in Docker: Bash, `df`, `awk`,
  `ping`, and `ip` or `ifconfig`.

## Build and run

```bash
docker build -t diagnostic-tool .

docker run --rm diagnostic-tool system
docker run --rm diagnostic-tool disk
docker run --rm diagnostic-tool network example.com
docker run --rm diagnostic-tool network example.com 443
docker run --rm diagnostic-tool help
docker run --rm diagnostic-tool            # no argument: prints help
```

The script is the image `ENTRYPOINT`, so whatever follows the image name is passed
to it as the command. The image tag is not referenced anywhere in the application, so
any tag works.

### Docker Compose

```bash
docker compose build
docker compose run --rm diagnostic system
docker compose run --rm diagnostic network 8.8.8.8
docker compose run --rm diagnostic disk
docker compose config      # validate the compose file
```

The service is a one-shot CLI, so use `run` rather than `up`.

### Without Docker

```bash
chmod +x app/*.sh
./app/diagnostic.sh system
./app/health-check.sh
```

## Example output

```
$ docker run --rm diagnostic-tool system
System information
==================
Hostname:            8f1c2d3e4a5b
Current user:        diag
Date/time:           2026-09-15 20:31:07 UTC
Operating system:    Alpine Linux v3.20
Kernel version:      6.8.0-1017-azure
Architecture:        x86_64
Uptime:              0 days, 0 hours, 6 minutes
Load average:        0.41, 0.29, 0.12 (1, 5, 15 min)
CPU model:           AMD EPYC 7763 64-Core Processor
CPU cores:           4
Memory:              total 15.6 GiB, used 1.3 GiB, available 14.3 GiB
Working directory:   /app
Environment:         container
```

```
$ docker run --rm diagnostic-tool network localhost 22 ; echo "exit $?"
Network check for: localhost (port 22)

--- Name resolution ---
Resolved localhost -> 127.0.0.1

--- Connectivity (ICMP ping) ---
Ping to localhost (127.0.0.1) succeeded

--- TCP connectivity ---
TCP port 22 on localhost is CLOSED or unreachable
...
RESULT: FAILED (connectivity)
exit 1
```

## Exit codes

| Code | Meaning | Examples |
|------|---------|----------|
| 0 | Success | `system`, `disk`, `help`, `network host` when the host is reachable |
| 1 | Operational/runtime failure | host cannot be resolved, ping fails, TCP port closed, `df` fails |
| 2 | Invalid command or input | no command, unknown command, `network` without a host, malformed host or out-of-range IPv4 address, port outside 1–65535, extra arguments |

Invalid input always prints an error and the usage text to stderr.

## Testing

```bash
chmod +x test.sh app/*.sh
./test.sh
```

`test.sh` builds a temporary image (`diagnostic-tool-test`), runs every command in
a fresh container and checks the exit code and output of each. It covers `help`,
`system`, `disk`, `network` (missing host, malformed host, bad ports, unresolvable
host, `localhost`), invalid/empty commands and the in-image health check. Any
failure makes the script exit 1; the temporary image is removed afterwards.

Options: `IMAGE=<tag>` to test a different tag, `SKIP_BUILD=1` to reuse an existing
image, `KEEP_IMAGE=1` to keep the test image.

Run the official grader with:

```bash
chmod +x grade.sh test.sh app/*.sh
./grade.sh
```

## Docker design notes

- **Base image**: `alpine:3.20` (about 8 MB). BusyBox already supplies `df`, `ping`,
  `getent`, `uptime` and `timeout`; only `bash` and `iproute2` are installed, with
  `--no-cache` so no package index is left in the layer.
- **Non-root**: the CLI runs as user `diag`. Docker's default `ping_group_range`
  lets unprivileged users send ICMP echo requests, so `network` still works.
- **Build-time verification**: `health-check.sh` runs in a `RUN` step, so an image
  with a missing tool or broken script never builds.
- **Entrypoint**: `ENTRYPOINT ["/app/diagnostic.sh"]` with `CMD ["help"]`, so the
  container behaves like the CLI binary.
- **Output**: the tool writes to stdout/stderr rather than files, which is the
  conventional way to log from containers (`docker logs`, CI output). `logs/` is
  still excluded by `.dockerignore` in case logs are captured next to the project.

## Assumptions

- The container reports the container's own view of the system (its hostname,
  overlay filesystem, virtual interfaces). Mount host paths or use `--network host`
  if the host's values are wanted.
- ICMP may be blocked on some networks; when a port is given, the TCP result decides
  the exit code and a failed ping is only reported.
- Name lookups are limited to 5 seconds so a broken resolver cannot hang the tool.

## Troubleshooting

- **`permission denied while trying to connect to the Docker daemon`** – add your user
  to the `docker` group or run with `sudo`.
- **`docker compose` not found** – install the Compose plugin, or use `docker-compose`.
- **`network` returns 1 for a host that is up** – ICMP is probably filtered; test a TCP
  port instead: `docker run --rm diagnostic-tool network host 443`.
- **Build fails while running `health-check.sh`** – the output lists the failing check;
  usually a package failed to install because the build had no network access.
