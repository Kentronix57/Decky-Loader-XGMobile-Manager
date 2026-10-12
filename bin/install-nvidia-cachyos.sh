#!/bin/bash
# NVIDIA driver installer for CachyOS. Installs the same packages as CachyOS's own chwd
# nvidia-open-dkms profile: the prebuilt kernel-matched module (<kernel>-nvidia-open) when the repo
# has one, nvidia-open-dkms + <kernel>-headers otherwise, plus the NVIDIA userspace.
# Unlike chwd, it leaves the initramfs modules alone: the eGPU is hot-plugged and egpu-enable
# loads the nvidia modules itself.
#
# No `set -e`: every step is checked, so each failure has its own exit code (see main.py):
#   2 not CachyOS | 3 pending updates or package not in the repo | 4 pacman -S failed
#   5 module not found after install | 9 xgm-common.sh missing | 10 already installed
# Never runs `pacman -Sy`: refreshing the database without upgrading is a partial upgrade.
LOG_DIR=$1
DATA_DIR=$2
ROOT="${XGM_ROOT:-}"
# pacman translates its field labels ("Versión"), and Decky inherits LANG from locale.conf.
export LC_ALL=C
# shellcheck source=bin/xgm-common.sh
. "$(dirname "$(readlink -f "$0")")/xgm-common.sh" || { echo "ERROR: xgm-common.sh is missing. Reinstall XG Mobile Manager."; exit 9; }

USERSPACE_PKGS=(nvidia-utils egl-wayland nvidia-settings opencl-nvidia lib32-opencl-nvidia lib32-nvidia-utils libva-nvidia-driver vulkan-icd-loader lib32-vulkan-icd-loader)
BLACKLIST_FILE="$ROOT/etc/modprobe.d/xgmobile-blacklist-nouveau.conf"

echo "--- XG Mobile Manager: CachyOS NVIDIA driver install ---"
echo "Log dir: $LOG_DIR | Data dir: $DATA_DIR"

if ! grep -qi "cachyos" $ROOT/etc/os-release; then
  echo "ERROR: Unsupported OS. This installer is for CachyOS only."
  exit 2
fi

# --- ALREADY INSTALLED? ---
# Known limitation: this only checks the running kernel, so other installed kernels without the
# module are ignored here (and the install isn't repeated for them).
NEED_MODULE=1
if modinfo nvidia >/dev/null 2>&1; then
  if pacman -Q nvidia-utils >/dev/null 2>&1; then
    VERSION=$(modinfo nvidia | grep "^version:" | awk '{print $2}')
    echo "ALREADY_INSTALLED NVIDIA Driver $VERSION is installed for the running kernel."
    exit 10
  fi
  echo "The NVIDIA kernel module is present, but nvidia-utils isn't installed. Installing the userspace only."
  NEED_MODULE=0
fi

# --- TARGET KERNELS ---
# Every installed kernel package leaves its pkgbase in its module directory.
# Known limitation: a leftover module directory from an old kernel that still has a pkgbase file
# is counted too, which can cause a false exit 5 or 10. Future fix: build KVERS
# from `pacman -Ql "$K"` instead of the directory names.
KERNELS=()
KVERS=()
for f in $ROOT/usr/lib/modules/*/pkgbase; do
  [ -f "$f" ] || continue
  K=$(head -n 1 "$f" | tr -d '[:space:]')
  [ -n "$K" ] || continue
  KERNELS+=("$K")
  KVERS+=("$(basename "$(dirname "$f")")")
done

if [ "${#KERNELS[@]}" -eq 0 ]; then
  echo "ERROR: No installed kernel found (no pkgbase file in any kernel module directory)."
  exit 3
fi
echo "Installed kernels: ${KERNELS[*]}"

pending_updates() {
  echo "ERROR: CachyOS has pending updates ($1)."
  echo "Run \`sudo pacman -Syu\`, reboot, then retry."
  exit 3
}

# --- NO PARTIAL UPGRADES ---
# The installed kernel must be the version the (unrefreshed) package database offers, or the
# module packages pacman picks won't match it.
for K in "${KERNELS[@]}"; do
  INSTALLED_VER=$(pacman -Q "$K" 2>/dev/null | awk '{print $2}')
  REPO_VER=$(pacman -Si "$K" 2>/dev/null | awk '/^Version/ {print $3; exit}')
  echo "Kernel $K: installed ${INSTALLED_VER:-none}, repo ${REPO_VER:-not found}"
  if [ -z "$REPO_VER" ]; then
    pending_updates "$K isn't in the package database, or the database is out of date"
  fi
  if [ "$INSTALLED_VER" != "$REPO_VER" ]; then
    pending_updates "$K $INSTALLED_VER is installed, the repo has $REPO_VER"
  fi
done

# --- PACKAGE SELECTION ---
MODULE_PKGS=()
add_module_pkg() {
  local p
  for p in "${MODULE_PKGS[@]}"; do
    [ "$p" = "$1" ] && return 0
  done
  MODULE_PKGS+=("$1")
}

if [ "$NEED_MODULE" -eq 1 ]; then
  for K in "${KERNELS[@]}"; do
    if pacman -Si "${K}-nvidia-open" >/dev/null 2>&1; then
      echo "Kernel $K: using the prebuilt ${K}-nvidia-open module."
      add_module_pkg "${K}-nvidia-open"
    else
      echo "Kernel $K: no prebuilt module in the repo, using nvidia-open-dkms with ${K}-headers."
      if ! pacman -Si "${K}-headers" >/dev/null 2>&1; then
        pending_updates "${K}-headers isn't in the package database"
      fi
      add_module_pkg nvidia-open-dkms
      add_module_pkg "${K}-headers"
    fi
  done
fi

# --- INSTALL ---
echo "Installing: ${MODULE_PKGS[*]} ${USERSPACE_PKGS[*]}"
pacman -S --needed --noconfirm "${MODULE_PKGS[@]}" "${USERSPACE_PKGS[@]}"
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "ERROR: pacman -S failed (exit $RC)."
  echo "Check pacman's error above. If the database is locked, another package manager is running; wait for it to finish and retry."
  exit 4
fi

# --- NOUVEAU ---
# nvidia-utils normally ships a nouveau blacklist. Only add one if nothing blacklists it yet.
if grep -rqsE '^[[:space:]]*blacklist[[:space:]]+nouveau([[:space:]]|$)' $ROOT/usr/lib/modprobe.d $ROOT/etc/modprobe.d; then
  echo "nouveau is already blacklisted."
else
  echo "Blacklisting nouveau..."
  mkdir -p $ROOT/etc/modprobe.d
  echo "blacklist nouveau" > "$BLACKLIST_FILE"
  echo "Rebuilding the initramfs..."
  if ! mkinitcpio -P; then
    echo "WARNING: mkinitcpio -P failed. nouveau may still load at boot until the initramfs is rebuilt."
  fi
fi

# --- VERIFY ---
if [ "$NEED_MODULE" -eq 1 ]; then
  for KVER in "${KVERS[@]}"; do
    if ! modinfo -k "$KVER" nvidia >/dev/null 2>&1; then
      echo "ERROR: The nvidia module wasn't found for kernel $KVER after the install."
      exit 5
    fi
    echo "Kernel $KVER: nvidia module OK."
  done
elif ! modinfo nvidia >/dev/null 2>&1; then
  echo "ERROR: The nvidia module wasn't found for the running kernel after the install."
  exit 5
fi

echo "SUCCESS: NVIDIA drivers installed. Reboot to finish."
exit 0
