#!/bin/sh
set -eu
repo=/srv/git/relay-infra.git
if [ ! -d "$repo" ]; then
  git init --bare -q "$repo"
fi
# Pushes arrive unauthenticated over port-forward, so git-http-backend needs receive-pack enabled explicitly.
git -C "$repo" config http.receivepack true
exec lighttpd -D -f /etc/lighttpd/relay-git.conf
