# shellcheck shell=bash
# Fake GPUs in the sandbox sysfs, laid out like the real thing: a PCI device dir under
# sys/devices (class 0x030000), a sys/bus/pci/devices/<address> symlink to it,
# sys/class/drm/<cardN|renderDN>/device and sys/class/graphics/fbN/device symlinks to it, and the
# /dev/dri and /dev/fbN nodes. Sourced by helpers/sandbox.bash and shims/sleep;
# needs $ROOT.

# The PCI dirs of the two GPUs. The addresses are the Ally's (iGPU) and the XG Mobile's (eGPU).
FAKE_IGPU_PCI_ADDR="0000:08:00.0"
FAKE_EGPU_PCI_ADDR="0000:01:00.0"
fake_gpu_pci_dir() {
  case "$1" in
    "$FAKE_IGPU_PCI_ADDR") echo "$ROOT/sys/devices/pci0000:00/0000:00:08.1/$1" ;;
    *) echo "$ROOT/sys/devices/pci0000:00/0000:00:01.1/$1" ;;
  esac
}

# fake_gpu_add <pci address> <vendor> <boot_vga> <cardN> <renderDN> [fbN]
fake_gpu_add() {
  local pci node
  pci=$(fake_gpu_pci_dir "$1")
  mkdir -p "$pci/drm/$4" "$pci/drm/$5" "$ROOT/sys/bus/pci/devices" "$ROOT/dev/dri"
  echo "$2" > "$pci/vendor"
  echo "0x030000" > "$pci/class"
  echo "$3" > "$pci/boot_vga"
  if [ -n "${6:-}" ]; then
    mkdir -p "$ROOT/sys/class/graphics/$6"
    ln -sfn "$pci" "$ROOT/sys/class/graphics/$6/device"
    touch "$ROOT/dev/$6"
  fi
  ln -sfn "$pci" "$ROOT/sys/bus/pci/devices/$1"
  for node in "$4" "$5"; do
    mkdir -p "$ROOT/sys/class/drm/$node"
    ln -sfn "$pci" "$ROOT/sys/class/drm/$node/device"
    touch "$ROOT/dev/dri/$node"
  done
}

# fake_gpu_remove <pci address>: the device, its class entries and its /dev/dri nodes go away.
fake_gpu_remove() {
  local pci entry
  pci=$(fake_gpu_pci_dir "$1")
  for entry in "$ROOT"/sys/class/drm/*; do
    [ -L "$entry/device" ] || continue
    if [ "$(readlink "$entry/device")" = "$pci" ]; then
      rm -rf "$entry" "$ROOT/dev/dri/${entry##*/}"
    fi
  done
  for entry in "$ROOT"/sys/class/graphics/*; do
    [ -L "$entry/device" ] || continue
    if [ "$(readlink "$entry/device")" = "$pci" ]; then
      rm -rf "$entry" "$ROOT/dev/${entry##*/}"
    fi
  done
  rm -rf "$pci" "$ROOT/sys/bus/pci/devices/$1"
}
