# shellcheck shell=bash
# Scripted timelines for the user-session shims (systemctl, loginctl, sleep). Time is counted in
# ticks: every `sleep` call is one tick ($SHIM_STATE/ticks). A timeline is a file
# $SHIM_STATE/timeline/<key> with one "<tick> <value>" line per change, in tick order; the value
# at tick t is the one on the last line with a tick <= t. Keys (see helpers/sandbox.bash timeline):
#   manager   user@64999.service as "<ActiveState>[:<InvocationID>]" (default active; the ID
#             defaults to inv0; inactive and failed keep the last ID, as systemd does, or
#             nothing if it never ran)
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

# tl_manager_state / tl_manager_id: the user manager's ActiveState and InvocationID now.
tl_manager_state() { local v; v=$(tl_value manager active); echo "${v%%:*}"; }
tl_manager_id() {
  local file="$SHIM_STATE/timeline/manager"
  [ -e "$file" ] || { echo inv0; return 0; }
  # The ID before a tl_restart (kill/stop) carries over into the follow-up timeline.
  awk -v t="$(tl_tick)" -v last="$(cat "$SHIM_STATE/manager_last_id" 2>/dev/null)" '
    $1 <= t {
      found = 1; s = $2; sub(/:.*/, "", s)
      if ($2 ~ /:/) { last = $2; sub(/^[^:]*:/, "", last) }
      else if (s != "inactive" && s != "failed") last = "inv0"
    }
    END { print (found ? last : "inv0") }' "$file"
}

# tl_manager_env_exit: the environments of a stopped or killed manager ($SHIM_STATE/env_drop_on_exit
# holds its ID) go once it's inactive or failed, or replaced; the next one starts clean.
tl_manager_env_exit() {
  local old
  [ -e "$SHIM_STATE/env_drop_on_exit" ] || return 0
  old=$(cat "$SHIM_STATE/env_drop_on_exit")
  case "$(tl_manager_state)" in
    inactive|failed) ;;
    *) [ "$(tl_manager_id)" != "$old" ] || return 0 ;;
  esac
  rm -f "$SHIM_STATE/env/user" "$SHIM_STATE/env/user_initial" "$SHIM_STATE/env_drop_on_exit"
}

# tl_manager_event <event>: the manager follows timeline/manager.after_<event> from now on, if set.
tl_manager_event() {
  [ -e "$SHIM_STATE/timeline/manager.after_$1" ] && tl_restart manager "$SHIM_STATE/timeline/manager.after_$1"
  return 0
}

# tl_advance: one tick passes.
tl_advance() { echo $(($(tl_tick) + 1)) > "$SHIM_STATE/ticks"; }

# tl_clock_add <seconds>: moves the fake wall clock ($XGM_FAKE_CLOCK, read by _xgm_now in
# bin/xgm-common.sh) forward. Ticks order the timelines; the clock is what the waits measure.
tl_clock_add() {
  [ -n "${XGM_FAKE_CLOCK:-}" ] && [ -f "$XGM_FAKE_CLOCK" ] || return 0
  awk -v a="$(cat "$XGM_FAKE_CLOCK")" -v b="$1" 'BEGIN { printf "%.6f\n", a + b }' > "$XGM_FAKE_CLOCK.new"
  mv "$XGM_FAKE_CLOCK.new" "$XGM_FAKE_CLOCK"
}

# tl_clock_steps: applies the clock steps (clock_step) set for the current tick.
tl_clock_steps() {
  local tick delta
  [ -e "$SHIM_STATE/clock_steps" ] || return 0
  while read -r tick delta; do
    [ "$tick" = "$(tl_tick)" ] && tl_clock_add "$delta"
  done < "$SHIM_STATE/clock_steps"
}

# tl_apply_fs <root>: makes the runtime dir and the bus socket match their timelines.
tl_apply_fs() {
  local dir="$1/run/user/64999"
  case "$(tl_value rundir "")" in
    present) mkdir -p "$dir" ;;
    absent) rm -rf "$dir" ;;
  esac
  case "$(tl_value bus "")" in
    # A real socket (make_root's template), for the scripts' -S checks.
    present) mkdir -p "$dir" && { ln -f "$SHIM_STATE/bus.sock" "$dir/bus" 2>/dev/null || touch "$dir/bus"; } ;;
    absent) rm -f "$dir/bus" ;;
  esac
}

# tl_restart <key> <follow-up file>: from now on, the key follows the follow-up file's
# "<ticks from now> <value>" lines (a kill replaces what was scripted). Without one, it ends inactive.
tl_restart() {
  local t file="$SHIM_STATE/timeline/$1"
  t=$(tl_tick)
  mkdir -p "$SHIM_STATE/timeline"
  [ "$1" = "manager" ] && tl_manager_id > "$SHIM_STATE/manager_last_id"
  if [ -e "$2" ]; then
    awk -v t="$t" '{ $1 = $1 + t; print }' "$2" > "$file"
  else
    echo "$t inactive" > "$file"
  fi
}
