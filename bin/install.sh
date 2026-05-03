#!/bin/bash

# Define variables
PLUGIN_NAME="xgmobile-manager"
RELEASE_URL="https://github.com/Kentronix57/Decky-Loader-XGMobile-Manager/releases/latest/download/xgmobile-manager.zip"
PLUGIN_DIR="$HOME/homebrew/plugins"

echo "Installing XG Mobile Manager..."

mkdir -p "$PLUGIN_DIR"
cd "$PLUGIN_DIR" || exit

rm -rf "$PLUGIN_NAME"

mkdir -p "$PLUGIN_NAME"
cd "$PLUGIN_NAME"

echo "Downloading latest release..."
curl -L -o "$PLUGIN_NAME.zip" "$RELEASE_URL"

echo "Extracting..."
unzip -q "$PLUGIN_NAME.zip" 
rm "$PLUGIN_NAME.zip"

# 4. Restart Decky to load the UI
echo "Restarting Decky Plugin Loader...(You may be prompted for your sudo password)"
sudo systemctl restart plugin_loader < /dev/tty

echo "Installation complete! Open the Quick Access Menu to get started."
