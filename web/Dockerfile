# RSDW web panel: the static admin panel on nginx, optionally proxying /api/ to the
# game server so the panel and API share one address. Build from the web/ directory:
#   docker build -t rsdw-panel web
FROM nginx:1.27.5-alpine

COPY index.html config.js /usr/share/nginx/html/
COPY docker/40-rsdw-panel.sh /docker-entrypoint.d/40-rsdw-panel.sh

# Strip CRLF in case the script was checked out on Windows, where it would otherwise fail
# with "not found" when the entrypoint runs it.
RUN sed -i 's/\r$//' /docker-entrypoint.d/40-rsdw-panel.sh \
 && chmod 755 /docker-entrypoint.d/40-rsdw-panel.sh \
 && chown nginx /usr/share/nginx/html/config.js

ENV RSDW_API_UPSTREAM="" \
    RSDW_API_URL=""

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD wget -qO- http://127.0.0.1/healthz >/dev/null || exit 1
