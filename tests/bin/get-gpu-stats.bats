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

@test "nvidia: nvidia-smi values in valid JSON" {
  set_lsmod nvidia
  cat > "$ROOT/usr/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --query-gpu=temperature.gpu) echo 61 ;;
  --query-gpu=utilization.gpu) echo 87 ;;
  --query-gpu=memory.used) echo 5120 ;;
  --query-gpu=power.draw) echo 142.30 ;;
esac
EOF
  chmod +x "$ROOT/usr/bin/nvidia-smi"

  run_script get-gpu-stats
  assert_success
  run json_fields
  assert_success
  assert_output "$(printf '%s\n' 'power=142.30W' 'temp=61°C' 'util=87%' 'vendor=nvidia' 'vram=5120MB')"
}

@test "nvidia without nvidia-smi: zeros, still valid JSON" {
  set_lsmod nvidia
  run_script get-gpu-stats
  assert_success
  run json_fields
  assert_success
  assert_line "vendor=nvidia"
  assert_line "temp=0°C"
}

@test "amd: sysfs values converted, valid JSON" {
  set_lsmod amdgpu
  local dev="$ROOT/sys/class/drm/card1/device"
  mkdir -p "$dev/hwmon/hwmon3"
  echo 54000 > "$dev/hwmon/hwmon3/temp1_input"
  echo 37 > "$dev/gpu_busy_percent"
  echo 1073741824 > "$dev/mem_info_vram_used"
  echo 15000000 > "$dev/hwmon/hwmon3/power1_average"

  run_script get-gpu-stats
  assert_success
  run json_fields
  assert_success
  assert_output "$(printf '%s\n' 'power=15W' 'temp=54°C' 'util=37%' 'vendor=amd' 'vram=1024MB')"
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
