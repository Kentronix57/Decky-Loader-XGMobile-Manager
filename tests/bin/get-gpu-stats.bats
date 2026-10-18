#!/usr/bin/env bats
# bin/get-gpu-stats: always prints one valid JSON object.

setup_file() {
  load helpers/sandbox
  xgm_setup_file
}

setup() {
  load helpers/sandbox
  make_root
}

# Parses $output as JSON and prints "key=value" lines, sorted.
json_fields() {
  python3 -c '
import json, sys
data = json.loads(sys.stdin.buffer.read().decode("utf-8"))
for k in sorted(data):
  print(f"{k}={data[k]}")
' <<< "$output"
}

# fake_nvidia_smi "<csv line>" [exit code]: answers only the combined query and logs each call.
fake_nvidia_smi() {
  printf '%s\n' "$1" > "$ROOT/usr/bin/nvidia-smi.out"
  cat > "$ROOT/usr/bin/nvidia-smi" <<EOF
#!/usr/bin/env bash
echo "nvidia-smi \$*" >> "\$SHIM_LOG"
[ "\$1" = "--query-gpu=temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw,enforced.power.limit" ] || exit 9
[ "\$#" = 2 ] && [ "\$2" = "--format=csv,noheader,nounits" ] || exit 9
cat "$ROOT/usr/bin/nvidia-smi.out"
exit ${2:-0}
EOF
  chmod +x "$ROOT/usr/bin/nvidia-smi"
}

# Every numeric key, as json_fields prints a null
assert_numerics_null() {
  local key
  for key in power_limit_w power_w temp_c util_pct vram_mb vram_total_mb; do
    assert_line "$key=None"
  done
}

@test "nvidia: nvidia-smi values in valid JSON" {
  set_lsmod nvidia
  fake_nvidia_smi "61, 87, 5120, 16376, 142.30, 150.00"

  run_script get-gpu-stats
  assert_success
  run json_fields
  assert_success
  assert_output "$(printf '%s\n' 'power=142.30W' 'power_limit_w=150.0' 'power_w=142.3' 'temp=61°C' 'temp_c=61' \
    'util=87%' 'util_pct=87' 'vendor=nvidia' 'vram=5120MB' 'vram_mb=5120' 'vram_total_mb=16376')"
}

@test "nvidia: one nvidia-smi call per poll" {
  set_lsmod nvidia
  fake_nvidia_smi "61, 87, 5120, 16376, 142.30, 150.00"
  run_script get-gpu-stats
  assert_success
  run grep -c "^nvidia-smi " "$SHIM_LOG"
  assert_output "1"
}

@test "nvidia: [N/A] and [Not Supported] fields are null" {
  set_lsmod nvidia
  fake_nvidia_smi "61, [Not Supported], 5120, 16376, 142.30, [N/A]"
  run_script get-gpu-stats
  assert_success
  run json_fields
  assert_success
  assert_line "power_limit_w=None"
  assert_line "util_pct=None"
  assert_line "power_w=142.3"
  assert_line "temp_c=61"
}

@test "nvidia: an empty field is null" {
  set_lsmod nvidia
  fake_nvidia_smi "61, 87, 5120, , 142.30, 150.00"
  run_script get-gpu-stats
  run json_fields
  assert_success
  assert_line "vram_total_mb=None"
  assert_line "vram_mb=5120"
}

@test "nvidia-smi failing: still valid JSON, numerics null" {
  set_lsmod nvidia
  # A failing nvidia-smi prints its error on stdout
  fake_nvidia_smi 'NVIDIA-SMI has failed because it could not communicate with the "NVIDIA" driver.' 9
  run_script get-gpu-stats
  assert_success
  run json_fields
  assert_success
  assert_line "vendor=nvidia"
  assert_line "temp=0°C"
  assert_line "power=0W"
  assert_numerics_null
}

@test "nvidia without nvidia-smi: zeros, still valid JSON" {
  set_lsmod nvidia
  run_script get-gpu-stats
  assert_success
  run json_fields
  assert_success
  assert_line "vendor=nvidia"
  assert_line "temp=0°C"
  assert_numerics_null
}

@test "amd: sysfs values converted, valid JSON" {
  set_lsmod amdgpu
  local dev="$ROOT/sys/class/drm/card1/device"
  mkdir -p "$dev/hwmon/hwmon3"
  echo 54000 > "$dev/hwmon/hwmon3/temp1_input"
  echo 37 > "$dev/gpu_busy_percent"
  echo 1073741824 > "$dev/mem_info_vram_used"
  echo 15000000 > "$dev/hwmon/hwmon3/power1_average"
  echo 17163091968 > "$dev/mem_info_vram_total"
  echo 120000000 > "$dev/hwmon/hwmon3/power1_cap"

  run_script get-gpu-stats
  assert_success
  run json_fields
  assert_success
  assert_output "$(printf '%s\n' 'power=15W' 'power_limit_w=120' 'power_w=15' 'temp=54°C' 'temp_c=54' \
    'util=37%' 'util_pct=37' 'vendor=amd' 'vram=1024MB' 'vram_mb=1024' 'vram_total_mb=16368')"
}

@test "amd: unreadable sysfs values are null, string keys still zero" {
  set_lsmod amdgpu
  mkdir -p "$ROOT/sys/class/drm/card1/device/hwmon/hwmon3"
  run_script get-gpu-stats
  assert_success
  run json_fields
  assert_success
  assert_line "temp=0°C"
  assert_line "vram=0MB"
  assert_numerics_null
}

@test "amd without power1_average: falls back to power1_input" {
  set_lsmod amdgpu
  mkdir -p "$ROOT/sys/class/drm/card1/device/hwmon/hwmon3"
  echo 22000000 > "$ROOT/sys/class/drm/card1/device/hwmon/hwmon3/power1_input"
  run_script get-gpu-stats
  run json_fields
  assert_line "power=22W"
}

@test "none: vendor none, valid JSON" {
  set_lsmod none
  run_script get-gpu-stats
  assert_success
  run json_fields
  assert_success
  assert_output "vendor=none"
}
