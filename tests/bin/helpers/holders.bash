# shellcheck shell=bash
# The fake processes holding the eGPU nodes, shared by shims/fuser, shims/kill and shims/systemctl.
#   $SHIM_STATE/gpu_holders      the session holder, PID 4242 (gpu_holders in helpers/sandbox.bash)
#   $SHIM_STATE/service_holders  system service holders, one "<pid> <unit>" per line
#                                (gpu_service_holder): they hold until their unit is stopped or
#                                the PID is signalled.

HOLDERS_STATE="$SHIM_STATE/gpu_holders"
SERVICE_HOLDERS="$SHIM_STATE/service_holders"

# hl_session_signal <TERM|KILL>: the session holder gets the signal.
hl_session_signal() {
  case "$(cat "$HOLDERS_STATE" 2>/dev/null || echo 0)" in
    unkillable) ;;
    ignore-term) [ "$1" = "KILL" ] && echo 0 > "$HOLDERS_STATE" ;;
    *) echo 0 > "$HOLDERS_STATE" ;;
  esac
  return 0
}

# The service holders, "<pid> <unit>" per line.
hl_services() { cat "$SERVICE_HOLDERS" 2>/dev/null || true; }

# hl_service_drop <field> <value>: removes the service holders whose pid (field 1) or unit
# (field 2) equals the value.
hl_service_drop() {
  [ -e "$SERVICE_HOLDERS" ] || return 0
  awk -v f="$1" -v v="$2" '$f != v' "$SERVICE_HOLDERS" > "$SERVICE_HOLDERS.new"
  mv "$SERVICE_HOLDERS.new" "$SERVICE_HOLDERS"
}

# hl_is_service_pid <pid>
hl_is_service_pid() { hl_services | awk -v p="$1" '$1 == p { found = 1 } END { exit !found }'; }
