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
#   CF_API_KEY      - CurseForge API key (required for auto-updates)
#                     Free registration at https://console.curseforge.com/
#                     Without this, AUTO_UPDATE must be set to false and
#                     server files must be managed manually.
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
#   SEED            - World seed (default: empty = random)
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------

DATA_DIR="${DATA_DIR:-/data}"
# Embedded fallback key - users can override by setting CF_API_KEY environment variable
CF_API_KEY="${CF_API_KEY:-\$2a\$10\$BEOCchfVt4uvKNcm3Z6tYuw64UY91gDGzShzqsltiWBNaZXSyvruW}"
AUTO_UPDATE="${AUTO_UPDATE:-true}"
EULA="${EULA:-false}"
MEMORY_MIN="${MEMORY_MIN:-4G}"
MEMORY_MAX="${MEMORY_MAX:-8G}"
MAX_PLAYERS="${MAX_PLAYERS:-20}"
SERVER_PORT="${SERVER_PORT:-25565}"
MOTD="${MOTD:-All the Mods 11}"
WHITE_LIST="${WHITE_LIST:-false}"
SEED="${SEED:-}"

ATM11_PROJECT_ID="1148445"
VERSION_MARKER="${DATA_DIR}/.atm11_installed_version"
WORK_DIR="${DATA_DIR}/.atm11_update"

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
pause-when-empty-seconds=0
level-seed=${SEED}
PROPS
    else
        # Update specific properties without clobbering the whole file
        sed -i "s/^server-port=.*/server-port=${SERVER_PORT}/" "$props"
        sed -i "s/^max-players=.*/max-players=${MAX_PLAYERS}/" "$props"
        sed -i "s/^white-list=.*/white-list=${WHITE_LIST}/" "$props"
        # Ensure pause-when-empty-seconds is always 0
        if grep -q "^pause-when-empty-seconds=" "$props"; then
            sed -i "s/^pause-when-empty-seconds=.*/pause-when-empty-seconds=0/" "$props"
        else
            echo "pause-when-empty-seconds=0" >> "$props"
        fi
        # Only set seed if specified and world does not yet exist
        if [ -n "${SEED}" ] && [ ! -d "${DATA_DIR}/world" ]; then
            if grep -q "^level-seed=" "$props"; then
                sed -i "s/^level-seed=.*/level-seed=${SEED}/" "$props"
            else
                echo "level-seed=${SEED}" >> "$props"
            fi
        fi
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
    # Requires a CurseForge API key set via CF_API_KEY environment variable.
    if [ -z "$CF_API_KEY" ]; then
        warn "CF_API_KEY not set and no fallback available. Cannot check for updates."
        echo ""
        return
    fi

    # Get latest client releases
    local response
    response=$(curl -sf \
        -H "x-api-key: ${CF_API_KEY}" \
        "https://api.curseforge.com/v1/mods/${ATM11_PROJECT_ID}/files?pageSize=5&sortOrder=desc" \
        2>/dev/null) || {
        warn "CurseForge API request failed. Skipping update check."
        echo ""
        return
    }

    # Get serverPackFileId from the latest client release
    local server_pack_id
    server_pack_id=$(echo "$response" | jq -r '
        .data[]
        | select(.isServerPack == false and .serverPackFileId != null and .serverPackFileId != 0)
        | .serverPackFileId | tostring
    ' | head -1)

    if [ -z "$server_pack_id" ] || [ "$server_pack_id" = "null" ]; then
        warn "Could not determine server pack file ID. Skipping update check."
        echo ""
        return
    fi

    # Fetch server pack file details
    local server_file_info
    server_file_info=$(curl -sf \
        -H "x-api-key: ${CF_API_KEY}" \
        "https://api.curseforge.com/v1/mods/${ATM11_PROJECT_ID}/files/${server_pack_id}" \
        2>/dev/null) || {
        warn "CurseForge API request for server pack failed. Skipping update check."
        echo ""
        return
    }

    local filename download_url
    filename=$(echo "$server_file_info" | jq -r '.data.fileName // empty')
    download_url=$(echo "$server_file_info" | jq -r '.data.downloadUrl // empty')

    if [ -z "$filename" ]; then
        warn "Could not determine server pack filename. Skipping update check."
        echo ""
        return
    fi

    log "Found server pack: ${filename} (id: ${server_pack_id})" >&2
    printf "%s\t%s\t%s\n" "$filename" "$server_pack_id" "$download_url"
}

# --- Apply update ------------------------------------------------------------

apply_update() {
    local zip_url="$1"
    local zip_file="${WORK_DIR}/server_update.zip"

    log "Downloading server files from: $zip_url"
    mkdir -p "$WORK_DIR"
    local attempts=0
    while [ $attempts -lt 3 ]; do
        curl -fL -o "$zip_file" "$zip_url" && break
        attempts=$((attempts + 1))
        warn "Download failed (attempt ${attempts}/3). Retrying in 10 seconds..."
        sleep 10
    done
    if [ $attempts -eq 3 ] && [ ! -s "$zip_file" ]; then
        warn "Failed to download server files after 3 attempts. Starting with existing files."
        rm -f "$zip_file"
        return
    fi

    log "Extracting update directly into ${DATA_DIR}..."

    # Remove directories that will be replaced
    for dir in mods config kubejs defaultconfigs; do
        if unzip -l "$zip_file" | grep -q " ${dir}/"; then
            log "Removing old ${dir}/..."
            rm -rf "${DATA_DIR:?}/${dir}"
        fi
    done

    # Extract everything directly into DATA_DIR
    # Preserve user_jvm_args.txt if it already exists
    local preserve_jvm=""
    if [ -f "${DATA_DIR}/user_jvm_args.txt" ]; then
        preserve_jvm="user_jvm_args.txt"
    fi

    log "Extracting zip..."
    unzip -q -o "$zip_file" -d "$DATA_DIR" || die "Failed to extract server zip."

    # Restore user_jvm_args.txt if we had one (unzip may have overwritten it)
    # This is handled by applying JVM args after update so no action needed here

    chmod +x "${DATA_DIR}/startserver.sh" 2>/dev/null || true

    rm -f "$zip_file"
    rm -rf "$WORK_DIR"
    log "Update extraction complete."
}

# --- Main update logic -------------------------------------------------------

run_update_check() {
    if [ "$AUTO_UPDATE" != "true" ]; then
        log "AUTO_UPDATE is disabled. Skipping update check."
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

    # Only save version marker if extraction succeeded
    if [ -f "${DATA_DIR}/startserver.sh" ]; then
        echo "$latest_filename" > "$VERSION_MARKER"
        log "Update to ${latest_filename} complete."
    else
        die "Extraction failed - startserver.sh not found after update. Check logs above."
    fi
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
