#!/bin/bash

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

# Script Version and Date
scriptversion="3.7.24"
scriptdate="2024-03-07"

# Terminate script if a command fails
set -euo pipefail

# Print script information
echo "Running *Arr Install Script - Version [$scriptversion] as of [$scriptdate]"

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root."
    exit
fi

# Select the application to install
echo "Select the application to install: "
select app in bazarr lidarr prowlarr radarr readarr sonarr whisparr quit; do
    case $app in
        bazarr)
            app_port="6767"
            app_prereq="sudo cifs-utils curl python3 python3-dev python3-pip git unrar ffmpeg software-properties-common qemu-guest-agent python3-setuptools python3-lxml python3-numpy"
            app_umask="0002"
            branch="master"
            break
            ;;
        lidarr)
            app_port="8686"
            app_prereq="curl sqlite3 libchromaprint-tools mediainfo"
            app_umask="0002"
            branch="master"
            break
            ;;
        prowlarr)
            app_port="9696"
            app_prereq="curl sqlite3"
            app_umask="0002"
            branch="develop"
            break
            ;;
        radarr)
            app_port="7878"
            app_prereq="curl sqlite3"
            app_umask="0002"
            branch="master"
            break
            ;;
        readarr)
            app_port="8787"
            app_prereq="curl sqlite3"
            app_umask="0002"
            branch="develop"
            break
            ;;
        sonarr)
            app_port="8989"
            app_prereq="curl sqlite3 mediainfo gnupg ca-certificates"
            app_umask="0002"
            branch="master"
            break
            ;;
        whiparr)
            app_port="6969"
            app_prereq="curl sqlite3 mediainfo gnupg ca-certificates"
            app_umask="0002"
            branch="master"
            break
            ;;
        quit)
            exit 0
            ;;
        *)
            echo "Invalid option $REPLY"
            ;;
    esac
done

# Constants
installdir="/opt"             
bindir="${installdir}/${app^}"
datadir="/var/lib/$app/"
app_bin=${app^}

# Warn about permissions
if [[ $app != 'prowlarr' ]]; then
    echo "It is critical that the user and group you select to run ${app^} as will have READ and WRITE access to your Media Library and Download Client Completed Folders"
fi

# Prompt for user and group
read -r -p "What user should ${app^} run as? (Default: servarr): " app_uid
app_uid=$(echo "$app_uid" | tr -d ' ')
app_uid=${app_uid:-servarr}

read -r -p "What group should ${app^} run as? (Default: servarr): " app_guid
app_guid=$(echo "$app_guid" | tr -d ' ')
app_guid=${app_guid:-servarr}

echo "${app^} selected"
echo "This will install [${app^}] to [$bindir] and use [$datadir] for the AppData Directory"
if [[ $app == 'prowlarr' ]]; then
    echo "${app^} will run as the user [$app_uid] and group [$app_guid]."
else
    echo "${app^} will run as the user [$app_uid] and group [$app_guid]. By continuing, you've confirmed that that user and group will have READ and WRITE access to your Media Library and Download Client Completed Download directories"
fi

# Confirm installation
echo "Continue with the installation [Yes/No]?"
select yn in "Yes" "No"; do
    case $yn in
        Yes) break ;;
        No) exit 0 ;;
    esac
done

# Create User / Group if needed
if [ "$app_guid" != "$app_uid" ]; then
    if ! getent group "$app_guid" >/dev/null; then
        groupadd "$app_guid"
    fi
fi
if ! getent passwd "$app_uid" >/dev/null; then
    adduser --system --no-create-home --ingroup "$app_guid" "$app_uid"
    echo "Created and added User [$app_uid] to Group [$app_guid]"
fi
if ! getent group "$app_guid" | grep -qw "$app_uid"; then
    echo "User [$app_uid] did not exist in Group [$app_guid]"
    usermod -a -G "$app_guid" "$app_uid"
    echo "Added User [$app_uid] to Group [$app_guid]"
fi

# Stop the App if running
if service --status-all | grep -Fq "$app"; then
    systemctl stop $app
    systemctl disable $app.service
    echo "Stopped existing $app"
fi

# Create Appdata Directory
mkdir -p "$datadir"
chown -R "$app_uid":"$app_guid" "$datadir"
chmod 775 "$datadir"
echo "Directories created"

# Install the App
echo "Installing..."

# Install prerequisite packages
apt update && apt install $app_prereq

# Download and extract the App
case $app in
    bazarr)
        # Download Bazarr
		# Clone Bazarr repository to /opt/Bazarr
		git clone https://github.com/morpheus65535/bazarr.git /opt/Bazarr
		cd /opt/Bazarr
        ;;
    sonarr)
        # Add Sonarr install
		wget -qO- https://raw.githubusercontent.com/Sonarr/Sonarr/develop/distribution/debian/install.sh | sudo bash        ;;
    *)
        # Download and install other Apps
        dlbase="https://$app.servarr.com/v1/update/$branch/updatefile?os=linux&runtime=netcore"
        ARCH=$(dpkg --print-architecture)
        case "$ARCH" in
            "amd64") DLURL="${dlbase}&arch=x64" ;;
            "armhf") DLURL="${dlbase}&arch=arm" ;;
            "arm64") DLURL="${dlbase}&arch=arm64" ;;
            *)
                echo "Arch not supported"
                exit 1
                ;;
        esac
        wget --content-disposition "$DLURL"
        tar -xvzf ${app^}.*.tar.gz
        ;;
esac

# Remove existing installation and install new
echo "Removing existing installation"
rm -rf $bindir
rm -rf ~/${app}.zip*

echo "Installing..."
mv "${app^}" $installdir
chown "$app_uid":"$app_guid" -R "$bindir"
chmod 775 "$bindir"
rm -rf "${app^}.*.tar.gz"
rm -rf "${app}.zip*"

# Ensure we check for an update
touch "$datadir"/update_required
chown "$app_uid":"$app_guid" "$datadir"/update_required
echo "App Installed"

# Configure Autostart
echo "Removing old service file"
rm -rf /etc/systemd/system/$app.service

echo "Creating service file"
cat <<EOF | tee /etc/systemd/system/$app.service >/dev/null
[Unit]
Description=${app^} Daemon
After=syslog.target network.target sonarr.service radarr.service

[Service]
User=$app_uid
Group=$app_guid
UMask=$app_umask
Type=simple
ExecStart=$(if [[ $app == 'sonarr' ]]; then echo "/usr/bin/mono --debug $bindir/$app_bin.exe -nobrowser -data=$datadir"; else echo "$bindir/$app_bin -nobrowser -data=$datadir"; fi)
TimeoutStopSec=20
SyslogIdentifier=$app
KillSignal=SIGINT
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Start the App
echo "Service file created. Attempting to start the app"
systemctl -q daemon-reload
systemctl enable --now -q "$app"

# Finish Installation
host=$(hostname -I)
ip_local=$(grep -oP '^\S*' <<<"$host")
echo "Install complete"
sleep 10
STATUS="$(systemctl is-active $app)"
if [ "${STATUS}" = "active" ]; then
    echo "Browse to http://$ip_local:$app_port for the ${app^} GUI"
else
    echo "${app^} failed to start"
fi

# Exit
exit 0
