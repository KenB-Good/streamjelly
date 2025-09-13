#!/usr/bin/env bash
set -euo pipefail
sudo apt-get update -y
sudo apt-get install -y caddy
echo "Caddy installed. Copy caddy/Caddyfile.sample to /etc/caddy/Caddyfile, set your domain, then:"
echo "  sudo systemctl reload caddy"
