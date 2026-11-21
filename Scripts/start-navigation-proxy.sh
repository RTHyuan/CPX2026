#!/bin/zsh
set -eu
exec python3 "${0:A:h:h}/Proxy/server.py" "$@"
