#!/bin/bash
set -e
# 1. Cleanup old builds
echo "Cleaning up old builds..."
rm -rf dist
rm -rf deploy_staging
rm -f xgmobile-manager.zip

# 2. Build the Frontend (React)
echo "Building React frontend..."
pnpm install
pnpm run build

# 3. Create a temporary staging directory
echo "Staging files for release..."
mkdir -p deploy_staging
mkdir -p deploy_staging/dist
mkdir -p deploy_staging/bin
mkdir -p deploy_staging/assets/services

# 4. Copy the essential files
# We exclude things like node_modules, .git, and src to keep the zip small
cp -r dist deploy_staging/
cp -r bin deploy_staging/
cp -r assets/services/ deploy_staging/assets/
cp decky.pyi deploy_staging/
cp main.py deploy_staging/
cp plugin.json deploy_staging/
cp package.json deploy_staging/

# 5. FIX PERMISSIONS
# This is the most important part for the Ally!
echo "Setting executable permissions for scripts..."
chmod +x deploy_staging/bin/*

# 6. Create the Zip
echo "Packaging into xgmobile-manager.zip..."
cd deploy_staging
zip -r ../xgmobile-manager.zip .
cd ..

# 7. Cleanup staging
rm -rf deploy_staging

echo "----------------------------------------"
echo "Build Complete: xgmobile-manager.zip"
echo "----------------------------------------"
