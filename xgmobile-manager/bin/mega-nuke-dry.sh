#!/bin/bash
echo "--- TOTAL SYSTEM RESTORATION ---"
steamos-readonly disable

# Target Arrays
ROOT_TARGETS=("/usr/lib/nvidia" "/usr/lib32/nvidia" "/usr/src" "/usr/lib/firmware/nvidia" "/usr/share/nvidia")
VAR_TARGETS=("/var/lib/dkms" "/var/cache/pacman/pkg")
ALL_TARGETS=("${ROOT_TARGETS[@]}" "${VAR_TARGETS[@]}")
BIND_TARGETS=("/usr/include" "/usr/lib/gcc" "/var/tmp")

echo "Ensuring all temporary bind mounts are detached..."
for B in "${BIND_TARGETS[@]}"; do
  umount -l "$B" 2>/dev/null || true
done

echo "Removing drivers and build dependencies..."
#yes | pacman -R \
#  nvidia-open-dkms nvidia-utils lib32-nvidia-utils nvidia-settings \
#  base-devel dkms linux-neptune-618-headers \
#  autoconf automake bison debugedit fakeroot flex gcc groff libisl libmpc m4 make pahole patch pkgconf texinfo \
#  2>/dev/null || true
echo "DRY RUN: Would have uninstalled NVIDIA packages and base-devel here."

echo "Purging NVIDIA system services..."
systemctl disable nvidia- nvidia-powerd nvidia-suspend nvidia-hibernate nvidia-resume 2>/dev/null || true
rm -f /etc/systemd/system/nvidia-*
systemctl daemon-reload

echo "Purging scattered NVIDIA binaries..."
#rm -rf /usr/lib/libnvidia-*
#rm -rf /usr/lib32/libnvidia-*
#rm -rf /usr/lib/vdpau/libvdpau_nvidia*
#rm -rf /usr/lib/modules/$(uname -r)/updates/dkms/nvidia* 2>/dev/null || true
echo "DRY RUN: Would delete /usr/lib/libnvidia-*"
echo "DRY RUN: Would delete /usr/lib32/libnvidia-*"
echo "DRY RUN: Would delete /usr/lib/vdpau/libvdpau_nvidia*"
echo "DRY RUN: Would delete /usr/lib/modules/$(uname -r)/updates/dkms/nvidia*"
depmod -a

# --- THE SMART RESTORE LOGIC ---
echo "Checking space to safely restore native SteamOS folders..."

# Calculate space of the backed up native files (in KB)
TOTAL_ROOT_NEEDED_KB=0
for T in "${ROOT_TARGETS[@]}"; do
  if [ -d "/home/deck/xgmobile_manager/system$T" ]; then
    DIR_KB=$(du -sk "/home/deck/xgmobile_manager/system$T" 2>/dev/null | awk '{print $1}')
    TOTAL_ROOT_NEEDED_KB=$((TOTAL_ROOT_NEEDED_KB + ${DIR_KB:-0}))
  fi
done
TOTAL_VAR_NEEDED_KB=0
for T in "${VAR_TARGETS[@]}"; do
  if [ -d "/home/deck/xgmobile_manager/system$T" ]; then
    DIR_KB=$(du -sk "/home/deck/xgmobile_manager/system$T" 2>/dev/null | awk '{print $1}')
    TOTAL_VAR_NEEDED_KB=$((TOTAL_VAR_NEEDED_KB + ${DIR_KB:-0}))
  fi
done
# Check available space on Root and Var
ROOT_FREE_KB=$(df / --output=avail | tail -1 | tr -dc '0-9')
VAR_FREE_KB=$(df /var --output=avail | tail -1 | tr -dc '0-9')

if [ "$ROOT_FREE_KB" -gt "$TOTAL_ROOT_NEEDED_KB" ] && [ "$VAR_FREE_KB" -gt "$TOTAL_VAR_NEEDED_KB" ]; then
  echo "Space check passed. Restoring native file structures..."
    
  # Clean cache first
  #yes | pacman -Scc 2>/dev/null || true
  echo "DRY RUN: Would have purged the pacman cache here."
    
  # 2. DYNAMIC SMART RESTORE
  for T in "${ALL_TARGETS[@]}"; do
      
    # SAFEGUARD: ONLY execute the restore if the target is currently a symlink
    if [ -L "$T" ]; then
      echo "Reverting symlink for $T..."
      #rm -f "$T"          # Safely remove the symlink pointer
      #mkdir -p "$T"       # Recreate the empty native directory
      echo "DRY RUN: Would have removed symlink $T and recreated directory."

      # If we have backup data, copy it back to root
      if [ -d "/home/deck/xgmobile_manager/system$T" ]; then
        # Sweep out half-installed NVIDIA junk so we only restore pure SteamOS files
        #rm -rf "/home/deck/xgmobile_manager/system$T/nvidia*" 2>/dev/null || true
        #cp -a "/home/deck/xgmobile_manager/system$T/." "$T/" 2>/dev/null
        echo "DRY RUN: Would have copied native files from backup to $T/"
      fi
        
    elif [ -d "$T" ]; then
      # SAFEGUARD: The target is a real directory, NOT a symlink. 
      echo "Target $T is already native. Skipping to prevent data loss."
        
    else
      # EDGE CASE: The target is completely missing. Restore it from backup.
      echo "Target $T is missing! Attempting emergency restore..."
      #mkdir -p "$T"
      if [ -d "/home/deck/xgmobile_manager/system$T" ]; then
        #cp -a "/home/deck/xgmobile_manager/system$T/." "$T/" 2>/dev/null
        echo "DRY RUN: Would have attempted emergency restore to $T"
      fi
    fi
      
  done

  echo "Native files restored successfully."
else
  echo "--------------------------------------------------------"
  echo "WARNING: Insufficient space on Root/Var to move native folders back."
  echo "Leaving symlinks to /home intact to prevent system crash."
  echo "--------------------------------------------------------"
fi

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
#rm -rf /home/deck/xgmobile_configs_backup/*
echo "DRY RUN: Would have permanently deleted all files in /home/deck/xgmobile_configs_backup/"

echo "Cleaning up temporary compiler bloat from /home..."
for B in "${BIND_TARGETS[@]}"; do
    rm -rf "/home/deck/xgmobile_manager/system$B" 2>/dev/null || true
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

if systemctl list-unit-files | grep -q all-ways-egpu; then
  echo "Detected all-ways-egpu. Disabling to ensure safe boot..."
  systemctl disable all-ways-egpu 2>/dev/null || true
fi

echo "Refreshing library cache and rebuilding boot image..."
ldconfig
mkinitcpio -P
steamos-readonly enable
echo "--- System is back to baseline. ---"
