#!/bin/bash

# Define variables
PLUGIN_NAME="xgmobile-manager"
RELEASE_URL="https://github.com/Kentronix57/Decky-Loader-XGMobile-Manager/releases/latest/download/xgmobile-manager.zip"
PLUGIN_DIR="$HOME/homebrew/plugins"

echo "Installing XG Mobile Manager..."

# 1. Stop Decky to release file locks (Request password safely)
echo "Stopping Decky Plugin Loader... (You may be prompted for your sudo password)"
sudo systemctl stop plugin_loader < /dev/tty

# 2. Navigate to plugins folder
sudo mkdir -p "$PLUGIN_DIR"
cd "$PLUGIN_DIR" || exit

# 3. Use sudo to obliterate old root-owned installations
sudo rm -rf "$PLUGIN_NAME"
sudo mkdir -p "$PLUGIN_NAME"
cd "$PLUGIN_NAME" || exit

# 4. Download directly
echo "Downloading latest release..."
sudo curl -L -o "$PLUGIN_NAME.zip" "$RELEASE_URL"

# 5. Extract using sudo and the -o flag (Force Overwrite to prevent prompt-eating)
echo "Extracting..."
sudo unzip -qo "$PLUGIN_NAME.zip"
sudo rm -f "$PLUGIN_NAME.zip"

# 6. Start Decky back up
echo "Restarting Decky Plugin Loader..."
sudo systemctl start plugin_loader < /dev/tty

echo "Installation complete! Return to GameMode and open the Quick Access Menu to get started."
