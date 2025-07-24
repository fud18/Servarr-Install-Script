#!/bin/bash
# ===================================================================================
# Description: Servarr Installer & Updater with Backup, Rollback, and CLI Mode
# Author:      Cory Funk 2025
# ===================================================================================

scriptversion="3.4.1"
scriptdate="2025-07-24"

set -euo pipefail

# ===================================================================================
# Colors
# ===================================================================================
green='\033[0;32m'
yellow='\033[1;33m'
red='\033[0;31m'
reset='\033[0m'

# ===================================================================================
# Logging
# ===================================================================================
LOG_FILE="/var/log/servarr-install.log"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo -e "$msg" | tee -a "$LOG_FILE"
}

# ===================================================================================
# Ensure root
# ===================================================================================
if [ "$EUID" -ne 0 ]; then
    log "${red}Please run as root!${reset}"
    exit 1
fi

# ===================================================================================
# CLI Flags
# ===================================================================================
APP_CHOICE=""
AUTO_YES=false
ROLLBACK_APP=""
LIST_APP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            APP_CHOICE="$2"
            shift 2
            ;;
        --yes|--force)
            AUTO_YES=true
            shift
            ;;
        --rollback)
            ROLLBACK_APP="$2"
            shift 2
            ;;
        --list-backups)
            LIST_APP="$2"
            shift 2
            ;;
        *)
            log "Unknown parameter: $1"
            exit 1
            ;;
    esac
done

# ===================================================================================
# Backup & Rollback Functions
# ===================================================================================
BACKUP_DIR="/opt/backups"

create_backup() {
    local app_display="$1"
    local bindir="$2"

    mkdir -p "$BACKUP_DIR/$app_display"
    local timestamp
    timestamp=$(date +'%Y-%m-%d_%H%M%S')
    local backup_file="$BACKUP_DIR/$app_display/${app_display}_${timestamp}.tar.gz"

    log "[INFO] Creating backup at $backup_file"
    tar -czf "$backup_file" -C "$(dirname "$bindir")" "$(basename "$bindir")"

    # Rotate backups (keep 3 most recent)
    local backups
    backups=($(ls -t "$BACKUP_DIR/$app_display"/*.tar.gz 2>/dev/null || true))
    if (( ${#backups[@]} > 3 )); then
        for ((i=3; i<${#backups[@]}; i++)); do
            log "[INFO] Removing old backup ${backups[$i]}"
            rm -f "${backups[$i]}"
        done
    fi
}

list_backups() {
    local app_display="$1"
    if [[ -d "$BACKUP_DIR/$app_display" ]]; then
        log "[INFO] Available backups for $app_display:"
        ls -t "$BACKUP_DIR/$app_display"/*.tar.gz | nl
    else
        log "[INFO] No backups found for $app_display."
    fi
}

rollback_backup() {
    local app_display="$1"
    if [[ ! -d "$BACKUP_DIR/$app_display" ]]; then
        log "${red}No backups found for $app_display.${reset}"
        exit 1
    fi

    local backups
    backups=($(ls -t "$BACKUP_DIR/$app_display"/*.tar.gz))
    log "[INFO] Backups available for $app_display:"
    for i in "${!backups[@]}"; do
        echo "$((i+1))) ${backups[$i]}"
    done

    read -r -p "Select a backup number to restore (default: 1): " selection
    selection=${selection:-1}
    local backup_file="${backups[$((selection-1))]}"

    log "[INFO] Restoring $backup_file"
    rm -rf "/opt/$app_display"
    tar -xzf "$backup_file" -C /opt/

    log "[INFO] Restarting service..."
    systemctl daemon-reload
    systemctl restart "$(echo "$app_display" | tr '[:upper:]' '[:lower:]').service"
    log "${green}Rollback complete.${reset}"
    exit 0
}

# ===================================================================================
# Handle List or Rollback Commands
# ===================================================================================
if [[ -n "$LIST_APP" ]]; then
    list_backups "$LIST_APP"
    exit 0
fi

if [[ -n "$ROLLBACK_APP" ]]; then
    rollback_backup "$ROLLBACK_APP"
    exit 0
fi

# ===================================================================================
# Main Menu
# ===================================================================================
log "${yellow}Running Servarr Install Script - Version [$scriptversion] as of [$scriptdate]${reset}"

select_app() {
    if [[ -n "$APP_CHOICE" ]]; then
        choice="$APP_CHOICE"
    else
        echo ""
        echo "Select the application to install/update:"
        echo ""
        select choice in Bazarr Lidarr Prowlarr Radarr Readarr Sonarr "Whisparr-v2" "Whisparr-v3" Quit; do
            [[ -n "$choice" ]] && break
        done
    fi
}

while true; do
    select_app
    case "$(echo "$choice" | tr '[:upper:]' '[:lower:]')" in
        bazarr) app_display="Bazarr"; app_lowercase="bazarr"; app_port="6767"; app_prereq="sudo cifs-utils python3 python3-dev python3-pip git unrar ffmpeg software-properties-common qemu-guest-agent python3-setuptools python3-lxml python3-numpy"; branch="master"; app_bin="bazarr.py" ;;
        lidarr) app_display="Lidarr"; app_lowercase="lidarr"; app_port="8686"; app_prereq="curl sqlite3 libchromaprint-tools mediainfo"; branch="master"; app_bin="Lidarr" ;;
        prowlarr) app_display="Prowlarr"; app_lowercase="prowlarr"; app_port="9696"; app_prereq="curl sqlite3"; branch="master"; app_bin="Prowlarr" ;;
        radarr) app_display="Radarr"; app_lowercase="radarr"; app_port="7878"; app_prereq="curl sqlite3"; branch="master"; app_bin="Radarr" ;;
        readarr) app_display="Readarr"; app_lowercase="readarr"; app_port="8787"; app_prereq="curl sqlite3"; branch="develop"; app_bin="Readarr" ;;
        sonarr) app_display="Sonarr"; app_lowercase="sonarr"; app_port="8989"; app_prereq="curl sqlite3 wget"; branch="main"; app_bin="Sonarr" ;;
        whisparr-v2) app_display="Whisparr-v2"; app_lowercase="whisparr-v2"; app_port="6969"; app_prereq="curl sqlite3"; branch="nightly"; app_bin="Whisparr" ;;
        whisparr-v3) app_display="Whisparr-v3"; app_lowercase="whisparr-v3"; app_port="56969"; app_prereq="curl sqlite3"; branch="eros"; app_bin="Whisparr" ;;
        quit) log "Exiting..."; exit 0 ;;
        *) log "Invalid option."; continue ;;
    esac

    installdir="/opt/${app_display}"
    bindir="${installdir}"
    datadir="/var/lib/${app_display}/"
    service_name="${app_lowercase}.service"
    app_umask="0002"

    # ===================================================================================
    # User/Group
    # ===================================================================================
    if $AUTO_YES; then
        app_uid="servarr"
        app_guid="servarr"
    else
        read -r -p "What user should $app_display run as? (Default: servarr): " app_uid
        app_uid=${app_uid:-servarr}
        read -r -p "What group should $app_display run as? (Default: servarr): " app_guid
        app_guid=${app_guid:-servarr}
    fi

    log "$app_display will install to $bindir and use $datadir"

    if ! $AUTO_YES; then
        read -r -p "Type 'yes' to continue: " confirm
        [[ "$confirm" != "yes" ]] && { log "Cancelled."; continue; }
    fi

    # ===================================================================================
    # Backup existing install
    # ===================================================================================
    if [[ -d "$bindir" ]]; then
        create_backup "$app_display" "$bindir"
    fi

    # ===================================================================================
    # Stop service
    # ===================================================================================
    systemctl stop "$service_name" 2>/dev/null || true

    # ===================================================================================
    # Install prerequisites
    # ===================================================================================
    log "[INFO] Installing prerequisites..."
    timeout 300 apt update && apt install -y $app_prereq

    # ===================================================================================
    # Download new version
    # ===================================================================================
    ARCH=$(dpkg --print-architecture)
    dlbase="https://whisparr.servarr.com/v1/update/${branch}/updatefile?os=linux&runtime=netcore"
    case "$ARCH" in
        amd64) DLURL="${dlbase}&arch=x64" ;;
        armhf) DLURL="${dlbase}&arch=arm" ;;
        arm64) DLURL="${dlbase}&arch=arm64" ;;
        *) log "${red}Unsupported architecture${reset}"; exit 1 ;;
    esac

    log "[INFO] Downloading latest version from $DLURL"
    wget --content-disposition "$DLURL"
    TARBALL=$(ls Whisparr*.tar.gz)
    tar -xzf "$TARBALL" >/dev/null 2>&1
    rm -f "$TARBALL"

    # ===================================================================================
    # Replace old install
    # ===================================================================================
    rm -rf "$bindir"
    mv Whisparr "$installdir"
    chown -R "$app_uid":"$app_guid" "$bindir"
    chmod 775 "$bindir"
    mkdir -p "$datadir"
    chown -R "$app_uid":"$app_guid" "$datadir"

    # ===================================================================================
    # Force Whisparr-v3 to Port 56969
    # ===================================================================================
    if [[ "$app_display" == "Whisparr-v3" ]]; then
        config_file="${datadir}/config.xml"
        if [[ ! -f "$config_file" ]]; then
            log "[INFO] Creating config.xml for Whisparr-v3 with port 56969"
            cat <<EOF > "$config_file"
<Config>
  <Port>56969</Port>
</Config>
EOF
        else
            log "[INFO] Updating Whisparr-v3 config.xml port to 56969"
            sed -i 's#<Port>.*</Port>#<Port>56969</Port>#' "$config_file"
        fi
        chown "$app_uid":"$app_guid" "$config_file"
    fi

    # ===================================================================================
    # Systemd Service
    # ===================================================================================
    cat <<EOF | tee /etc/systemd/system/${service_name} >/dev/null
[Unit]
Description=${app_display} Daemon
After=syslog.target network.target
[Service]
User=$app_uid
Group=$app_guid
UMask=$app_umask
Type=simple
ExecStart=$bindir/$app_bin -nobrowser -data=$datadir
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$service_name"
    systemctl start "$service_name" || {
        log "${red}Service failed to start. Rolling back...${reset}"
        rollback_backup "$app_display"
    }

    log "${green}$app_display installed successfully! Access: http://$(hostname -I | awk '{print $1}'):$app_port${reset}"

    if [[ -z "$APP_CHOICE" ]]; then
        read -r -p "Install another app? (yes/no): " again
        [[ "$again" != "yes" ]] && break
    else
        break
    fi
done
