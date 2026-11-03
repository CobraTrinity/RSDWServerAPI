#!/bin/sh
# Runs from the nginx image's /docker-entrypoint.d on every start: writes the panel's
# config.js and the nginx site from the container environment.
#
#   RSDW_API_UPSTREAM  Game server API to proxy /api/ to, e.g. http://10.0.0.5:8080.
#                      The panel then talks to its own address, so one HTTPS host in
#                      front of this container covers both the panel and the API.
#   RSDW_API_URL       API address pre-filled in the panel when not proxying,
#                      e.g. https://api.example.com. Ignored when RSDW_API_UPSTREAM is set.
set -eu

HTML=/usr/share/nginx/html
UPSTREAM="${RSDW_API_UPSTREAM:-}"
API_URL="${RSDW_API_URL:-}"

# Both values end up inside nginx config or JavaScript, so anything beyond a plain
# http(s) URL is refused rather than escaped.
require_url() {
    if [ -n "$2" ] && ! printf '%s' "$2" | grep -Eq '^https?://[]A-Za-z0-9._~:/@%[-]+$'; then
        echo "rsdw-panel: $1 is not a plain http(s) URL: '$2'" >&2
        exit 1
    fi
}
require_url RSDW_API_UPSTREAM "$UPSTREAM"
require_url RSDW_API_URL "$API_URL"

UPSTREAM="${UPSTREAM%/}"
API_URL="${API_URL%/}"

if [ -n "$UPSTREAM" ]; then
    SAME_ORIGIN=true
    API_URL=""
else
    SAME_ORIGIN=false
fi

cat > "$HTML/config.js" <<EOF
window.RSDW_CONFIG = {
  apiUrl: "$API_URL",
  sameOrigin: $SAME_ORIGIN,
};
EOF

API_BLOCK=""
if [ -n "$UPSTREAM" ]; then
    # A variable in proxy_pass makes nginx resolve the host per request instead of once
    # at startup, so the panel still starts while the game server is down. With no URI
    # part, the original request path (/api/...) is passed through unchanged.
    RESOLVER=$(awk '/^nameserver/ { ns = ns " " ($2 ~ /:/ ? "[" $2 "]" : $2) } END { print ns }' /etc/resolv.conf)
    API_BLOCK="
    resolver${RESOLVER:- 127.0.0.11} valid=30s ipv6=off;

    location /api/ {
        set \$rsdw_upstream $UPSTREAM;
        proxy_pass \$rsdw_upstream;
        proxy_http_version 1.1;
        proxy_set_header Host \$proxy_host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout 30s;
    }"
    echo "rsdw-panel: proxying /api/ to $UPSTREAM"
elif [ -n "$API_URL" ]; then
    echo "rsdw-panel: panel defaults to API at $API_URL"
else
    echo "rsdw-panel: no API configured, the panel will ask for its address"
fi

# 'expires' rather than add_header for caching: an add_header inside a location would
# drop every add_header inherited from the server block.
cat > /etc/nginx/conf.d/default.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_tokens off;

    root $HTML;
    index index.html;

    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src *; frame-ancestors 'none'" always;

    location = / {
        expires -1;
        try_files /index.html =404;
    }

    location = /config.js {
        expires -1;
    }

    location = /healthz {
        access_log off;
        default_type text/plain;
        return 200 "ok\n";
    }
$API_BLOCK
}
EOF
