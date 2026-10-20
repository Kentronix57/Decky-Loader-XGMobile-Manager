#!/usr/bin/env bats
# bin/install-nvidia-cachyos.sh: package selection, the no-partial-upgrade guard, the nouveau
# blacklist and every exit code. pacman, modinfo and mkinitcpio are shims.

DECKIFY=7.2.9-2-cachyos-deckify
LTS=6.12.50-1-lts

USERSPACE="nvidia-utils egl-wayland nvidia-settings opencl-nvidia lib32-opencl-nvidia lib32-nvidia-utils libva-nvidia-driver vulkan-icd-loader lib32-vulkan-icd-loader"

setup_file() {
  load helpers/sandbox
  xgm_setup_file
}

setup() {
  load helpers/sandbox
  make_root
  set_os cachyos
  no_steamos_readonly
  installed_kernel "$DECKIFY" linux-cachyos-deckify
}

teardown() {
  refute_called "steamos-readonly"
}

run_install() {
  run_script install-nvidia-cachyos.sh "$LOG_DIR" "$DATA_DIR"
}

# Only the `pacman -S` line, without the "pacman -S --needed --noconfirm " prefix.
install_args() {
  local line
  line=$(calls_matching "pacman -S --needed --noconfirm ")
  assert_equal "$(printf '%s\n' "$line" | grep -c .)" 1
  echo "${line#pacman -S --needed --noconfirm }"
}

refute_db_refresh() {
  if grep -Eq -- '^pacman (-S[A-Za-z]*y|.*--refresh)' "$SHIM_LOG"; then
    fail "$(printf 'pacman refreshed the sync database (partial upgrade):\n%s' "$(sed 's/^/  /' "$SHIM_LOG")")"
  fi
}

@test "not cachyos: exit 2, nothing installed" {
  local os
  for os in steamos bazzite bazzite-nvidia; do
    set_os "$os"
    run_install
    assert_failure 2
    refute_called "pacman"
  done
}

@test "module and nvidia-utils already installed: exit 10, no pacman -S" {
  nvidia_driver installed
  pacman_local nvidia-utils 615.78.08-1
  run_install
  assert_failure 10
  assert_output --partial "ALREADY_INSTALLED NVIDIA Driver 610.43.02"
  refute_called "pacman -S"
  refute_called "mkinitcpio"
}

@test "module present, nvidia-utils missing: userspace only" {
  nvidia_driver installed
  pacman_repo linux-cachyos-deckify-nvidia-open 7.2.9-2
  run_install
  assert_success
  assert_equal "$(install_args)" "$USERSPACE"
  refute_called "pacman -Si linux-cachyos-deckify-nvidia-open"
  assert_called "modinfo nvidia"
  refute_called "modinfo -k"
}

@test "installed kernel differs from the repo: exit 3, no pacman -S" {
  pacman_repo linux-cachyos-deckify 7.2.10-1
  pacman_repo linux-cachyos-deckify-nvidia-open 7.2.10-1
  run_install
  assert_failure 3
  assert_output --partial "CachyOS has pending updates"
  assert_output --partial "sudo pacman -Syu"
  refute_called "pacman -S"
  refute_db_refresh
}

@test "kernel not in the sync database (stale or offline): exit 3, no pacman -S" {
  pacman_repo linux-cachyos-deckify none
  run_install
  assert_failure 3
  assert_output --partial "CachyOS has pending updates"
  refute_called "pacman -S"
}

@test "no kernel module directories: exit 3" {
  rm -rf "$ROOT/usr/lib/modules"
  run_install
  assert_failure 3
  refute_called "pacman -S"
}

@test "prebuilt module available: kernel-nvidia-open + the chwd userspace, no dkms" {
  pacman_repo linux-cachyos-deckify-nvidia-open 7.2.9-2
  nvidia_module_for "$DECKIFY"
  run_install
  assert_success
  assert_output --partial "Reboot to finish"
  assert_equal "$(install_args)" "linux-cachyos-deckify-nvidia-open $USERSPACE"
  [[ "$(install_args)" != *dkms* ]]
  [[ "$(install_args)" != *headers* ]]
  assert_called "pacman -Q linux-cachyos-deckify"
  assert_called "pacman -Si linux-cachyos-deckify"
  assert_called "modinfo -k $DECKIFY nvidia"
  refute_db_refresh
}

@test "no prebuilt module: nvidia-open-dkms + kernel headers" {
  pacman_repo linux-cachyos-deckify-headers 7.2.9-2
  nvidia_module_for "$DECKIFY"
  run_install
  assert_success
  assert_equal "$(install_args)" "nvidia-open-dkms linux-cachyos-deckify-headers $USERSPACE"
  refute_db_refresh
}

@test "no prebuilt module and no headers: exit 3, no pacman -S" {
  run_install
  assert_failure 3
  assert_output --partial "linux-cachyos-deckify-headers"
  refute_called "pacman -S"
}

@test "pacman -S fails (e.g. database lock): exit 4" {
  pacman_repo linux-cachyos-deckify-nvidia-open 7.2.9-2
  nvidia_module_for "$DECKIFY"
  pacman_install_rc 1
  run_install
  assert_failure 4
  refute_called "mkinitcpio"
  refute_called "modinfo -k"
}

@test "module not found after install: exit 5" {
  pacman_repo linux-cachyos-deckify-nvidia-open 7.2.9-2
  run_install
  assert_failure 5
  assert_called "modinfo -k $DECKIFY nvidia"
}

@test "two kernels (deckify + lts): per-kernel module choice" {
  installed_kernel "$LTS" linux-cachyos-lts 6.12.50-1
  pacman_repo linux-cachyos-deckify-nvidia-open 7.2.9-2
  pacman_repo linux-cachyos-lts-headers 6.12.50-1
  nvidia_module_for "$DECKIFY"
  nvidia_module_for "$LTS"
  run_install
  assert_success
  # Kernels in /usr/lib/modules glob order: the lts dir (6.12...) sorts first.
  assert_equal "$(install_args)" "nvidia-open-dkms linux-cachyos-lts-headers linux-cachyos-deckify-nvidia-open $USERSPACE"
  assert_called "modinfo -k $DECKIFY nvidia"
  assert_called "modinfo -k $LTS nvidia"
}

@test "two kernels, one out of date: exit 3, no pacman -S" {
  installed_kernel "$LTS" linux-cachyos-lts 6.12.50-1
  pacman_repo linux-cachyos-lts 6.12.51-1
  pacman_repo linux-cachyos-deckify-nvidia-open 7.2.9-2
  run_install
  assert_failure 3
  assert_output --partial "linux-cachyos-lts 6.12.50-1 is installed, the repo has 6.12.51-1"
  refute_called "pacman -S"
}

@test "two kernels, module missing for the second after install: exit 5" {
  installed_kernel "$LTS" linux-cachyos-lts 6.12.50-1
  pacman_repo linux-cachyos-deckify-nvidia-open 7.2.9-2
  pacman_repo linux-cachyos-lts-nvidia-open 6.12.50-1
  nvidia_module_for "$DECKIFY"
  run_install
  assert_failure 5
  assert_output --partial "kernel $LTS"
}

@test "no nouveau blacklist yet: blacklist written, initramfs rebuilt" {
  pacman_repo linux-cachyos-deckify-nvidia-open 7.2.9-2
  nvidia_module_for "$DECKIFY"
  run_install
  assert_success
  assert_equal "$(cat "$ROOT/etc/modprobe.d/xgmobile-blacklist-nouveau.conf")" "blacklist nouveau"
  assert_called_before "pacman -S --needed --noconfirm linux-cachyos-deckify-nvidia-open $USERSPACE" "mkinitcpio -P"
}

@test "nouveau already blacklisted by nvidia-utils: no file, no initramfs rebuild" {
  pacman_repo linux-cachyos-deckify-nvidia-open 7.2.9-2
  nvidia_module_for "$DECKIFY"
  mkdir -p "$ROOT/usr/lib/modprobe.d"
  echo "blacklist nouveau" > "$ROOT/usr/lib/modprobe.d/nvidia-utils.conf"
  run_install
  assert_success
  assert [ ! -e "$ROOT/etc/modprobe.d/xgmobile-blacklist-nouveau.conf" ]
  refute_called "mkinitcpio"
}

@test "nouveau already blacklisted in /etc/modprobe.d: no file, no initramfs rebuild" {
  pacman_repo linux-cachyos-deckify-nvidia-open 7.2.9-2
  nvidia_module_for "$DECKIFY"
  printf '%s\n' "# mine" "  blacklist   nouveau" > "$ROOT/etc/modprobe.d/custom.conf"
  run_install
  assert_success
  assert [ ! -e "$ROOT/etc/modprobe.d/xgmobile-blacklist-nouveau.conf" ]
  refute_called "mkinitcpio"
}

@test "a commented-out blacklist line doesn't count" {
  pacman_repo linux-cachyos-deckify-nvidia-open 7.2.9-2
  nvidia_module_for "$DECKIFY"
  echo "# blacklist nouveau" > "$ROOT/etc/modprobe.d/custom.conf"
  run_install
  assert_success
  assert [ -f "$ROOT/etc/modprobe.d/xgmobile-blacklist-nouveau.conf" ]
  assert_called "mkinitcpio -P"
}

@test "pacman never refreshes the sync database, on any path" {
  pacman_repo linux-cachyos-deckify-headers 7.2.9-2
  nvidia_module_for "$DECKIFY"
  run_install
  assert_success
  refute_db_refresh
  pacman_repo linux-cachyos-deckify 7.2.10-1
  run_install
  assert_failure 3
  refute_db_refresh
  refute_called "pacman -Sy"
  refute_called "pacman -Syu"
}

@test "non-English locale: pacman's translated labels don't break the version check" {
  pacman_repo linux-cachyos-deckify-nvidia-open 7.2.9-2
  nvidia_module_for "$DECKIFY"
  SANDBOX_LANG=es_ES.UTF-8 run_install
  assert_success
  assert_output --partial "Kernel linux-cachyos-deckify: installed 7.2.9-2, repo 7.2.9-2"
  install_args >/dev/null
}

@test "the shim really translates the labels outside the C locale" {
  pacman_repo linux-cachyos-deckify 7.2.9-2
  run env PATH="$XGM_SHIMS:$SYSBIN" LANG=es_ES.UTF-8 SHIM_LOG=/dev/null SHIM_STATE="$SHIM_STATE" pacman -Si linux-cachyos-deckify
  assert_line --regexp "^Versión +: 7\.2\.9-2$"
  refute_line --partial "Version"
}

@test "several repo records: the first (highest-priority) one counts" {
  pacman_repo linux-cachyos-deckify cachyos-znver4=7.2.9-2 cachyos=7.2.3-1
  pacman_repo linux-cachyos-deckify-nvidia-open cachyos-znver4=7.2.9-2 cachyos=7.2.3-1
  nvidia_module_for "$DECKIFY"
  run_install
  assert_success
  assert_output --partial "installed 7.2.9-2, repo 7.2.9-2"
}

@test "several repo records, installed matches only the second: exit 3" {
  pacman_local linux-cachyos-deckify 7.2.3-1
  pacman_repo linux-cachyos-deckify cachyos-znver4=7.2.9-2 cachyos=7.2.3-1
  pacman_repo linux-cachyos-deckify-nvidia-open cachyos-znver4=7.2.9-2 cachyos=7.2.3-1
  run_install
  assert_failure 3
  assert_output --partial "linux-cachyos-deckify 7.2.3-1 is installed, the repo has 7.2.9-2"
  refute_called "pacman -S"
}

@test "epoch in the version, installed and repo identical: proceeds" {
  installed_kernel "$DECKIFY" linux-cachyos-deckify 1:615.78.08-1
  pacman_repo linux-cachyos-deckify-nvidia-open 1:615.78.08-1
  nvidia_module_for "$DECKIFY"
  run_install
  assert_success
  assert_output --partial "installed 1:615.78.08-1, repo 1:615.78.08-1"
}

@test "only the pkgrel differs: exit 3" {
  pacman_repo linux-cachyos-deckify 7.2.9-3
  pacman_repo linux-cachyos-deckify-nvidia-open 7.2.9-3
  run_install
  assert_failure 3
  assert_output --partial "linux-cachyos-deckify 7.2.9-2 is installed, the repo has 7.2.9-3"
  refute_called "pacman -S"
}
