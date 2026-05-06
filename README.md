# ATM11 Auto-Update Server for Unraid

A Docker container that runs an [All the Mods 11](https://www.curseforge.com/minecraft/modpacks/all-the-mods-11) Minecraft server on Unraid, with automatic updates on each restart.

## Features

- Automatically checks CurseForge for the latest ATM11 server release on every container start
- Downloads and applies updates to mods, config, and kubejs without touching your world data
- Automatically detects NeoForge version changes and re-runs the installer when required
- All key server settings are configurable via environment variables in the Unraid UI

---

## Installation

The recommended installation method is via the Unraid Docker template, which pre-fills all configuration fields automatically.

**Step 1 — Copy the template to Unraid**

Open the Unraid terminal and run:

```bash
wget -O /boot/config/plugins/dockerMan/templates-user/atm11-server.xml \
  https://raw.githubusercontent.com/johnwhite20/atm11-server/main/atm11-server.xml
```

**Step 2 — Add the container**

1. Go to the **Docker** tab in Unraid
2. Click **Add Container**
3. Click the **Template** dropdown at the top and select **atm11-server**
4. Fill in the required variables (see below)
5. Click **Apply**

---

## Required Variables

These must be set before the container will start correctly.

| Variable | Description |
|---|---|
| `EULA` | Must be set to `true` to accept the [Minecraft EULA](https://aka.ms/MinecraftEULA). The server will not start without this. |

---

## Optional Variables

| Variable | Default | Description |
|---|---|---|
| `AUTO_UPDATE` | `true` | Check for and apply ATM11 updates on each container start. Set to `false` to disable. |
| `MEMORY_MAX` | `8G` | Maximum JVM heap size. Use `G` for gigabytes or `M` for megabytes e.g. `10G` or `10240M`. Recommended minimum `6G`. |
| `MEMORY_MIN` | `4G` | Minimum JVM heap size. |
| `MAX_PLAYERS` | `20` | Maximum number of players allowed on the server. |
| `SERVER_PORT` | `25565` | Minecraft server port. Must match the host port mapping in the container settings. |
| `MOTD` | `All the Mods 11` | Message of the day displayed in the Minecraft server list. |
| `SEED` | _(blank)_ | World generation seed. Leave blank for a random seed. Only applied before a world is first created — changing this after a world exists has no effect. |
| `WHITE_LIST` | `false` | Set to `true` to enable the server whitelist. |
| `WHITELIST` | _(blank)_ | Comma-separated list of player usernames to add to the whitelist e.g. `Player1,Player2` |
| `OPS` | _(blank)_ | Comma-separated list of player usernames to grant operator status e.g. `Player1,Player2` |

---

## Data Directory

All server files, world data, mods, and configuration are stored in the container's `/data` directory. In the Unraid template this defaults to `/mnt/user/appdata/atm11`.

**Files that are updated automatically on each new ATM11 release:**
- `mods/`
- `config/`
- `kubejs/`
- `defaultconfigs/`
- `startserver.sh`

**Files that are never overwritten:**
- `world/` (your world data)
- `server.properties`
- `ops.json`
- `whitelist.json`
- `banned-players.json`
- `banned-ips.json`
- `user_jvm_args.txt`

---

## First Run

On first start the container will:

1. Check CurseForge for the latest ATM11 server files and download them (~500MB)
2. Download and run the NeoForge installer (~11MB installer, downloads ~200MB of libraries)
3. Start the server

This process can take **10–15 minutes**. Watch the container logs in Unraid to follow progress. The server is ready when you see `Done! For help, type "help"` in the logs.

---

## Updating

Simply restart the container. If a new ATM11 version has been published on CurseForge since the last start, it will be downloaded and applied automatically before the server starts.

> **Note:** ATM11 is currently in early alpha. Some updates may include mod removals or world-breaking changes. It is recommended to back up your `/data` directory before restarting if you want to preserve the ability to roll back.

---

## Requirements

- Unraid 6.9 or later
- At least 10GB free disk space for the server data directory
- At least 8GB RAM allocated to the container (12GB+ recommended for multiple players)

---

## Support

- [ATM11 on CurseForge](https://www.curseforge.com/minecraft/modpacks/all-the-mods-11)
- [ATM11 GitHub Issues](https://github.com/AllTheMods/ATM-11)
- [Unraid Forums](https://forums.unraid.net)
