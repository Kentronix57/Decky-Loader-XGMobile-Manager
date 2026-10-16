# shellcheck shell=bash
# Scripted timelines for the user-session shims (systemctl, loginctl, sleep). Time is counted in
# ticks: every `sleep` call is one tick ($SHIM_STATE/ticks). A timeline is a file
# $SHIM_STATE/timeline/<key> with one "<tick> <value>" line per change, in tick order; the value
# at tick t is the one on the last line with a tick <= t. Keys (see helpers/sandbox.bash timeline):
#   manager   user@64999.service ActiveState (default active)
#   sessions  the login sessions, "<id>:<class>:<state>[:<user>] ..." (default 2:user:active)
#   rundir    present|absent: $ROOT/run/user/64999
#   bus       present|absent: $ROOT/run/user/64999/bus
#   graphical the user manager's graphical-session.target (default: $SHIM_STATE/session_ready)
#   jobs      the number of jobs queued in the user manager (default 0)

tl_tick() { cat "$SHIM_STATE/ticks" 2>/dev/null || echo 0; }

# tl_value <key> <default>: the key's value now.
tl_value() {
  local file="$SHIM_STATE/timeline/$1"
  if [ ! -e "$file" ]; then
    echo "$2"
    return 0
  fi
  awk -v t="$(tl_tick)" -v d="$2" '$1 <= t { v = $0; sub(/^[^ ]+ ?/, "", v); found = 1 } END { print (found ? v : d) }' "$file"
}

# tl_advance: one tick passes.
tl_advance() { echo $(($(tl_tick) + 1)) > "$SHIM_STATE/ticks"; }

# tl_apply_fs <root>: makes the runtime dir and the bus socket match their timelines.
tl_apply_fs() {
  local dir="$1/run/user/64999"
  case "$(tl_value rundir "")" in
    present) mkdir -p "$dir" ;;
    absent) rm -rf "$dir" ;;
  esac
  case "$(tl_value bus "")" in
    present) mkdir -p "$dir" && touch "$dir/bus" ;;
    absent) rm -f "$dir/bus" ;;
  esac
}

# tl_restart <key> <follow-up file>: from now on, the key follows the follow-up file's
# "<ticks from now> <value>" lines (a kill replaces what was scripted). Without one, it ends inactive.
tl_restart() {
  local t file="$SHIM_STATE/timeline/$1"
  t=$(tl_tick)
  mkdir -p "$SHIM_STATE/timeline"
  if [ -e "$2" ]; then
    awk -v t="$t" '{ $1 = $1 + t; print }' "$2" > "$file"
  else
    echo "$t inactive" > "$file"
  fi
}
