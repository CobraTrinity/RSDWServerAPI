#!/bin/bash
# RSDWServerAPI version check for the Pterodactyl/Pelican egg.
#
# Runs at install time and before every boot. Asks the configured GitHub repository which
# build its release currently holds and installs it when it differs from the one on disk.
# Needs only bash, curl, awk and sha256sum (the runtime image has no jq); zips are unpacked
# with the unzip the installer leaves in .egg/.
#
#   usage: rsdwapi-update.sh SERVER_DIR LOG_PREFIX
#
# Settings (panel variables):
#   RSDWAPI_REPO     owner/repo to follow                      (default CobraTrinity/RSDWServerAPI)
#   RSDWAPI_RELEASE  'latest', a tag to pin, or 'manual' to never touch librsdwapi.so
#   RSDWAPI_URL      direct link; overrides REPO/RELEASE, re-downloaded and compared each boot
#
# Never fails the boot: any error keeps whatever build is already installed.

SERVER_DIR="${1:-/home/container}"
P="${2:-[rsdwapi]}"
REPO="${RSDWAPI_REPO:-CobraTrinity/RSDWServerAPI}"
RELEASE="${RSDWAPI_RELEASE:-latest}"
URL="${RSDWAPI_URL:-}"

SO="${SERVER_DIR}/librsdwapi.so"
EGG="${SERVER_DIR}/.egg"
STATE="${EGG}/rsdwapi.state"

log() { echo "${P} $*"; }

if [ "${RELEASE}" = "manual" ]; then
    log "RSDWServerAPI: Release is 'manual', leaving librsdwapi.so as it is"
    exit 0
fi

mkdir -p "${EGG}" 2>/dev/null
if [ ! -w "${EGG}" ] || [ ! -w "${SERVER_DIR}" ]; then
    log "RSDWServerAPI: ${SERVER_DIR} or .egg/ is not writable (file ownership?), skipping the version check"
    exit 0
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/rsdwapi.XXXXXX") || exit 0
trap 'rm -rf "${WORK}"' EXIT

CURL=(curl -fsSL --connect-timeout 10 --retry 2)

sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
state_get() { [ -f "${STATE}" ] && sed -n "s/^$1=//p" "${STATE}" | head -n 1; }

# The installed file is "ours" when it is the one this script last wrote. Anything else
# was uploaded by hand and is not overwritten.
LOCAL_SHA=$(sha "${SO}")
if [ -n "${LOCAL_SHA}" ] && [ -f "${STATE}" ] && [ "${LOCAL_SHA}" != "$(state_get so_sha256)" ]; then
    log "RSDWServerAPI: librsdwapi.so was replaced by hand, not updating it."
    log "               Delete it (or reinstall) to follow ${URL:-${REPO}} again, or set Release to 'manual'."
    exit 0
fi

# release_asset - prints "key<TAB>tag<TAB>download url<TAB>digest" for the release's
# librsdwapi.so (else the first .so, else a linux zip, else any zip - same order as before).
# The key changes whenever the asset is replaced, even under the same tag.
release_asset() {
    local api="https://api.github.com/repos/${REPO}/releases"
    if [ "${RELEASE}" = "latest" ]; then api="${api}/latest"; else api="${api}/tags/${RELEASE}"; fi

    "${CURL[@]}" --max-time 30 -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" "${api}" -o "${WORK}/release.json" || return 1

    # Flatten the JSON and cut it into one record per asset. Asset objects are the only
    # ones whose "url" is .../releases/assets/<id>; uploader objects carry no name, digest
    # or browser_download_url, so the first match of each inside a record is the asset's.
    tr -d '\n' < "${WORK}/release.json" | sed 's/"\([a-z_]*\)": */"\1":/g' | awk '
        function field(rec, key,    m) {
            if (match(rec, "\"" key "\":\"[^\"]*\"")) {
                m = substr(rec, RSTART, RLENGTH); sub("^\"" key "\":\"", "", m); sub("\"$", "", m); return m
            }
            return ""
        }
        function num(rec, key,    m) {
            if (match(rec, "\"" key "\":[0-9]+")) { m = substr(rec, RSTART, RLENGTH); sub("^\"" key "\":", "", m); return m }
            return ""
        }
        {
            tag = field($0, "tag_name")
            n = split($0, recs, /"url":"https:\/\/api\.github\.com\/repos\/[^"]*\/releases\/assets\//)
            best = ""; rank = 99
            for (i = 2; i <= n; i++) {
                name = field(recs[i], "name"); dl = field(recs[i], "browser_download_url")
                if (name == "" || dl == "") continue
                r = 99
                if (name == "librsdwapi.so") r = 1
                else if (name ~ /\.so$/) r = 2
                else if (tolower(name) ~ /linux.*\.zip$/) r = 3
                else if (name ~ /\.zip$/) r = 4
                if (r < rank) {
                    rank = r
                    digest = field(recs[i], "digest"); sub(/^sha256:/, "", digest)
                    key = (digest != "") ? "sha256:" digest : "asset:" num(recs[i], "id") ":" field(recs[i], "updated_at")
                    best = key "\t" tag "\t" dl "\t" digest
                }
            }
            if (best != "") print best
        }'
}

# fetch URL - downloads to WORK and prints the path of the extracted .so, or nothing.
# Its stdout is captured, so messages go to stderr.
fetch() {
    "${CURL[@]}" --max-time 300 -o "${WORK}/download" "$1" || return 1
    local file="${WORK}/download"
    if [ "$(head -c 2 "${file}")" = "PK" ]; then
        local unzip
        unzip=$(command -v unzip || { [ -x "${EGG}/unzip" ] && echo "${EGG}/unzip"; })
        if [ -z "${unzip}" ]; then
            log "RSDWServerAPI: the release is a zip and unzip is unavailable - reinstall the server once" >&2
            return 1
        fi
        "${unzip}" -oq "${file}" -d "${WORK}/x" || return 1
        file=$(find "${WORK}/x" -type f -name 'librsdwapi.so' | head -n 1)
        [ -n "${file}" ] || file=$(find "${WORK}/x" -type f -name '*.so' | head -n 1)
    fi
    [ -n "${file}" ] && [ "$(head -c 4 "${file}" | od -An -c | tr -d ' ')" = '177ELF' ] || return 1
    echo "${file}"
}

if [ -n "${URL}" ]; then
    SOURCE="${URL}"
    log "RSDWServerAPI: checking ${URL}"
    NEW=$(fetch "${URL}") || { log "RSDWServerAPI: download failed or is not a Linux shared library, keeping the installed build"; exit 0; }
    KEY="sha256:$(sha "${NEW}")"; TAG=""; DIGEST=""
    if [ "$(sha "${NEW}")" = "${LOCAL_SHA}" ]; then
        log "RSDWServerAPI: up to date"
        exit 0
    fi
else
    SOURCE="${REPO}@${RELEASE}"
    INFO=$(release_asset)
    if [ -z "${INFO}" ]; then
        log "RSDWServerAPI: could not read release '${RELEASE}' of ${REPO} (offline, rate limited, or no"
        log "               .so/.zip asset) - $( [ -n "${LOCAL_SHA}" ] && echo "keeping the installed build" || echo "starting without the API")"
        exit 0
    fi
    IFS=$'\t' read -r KEY TAG DLURL DIGEST <<< "${INFO}"

    if [ -n "${LOCAL_SHA}" ] && [ "$(state_get source)" = "${SOURCE}" ] && [ "$(state_get key)" = "${KEY}" ]; then
        log "RSDWServerAPI: up to date (${REPO} ${TAG})"
        exit 0
    fi

    log "RSDWServerAPI: installing ${REPO} ${TAG}$( [ -n "$(state_get tag)" ] && echo " (was $(state_get tag))")"
    NEW=$(fetch "${DLURL}") || { log "RSDWServerAPI: download failed or is not a Linux shared library, keeping the installed build"; exit 0; }

    # GitHub's digest is of the asset itself, so it is checked before any unzip.
    if [ -n "${DIGEST}" ] && [ "$(sha "${WORK}/download")" != "${DIGEST}" ]; then
        log "RSDWServerAPI: download does not match GitHub's SHA-256, keeping the installed build"
        exit 0
    fi
fi

# Same directory, so the rename is atomic: a crash never leaves half a library behind.
install -m 0755 "${NEW}" "${SO}.new" && mv -f "${SO}.new" "${SO}" || {
    log "RSDWServerAPI: could not write ${SO}, keeping the installed build"
    rm -f "${SO}.new"
    exit 0
}
mkdir -p "${SERVER_DIR}/rsdwapi"
printf 'source=%s\nkey=%s\ntag=%s\nso_sha256=%s\n' "${SOURCE}" "${KEY}" "${TAG}" "$(sha "${SO}")" > "${STATE}.tmp" &&
    mv -f "${STATE}.tmp" "${STATE}"
log "RSDWServerAPI: installed ${TAG:-from ${URL}} ($(stat -c %s "${SO}") bytes)"
