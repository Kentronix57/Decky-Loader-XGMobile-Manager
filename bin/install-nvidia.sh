#!/bin/bash

echo "Checking NVIDIA driver status..."

# Check if the kernel module is actually loadable
if modinfo nvidia >/dev/null 2>&1; then
  VERSION=$(modinfo nvidia | grep "^version:" | awk '{print $2}')
  echo "SUCCESS: NVIDIA Driver $VERSION is already installed and matched to the current kernel."
  exit 0
fi

# Exit immediately on error
set -e

echo "Drivers missing or mismatched. Starting repair..."

# --- CONFIGURATION ---
NV_VERSION="595.71.05-1"
REPO_ROOT=$(readlink -f "$(dirname "$(readlink -f "$0")")/..")
BASE_URL="https://archive.archlinux.org/packages"

# Package list for 595 setup
DKMS_URL="$BASE_URL/n/nvidia-open-dkms/nvidia-open-dkms-$NV_VERSION-x86_64.pkg.tar.zst"
UTILS_URL="$BASE_URL/n/nvidia-utils/nvidia-utils-$NV_VERSION-x86_64.pkg.tar.zst"
LIB32_URL="$BASE_URL/l/lib32-nvidia-utils/lib32-nvidia-utils-$NV_VERSION-x86_64.pkg.tar.zst"
WAYLAND2_URL="$BASE_URL/e/egl-wayland2/egl-wayland2-1.0.1-1-x86_64.pkg.tar.zst"
SETTINGS_URL="$BASE_URL/n/nvidia-settings/nvidia-settings-$NV_VERSION-x86_64.pkg.tar.zst"

# Detect Kernel Info
KVER_FULL=$(uname -r)
KVER_SHORT=$(echo $KVER_FULL | cut -d'.' -f1,2 | tr -d '.')
HEADER_PKG="linux-neptune-${KVER_SHORT}-headers"

ROOT_TARGETS=("/usr/lib/nvidia" "/usr/lib32/nvidia" "/usr/src" "/usr/lib/firmware/nvidia" "/usr/share/nvidia")
VAR_TARGETS=("/var/lib/dkms" "/var/cache/pacman/pkg")
ALL_TARGETS=("${ROOT_TARGETS[@]}" "${VAR_TARGETS[@]}")

# These are STRICTLY temporary catch-basins for the compiler bloat
BIND_TARGETS=("/usr/include" "/usr/lib/gcc" "/var/tmp")

# --- PRE-FLIGHT KERNEL CHECK ---
echo "Verifying Arch repository kernel headers..."
pacman -Sy >/dev/null 2>&1 || true
REPO_VER=$(pacman -Si "$HEADER_PKG" 2>/dev/null | grep "^Version" | awk '{print $3}')

KVER_BASE=$(echo "$KVER_FULL" | cut -d'-' -f1)
REPO_BASE=$(echo "$REPO_VER" | cut -d'.' -f1,2,3)

if [ "$KVER_BASE" != "$REPO_BASE" ]; then
  echo "ERROR: Kernel mismatch detected!"
  echo "Active Kernel: $KVER_FULL"
  echo "Repository Headers: $REPO_VER"
  echo "Please update SteamOS via Gaming Mode and reboot before installing."
  exit 1
fi
echo "Kernel check passed: $KVER_BASE"

echo "--- STARTING NVIDIA eGPU UPDATER/INSTALLER (Target: $NV_VERSION) ---"

# UNLOCK SYSTEM
echo "[1/9] Unlocking SteamOS file system and setting a trap to re-enable on exit..."
steamos-readonly disable || echo "Already unlocked."

cleanup_on_exit() {
  EXIT_CODE=$?

  # ALWAYS UNMOUNT FIRST (Critical to protect /home data during a crash)
  echo "Ensuring all target mounts are detached..."
  for T in "${ALL_TARGETS[@]}" "${BIND_TARGETS[@]}"; do
    umount -l "$T" 2>/dev/null || true
  done

  # ONLY restore native environment if the script FAILED
  if [ $EXIT_CODE -ne 0 ]; then
    echo "INSTALL FAILED (Code: $EXIT_CODE). Rolling back to prevent boot hang..."
        
    yes | pacman -Scc 2>/dev/null || true
    rm -rf /home/deck/xgmobile_manager/system/var/cache/pacman/pkg/* 2>/dev/null

    # PRESERVE LOGS FIRST
    if [ -d "/home/deck/xgmobile_manager/system/var/lib/dkms" ]; then
      echo "Saving failed compiler logs to /home/deck/xgmobile_manager/logs/..."
      mkdir -p /home/deck/xgmobile_manager/logs/
      mv /home/deck/xgmobile_manager/system/var/lib/dkms/nvidia* /home/deck/xgmobile_manager/logs/ 2>/dev/null || true
    fi

    # DYNAMIC SMART RESTORE
    for T in "${ALL_TARGETS[@]}"; do
      
      # SAFEGUARD: ONLY execute the restore if the target is currently a symlink
      if [ -L "$T" ]; then
        echo "Reverting symlink for $T..."
        rm -f "$T"          # Safely remove the symlink pointer
        mkdir -p "$T"       # Recreate the empty native directory
        
        # If we have backup data, copy it back to root
        if [ -d "/home/deck/xgmobile_manager/system$T" ]; then
          # Sweep out half-installed NVIDIA junk so we only restore pure SteamOS files
          rm -rf "/home/deck/xgmobile_manager/system$T/nvidia*" 2>/dev/null || true
          cp -a "/home/deck/xgmobile_manager/system$T/." "$T/" 2>/dev/null
        fi
        
      elif [ -d "$T" ]; then
        # SAFEGUARD: The target is a real directory, NOT a symlink. 
        echo "Target $T is already native. Skipping to prevent data loss."
        
      else
        # EDGE CASE: The target is completely missing. Restore it from backup.
        echo "Target $T is missing! Attempting emergency restore..."
        mkdir -p "$T"
        if [ -d "/home/deck/xgmobile_manager/system$T" ]; then
          cp -a "/home/deck/xgmobile_manager/system$T/." "$T/" 2>/dev/null
        fi
      fi
      
    done
  fi

  echo "Restoring Steam recovery image..."
  if [ -f /home/deck/xgmobile_manager/recovery/bootstraplinux_ubuntu12_32.tar.xz ]; then
    mv /home/deck/xgmobile_manager/recovery/bootstraplinux_ubuntu12_32.tar.xz /usr/lib/steam/ 2>/dev/null || true
  fi

  echo "Purging temporary build tools to recover 390 MiB of Rootfs space..."
  yes | pacman -Rdd base-devel gcc make autoconf automake bison flex m4 patch pkgconf 2>/dev/null || true
  
  steamos-readonly enable
}
trap cleanup_on_exit EXIT SIGINT SIGTERM

# PRE-FLIGHT CHECKS
echo "[2/9] Verifying system health..."

echo "Deploying Universal Bind Mounts and preserving existing system files..."
for T in "${ALL_TARGETS[@]}" "${BIND_TARGETS[@]}"; do
  mkdir -p "/home/deck/xgmobile_manager/system$T"
    
  if [ -d "$T" ] && [ ! -L "$T" ]; then
    cp -a "$T/." "/home/deck/xgmobile_manager/system$T/" 2>/dev/null || true
  fi
    
  mkdir -p "$T" 2>/dev/null || true
  [ -L "$T" ] && rm -f "$T"
    
  mount --bind "/home/deck/xgmobile_manager/system$T" "$T"
done

echo "Purging SteamOS update cache to free root space..."
rm -rf /var/lib/steamos-atomupd/*
rm -rf /var/cache/pacman/pkg/*

echo "Relocating Steam recovery boot image..."
mkdir -p /home/deck/xgmobile_manager/recovery
[ -f /usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz ] && mv /usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz /home/deck/xgmobile_manager/recovery/

# Get available space on root in Kilobytes
ROOT_FREE_KIB=$(df / --output=avail | tail -1 | tr -dc '0-9')
HOME_FREE_KIB=$(df /home --output=avail | tail -1 | tr -dc '0-9')
MIN_HOME_KIB=4194304 #4GB

MIN_ROOT_KIB=512000 # 500 MiB #614400 # 600 MiB
if [ "$ROOT_FREE_KIB" -lt "$MIN_ROOT_KIB" ]; then
  echo "ERROR: Rootfs (/) is too full. You have $(($ROOT_FREE_KIB / 1024)) MiB, but require at least 800 MiB."
  exit 1
fi
if [ "$HOME_FREE_KIB" -lt "$MIN_HOME_KIB" ]; then
  echo "ERROR: Not enough space on /home partition."
  echo "You have $(($HOME_FREE_KIB / 4096)) MiB, but this install requires 4096 MiB."
  exit 1
fi

echo "Initial space check: $(($HOME_FREE_KIB / 4096)) MiB available on /home."
echo "Initial space check: $(($ROOT_FREE_KIB / 2048)) MiB available on /."

# INSTALL SYSTEM TOOLS & HEADERS
echo "[3/9] Signing pacman-keys and syncing system dependencies (Headers: $HEADER_PKG)..."
pacman-key --init
pacman-key --populate archlinux holo
yes | pacman -Sy --needed --overwrite "/usr/src,/usr/src/*,/var/lib/dkms,/var/lib/dkms/*" "$HEADER_PKG" base-devel dkms curl

# ACQUIRE SOURCES
echo "[4/9] Downloading packages..."
PKGS_TO_INSTALL=()
TEMP_DIR=$(mktemp -d)

# Function to download if not in repo
fetch_pkg() {
  local name=$1
  local url=$2
  local dest="$TEMP_DIR/$name.pkg.tar.zst"
  echo "Downloading $name..."
  curl -L --fail "$url" -o "$dest"
  PKGS_TO_INSTALL+=("$dest")
}

# Main Driver components
fetch_pkg "lib32-utils" "$LIB32_URL"
fetch_pkg "dkms" "$DKMS_URL"
fetch_pkg "utils" "$UTILS_URL"
fetch_pkg "wayland" "$WAYLAND2_URL"
fetch_pkg "settings" "$SETTINGS_URL"

# ATOMIC INSTALL
echo "[5/9] Running atomic installation..."

# Temporarily disable the pessimistic check
sed -i 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf
yes | pacman -U \
  --overwrite "/usr/lib/nvidia*,/usr/lib32/nvidia*,/usr/share/nvidia*,/usr/include/nvidia*,/usr/lib/firmware/nvidia*,/usr/src/*,/var/lib/dkms*,/var/cache/pacman/pkg*" \
  "${PKGS_TO_INSTALL[@]}"
sed -i 's/#CheckSpace/CheckSpace/' /etc/pacman.conf

# KERNEL PATCHING (Conditional)
if [[ $(echo -e "${NV_VERSION%-*}\n580.00" | sort -V | head -n1) == "${NV_VERSION%-*}" ]]; then
  echo "[6/9] Applying legacy kernel patch..."
  SOURCE_DIR="/usr/src/nvidia-${NV_VERSION%-*}"
  PATCH_FILE="$REPO_ROOT/assets/patches/egpu-kernel-fix.patch"
  if [ -d "$SOURCE_DIR" ] && [ -f "$PATCH_FILE" ]; then
    if ! grep -q "vmf_insert_pfn" "$SOURCE_DIR/kernel-open/nvidia-drm/nvidia-drm-gem-user-memory.c"; then
      patch -p1 -d "$SOURCE_DIR" < "$PATCH_FILE"
      echo "Patch applied successfully."
    else
      echo "Source already patched. Skipping."
    fi
  else
    echo "ERROR: NVIDIA source not found at $SOURCE_DIR or patch missing."
  fi
else
  echo "[6/9] Skipping patch: $NV_VERSION is modern-kernel ready."
fi

# REBUILD DRIVER
echo "[7/9] Building DKMS modules for $KVER_FULL (This will take a moment)..."

dkms remove nvidia/"${NV_VERSION%-*}" --all >/dev/null 2>&1 || true
dkms install nvidia/"${NV_VERSION%-*}"

# INJECT CONFIGURATIONS
echo "[8/9] Applying modprobe and environment configs..."
safe_append() {
  local file=$1
  local line=$2
  grep -qF "$line" "$file" || echo "$line" | tee -a "$file"
}

mkdir -p /etc/modprobe.d
safe_append "/etc/modprobe.d/nvidia.conf" "options nvidia NVreg_RegistryDwords=\"PowerMizerEnable=0x1; PerfStrategy=0x1; PowerMizerDefaultAC=0x1\""
safe_append "/etc/modprobe.d/nvidia.conf" "options nvidia NVreg_PreserveVideoMemoryAllocations=1"
safe_append "/etc/modprobe.d/nvidia.conf" "options nvidia NVreg_TemporaryFilePath=/var/tmp"

echo "Rebuilding initramfs..."
mkinitcpio -P || true

# SETUP SERVICES & SYMLINKS
echo "[9/9] Restoring services and terminal commands..."
ln -sf "$REPO_ROOT/bin/egpu-enable" /usr/local/bin/egpu-enable
ln -sf "$REPO_ROOT/bin/egpu-eject" /usr/local/bin/egpu-eject
ln -sf "$REPO_ROOT/bin/egpu-resume-fix" /usr/lib/systemd/system-sleep/egpu-resume-fix
chmod +x "$REPO_ROOT/bin/egpu-enable"
chmod +x "$REPO_ROOT/bin/egpu-eject"
chmod +x "$REPO_ROOT/bin/egpu-resume-fix"
cp "$REPO_ROOT/assets/services/"*.service /etc/systemd/system/ 2>/dev/null || true
systemctl daemon-reload
systemctl enable nvidia-persistenced nvidia-powerd nvidia-suspend.service nvidia-hibernate.service nvidia-resume.service|| true
systemctl daemon-reload

# DE-FANG & CLEANUP 
echo "[10/10] Securing the installation..."

echo "De-fanging NVIDIA configs to protect AMD Handheld Mode..."
mkdir -p /home/deck/xgmobile_configs_backup
mv /usr/share/glvnd/egl_vendor.d/*nvidia* /home/deck/xgmobile_configs_backup/ 2>/dev/null || true
mv /usr/share/vulkan/implicit_layer.d/*nvidia* /home/deck/xgmobile_configs_backup/ 2>/dev/null || true
mv /usr/share/vulkan/explicit_layer.d/*nvidia* /home/deck/xgmobile_configs_backup/ 2>/dev/null || true
mv /usr/share/vulkan/icd.d/*nvidia* /home/deck/xgmobile_configs_backup/ 2>/dev/null || true
mv /usr/share/X11/xorg.conf.d/10-nvidia* /home/deck/xgmobile_configs_backup/ 2>/dev/null || true

echo "Purging temporary build tools..."
yes | pacman -Rdd base-devel gcc make autoconf automake bison flex m4 patch pkgconf 2>/dev/null || true
yes | pacman -Scc 2>/dev/null || true

echo "Converting Bind Mounts to Permanent Symlinks..."
# Unmount everything FIRST
for T in "${ALL_TARGETS[@]}" "${BIND_TARGETS[@]}"; do
  umount -l "$T" 2>/dev/null || true
done

# Lock ONLY the permanent targets to /home
for T in "${ALL_TARGETS[@]}"; do
  rm -rf "$T" 2>/dev/null # Delete the empty mount point
  ln -sf "/home/deck/xgmobile_manager/system$T" "$T"
done

echo "Re-locking SteamOS file system..."

# FINALIZING
echo "Repair/Install complete."
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "--- PLEASE REBOOT TO ACTIVATE NVIDIA DRIVER $NV_VERSION ---"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
