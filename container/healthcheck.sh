#!/bin/sh
# Health check of the Phorge container. Phorge only answers a request whose
# Host header matches the base URI, so the host name and the port are taken
# from PHORGE_BASE_URI.
set -eu

host=${PHORGE_BASE_URI#*://}
host=${host%%/*}

exec curl --fail --silent --show-error --output /dev/null --max-time 5 \
    --header "Host: $host" http://127.0.0.1/status/
