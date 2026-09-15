# Lightweight image for the diagnostic CLI.
# Alpine provides df, uptime, ping, getent and timeout through BusyBox; only bash
# (the script interpreter) and iproute2 (full-featured `ip` output) are added.
FROM alpine:3.20

RUN apk add --no-cache bash iproute2 \
    && addgroup -S diag \
    && adduser -S -G diag -h /app diag

WORKDIR /app
COPY app/ /app/

# Make the scripts executable regardless of how they were checked out, then
# verify the image is usable before it is published.
RUN chmod 0755 /app/*.sh && /app/health-check.sh

USER diag

# The CLI is the entrypoint; the command name is passed as the container argument:
#   docker run --rm diagnostic-tool system
ENTRYPOINT ["/app/diagnostic.sh"]
CMD ["help"]
