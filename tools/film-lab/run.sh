#!/usr/bin/env bash
# Build the renderer if needed and start the local Film Lab.
#   tools/film-lab/run.sh [--port N] [--tailnet] [--no-open] [other server.py flags]
# The server binds 127.0.0.1 only. --tailnet additionally publishes it to this
# tailnet (never the internet) with `tailscale serve` until the server exits.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
open_browser=1
server_args=()
for argument in "$@"; do
  case "$argument" in
    --no-open) open_browser=0 ;;
    *) server_args+=("$argument") ;;
  esac
done

"$here/build.sh"

if [[ "$open_browser" == 1 && "$(uname)" == Darwin ]]; then
  # A fresh private directory; the server creates the owner-only file inside.
  ready_dir="$(mktemp -d -t film-lab)"
  ready_file="$ready_dir/ready.json"
  server_args+=(--ready-file "$ready_file")
  # Open the capability URL once the server reports it is listening. The token
  # travels in the URL fragment, so it is not sent in any HTTP request line.
  (
    for _ in $(seq 1 600); do
      if [[ -s "$ready_file" ]]; then
        url="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["local"])' "$ready_file")"
        rm -rf "$ready_dir"
        /usr/bin/open "$url"
        exit 0
      fi
      sleep 0.1
    done
    rm -rf "$ready_dir"
  ) &
fi

exec python3 "$here/server.py" ${server_args[@]+"${server_args[@]}"}
