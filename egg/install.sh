#!/bin/bash
# RuneScape: Dragonwilds (Linux) + RSDWServerAPI - install script for the Pterodactyl/Pelican egg.
# Runs in ghcr.io/parkervcp/installers:debian with the server's files mounted at /mnt/server.

SERVER_DIR=/mnt/server
APPID="${SRCDS_APPID:-4019830}"

need_tools() {
    for tool in curl unzip tar; do
        command -v "${tool}" >/dev/null 2>&1 && continue
        apt-get update -qq && apt-get install -y -qq --no-install-recommends \
            curl unzip tar ca-certificates >/dev/null
        return
    done
}

install_game() {
    echo "[install] SteamCMD"
    mkdir -p "${SERVER_DIR}/steamcmd" "${SERVER_DIR}/steamapps"
    curl -fsSL -o /tmp/steamcmd.tar.gz \
        https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz || return 1
    tar -xzf /tmp/steamcmd.tar.gz -C "${SERVER_DIR}/steamcmd" || return 1

    export HOME="${SERVER_DIR}"
    cd "${SERVER_DIR}/steamcmd" || return 1

    # SteamCMD frequently exits non-zero on its first run while it self-updates.
    local tries=0
    until [ -x "${SERVER_DIR}/RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping" ]; do
        tries=$((tries + 1))
        [ "${tries}" -gt 3 ] && { echo "[install] SteamCMD failed after 3 attempts"; return 1; }
        echo "[install] Dragonwilds dedicated server, app ${APPID} (attempt ${tries})"
        ./steamcmd.sh +force_install_dir "${SERVER_DIR}" +login anonymous \
            +app_update "${APPID}" validate +quit
    done

    # Unreal's Steam subsystem looks for this in ~/.steam/sdk64 (HOME is /home/container).
    mkdir -p "${SERVER_DIR}/.steam/sdk64"
    cp -f linux64/steamclient.so "${SERVER_DIR}/.steam/sdk64/steamclient.so"
    chmod +x "${SERVER_DIR}/RSDragonwilds/Binaries/Linux/RSDragonwildsServer-Linux-Shipping"
}

# The mod is installed by the same version check start.sh runs before every boot, so an
# install and a later update can never pick different builds. It needs no jq; zips are
# unpacked with a copy of this image's unzip (the runtime image has none, same Debian).
install_rsdwapi() {
    mkdir -p "${SERVER_DIR}/.egg"
    cat > "${SERVER_DIR}/.egg/rsdwapi-update.sh" <<'__UPDATE_SH__'
@@UPDATE_SH@@
__UPDATE_SH__
    chmod +x "${SERVER_DIR}/.egg/rsdwapi-update.sh"
    install -m 0755 "$(command -v unzip)" "${SERVER_DIR}/.egg/unzip" 2>/dev/null

    if [ "${RSDWAPI_ENABLED:-1}" != "1" ] && [ "${RSDWAPI_ENABLED:-}" != "true" ]; then
        echo "[install] RSDWServerAPI disabled, skipping the download"
        return 0
    fi
    bash "${SERVER_DIR}/.egg/rsdwapi-update.sh" "${SERVER_DIR}" "[install]"
}

write_launcher() {
    cat > "${SERVER_DIR}/start.sh" <<'__START_SH__'
@@START_SH@@
__START_SH__
    chmod +x "${SERVER_DIR}/start.sh"
}

need_tools
install_game || { echo "[install] game install failed"; exit 1; }
install_rsdwapi
write_launcher
echo "[install] done"
