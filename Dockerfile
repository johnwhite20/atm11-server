# =============================================================================
# ATM11 Auto-Update Server Docker Image
#
# Build:
#   docker build -t my-atm11-server .
#
# Or push to Docker Hub:
#   docker build -t norbertcolon/atm11-server:latest .
#   docker push norbertcolon/atm11-server:latest
# =============================================================================

# NeoForge 26.1.2.41-beta requires Java 25 (class file version 69).
FROM eclipse-temurin:25-jre-noble

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    jq \
    unzip \
    bash \
    && rm -rf /var/lib/apt/lists/*

# Unraid runs containers as uid 99 (nobody) / gid 100 (users)
# This matches the host permission model for /mnt/user/appdata paths
RUN groupmod -g 100 users 2>/dev/null || groupadd -g 100 users && \
    usermod -u 99 -g 100 nobody 2>/dev/null || useradd -u 99 -g 100 -M nobody

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Server data lives on a bind-mounted volume
VOLUME ["/data"]

# Default Minecraft port
EXPOSE 25565

# Environment variable defaults (override in Unraid container template)
ENV DATA_DIR=/data \
    CF_API_KEY="" \
    AUTO_UPDATE="true" \
    EULA="false" \
    MEMORY_MIN="4G" \
    MEMORY_MAX="8G" \
    MAX_PLAYERS="20" \
    SERVER_PORT="25565" \
    MOTD="All the Mods 11" \
    WHITE_LIST="false" \
    OPS="" \
    WHITELIST=""

USER nobody

ENTRYPOINT ["/entrypoint.sh"]
