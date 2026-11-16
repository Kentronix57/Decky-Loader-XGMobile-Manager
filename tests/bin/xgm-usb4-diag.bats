#!/usr/bin/env bats
# bin/xgm-usb4-diag: the read-only USB4 / Thunderbolt diagnostics snapshot (issues #15, #16).
# Fixtures: (a) an ASUS Ally with the XG Mobile connector nodes and the eGPU enabled, (b) a USB4
# host (no asus-nb-wmi) with a Thunderbolt domain, an authorized dock and an NVIDIA GPU behind
# its bridges, (c) the same host with the dock present but not authorized, and no GPU.

setup_file() {
  load helpers/sandbox
  xgm_setup_file
}

setup() {
  load helpers/sandbox
  make_root
}

DIAG_LOG_NAME=usb4_diagnostics.log

# The identifiers the fixtures plant; none may reach the log.
SECRET_UUID="5b2f7c1e-8a3d-4f6b-9e0a-1c2d3e4f5a6b"
SECRET_TB_UID="d9a1c3e5-0000-0000-1111-223344556677"
SECRET_GPU_UUID="GPU-3f1c2a7e-9b4d-4e21-8c3a-5d6e7f809a1b"
SECRET_DSN="12-34-56-78-9a-bc-de-f0"
SECRET_MAC="02:1a:2b:3c:4d:5e"
SECRET_HOST="alices-legion"
SECRET_USER="alicesmith"
SECRET_DMI_SERIAL="PF5SECRET1"

diag() { run_script xgm-usb4-diag --log-dir "$LOG_DIR" "$@"; }
diag_log() { cat "$LOG_DIR/$DIAG_LOG_NAME"; }

# fake_pci <path under sys/devices> <class> <vendor> <device> [driver]: a PCI device dir (its
# parents are its upstream bridges), the sys/bus/pci/devices link and the driver link.
fake_pci() {
  local dir="$ROOT/sys/devices/$1" addr
  addr=$(basename "$1")
  mkdir -p "$dir" "$ROOT/sys/bus/pci/devices"
  echo "$2" > "$dir/class"
  echo "$3" > "$dir/vendor"
  echo "$4" > "$dir/device"
  if [ -n "${5:-}" ]; then
    mkdir -p "$ROOT/sys/bus/pci/drivers/$5"
    ln -sfn "$ROOT/sys/bus/pci/drivers/$5" "$dir/driver"
  fi
  ln -sfn "$dir" "$ROOT/sys/bus/pci/devices/$addr"
}

# tb_dev <name> <attr=value>...: a /sys/bus/thunderbolt/devices entry.
tb_dev() {
  local d="$ROOT/sys/bus/thunderbolt/devices/$1" kv
  shift
  mkdir -p "$d"
  for kv in "$@"; do echo "${kv#*=}" > "$d/${kv%%=*}"; done
}

# Parts shared by the fixtures: a kernel config, /proc/modules, the boot id and DMI serials.
common_proc() {
  mkdir -p "$ROOT/proc/sys/kernel/random"
  echo "0123abcd-1111-2222-3333-444455556666" > "$ROOT/proc/sys/kernel/random/boot_id"
  echo "BOOT_IMAGE=/vmlinuz root=UUID=$SECRET_UUID rw quiet" > "$ROOT/proc/cmdline"
  echo "$SECRET_DMI_SERIAL" > "$ROOT/sys/class/dmi/id/product_serial"
  echo "$SECRET_DMI_SERIAL" > "$ROOT/sys/class/dmi/id/board_serial"
  echo "$SECRET_DMI_SERIAL" > "$ROOT/sys/class/dmi/id/chassis_serial"
  echo "$SECRET_UUID" > "$ROOT/sys/class/dmi/id/product_uuid"
}

# (a) ASUS Ally + XG Mobile (connector): asus-nb-wmi with the eGPU nodes, the eGPU enabled.
fixture_ally() {
  common_proc
  set_product "ROG Ally RC71L_RC71L"
  echo "ASUSTeK COMPUTER INC." > "$ROOT/sys/class/dmi/id/sys_vendor"
  egpu_present nvidia
  printf '%s\n' "asus_wmi 98304 1 asus_nb_wmi, Live 0xffffffffc1000000" \
    "asus_nb_wmi 32768 0 - Live 0xffffffffc1100000" "nvidia 9000000 40 nvidia_drm, Live 0xffffffffc2000000" \
    "nvidia_drm 131072 12 - Live 0xffffffffc2100000" "amdgpu 15000000 30 - Live 0xffffffffc3000000" > "$ROOT/proc/modules"
  # No /proc/config.gz here: the config comes from /boot.
  mkdir -p "$ROOT/boot"
  printf '%s\n' "CONFIG_USB4=m" "CONFIG_HOTPLUG_PCI_PCIE=y" "CONFIG_HOTPLUG_PCI=y" > "$ROOT/boot/config-$(cat "$SHIM_STATE/uname" 2>/dev/null || echo 6.11.11-valve12-1-neptune-611-gb3afa9aa9ae7)"
  printf '%s\n' "[    1.000000] amdgpu 0000:08:00.0: amdgpu: SMU is initialized" \
    "[   12.500000] NVRM: loading NVIDIA UNIX Open Kernel Module for x86_64  620.70.06" > "$SHIM_STATE/dmesg"
}

# (b) USB4 host (a Legion Go 2): no asus-nb-wmi, a Thunderbolt domain with an authorized dock,
# and an NVIDIA GPU behind the dock's PCIe bridges. With "unauthorized": (c), the dock is there
# but not authorized, so no tunnel and no GPU.
fixture_usb4() {
  local auth=1
  [ "${1:-}" = "unauthorized" ] && auth=0
  common_proc
  rm -rf "$ROOT/sys/devices/platform/asus-nb-wmi"
  set_product "83N0"
  echo "LENOVO" > "$ROOT/sys/class/dmi/id/sys_vendor"
  echo "Legion Go 2 8ASP2" > "$ROOT/sys/class/dmi/id/product_family"
  echo "LNVNB161216" > "$ROOT/sys/class/dmi/id/board_name"
  echo "QCCN17WW" > "$ROOT/sys/class/dmi/id/bios_version"
  echo "$SECRET_HOST" > "$ROOT/etc/hostname"
  set_hostname "$SECRET_HOST"

  printf '%s\n' "thunderbolt 516096 0 - Live 0xffffffffc0a00000" "typec 110592 1 ucsi_acpi, Live 0xffffffffc0b00000" \
    "ucsi_acpi 12288 0 - Live 0xffffffffc0c00000" "amdgpu 15000000 30 - Live 0xffffffffc3000000" > "$ROOT/proc/modules"
  printf '%s\n' "CONFIG_USB4=y" "CONFIG_HOTPLUG_PCI_PCIE=y" "CONFIG_HOTPLUG_PCI=y" "# CONFIG_THUNDERBOLT_NET is not set" "CONFIG_DRM=y" \
    | gzip -c > "$ROOT/proc/config.gz"

  tb_dev domain0 security=user iommu_dma_protection=1 deauthorization=1
  tb_dev 0-0 vendor_name=AMD device_name="USB4 host" vendor=0x1022 device=0x1668 generation=4 unique_id="$SECRET_TB_UID"
  tb_dev 0-1 authorized=$auth vendor_name="ASUSTeK Computer Inc." device_name="ROG XG Mobile" vendor=0x1043 device=0x1a1 \
    generation=4 rx_speed="40.0 Gb/s" rx_lanes=2 tx_speed="40.0 Gb/s" tx_lanes=2 boot=0 unique_id="$SECRET_TB_UID"

  # The USB4 host interface, and the dock's bridges.
  fake_pci pci0000:00/0000:00:08.3/0000:c6:00.5 0x0c0340 0x1022 0x1668 thunderbolt
  fake_pci pci0000:00/0000:00:03.1 0x060400 0x1022 0x14ef pcieport
  if [ "$auth" = 1 ]; then
    fake_pci pci0000:00/0000:00:03.1/0000:62:00.0 0x060400 0x8086 0x5786 pcieport
    fake_pci pci0000:00/0000:00:03.1/0000:62:00.0/0000:63:01.0 0x060400 0x8086 0x5786 pcieport
    fake_pci pci0000:00/0000:00:03.1/0000:62:00.0/0000:63:01.0/0000:64:00.0 0x030000 0x10de 0x2c18 nvidia
    local gpu="$ROOT/sys/devices/pci0000:00/0000:00:03.1/0000:62:00.0/0000:63:01.0/0000:64:00.0"
    echo 0 > "$gpu/boot_vga"
    mkdir -p "$ROOT/sys/class/drm/card1" "$ROOT/sys/module/nvidia" "$ROOT/proc/driver/nvidia/gpus/0000:64:00.0"
    ln -sfn "$gpu" "$ROOT/sys/class/drm/card1/device"
    touch "$ROOT/dev/dri/card1"
    echo "620.70.06" > "$ROOT/sys/module/nvidia/version"
    printf '%s\n' "Model:           NVIDIA GeForce RTX 5070 Ti Laptop GPU" "GPU UUID:        $SECRET_GPU_UUID" \
      "Bus Location:    0000:64:00.0" > "$ROOT/proc/driver/nvidia/gpus/0000:64:00.0/information"
    echo "nvidia 9000000 40 nvidia_drm, Live 0xffffffffc2000000" >> "$ROOT/proc/modules"
  fi
  mkdir -p "$ROOT/sys/bus/pci/slots/0"
  echo "0000:62:00" > "$ROOT/sys/bus/pci/slots/0/address"
  echo 1 > "$ROOT/sys/bus/pci/slots/0/power"

  echo "-[0000:00]-+-03.1-[62-64]----00.0-[63-64]----01.0-[64]----00.0  NVIDIA Corporation Device 2c18" > "$SHIM_STATE/lspci_tv"
  printf '%s\n' "64:00.0 VGA compatible controller [0300]: NVIDIA Corporation Device [10de:2c18] (rev a1)" \
    "	Kernel driver in use: nvidia" > "$SHIM_STATE/lspci_nnk"
  mkdir -p "$SHIM_STATE/lspci_vv"
  printf '%s\n' "64:00.0 VGA compatible controller: NVIDIA Corporation Device 2c18 (rev a1)" \
    "	Latency: 0" \
    "	Region 0: Memory at 7c000000 (32-bit, non-prefetchable) [size=16M]" \
    "	Region 1: Memory at 6000000000 (64-bit, prefetchable) [size=16G]" \
    "	Capabilities: [68] Express (v2) Legacy Endpoint, MSI 00" \
    "		LnkCap:	Port #0, Speed 16GT/s, Width x4, ASPM L1, Exit Latency L1 unlimited" \
    "		LnkSta:	Speed 16GT/s, Width x4" \
    "	Capabilities: [250 v1] Device Serial Number $SECRET_DSN" \
    "	Kernel driver in use: nvidia" > "$SHIM_STATE/lspci_vv/0000:64:00.0"
  printf '%s\n' "00:03.1 PCI bridge: Advanced Micro Devices, Inc. [AMD] Device 14ef" \
    "	Memory behind bridge: 7c000000-7dffffff [size=32M] [32-bit]" \
    "	Prefetchable memory behind bridge: 6000000000-63ffffffff [size=16G] [32-bit]" \
    "		SltCap:	AttnBtn- PwrCtrl- MRL- AttnInd- PwrInd- HotPlug+ Surprise+" \
    "		SltSta:	Status: AttnBtn- PowerFlt- MRL- CmdCplt- PresDet+ Interlock-" \
    "	Kernel driver in use: pcieport" > "$SHIM_STATE/lspci_vv/0000:00:03.1"

  printf '%s\n' " ● ROG XG Mobile" "   ├─ type:          peripheral" "   ├─ uuid:          $SECRET_UUID" \
    "   └─ authorized:    $( [ "$auth" = 1 ] && echo yes || echo no )" > "$SHIM_STATE/boltctl_list"
  printf '%s\n' "domain0" "   ├─ security:      user" > "$SHIM_STATE/boltctl_domains"
  printf '%s\n' "Nov 15 10:00:00 $SECRET_HOST boltd[812]: [$SECRET_UUID] ROG XG Mobile: authorized" \
    "Nov 15 10:00:01 $SECRET_HOST boltd[812]: store: /home/$SECRET_USER/.local is not used" > "$SHIM_STATE/journal_bolt"
  printf '%s\n' "[    1.234567] thunderbolt 0-1: new device found, vendor=0x1043 device=0x1a1" \
    "[    2.000000] pcieport 0000:00:03.1: pciehp: Slot(0): Card present" \
    "[    3.100000] thunderbolt-net 0-1.0: MAC address $SECRET_MAC" \
    "[    4.000000] systemd[1]: Started Some Unrelated Service." \
    "[    5.000000] nvidia: firmware from /home/$SECRET_USER/fw on $SECRET_HOST" \
    "[  200.250000] audit: type=1130 audit(0.0:1): unrelated line" > "$SHIM_STATE/dmesg"
  bolt_running
}

bolt_running() { touch "$SHIM_STATE/active/bolt"; }

# The sandbox as a list of "<path> <type> <size> <mtime> <mode> <link target> <sha256>", without
# the plugin log folder and the shims' own bookkeeping (shim.log, shim-state).
tree_state() {
  (
    cd "$BATS_TEST_TMPDIR" || exit 1
    find . \( -path ./shim.log -o -path ./shim-state -o -path ./homebrew/logs \) -prune -o -printf '%p %y %s %T@ %m %l\n' \
      | sort
    find . \( -path ./shim.log -o -path ./shim-state -o -path ./homebrew/logs \) -prune -o -type f -print0 \
      | sort -z | xargs -0 -r sha256sum
  )
}

# Fails on any call that could change the system.
refute_mutating_calls() {
  local bad
  bad=$(grep -E '^(modprobe|rmmod|insmod|setpci|tee)( |$)|^systemctl( .*)? (start|stop|restart|reload|enable|disable|kill|mask|set-environment|unset-environment)( |$)|^boltctl( .*)? (authorize|enroll|forget)( |$)|^udevadm (trigger|control)' "$SHIM_LOG" || true)
  [ -z "$bad" ] || fail "$(printf 'mutating calls:\n%s' "$bad")"
}

# Runs the script on the current fixture and checks it changed nothing but its own log.
check_read_only() {
  local before after
  with_command boltctl mokutil dkms nvidia-smi
  before=$(tree_state)
  diag plugged
  assert_success
  after=$(tree_state)
  assert_equal "$after" "$before"
  refute_mutating_calls
  assert_equal "$(ls -A "$LOG_DIR" | sort)" "$(printf '%s\n' "$DIAG_LOG_NAME" usb4_diagnostics.lock | sort)"
  [[ "$output" == *"Saved snapshot 1 to "* ]] || fail "no closing line"
  grep -q '^===== Snapshot 1 ' "$LOG_DIR/$DIAG_LOG_NAME" || fail "no snapshot in the log"
}

# --- 1. Read-only guarantee ---

@test "read-only: (a) ASUS Ally with the XG Mobile connector" {
  fixture_ally
  check_read_only
}

@test "read-only: (b) USB4 host, authorized dock, NVIDIA GPU behind a bridge" {
  fixture_usb4
  check_read_only
  # The run really went through the commands it's meant to only query with.
  assert_called "boltctl list"
  assert_called "lspci -vv -s 0000:64:00.0"
  assert_called "nvidia-smi -L"
}

@test "read-only: (c) USB4 host, dock not authorized, no GPU" {
  fixture_usb4 unauthorized
  check_read_only
  diag_log | grep -qx '  authorized: 0' || fail "authorized=0 not reported"
}

@test "read-only: the tree checksum catches a write to sysfs (control for the read-only tests)" {
  fixture_usb4
  local before after
  before=$(tree_state)
  echo 1 > "$ROOT/sys/bus/pci/rescan"
  after=$(tree_state)
  [ "$after" != "$before" ] || fail "tree_state missed a write to sys/bus/pci/rescan"
  echo "tee $ROOT/sys/bus/pci/rescan" >> "$SHIM_LOG"
  run refute_mutating_calls
  assert_failure
}

@test "read-only: bolt isn't queried (or started) when bolt.service isn't active" {
  fixture_usb4
  rm -f "$SHIM_STATE/active/bolt"
  with_command boltctl
  diag
  assert_success
  refute_called "boltctl"
  assert_line "(skipped: bolt.service isn't active, and boltctl would start it)"
}

@test "read-only: nvidia-smi doesn't run when the nvidia module isn't loaded" {
  fixture_usb4 unauthorized
  with_command nvidia-smi
  diag
  assert_success
  refute_called "nvidia-smi"
  assert_line "(not available: nvidia module not loaded (nvidia-smi not run, it would load it))"
}

@test "read-only: the script has no mutating commands or writes to system paths" {
  local code
  code=$(grep -vE '^[[:space:]]*#' "$XGM_REPO/bin/xgm-usb4-diag")
  ! grep -nE '\b(modprobe|rmmod|insmod|setpci|tee|authorize|enroll|forget|rescan|unbind|bind|remove)\b' <<< "$code" \
    | grep -vE "boltctl would start it|nvidia-smi not run, it would load it" || fail "found a mutating command"
  ! grep -nE '>>? *"?\$ROOT/(sys|proc|dev)' <<< "$code" || fail "found a write to sysfs/procfs/devfs"
  ! grep -nE 'systemctl +(start|stop|restart|enable|disable)' <<< "$code" || fail "found a systemctl change"
}

# --- 2. Missing tools ---

@test "missing tools: no boltctl, lspci, nvidia-smi, mokutil, dkms; dmesg restricted; exit 0" {
  fixture_usb4
  hide_command lspci
  dmesg_restricted
  diag
  assert_success
  assert_line "(not available: boltctl not installed (bolt missing))"
  assert_line "(not available: lspci not installed)"
  assert_line "(not available: lspci not installed (only the sysfs view above))"
  assert_line "(not available: nvidia-smi not installed)"
  assert_line "secure boot: (not available: mokutil not installed)"
  assert_line "(not available: dkms not installed)"
  assert_line "(not available: dmesg restricted or missing, and no kernel journal)"
  assert_line "(not available: bolt not installed)"
  # The sysfs view still names the GPU behind the dock.
  assert_line "0000:64:00.0 (target): class 0x030000 vendor 0x10de device 0x2c18 driver nvidia"
  # Every section is still there, in order.
  run grep -E '^--- .* ---$' "$LOG_DIR/$DIAG_LOG_NAME"
  assert_output "$(printf '%s\n' '--- System ---' '--- Kernel support ---' '--- Thunderbolt / USB4 ---' '--- PCI ---' \
    '--- GPUs / DRM ---' '--- ASUS interfaces ---' '--- Kernel log ---' '--- bolt journal ---')"
}

@test "missing tools: a restricted dmesg falls back to the kernel journal" {
  fixture_usb4
  dmesg_restricted
  printf '%s\n' "[    7.000000] $SECRET_HOST kernel: pcieport 0000:00:03.1: pciehp: Slot(0): Link Up" > "$SHIM_STATE/journal_kernel"
  diag
  assert_success
  assert_line "source: journalctl -k -b (dmesg not available or restricted) (the last 400 matching lines)"
  assert_line "[    7.000000] <host> kernel: pcieport 0000:00:03.1: pciehp: Slot(0): Link Up"
  assert_line "dmesg_last_ts=7.000000"
}

@test "missing tools: no thunderbolt sysfs, no PCI sysfs, no /proc files, no systemctl, journalctl or timeout" {
  rm -rf "$ROOT/sys/bus" "$ROOT/proc"
  hide_command systemctl journalctl timeout dmesg
  diag
  assert_success
  assert_line "(not available: systemctl not installed)"
  assert_line "(not available: $ROOT/sys/bus/thunderbolt missing (no thunderbolt driver or no USB4 controller))"
  assert_line "(not available: $ROOT/sys/bus/pci/devices missing)"
  assert_line "(not available: $ROOT/proc/modules unreadable)"
  assert_line "(not available: no kernel config found (config.gz, boot config, modules config))"
}

# --- 3. Redaction ---

@test "redaction: UUIDs, serials, MACs, the hostname and /home/<user> never reach the log" {
  fixture_usb4
  with_command boltctl nvidia-smi
  diag
  assert_success
  local log secret
  log=$(diag_log)
  for secret in "$SECRET_UUID" "$SECRET_TB_UID" "${SECRET_GPU_UUID#GPU-}" "$SECRET_DSN" "$SECRET_MAC" \
    "$SECRET_HOST" "$SECRET_USER" "$SECRET_DMI_SERIAL" "0123abcd-1111"; do
    [[ "$log" != *"$secret"* ]] || fail "'$secret' is in the log"
    [[ "$output" != *"$secret"* ]] || fail "'$secret' is in the output"
  done
  [[ "$log" == *"root=UUID=<uuid>"* ]] || fail "no <uuid> in the cmdline"
  [[ "$log" == *"uuid:          <uuid>"* ]] || fail "no <uuid> in boltctl list"
  [[ "$log" == *"unique_id: <uuid>"* ]] || fail "no <uuid> for the Thunderbolt unique_id"
  [[ "$log" == *"GPU UUID:        GPU-<uuid>"* ]] || fail "no <uuid> in the NVIDIA information"
  # (lspci's Device Serial Number line is filtered out before redaction; its placeholder is
  # checked in "other placeholders".)
  [[ "$log" == *"MAC address <mac>"* ]] || fail "no <mac>"
  [[ "$log" == *"<host> boltd[812]"* ]] || fail "no <host>"
  [[ "$log" == *"/home/<user>/fw"* ]] || fail "no /home/<user>"
  # The boot id: only its first 8 characters, in the header.
  [[ "$log" == *"boot=0123abcd ="* ]] || fail "no boot id in the header"
  [[ "$log" == *"Identifiers (UUIDs, serials, MACs, hostname) are redacted. Please still skim this before posting it publicly."* ]] \
    || fail "no redaction notice"
  # The DMI serial files and the product UUID are never read.
  refute_called "timeout -k 2 10 cat -- $ROOT/sys/class/dmi/id/product_serial"
  ! grep -qE 'product_serial|board_serial|product_uuid|chassis_serial' "$SHIM_LOG" || fail "a DMI serial was read"
}

@test "redaction: other placeholders" {
  fixture_ally
  printf '%s\n' "[    1.0] thunderbolt 0-1: SerialNumber: ABC123456" "[    1.1] xhci_hcd: Serial Number: XYZ987" \
    "[    1.2] thunderbolt 0-0: eui AA:BB:CC:DD:EE:FF:00:11" "[    1.3] thunderbolt 0-0: uuid 5B2F7C1E-8A3D-4F6B-9E0A-1C2D3E4F5A6B" \
    "[    1.4] xhci_hcd 0000:0a:00.3: hello" "[    1.5] pcieport 0000:00:03.1: Device Serial Number $SECRET_DSN" > "$SHIM_STATE/dmesg"
  diag
  assert_success
  run diag_log
  assert_line "[    1.0] thunderbolt 0-1: SerialNumber: <serial>"
  assert_line "[    1.1] xhci_hcd: Serial Number: <serial>"
  assert_line "[    1.2] thunderbolt 0-0: eui <mac>"
  assert_line "[    1.3] thunderbolt 0-0: uuid <uuid>"
  # A PCI address isn't a MAC.
  assert_line "[    1.4] xhci_hcd 0000:0a:00.3: hello"
  assert_line "[    1.5] pcieport 0000:00:03.1: Device Serial Number <serial>"
}

@test "redaction: the hostname in any case and inside _-joined tokens" {
  fixture_usb4
  printf '%s\n' "[    1.0] thunderbolt: ALICES-LEGION_dock and nvidia_Alices-Legion_x, alices-legion alices-legion." \
    "[    1.1] thunderbolt: not-alices-legionx stays" > "$SHIM_STATE/dmesg"
  diag
  assert_success
  run diag_log
  assert_line "[    1.0] thunderbolt: <host>_dock and nvidia_<host>_x, <host> <host>."
  # Part of a longer alphanumeric word: not the hostname.
  assert_line "[    1.1] thunderbolt: not-alices-legionx stays"
}

@test "redaction: PARTUUID=, short UUID= forms, /run/media/<user>, iSerial and serial values" {
  fixture_ally
  echo "BOOT_IMAGE=/vmlinuz root=PARTUUID=1a2b3c4d-02 resume=UUID=1234-ABCD rw" > "$ROOT/proc/cmdline"
  printf '%s\n' "[    1.0] thunderbolt: mounted /run/media/$SECRET_USER/disk" \
    "[    1.1] xhci_hcd: iSerial                 3 0123456789AB" \
    "[    1.2] xhci_hcd: serial XYZ0001 attached" \
    "[    1.3] typec: Serial: QQ77" \
    "[    1.4] xhci_hcd: iSerial                 0 " \
    "[    1.5] thunderbolt: Device Serial Number 12-34-56-78-9a-bc-de-f0" > "$SHIM_STATE/dmesg"
  diag
  assert_success
  run diag_log
  assert_line "cmdline: BOOT_IMAGE=/vmlinuz root=PARTUUID=<uuid> resume=UUID=<uuid> rw"
  assert_line "[    1.0] thunderbolt: mounted /run/media/<user>/disk"
  assert_line "[    1.1] xhci_hcd: iSerial                 3 <serial>"
  assert_line "[    1.2] xhci_hcd: serial <serial> attached"
  assert_line "[    1.3] typec: Serial: <serial>"
  assert_line "[    1.4] xhci_hcd: iSerial                 0 "
  assert_line "[    1.5] thunderbolt: Device Serial Number <serial>"
  refute_output --partial "$SECRET_USER"
  refute_output --partial "1a2b3c4d"
  refute_output --partial "1234-ABCD"
}

@test "redaction: lspci class names with Serial survive, real serial forms don't" {
  fixture_usb4
  printf '%s\n' "00:14.3 Serial bus controller [0c80]: Intel Corporation Device [8086:51e8]" \
    "00:15.0 Serial bus controller: Intel Corporation Serial IO I2C Host Controller" \
    "01:00.0 Serial Attached SCSI controller [0107]: Broadcom / LSI SAS3008" > "$SHIM_STATE/lspci_nnk"
  printf '%s\n' "[    1.0] xhci_hcd: serial XYZ0001 attached" "[    1.1] xhci_hcd: serial=ABC" \
    "[    1.2] typec: Serial: QQ77" "[    1.3] xhci_hcd: iSerial                 3 0123456789AB" \
    "[    1.4] thunderbolt 0-1: SerialNumber: ABC123456" "[    1.5] xhci_hcd: Serial Number: XYZ987" \
    "[    1.6] pcieport 0000:00:03.1: Device Serial Number $SECRET_DSN" \
    "[    1.7] xhci_hcd: Serial bus controller ready" > "$SHIM_STATE/dmesg"
  diag
  assert_success
  run diag_log
  assert_line "00:14.3 Serial bus controller [0c80]: Intel Corporation Device [8086:51e8]"
  assert_line "00:15.0 Serial bus controller: Intel Corporation Serial IO I2C Host Controller"
  assert_line "01:00.0 Serial Attached SCSI controller [0107]: Broadcom / LSI SAS3008"
  assert_line "[    1.0] xhci_hcd: serial <serial> attached"
  assert_line "[    1.1] xhci_hcd: serial=<serial>"
  assert_line "[    1.2] typec: Serial: <serial>"
  assert_line "[    1.3] xhci_hcd: iSerial                 3 <serial>"
  assert_line "[    1.4] thunderbolt 0-1: SerialNumber: <serial>"
  assert_line "[    1.5] xhci_hcd: Serial Number: <serial>"
  assert_line "[    1.6] pcieport 0000:00:03.1: Device Serial Number <serial>"
  assert_line "[    1.7] xhci_hcd: Serial bus controller ready"
}

@test "redaction: a model-word hostname (legion) keeps \"Legion Go 2\"; kenny-legion is still redacted" {
  fixture_usb4
  echo "legion" > "$ROOT/etc/hostname"
  set_hostname legion
  printf '%s\n' "[    1.0] thunderbolt: Legion Go 2 dock on legion" > "$SHIM_STATE/dmesg"
  diag
  assert_success
  run diag_log
  assert_line "dmi product_family: Legion Go 2 8ASP2"
  assert_line "[    1.0] thunderbolt: Legion Go 2 dock on legion"

  echo "kenny-legion" > "$ROOT/etc/hostname"
  set_hostname kenny-legion
  printf '%s\n' "[    1.0] thunderbolt: Legion Go 2 dock on kenny-legion and Kenny-Legion_x" > "$SHIM_STATE/dmesg"
  diag
  assert_success
  run diag_log
  assert_line "dmi product_family: Legion Go 2 8ASP2"
  assert_line "[    1.0] thunderbolt: Legion Go 2 dock on <host> and <host>_x"
  refute_output --partial "kenny-legion"
}

@test "redaction: the DMI lines are never hostname-redacted, the rest still is" {
  fixture_usb4
  # A hostname equal to the board name (not in the skip list): DMI keeps it, other lines don't.
  echo "LNVNB161216" > "$ROOT/etc/hostname"
  set_hostname LNVNB161216
  printf '%s\n' "[    1.0] thunderbolt: host lnvnb161216 ready" > "$SHIM_STATE/dmesg"
  diag
  assert_success
  run diag_log
  assert_line "dmi board_name: LNVNB161216"
  assert_line "[    1.0] thunderbolt: host <host> ready"
}

@test "redaction: an OS default hostname (steamdeck) isn't redacted" {
  fixture_ally
  set_hostname steamdeck
  diag
  assert_success
  run diag_log
  assert_line "VARIANT_ID=steamdeck"
}

# --- 4. Snapshots ---

@test "snapshots: two runs append Snapshot 1 and 2, with label, version, boot and dmesg timestamp" {
  fixture_usb4
  diag unplugged
  assert_success
  KEEP_LOG_DIR=1 diag plugged
  assert_success
  local version
  version=$(sed -nE 's/^[[:space:]]*"version":[[:space:]]*"([^"]*)".*/\1/p' "$XGM_REPO/package.json")
  run grep -E '^===== Snapshot ' "$LOG_DIR/$DIAG_LOG_NAME"
  assert_line --index 0 --regexp "^===== Snapshot 1  [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+[+-][0-9:]+  label=unplugged  plugin=$version  boot=0123abcd =====\$"
  assert_line --index 1 --regexp "^===== Snapshot 2  .*  label=plugged  plugin=$version  boot=0123abcd =====\$"
  assert_equal "${#lines[@]}" 2
  run grep -c '^dmesg_last_ts=200.250000$' "$LOG_DIR/$DIAG_LOG_NAME"
  assert_output 2
}

@test "snapshots: the label is sanitized and capped at 32 characters" {
  diag "plug ged;rm -rf"
  assert_success
  grep -q '^===== Snapshot 1  .*  label=plug_ged_rm_-rf  ' "$LOG_DIR/$DIAG_LOG_NAME" || fail "label not sanitized: $(head -n 1 "$LOG_DIR/$DIAG_LOG_NAME")"
  KEEP_LOG_DIR=1 diag '$(touch x)abcdefghijklmnopqrstuvwxyz0123456789'
  grep -q '^===== Snapshot 2  .*  label=__touch_x_abcdefghijklmnopqrstuv  ' "$LOG_DIR/$DIAG_LOG_NAME" || fail "label not capped"
  KEEP_LOG_DIR=1 diag
  grep -q '^===== Snapshot 3  .*  label=none  ' "$LOG_DIR/$DIAG_LOG_NAME" || fail "no default label"
}

@test "snapshots: a log over 2 MB moves to usb4_diagnostics.prev.log first, numbering continues" {
  { echo "===== Snapshot 7  2026-11-01T10:00:00+00:00  label=old  plugin=0.3.0  boot=aaaaaaaa ====="
    head -c 2200000 /dev/zero | tr '\0' 'x'; echo; } > "$LOG_DIR/$DIAG_LOG_NAME"
  local old_sum
  old_sum=$(sha256sum < "$LOG_DIR/$DIAG_LOG_NAME")
  KEEP_LOG_DIR=1 diag plugged
  assert_success
  assert_equal "$(sha256sum < "$LOG_DIR/usb4_diagnostics.prev.log")" "$old_sum"
  grep -q '^===== Snapshot 8 ' "$LOG_DIR/$DIAG_LOG_NAME" || fail "numbering didn't continue"
  ! grep -q 'Snapshot 7' "$LOG_DIR/$DIAG_LOG_NAME" || fail "the old snapshot is still in the log"
}

@test "snapshots: a log under 2 MB is appended to, not rotated" {
  { echo "===== Snapshot 3  2026-11-01T10:00:00+00:00  label=old  plugin=0.3.0  boot=aaaaaaaa ====="; echo old; } > "$LOG_DIR/$DIAG_LOG_NAME"
  KEEP_LOG_DIR=1 diag
  assert_success
  assert [ ! -e "$LOG_DIR/usb4_diagnostics.prev.log" ]
  assert_equal "$(head -n 2 "$LOG_DIR/$DIAG_LOG_NAME" | tail -n 1)" "old"
  grep -q '^===== Snapshot 4 ' "$LOG_DIR/$DIAG_LOG_NAME" || fail "no Snapshot 4"
}

@test "snapshots: the report also goes to stdout, then where it was saved" {
  fixture_usb4
  diag plugged
  assert_success
  assert_line --regexp '^===== Snapshot 1  .*label=plugged'
  assert_line --index $((${#lines[@]} - 1)) "Saved snapshot 1 to $LOG_DIR/$DIAG_LOG_NAME"
}

@test "log dir: without --log-dir it's the plugin's activity folder, found from the script's location" {
  local plugin="$BATS_TEST_TMPDIR/homebrew/plugins/xgmobile-manager"
  mkdir -p "$plugin/bin"
  cp "$XGM_REPO/bin/xgm-usb4-diag" "$XGM_REPO/bin/xgm-common.sh" "$plugin/bin/"
  cp "$XGM_REPO/package.json" "$plugin/"
  XGM_BIN_DIR="$plugin/bin" run_script xgm-usb4-diag boot-plugged
  assert_success
  grep -q '^===== Snapshot 1  .*  label=boot-plugged  ' "$LOG_DIR/$DIAG_LOG_NAME" || fail "not in $LOG_DIR"
}

# The exit 3 hint: a CLI run with a writable folder.
assert_cli_hint() {
  assert_output --partial "The snapshot above was NOT saved. Run it again with a writable folder and attach the log from there: sudo "
  assert_output --partial "/bin/xgm-usb4-diag --log-dir /tmp/xgm-usb4 plugged"
}

@test "log dir: can't be created, exit 3, the snapshot is still collected and printed" {
  fixture_usb4
  : > "$BATS_TEST_TMPDIR/not-a-dir"
  run_script xgm-usb4-diag --log-dir "$BATS_TEST_TMPDIR/not-a-dir/activity" plugged
  assert_failure 3
  assert_line --regexp '^===== Snapshot 1  .*  label=plugged  '
  assert_line "===== End of snapshot 1 ====="
  assert_line "0000:64:00.0 (target): class 0x030000 vendor 0x10de device 0x2c18 driver nvidia"
  assert_output --partial "ERROR: can't create the log folder $BATS_TEST_TMPDIR/not-a-dir/activity."
  assert_cli_hint
  refute_output --partial "Saved snapshot"
  # Still redacted.
  refute_output --partial "$SECRET_MAC"
}

@test "log dir: log not writable, exit 3, the snapshot is printed but the log is untouched" {
  : > "$LOG_DIR/$DIAG_LOG_NAME"
  chmod 444 "$LOG_DIR/$DIAG_LOG_NAME"
  KEEP_LOG_DIR=1 diag plugged
  assert_failure 3
  assert_line --regexp '^===== Snapshot 1  .*  label=plugged  '
  assert_output --partial "ERROR: can't write $LOG_DIR/$DIAG_LOG_NAME. The snapshot above was NOT saved."
  assert_cli_hint
  assert_equal "$(wc -c < "$LOG_DIR/$DIAG_LOG_NAME")" 0
}

@test "log dir: the hint's --log-dir /tmp/xgm-usb4 form works (a fresh folder is created)" {
  run_script xgm-usb4-diag --log-dir "$BATS_TEST_TMPDIR/xgm-usb4" plugged
  assert_success
  grep -q '^===== Snapshot 1  .*  label=plugged  ' "$BATS_TEST_TMPDIR/xgm-usb4/$DIAG_LOG_NAME" || fail "no snapshot"
}

@test "log dir under /home/<user>: stdout and stderr name it as ~ and never the user name" {
  fixture_usb4
  local home="$BATS_TEST_TMPDIR/home/$SECRET_USER" dir
  # The sandbox prefix comes before /home here, so tilde leaves the path alone and the redaction
  # (/home/<user>) is what hides the name. (A leading /home/<user> becomes ~: see the tilde test.)
  dir="$home/homebrew/logs/xgmobile-manager/activity"
  run_script xgm-usb4-diag --log-dir "$dir" plugged
  assert_success
  refute_output --partial "$SECRET_USER"
  assert_line --partial "Saved snapshot 1 to "
  assert_line --partial "/home/<user>/homebrew/logs/xgmobile-manager/activity/usb4_diagnostics.log"
  # And stderr, on the exit 3 path.
  chmod 444 "$dir/$DIAG_LOG_NAME"
  run_script xgm-usb4-diag --log-dir "$dir" plugged
  assert_failure 3
  refute_output --partial "$SECRET_USER"
  assert_output --partial "ERROR: can't write "
}

@test "tilde: a leading /home/<user> or /var/home/<user> is shown as ~" {
  run bash -c '. <(sed -n "/^tilde()/p" "$1"); tilde /home/deck/homebrew/logs/x.log; echo; tilde /var/home/bob/a; echo; tilde /tmp/x' _ "$XGM_REPO/bin/xgm-usb4-diag"
  assert_output "$(printf '%s\n' '~/homebrew/logs/x.log' '~/a' '/tmp/x')"
}

# --- Concurrent runs ---

@test "lock: two runs at once get Snapshot 1 and 2, not the same number" {
  fixture_usb4
  ( KEEP_LOG_DIR=1 diag one ) &
  ( KEEP_LOG_DIR=1 diag two ) &
  wait
  run grep -oE '^===== Snapshot [0-9]+' "$LOG_DIR/$DIAG_LOG_NAME"
  assert_output "$(printf '%s\n' '===== Snapshot 1' '===== Snapshot 2')"
}

@test "lock: held by another run for longer than the wait, exit 4 and nothing collected" {
  touch "$LOG_DIR/usb4_diagnostics.lock"
  flock "$LOG_DIR/usb4_diagnostics.lock" sleep 20 &
  local holder=$!
  local i
  for i in $(seq 1 50); do flock -n "$LOG_DIR/usb4_diagnostics.lock" true || break; sleep 0.1; done
  XGM_DIAG_LOCK_WAIT=1 KEEP_LOG_DIR=1 diag plugged
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  assert_failure 4
  assert_output "ERROR: another USB4 diagnostics run is still going (waited 1 s for $LOG_DIR/usb4_diagnostics.lock). Nothing was collected; try again in a minute."
  refute_called "lspci"
  assert [ ! -s "$LOG_DIR/$DIAG_LOG_NAME" ]
}

# --- 5. ASUS section ---

@test "ASUS: (a) the Ally reports asus-nb-wmi and its eGPU nodes with values" {
  fixture_ally
  mkdir -p "$ROOT/sys/class/firmware-attributes/asus-armoury/attributes/ppt_pl1_spl" \
    "$ROOT/sys/class/firmware-attributes/asus-armoury/attributes/egpu_enable"
  diag
  assert_success
  assert_line "asus-nb-wmi: present"
  assert_line "  egpu_enable: present, 1"
  assert_line "  egpu_connected: present, 1"
  assert_line "  throttle_thermal_policy: present, 0"
  assert_line "  dgpu_disable: absent"
  assert_line "asus-armoury firmware attributes: present"
  assert_line "  egpu_enable ppt_pl1_spl "
  assert_line "  asus_nb_wmi: loaded (refcount 0, Live)"
  # The kernel config came from /boot; no kernel addresses from /proc/modules.
  assert_line "  CONFIG_USB4=m"
  refute_output --partial "0xffffffff"
}

@test "ASUS: (b) the USB4 host has none of them" {
  fixture_usb4
  diag
  assert_success
  assert_line "asus-nb-wmi: absent"
  assert_line "  egpu_enable: absent"
  assert_line "  egpu_connected: absent"
  assert_line "  throttle_thermal_policy: absent"
  assert_line "  dgpu_disable: absent"
  assert_line "asus-armoury firmware attributes: absent"
  assert_line "  asus_nb_wmi: not loaded"
  assert_line "  thunderbolt: loaded (refcount 0, Live)"
  assert_line "  CONFIG_USB4=y"
  assert_line "  # CONFIG_THUNDERBOLT_NET is not set"
  refute_line "  CONFIG_DRM=y"
}

# --- What (b) collects ---

@test "USB4 host: Thunderbolt, the bridges up to the GPU, DRM and the filtered kernel log" {
  fixture_usb4
  with_command boltctl nvidia-smi dkms mokutil
  diag
  assert_success
  # Thunderbolt
  assert_line "bolt 0.9.8"
  assert_line "0-1:"
  assert_line "  authorized: 1"
  assert_line "  device_name: ROG XG Mobile"
  assert_line "  rx_speed: 40.0 Gb/s"
  assert_line "  iommu_dma_protection: 1"
  # PCI: the GPU, every bridge above it, the USB4 controller; lspci -vv only the wanted lines.
  assert_line "0000:00:03.1 (bridge): class 0x060400 vendor 0x1022 device 0x14ef driver pcieport"
  assert_line "0000:62:00.0 (bridge): class 0x060400 vendor 0x8086 device 0x5786 driver pcieport"
  assert_line "0000:63:01.0 (bridge): class 0x060400 vendor 0x8086 device 0x5786 driver pcieport"
  assert_line "0000:64:00.0 (target): class 0x030000 vendor 0x10de device 0x2c18 driver nvidia"
  assert_line "0000:c6:00.5 (target): class 0x0c0340 vendor 0x1022 device 0x1668 driver thunderbolt"
  assert_line "		LnkSta:	Speed 16GT/s, Width x4"
  assert_line "	Prefetchable memory behind bridge: 6000000000-63ffffffff [size=16G] [32-bit]"
  assert_line "		SltSta:	Status: AttnBtn- PowerFlt- MRL- CmdCplt- PresDet+ Interlock-"
  assert_line "	Region 1: Memory at 6000000000 (64-bit, prefetchable) [size=16G]"
  refute_line "	Latency: 0"
  assert_line "  0: address 0000:62:00 power 1"
  # DRM and NVIDIA
  assert_line "card1: 0000:64:00.0 vendor 0x10de device 0x2c18 boot_vga 0"
  assert_line "card0: 0000:08:00.0 vendor 0x1002 device  boot_vga 1"
  assert_line "nvidia module version: 620.70.06"
  assert_line "620.70.06, 00000000:03:00.0"
  assert_line --regexp '^nvidia/620\.70\.06, .*: installed$'
  assert_line "secure boot: SecureBoot disabled "
  # Kernel log: only the matching lines, the last timestamp of the whole log in the header.
  assert_line "[    2.000000] pcieport 0000:00:03.1: pciehp: Slot(0): Card present"
  refute_line --partial "Some Unrelated Service"
  assert_line "dmesg_last_ts=200.250000"
}

@test "kernel log: only the last 400 matching lines" {
  local i
  for i in $(seq 1 500); do printf '[ %4d.000000] thunderbolt 0-0: line %d\n' "$i" "$i"; done > "$SHIM_STATE/dmesg"
  diag
  assert_success
  run grep -c 'thunderbolt 0-0: line' "$LOG_DIR/$DIAG_LOG_NAME"
  assert_output 400
  grep -q 'thunderbolt 0-0: line 101$' "$LOG_DIR/$DIAG_LOG_NAME" || fail "line 101 missing"
  ! grep -q 'thunderbolt 0-0: line 100$' "$LOG_DIR/$DIAG_LOG_NAME" || fail "line 100 kept"
}

# --- 6. Timeout ---

@test "timeout: a hanging boltctl is cut off and the run still finishes" {
  fixture_usb4
  with_command boltctl
  hang_command boltctl
  real_timeout 1
  local start=$SECONDS
  diag plugged
  assert_success
  [ $((SECONDS - start)) -lt 30 ] || fail "took $((SECONDS - start)) s"
  run grep -c '^(timed out after 10 s)$' "$LOG_DIR/$DIAG_LOG_NAME"
  assert_output 3
  grep -q '^--- bolt journal ---$' "$LOG_DIR/$DIAG_LOG_NAME" || fail "the run didn't reach the last section"
  grep -q '^===== End of snapshot 1 =====$' "$LOG_DIR/$DIAG_LOG_NAME" || fail "no end marker"
}

@test "timeout: the message names the limit actually used, capped by the budget" {
  fixture_usb4
  with_command boltctl
  hang_command boltctl
  real_timeout 1
  XGM_DIAG_BUDGET=5 diag plugged
  assert_success
  run grep -E '^\(timed out after [0-9]+ s\)$' "$LOG_DIR/$DIAG_LOG_NAME"
  assert_equal "${#lines[@]}" 3
  local l
  for l in "${lines[@]}"; do
    [[ "$l" =~ ^\(timed\ out\ after\ [1-5]\ s\)$ ]] || fail "not capped by the 5 s budget: $l"
  done
}

@test "timeout: every external command runs under timeout" {
  fixture_usb4
  with_command boltctl mokutil dkms nvidia-smi
  diag
  assert_success
  # Each shim logs its own call, and the timeout shim logs the call it wraps: for every shimmed
  # command, every call must have come through timeout.
  local cmd direct wrapped
  for cmd in boltctl lspci nvidia-smi dmesg journalctl mokutil dkms uname hostname systemctl; do
    direct=$(grep -cE "^$cmd( |\$)" "$SHIM_LOG" || true)
    wrapped=$(grep -cE "^timeout -k 2 [0-9]+ $cmd( |\$)" "$SHIM_LOG" || true)
    [ "$direct" -gt 0 ] || fail "$cmd never ran"
    assert_equal "$cmd: $wrapped" "$cmd: $direct"
  done
}

@test "arguments: after --, a label that looks like an option is still a label" {
  run_script xgm-usb4-diag --log-dir "$LOG_DIR" -- --log-dir
  assert_success
  grep -q '^===== Snapshot 1  .*  label=--log-dir  ' "$LOG_DIR/$DIAG_LOG_NAME" || fail "label lost: $(head -n 1 "$LOG_DIR/$DIAG_LOG_NAME")"
}
