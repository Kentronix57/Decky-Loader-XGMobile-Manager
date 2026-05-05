#!/bin/bash
echo "--- SURGICAL XG MOBILE UNINSTALLER ---"
steamos-readonly disable

# Check if the OS is Bazzite
if grep -qi "bazzite" /etc/os-release; then
    echo "ERROR: BazziteOS detected. This plugin's driver installation is built for SteamOS (Arch)."
    echo "Bazzite natively handles the XG Mobile via supergfxctl. No need to reset driver environment."
    exit 1
fi

DATA_DIR="$HOME/homebrew/data/xgmobile-manager"
LOG_DIR="$HOME/homebrew/logs"
mkdir -p "$DATA_DIR/configs"

# Detect Kernel Info dynamically
KVER_FULL=$(uname -r)
KVER_SHORT=$(echo $KVER_FULL | cut -d'.' -f1,2 | tr -d '.')
HEADER_PKG="linux-neptune-${KVER_SHORT}-headers"

# Target Arrays
ROOT_TARGETS=("/usr/lib/nvidia" "/usr/lib32/nvidia" "/usr/src" "/usr/lib/firmware/nvidia" "/usr/share/nvidia")
VAR_TARGETS=("/var/lib/dkms" "/var/cache/pacman/pkg")
ALL_TARGETS=("${ROOT_TARGETS[@]}" "${VAR_TARGETS[@]}")
BIND_TARGETS=("/usr/include" "/usr/lib/gcc" "/var/tmp")

echo "Ensuring all temporary bind mounts are detached..."
for B in "${BIND_TARGETS[@]}"; do
  umount -l "$B" 2>/dev/null || true
done

echo "Removing drivers and build dependencies safely..."
yes | pacman -Rn \
  nvidia-open-dkms nvidia-utils lib32-nvidia-utils nvidia-settings \
  dkms "$HEADER_PKG" \
  2>/dev/null || true

echo "Purging orphaned kernel modules..."
rm -f /usr/lib/modules/$(uname -r)/updates/dkms/nvidia*.ko* 2>/dev/null || true
depmod -a

echo "Purging NVIDIA system services..."
systemctl disable nvidia- nvidia-powerd nvidia-suspend nvidia-hibernate nvidia-resume 2>/dev/null || true
rm -f /etc/systemd/system/nvidia-*
systemctl daemon-reload

echo "Reverting native SteamOS directory structures..."
for T in "${ALL_TARGETS[@]}"; do
  # Only act if the target is currently a symlink
  if [ -L "$T" ]; then
    echo "Restoring native folder: $T"
    rm -f "$T"          # Remove the symlink
    mkdir -p "$T"       # Recreate the empty native directory
  fi
done

# Clean up Steam update redirects
if [ -L "/usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz" ]; then
  rm -f "/usr/lib/steam/bootstraplinux_ubuntu12_32.tar.xz"
fi

echo "Cleaning up X11, Vulkan, and EGL ghosts..."
rm -f /etc/X11/xorg.conf.d/*nvidia*
rm -f /usr/share/X11/xorg.conf.d/10-nvidia*
rm -f /usr/share/glvnd/egl_vendor.d/*nvidia*
rm -f /usr/share/vulkan/implicit_layer.d/*nvidia*
rm -f /usr/share/vulkan/explicit_layer.d/*nvidia*
rm -f /usr/share/vulkan/icd.d/*nvidia*

echo "Cleaning up temporary compiler bloat from /home..."
for B in "${BIND_TARGETS[@]}"; do
    rm -rf "$DATA_DIR/system$B" 2>/dev/null || true
done

echo "Sanitizing global environment variables..."
rm -f /etc/modprobe.d/nvidia.conf
rm -f /etc/modules-load.d/nvidia.conf
rm -f /etc/ld.so.conf.d/nvidia.conf
[ -f /etc/ld.so.preload ] && sed -i '/nvidia/d' /etc/ld.so.preload
[ -f /etc/environment ] && sed -i '/__NV_PRIME_RENDER_OFFLOAD/d' /etc/environment
[ -f /etc/environment ] && sed -i '/__GLX_VENDOR_LIBRARY_NAME/d' /etc/environment

echo "Resetting hardware flags and UI session locks..."
echo 0 > /sys/devices/platform/asus-nb-wmi/egpu_enable 2>/dev/null || true
rm -f /home/deck/.config/gamescope/edid.bin
rm -f /tmp/.X*lock

#if systemctl list-unit-files | grep -q all-ways-egpu; then
#  echo "Detected all-ways-egpu. Disabling to ensure safe boot..."
#  systemctl disable all-ways-egpu 2>/dev/null || true
#fi

echo "Refreshing library cache and rebuilding boot image..."
ldconfig
mkinitcpio -P
steamos-readonly enable
echo "--- Uninstall Complete. Safe to Reboot. ---"
