#!/bin/bash
# =============================================================================
# ATM11 Auto-Update Entrypoint Script
# For use with itsnotwebby/unraid-atm11 or a custom Docker image
#
# On each container start this script will:
#   1. Check CurseForge for the latest ATM11 server file
#   2. If newer than the installed version, download and apply the update
#   3. If the NeoForge version has changed, remove libraries/ so that
#      startserver.sh will re-run the NeoForge installer automatically
#   4. Launch the server via startserver.sh
#
# Environment variables (set in Unraid container template):
#   CF_API_KEY      - CurseForge API key (required)
#   DATA_DIR        - Server data directory (default: /data)
#   AUTO_UPDATE     - Enable automatic updates: true/false (default: true)
#   EULA            - Accept Minecraft EULA: true/false (default: false)
#   MEMORY_MIN      - JVM minimum heap e.g. 4G (default: 4G)
#   MEMORY_MAX      - JVM maximum heap e.g. 8G (default: 8G)
#   MAX_PLAYERS     - Max players (default: 20)
#   SERVER_PORT     - Server port (default: 25565)
#   MOTD            - Server MOTD (default: All the Mods 11)
#   OPS             - Comma-separated list of operator usernames
#   WHITELIST       - Comma-separated list of whitelisted usernames
#   WHITE_LIST      - Enable whitelist: true/false (default: false)
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------

DATA_DIR="${DATA_DIR:-/data}"
CF_API_KEY="${CF_API_KEY:-}"
AUTO_UPDATE="${AUTO_UPDATE:-true}"
EULA="${EULA:-false}"
MEMORY_MIN="${MEMORY_MIN:-4G}"
MEMORY_MAX="${MEMORY_MAX:-8G}"
MAX_PLAYERS="${MAX_PLAYERS:-20}"
SERVER_PORT="${SERVER_PORT:-25565}"
MOTD="${MOTD:-All the Mods 11}"
WHITE_LIST="${WHITE_LIST:-false}"

ATM11_PROJECT_ID="1148445"
VERSION_MARKER="${DATA_DIR}/.atm11_installed_version"
WORK_DIR="/tmp/atm11_update"

# --- Helpers -----------------------------------------------------------------

log()  { echo "[ATM11] $*"; }
warn() { echo "[ATM11] WARNING: $*" >&2; }
die()  { echo "[ATM11] ERROR: $*" >&2; exit 1; }

check_dependencies() {
    for cmd in curl jq unzip java; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
    done
}

# --- EULA --------------------------------------------------------------------

apply_eula() {
    if [ "$EULA" = "true" ]; then
        log "Accepting Minecraft EULA."
        echo "eula=true" > "${DATA_DIR}/eula.txt"
    else
        if [ ! -f "${DATA_DIR}/eula.txt" ] || ! grep -q "eula=true" "${DATA_DIR}/eula.txt"; then
            die "You must accept the Minecraft EULA by setting the EULA environment variable to 'true'."
        fi
    fi
}

# --- server.properties -------------------------------------------------------

apply_server_properties() {
    local props="${DATA_DIR}/server.properties"
    if [ ! -f "$props" ]; then
        log "Creating server.properties."
        cat > "$props" << PROPS
allow-flight=true
motd=${MOTD}
max-tick-time=180000
simulation-distance=5
view-distance=8
max-players=${MAX_PLAYERS}
server-port=${SERVER_PORT}
white-list=${WHITE_LIST}
PROPS
    else
        # Update specific properties without clobbering the whole file
        sed -i "s/^server-port=.*/server-port=${SERVER_PORT}/" "$props"
        sed -i "s/^max-players=.*/max-players=${MAX_PLAYERS}/" "$props"
        sed -i "s/^white-list=.*/white-list=${WHITE_LIST}/" "$props"
    fi
}

# --- ops / whitelist ---------------------------------------------------------

apply_ops() {
    if [ -n "${OPS:-}" ]; then
        local ops_file="${DATA_DIR}/ops.json"
        if [ ! -f "$ops_file" ]; then
            log "Creating ops.json."
            echo "[]" > "$ops_file"
        fi
        # Add any ops not already listed (by name)
        IFS=',' read -ra OP_LIST <<< "$OPS"
        for op in "${OP_LIST[@]}"; do
            op=$(echo "$op" | tr -d ' ')
            if ! jq -e --arg n "$op" '.[] | select(.name == $n)' "$ops_file" > /dev/null 2>&1; then
                log "Adding op: $op"
                jq --arg n "$op" '. + [{"uuid":"","name":$n,"level":4,"bypassesPlayerLimit":false}]' \
                    "$ops_file" > /tmp/ops_tmp.json && mv /tmp/ops_tmp.json "$ops_file"
            fi
        done
    fi
}

apply_whitelist() {
    if [ -n "${WHITELIST:-}" ]; then
        local wl_file="${DATA_DIR}/whitelist.json"
        if [ ! -f "$wl_file" ]; then
            log "Creating whitelist.json."
            echo "[]" > "$wl_file"
        fi
        IFS=',' read -ra WL_LIST <<< "$WHITELIST"
        for player in "${WL_LIST[@]}"; do
            player=$(echo "$player" | tr -d ' ')
            if ! jq -e --arg n "$player" '.[] | select(.name == $n)' "$wl_file" > /dev/null 2>&1; then
                log "Adding to whitelist: $player"
                jq --arg n "$player" '. + [{"uuid":"","name":$n}]' \
                    "$wl_file" > /tmp/wl_tmp.json && mv /tmp/wl_tmp.json "$wl_file"
            fi
        done
    fi
}

# --- user_jvm_args.txt -------------------------------------------------------

apply_jvm_args() {
    local jvm_file="${DATA_DIR}/user_jvm_args.txt"
    # Always update heap settings; preserve any other user additions
    if [ ! -f "$jvm_file" ]; then
        log "Creating user_jvm_args.txt."
        cat > "$jvm_file" << JVM
-Xms${MEMORY_MIN}
-Xmx${MEMORY_MAX}
-XX:+UseG1GC
-XX:+ParallelRefProcEnabled
-XX:MaxGCPauseMillis=200
-XX:+UnlockExperimentalVMOptions
-XX:+DisableExplicitGC
-XX:+AlwaysPreTouch
-XX:G1NewSizePercent=30
-XX:G1MaxNewSizePercent=40
-XX:G1HeapRegionSize=8M
-XX:G1ReservePercent=20
-XX:G1HeapWastePercent=5
-XX:G1MixedGCCountTarget=4
-XX:InitiatingHeapOccupancyPercent=15
-XX:G1MixedGCLiveThresholdPercent=90
-XX:G1RSetUpdatingPauseTimePercent=5
-XX:SurvivorRatio=32
-XX:+PerfDisableSharedMem
-XX:MaxTenuringThreshold=1
JVM
    else
        # Only update the -Xms and -Xmx lines
        sed -i "s/^-Xms.*/-Xms${MEMORY_MIN}/" "$jvm_file"
        sed -i "s/^-Xmx.*/-Xmx${MEMORY_MAX}/" "$jvm_file"
    fi
}

# --- NeoForge version from startserver.sh ------------------------------------

get_installed_neoforge_version() {
    local ss="${DATA_DIR}/startserver.sh"
    if [ -f "$ss" ]; then
        grep "^NEOFORGE_VERSION=" "$ss" | cut -d= -f2 | tr -d '"' | tr -d "'"
    else
        echo ""
    fi
}

# --- CurseForge update check -------------------------------------------------

get_latest_cf_server_file() {
    # The CurseForge API returns client pack files. Each client pack has a
    # serverPackFileId field pointing to the corresponding server pack.
    # We fetch the latest client release, extract serverPackFileId, then
    # fetch that file's details to get the server pack fileName and downloadUrl.
    if [ -z "$CF_API_KEY" ]; then
        warn "CF_API_KEY not set. Skipping update check."
        echo ""
        return
    fi

    # Get latest client release (first result, sorted by date desc)
    local response
    response=$(curl -sf \
        -H "x-api-key: ${CF_API_KEY}" \
        "https://api.curseforge.com/v1/mods/${ATM11_PROJECT_ID}/files?pageSize=5&sortOrder=desc" \
        2>/dev/null) || {
        warn "CurseForge API request failed. Skipping update check."
        echo ""
        return
    }

    # Extract serverPackFileId from the latest release
    local server_pack_id
    server_pack_id=$(echo "$response" | jq -r '
        .data[]
        | select(.isServerPack == false and .serverPackFileId != null)
        | .serverPackFileId | tostring
    ' | head -1)

    if [ -z "$server_pack_id" ] || [ "$server_pack_id" = "null" ]; then
        warn "Could not determine server pack file ID from CurseForge."
        echo ""
        return
    fi

    # Fetch the server pack file details
    local server_file_info
    server_file_info=$(curl -sf \
        -H "x-api-key: ${CF_API_KEY}" \
        "https://api.curseforge.com/v1/mods/${ATM11_PROJECT_ID}/files/${server_pack_id}" \
        2>/dev/null) || {
        warn "CurseForge API request for server pack failed. Skipping update check."
        echo ""
        return
    }

    # Return fileName, fileId, and downloadUrl as TSV
    echo "$server_file_info" | jq -r '
        .data
        | [.fileName, (.id | tostring), .downloadUrl]
        | @tsv
    '
}

# --- Apply update ------------------------------------------------------------

apply_update() {
    local zip_url="$1"
    local zip_file="${WORK_DIR}/server_update.zip"

    log "Downloading server files from: $zip_url"
    mkdir -p "$WORK_DIR"
    curl -sfL -o "$zip_file" "$zip_url" || die "Failed to download server files."

    log "Extracting update..."

    # Directories to replace entirely
    for dir in mods config kubejs defaultconfigs; do
        if unzip -l "$zip_file" | grep -q "^.*  ${dir}/"; then
            log "Replacing ${dir}/..."
            rm -rf "${DATA_DIR:?}/${dir}"
            unzip -q -o "$zip_file" "${dir}/*" -d "$DATA_DIR"
        fi
    done

    # Root-level files to always overwrite
    for f in startserver.sh startserver.bat server-icon.png; do
        if unzip -l "$zip_file" | grep -q " ${f}$"; then
            log "Updating ${f}..."
            unzip -q -o "$zip_file" "$f" -d "$DATA_DIR"
        fi
    done

    # user_jvm_args.txt: only extract if not already present
    if [ ! -f "${DATA_DIR}/user_jvm_args.txt" ]; then
        log "Extracting user_jvm_args.txt (first install)..."
        unzip -q -o "$zip_file" "user_jvm_args.txt" -d "$DATA_DIR" 2>/dev/null || true
    fi

    chmod +x "${DATA_DIR}/startserver.sh" 2>/dev/null || true

    rm -rf "$WORK_DIR"
    log "Update extraction complete."
}

# --- Main update logic -------------------------------------------------------

run_update_check() {
    if [ "$AUTO_UPDATE" != "true" ]; then
        log "AUTO_UPDATE is disabled. Skipping update check."
        return
    fi

    if [ -z "$CF_API_KEY" ]; then
        warn "CF_API_KEY not set. Skipping update check."
        return
    fi

    log "Checking for ATM11 updates..."

    local latest_info
    latest_info=$(get_latest_cf_server_file)

    if [ -z "$latest_info" ]; then
        warn "Could not retrieve latest version info. Starting with existing files."
        return
    fi

    local latest_filename latest_id download_url
    latest_filename=$(echo "$latest_info" | cut -f1)
    latest_id=$(echo "$latest_info" | cut -f2)
    download_url=$(echo "$latest_info" | cut -f3)

    local installed_version=""
    if [ -f "$VERSION_MARKER" ]; then
        installed_version=$(cat "$VERSION_MARKER")
    fi

    log "Latest available: ${latest_filename} (id: ${latest_id})"
    log "Installed version: ${installed_version:-none}"

    if [ "$latest_filename" = "$installed_version" ]; then
        log "ATM11 is up to date."
        return
    fi

    log "Update available: ${latest_filename}. Applying update..."

    # Record NeoForge version before update
    local old_neoforge
    old_neoforge=$(get_installed_neoforge_version)

    # Fall back to constructing URL if API returned null
    if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
        local id_part1 id_part2
        id_part1=$(echo "$latest_id" | cut -c1-4)
        id_part2=$(echo "$latest_id" | cut -c5-)
        download_url="https://mediafilez.forgecdn.net/files/${id_part1}/${id_part2}/${latest_filename// /%20}"
        log "Constructed download URL: ${download_url}"
    fi

    apply_update "$download_url"

    # Check if NeoForge version has changed
    local new_neoforge
    new_neoforge=$(get_installed_neoforge_version)

    if [ "$old_neoforge" != "$new_neoforge" ]; then
        log "NeoForge version changed: ${old_neoforge:-none} -> ${new_neoforge}"
        log "Removing libraries/ so NeoForge installer will run on next start."
        rm -rf "${DATA_DIR:?}/libraries"
    fi

    # Save installed version marker
    echo "$latest_filename" > "$VERSION_MARKER"
    log "Update to ${latest_filename} complete."
}

# --- Entry point -------------------------------------------------------------

mkdir -p "$DATA_DIR"
cd "$DATA_DIR"

check_dependencies
apply_eula
run_update_check
apply_server_properties
apply_jvm_args
apply_ops
apply_whitelist

# Ensure startserver.sh is executable
if [ ! -f "${DATA_DIR}/startserver.sh" ]; then
    die "startserver.sh not found in ${DATA_DIR}. Has the server been initialised?"
fi
chmod +x "${DATA_DIR}/startserver.sh"

log "Starting ATM11 server..."
exec "${DATA_DIR}/startserver.sh"
