#!/bin/bash
# Shared helpers for the bin/ scripts. Source it, don't run it, and fail fast (exit 9, catalogued
# in main.py) before touching anything if it's missing:
#   . "$(dirname "$(readlink -f "$0")")/xgm-common.sh" || { echo "ERROR: ..."; exit 9; }
# Only defines functions and constants; sourcing it has no side effects.
ROOT="${XGM_ROOT:-}"

# The display-manager unit: sddm on SteamOS/Bazzite, plasmalogin on CachyOS Handheld.
# Resolved from the display-manager.service alias, but only known units are accepted, and only if
# the alias target exists. Anything else falls back to sddm.service (the pre-alias behavior) with
# a warning on stderr. Other display managers (gdm, lightdm, greetd) stay on the fallback until a
# community tester has verified enable/eject with them; then add them to the case below.
xgm_dm_service() {
  local alias="$ROOT/etc/systemd/system/display-manager.service" target unit
  if [ ! -L "$alias" ] && [ ! -e "$alias" ]; then
    echo "sddm.service"
    return 0
  fi
  target=$(readlink -f "$alias" 2>/dev/null)
  unit=$(basename "$target" 2>/dev/null)
  case "$unit" in
    sddm.service|plasmalogin.service)
      if [ -e "$target" ]; then
        echo "$unit"
        return 0
      fi
      ;;
  esac
  echo "WARNING: unrecognized display manager '$unit', using sddm.service" >&2
  echo "sddm.service"
}

# steamos-readonly only exists on SteamOS; elsewhere these do nothing.
xgm_ro_disable() {
  if command -v steamos-readonly >/dev/null 2>&1; then
    steamos-readonly disable
  fi
}

xgm_ro_enable() {
  if command -v steamos-readonly >/dev/null 2>&1; then
    steamos-readonly enable
  fi
}

# The user whose session the plugin configures: the owner of the Steam process; when Steam isn't
# running (e.g. at boot), the first regular user (uid 1000-65533) with a home dir; else "deck".
xgm_primary_user() {
  local user candidate
  user=$(ps -o user= -C steam | head -n 1 | xargs)
  if [ -z "$user" ]; then
    for candidate in $(awk -F: '$3 >= 1000 && $3 < 65534 { print $1 }' "$ROOT/etc/passwd" 2>/dev/null); do
      if [ -d "$ROOT/home/$candidate" ]; then
        user="$candidate"
        break
      fi
    done
  fi
  echo "${user:-deck}"
}

# The plugin's log folder: the activity/ subfolder of the one Decky uses for
# DECKY_PLUGIN_LOG_DIR, <homebrew>/logs/<plugin folder name>/activity (Decky deletes all but the
# newest 4 *.log files at its top level on every plugin load). Resolved from this file's location
# (<homebrew>/plugins/<plugin>/bin), for callers that don't get a log dir (egpu-sync at boot).
xgm_log_dir() {
  local plugin
  plugin=$(readlink -m "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/..")
  readlink -m "$plugin/../../logs/$(basename "$plugin")/activity"
}

# The host OS, with the same rules as main.py get_os_type: steamos | cachyos | bazzite |
# bazzite-nvidia | unsupported. For callers that don't get the OS as an argument (egpu-sync at boot).
xgm_os_type() {
  local data
  data=$(tr '[:upper:]' '[:lower:]' < "$ROOT/etc/os-release" 2>/dev/null) || { echo "unsupported"; return 0; }
  case "$data" in
    *bazzite*)
      if [[ "$data" == *nvidia* ]]; then echo "bazzite-nvidia"; else echo "bazzite"; fi ;;
    *cachyos*) echo "cachyos" ;;
    *steamos*) echo "steamos" ;;
    *) echo "unsupported" ;;
  esac
}

# Every variable egpu-enable injects on SteamOS/CachyOS (/etc/environment and systemctl
# set-environment). Keep in sync with egpu-enable.
XGM_ENV_VARS=(MESA_VK_DEVICE_SELECT VK_ICD_FILENAMES WLR_DRM_DEVICES VK_LOADER_LAYERS_DISABLE GAMESCOPE_DISABLE_VK_KHR_PRESENT_WAIT)

# xgm_egpu_env_names: reads `systemctl show-environment` output on stdin and prints the names of
# the eGPU variables in it: XGM_ENV_VARS and KWIN_DRM_DEVICES (from the xgmobile-*-kwin.sh Plasma
# env files, which Plasma imports into the user manager) whatever their value; GBM_BACKEND and
# __GLX_VENDOR_LIBRARY_NAME only with the values those files set, since other setups use them too.
xgm_egpu_env_names() {
  local line name value
  while IFS= read -r line; do
    name="${line%%=*}"
    value="${line#*=}"
    # show-environment shell-quotes values with special characters.
    value="${value#\$}"
    case "$value" in
      \"*\"|\'*\') value="${value:1:${#value}-2}" ;;
    esac
    case "$name" in
      KWIN_DRM_DEVICES) ;;
      GBM_BACKEND) [ "$value" = "nvidia-drm" ] || continue ;;
      __GLX_VENDOR_LIBRARY_NAME) [ "$value" = "nvidia" ] || continue ;;
      *) [[ " ${XGM_ENV_VARS[*]} " == *" $name "* ]] || continue ;;
    esac
    echo "$name"
  done
}

# _xgm_user_systemctl <user> <uid> <systemctl args...>: runs `systemctl --user` against that user's
# manager as the user. setpriv, not sudo/runuser: their PAM stacks can open a logind session, which
# would keep a stopping user manager alive. Without setpriv, falls back to the sudo form used
# before (_xgm_check_setpriv logs that). Killed after 2 s, so a hung manager can't block the caller.
_xgm_user_systemctl() {
  local user="$1" uid="$2" gid
  shift 2
  if command -v setpriv >/dev/null 2>&1; then
    gid=$(id -g "$user" 2>/dev/null)
    timeout -s KILL 2 setpriv --reuid="$uid" --regid="${gid:-$uid}" --init-groups \
      env XDG_RUNTIME_DIR="$ROOT/run/user/$uid" systemctl --user "$@"
  else
    # The inner timeout also bounds systemctl if the outer one only kills sudo.
    timeout -s KILL 2 sudo -u "$user" XDG_RUNTIME_DIR=/run/user/$uid timeout -s KILL 2 systemctl --user "$@"
  fi
}

# _xgm_check_setpriv: logs, once per run, that setpriv is missing (_xgm_user_systemctl then uses
# sudo). Call it outside $(...), where the log line would be captured instead.
_xgm_check_setpriv() {
  command -v setpriv >/dev/null 2>&1 && return 0
  [ -n "${_XGM_SETPRIV_LOGGED:-}" ] && return 0
  echo "setpriv not found; using sudo -u"
  _XGM_SETPRIV_LOGGED=1
}

# _xgm_manager <system|user> <user> <uid> <systemctl args...>: runs systemctl against the system
# manager, or against that user's manager as the user.
_xgm_manager() {
  local scope="$1" user="$2" uid="$3"
  shift 3
  if [ "$scope" = "system" ]; then
    systemctl "$@"
  else
    _xgm_user_systemctl "$user" "$uid" "$@"
  fi
}

# _xgm_manager_egpu_vars <system|user> <user> <uid>: the eGPU variables in that manager as
# "<names>", "none", or "unknown (...)" if its environment can't be read.
_xgm_manager_egpu_vars() {
  local out names
  if ! out=$(_xgm_manager "$@" show-environment 2>&1); then
    echo "unknown (couldn't read it: $(head -n 1 <<< "$out"))"
    return 0
  fi
  names=$(xgm_egpu_env_names <<< "$out" | xargs)
  echo "${names:-none}"
}

# _xgm_clean_manager <system|user> <user> <uid>: logs the eGPU variables in that manager, unsets
# them, and logs what's left. The variables that are always ours are unset even when the
# environment can't be read; GBM_BACKEND and __GLX_VENDOR_LIBRARY_NAME only when seen with our values.
_xgm_clean_manager() {
  local found var
  found=$(_xgm_manager_egpu_vars "$@")
  echo "eGPU variables found in $1 manager: $found"
  for var in "${XGM_ENV_VARS[@]}" KWIN_DRM_DEVICES; do
    if [[ "$found" == unknown* ]]; then
      # The manager doesn't answer; the line above already says so, once.
      _xgm_manager "$@" unset-environment "$var" 2>/dev/null
    else
      _xgm_manager "$@" unset-environment "$var"
    fi
  done
  for var in GBM_BACKEND __GLX_VENDOR_LIBRARY_NAME; do
    [[ " $found " == *" $var "* ]] && _xgm_manager "$@" unset-environment "$var"
  done
  echo "eGPU variables left in $1 manager: $(_xgm_manager_egpu_vars "$@")"
}

# _xgm_cs <seconds>: seconds (0.25) as whole centiseconds, at least 1. _xgm_secs <cs>: back as "0.25".
_xgm_cs() { awk -v s="$1" 'BEGIN { c = int(s * 100 + 0.5); print (c < 1 ? 1 : c) }'; }
_xgm_secs() { printf '%d.%02d' $(($1 / 100)) $(($1 % 100)); }

# _xgm_now: the wall clock in seconds with a fraction ($EPOCHREALTIME, else date). The waits use
# it, not poll counts: a single check can take seconds when the user manager is hung. Tests point
# XGM_FAKE_CLOCK at a file that the sleep shim advances.
_xgm_now() {
  if [ -n "${XGM_FAKE_CLOCK:-}" ] && [ -f "$XGM_FAKE_CLOCK" ]; then
    cat "$XGM_FAKE_CLOCK"
  elif [ -n "${EPOCHREALTIME:-}" ]; then
    echo "${EPOCHREALTIME/,/.}"
  else
    date +%s.%N
  fi
}

# _xgm_now_cs: _xgm_now in whole centiseconds.
_xgm_now_cs() {
  local t frac
  t=$(_xgm_now)
  frac=00
  if [[ "$t" == *.* ]]; then
    frac="${t#*.}00"
    t="${t%%.*}"
  fi
  echo $((10#${t:-0} * 100 + 10#${frac:0:2}))
}

# _xgm_since <cs>: centiseconds from <cs> (an _xgm_now_cs value) to now, never negative.
_xgm_since() {
  local d=$(($(_xgm_now_cs) - $1))
  echo $((d < 0 ? 0 : d))
}

# _xgm_new_user_session <user> <known ids>: prints the ID of a login session of that user with
# Class=user and State active or online that isn't in <known ids> (space-separated; empty: any
# counts). The user manager's own session (Class=manager), greeter and lock-screen sessions, and
# sessions still listed as closing don't count. Fails if there's none.
_xgm_new_user_session() {
  local user="$1" known=" $2 " id props
  for id in $(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$user" '$3 == u { print $1 }'); do
    [ -n "${known// }" ] && [[ "$known" == *" $id "* ]] && continue
    props=$(loginctl show-session "$id" -p Class -p State 2>/dev/null)
    grep -qx "Class=user" <<< "$props" || continue
    grep -qxE "State=(active|online)" <<< "$props" || continue
    echo "$id"
    return 0
  done
  return 1
}

# _xgm_manager_state <uid>: user@<uid>.service's ActiveState and InvocationID, as "<state> <id>".
_xgm_manager_state() {
  systemctl show -p ActiveState -p InvocationID "user@$1.service" 2>/dev/null \
    | awk -F= '$1 == "ActiveState" { s = $2 } $1 == "InvocationID" { i = $2 } END { print s, i }'
}

# _xgm_still_stopping <uid> <invocation id> <what>: succeeds if the user manager that was seen
# stopping (that invocation) is still the one there and still deactivating. Otherwise logs that
# <what> won't be killed: a new user manager must never be.
# The few-ms window between this check and the kill can't be closed from shell: systemctl kill has
# no invocation-conditional form, the cgroup path is reused by the next user@<uid>, and there's no
# pidfd; killing only MainPID would leave the stuck fusermount3 child behind.
_xgm_still_stopping() {
  local state id
  read -r state id < <(_xgm_manager_state "$1")
  [ "$state" = "deactivating" ] && [ "$id" = "$2" ] && return 0
  echo "old user manager gone; not killing $3"
  return 1
}

# _xgm_end_stuck_units <user> <uid> <invocation id>: unmounts the document portal's FUSE mount (a
# fusermount3 child of xdg-document-portal kept the old manager stopping for 90 s) and kills every
# unit the stopping user manager still has in "deactivating". Rechecks before each action that
# it's still that manager; stops (and fails) as soon as it isn't.
_xgm_end_stuck_units() {
  local user="$1" uid="$2" id="$3" doc="$ROOT/run/user/$2/doc" unit
  if findmnt -n "$doc" >/dev/null 2>&1; then
    _xgm_still_stopping "$uid" "$id" "$doc" || return 1
    timeout -s KILL 2 fusermount3 -uz "$doc"
  fi
  for unit in $(_xgm_user_systemctl "$user" "$uid" list-units --state=deactivating --no-legend --plain 2>/dev/null | awk '{ print $1 }'); do
    _xgm_still_stopping "$uid" "$id" "$unit" || return 1
    if _xgm_user_systemctl "$user" "$uid" kill -s KILL -- "$unit"; then
      echo "killed stuck unit: $unit"
    else
      echo "couldn't kill stuck unit: $unit"
    fi
  done
}

# _xgm_clock_read [slept cs]: sets now for xgm_wait_for_user_session and
# xgm_restart_dirty_user_manager, whose locals it shares (bash's dynamic scope): start, last,
# deact_since and step1_at. If the clock shows less time
# since the last reading than certainly passed (the poll just slept; NTP stepped the clock back),
# those reference times move back by the difference, so the time already waited still counts.
_xgm_clock_read() {
  local d
  now=$(_xgm_now_cs)
  d=$((last + ${1:-0} - now))
  if [ "$d" -gt 0 ]; then
    start=$((start - d))
    [ "$deact_since" -ge 0 ] && deact_since=$((deact_since - d))
    [ "$step1_at" -ge 0 ] && step1_at=$((step1_at - d))
  fi
  last=$now
}

# _xgm_end_hung_manager <user> <uid> <state> <invocation id>: one step of the hung-manager
# escalation, for the user manager state just read. If that manager (its InvocationID) has been
# stopping for XGM_HUNG_AFTER s, its stuck units are killed; if it's still stopping XGM_HUNG_AFTER s
# later, the manager itself. Both recheck that it's still that manager first. Another manager (or
# none) gets a fresh XGM_HUNG_AFTER. Shares the caller's locals (bash's dynamic scope): now,
# hung_cs, deact_since, step1_at, step2 and hung_id (and _xgm_clock_read's).
_xgm_end_hung_manager() {
  local user="$1" uid="$2" state="$3" id="$4"
  if [ "$id" != "$hung_id" ]; then
    # Another manager (or none): it gets its own XGM_HUNG_AFTER.
    deact_since=-1 step1_at=-1 step2=0 hung_id=""
  fi
  if [ "$state" = "deactivating" ]; then
    # Measured from the first time it was seen stopping, and from the end of step 1.
    if [ "$deact_since" -lt 0 ]; then
      deact_since=$now
      hung_id="$id"
    fi
    if [ "$step1_at" -lt 0 ] && [ $((now - deact_since)) -ge "$hung_cs" ]; then
      echo "old user manager still stopping after $(_xgm_secs $((now - deact_since)))s; ending its stuck units"
      _xgm_end_stuck_units "$user" "$uid" "$hung_id"
      _xgm_clock_read
      step1_at=$now
    elif [ "$step1_at" -ge 0 ] && [ "$step2" -eq 0 ] && [ $((now - step1_at)) -ge "$hung_cs" ]; then
      step2=1
      if _xgm_still_stopping "$uid" "$hung_id" "user@$uid.service"; then
        echo "old user manager still stopping; killing it"
        systemctl kill -s KILL "user@$uid.service"
      fi
    fi
  else
    deact_since=-1
  fi
}

# xgm_wait_for_user_session <user> [known session ids]: waits until the user's new graphical
# session is usable, so that a Plasma session that imports its environment into the user manager
# has done it before the cleanup, and steamos-session-select finds a user bus. Ready means all of:
#   1. a new login session (see _xgm_new_user_session; <known ids> are the ones from before eject)
#   2. user@<uid>.service active
#   3. the user bus socket exists
#   4. graphical-session.target active in the user manager
#   5. no jobs queued in the user manager
# Checks every XGM_WAIT_POLL s (0.25) for up to XGM_WAIT_CAP s (60) of wall-clock time (_xgm_now).
# A missing runtime dir or a manager that doesn't answer only means "not yet": the eject stopped
# the display manager, and logind removes the old user manager seconds later. If the old manager
# is stuck stopping for XGM_HUNG_AFTER s (5), its stuck units are killed; if it's still stopping
# XGM_HUNG_AFTER s later, the manager itself. Only that manager (its InvocationID): a new one gets a
# fresh XGM_HUNG_AFTER. Logs how long it took, or what was still missing.
# Always returns 0: the caller cleans anyway.
xgm_wait_for_user_session() {
  local user="$1" known="${2:-}" uid poll poll_cs cap cap_cs hung_cs start now last slept=0
  local deact_since=-1 step1_at=-1 step2=0 state id hung_id="" session target jobs missing
  uid=$(id -u "$user" 2>/dev/null)
  [ -n "$uid" ] || return 0
  _xgm_check_setpriv
  poll="${XGM_WAIT_POLL:-0.25}"
  cap="${XGM_WAIT_CAP:-60}"
  poll_cs=$(_xgm_cs "$poll")
  cap_cs=$(_xgm_cs "$cap")
  hung_cs=$(_xgm_cs "${XGM_HUNG_AFTER:-5}")
  start=$(_xgm_now_cs)
  last=$start
  while :; do
    read -r state id < <(_xgm_manager_state "$uid")
    _xgm_clock_read "$slept"
    slept=0
    _xgm_end_hung_manager "$user" "$uid" "$state" "$id"

    if ! session=$(_xgm_new_user_session "$user" "$known"); then
      missing="no new user session for $user"
    elif [ "$state" != "active" ]; then
      missing="user@$uid.service is ${state:-unknown}"
    elif [ ! -e "$ROOT/run/user/$uid/bus" ]; then
      missing="no $ROOT/run/user/$uid/bus"
    elif ! target=$(_xgm_user_systemctl "$user" "$uid" is-active graphical-session.target 2>/dev/null); then
      missing="graphical-session.target is ${target:-not answering}"
    elif ! jobs=$(_xgm_user_systemctl "$user" "$uid" list-jobs --no-legend 2>/dev/null) || [ -n "$jobs" ]; then
      missing="the user manager has jobs queued"
    else
      _xgm_clock_read
      echo "user session ready after $(_xgm_secs $((now - start)))s (session $session)"
      return 0
    fi
    _xgm_clock_read
    if [ $((now - start)) -ge "$cap_cs" ]; then
      echo "user session not ready after ${cap}s ($missing), continuing anyway"
      return 0
    fi
    sleep "$poll"
    slept=$poll_cs
  done
}

# xgm_restart_dirty_user_manager <user>: stops that user's systemd manager if it still holds eGPU
# variables after the cleanup. A manager that started while /etc/environment had them (a boot with
# the eGPU active) keeps them in its initial environment, which unset-environment and daemon-reload
# can't remove; if the display manager starts again within logind's UserStopDelay (10 s), or
# another login (SSH) is open, that manager survives the eject and the next Game Mode session
# inherits them. Stopped with --no-block and not started again: logind starts a fresh one, from
# the clean /etc/environment, at the next login. SSH shells live in their session scopes, not in
# user@<uid>.service, so they survive. A manager that isn't active, or is clean, is left alone; one
# whose environment can't be read is stopped, since it can't be proven clean.
# Waits until that manager (its InvocationID) is gone, for up to XGM_RESTART_CAP s (15) of wall-clock
# time, checking every XGM_WAIT_POLL s (0.25), with the same hung-manager escalation as
# xgm_wait_for_user_session. Always returns 0: the eject must go on to start the display manager.
xgm_restart_dirty_user_manager() {
  local user="$1" uid vars old_id poll poll_cs cap cap_cs hung_cs start now last slept=0
  local deact_since=-1 step1_at=-1 step2=0 state id hung_id=""
  uid=$(id -u "$user" 2>/dev/null)
  [ -n "$uid" ] || return 0
  read -r state old_id < <(_xgm_manager_state "$uid")
  [ "$state" = "active" ] || return 0
  _xgm_check_setpriv
  vars=$(_xgm_manager_egpu_vars user "$user" "$uid")
  [ "$vars" = "none" ] && return 0
  echo "eGPU variables can't be removed from the running user manager (it started with them): $vars; restarting it so the next login starts clean"
  systemctl stop --no-block "user@$uid.service"
  poll="${XGM_WAIT_POLL:-0.25}"
  cap="${XGM_RESTART_CAP:-15}"
  poll_cs=$(_xgm_cs "$poll")
  cap_cs=$(_xgm_cs "$cap")
  hung_cs=$(_xgm_cs "${XGM_HUNG_AFTER:-5}")
  start=$(_xgm_now_cs)
  last=$start
  while :; do
    read -r state id < <(_xgm_manager_state "$uid")
    _xgm_clock_read "$slept"
    slept=0
    if [ "$id" != "$old_id" ] || [ "$state" = "inactive" ] || [ "$state" = "failed" ]; then
      echo "old user manager stopped after $(_xgm_secs $((now - start)))s"
      return 0
    fi
    _xgm_end_hung_manager "$user" "$uid" "$state" "$id"
    _xgm_clock_read
    if [ $((now - start)) -ge "$cap_cs" ]; then
      echo "user manager still running after ${cap}s; continuing (a reboot clears the eGPU variables)"
      return 0
    fi
    sleep "$poll"
    slept=$poll_cs
  done
}

# xgm_clean_session_env <user>: unsets the eGPU variables in the system manager and in that user's
# manager (no files), logging what each held before and after. A user manager that isn't running
# (no runtime dir: no session yet, or the display manager is stopped) or is stopping is logged, not
# skipped silently.
xgm_clean_session_env() {
  local user="$1" uid
  _xgm_clean_manager system "" ""
  uid=$(id -u "$user" 2>/dev/null)
  if [ -z "$uid" ]; then
    echo "eGPU variables left in user manager: not checked (no user '$user')"
  elif [ ! -d "$ROOT/run/user/$uid" ]; then
    echo "eGPU variables left in user manager: not checked (the user manager for $user isn't running: no $ROOT/run/user/$uid)"
  elif [ "$(systemctl show -p ActiveState --value "user@$uid.service" 2>/dev/null)" = "deactivating" ]; then
    echo "eGPU variables left in user manager: not checked (the user manager for $user is stopping; its environment won't carry over)"
  else
    _xgm_check_setpriv
    _xgm_clean_manager user "$user" "$uid"
  fi
}

# Undoes everything egpu-enable injects on SteamOS/CachyOS: the variables in /etc/environment,
# the system and user systemd managers (xgm_clean_session_env), the Plasma env files and
# nvidia-egpu.conf.
xgm_sanitize_environment() {
  local user="$1" var left
  echo "Sanitizing the eGPU environment..."
  for var in "${XGM_ENV_VARS[@]}"; do
    sed -i "/^$var=/d" "$ROOT/etc/environment"
  done
  left=$(for var in "${XGM_ENV_VARS[@]}"; do grep -q "^$var=" "$ROOT/etc/environment" 2>/dev/null && echo "$var"; done | xargs)
  echo "eGPU variables left in /etc/environment: ${left:-none}"
  xgm_clean_session_env "$user"
  rm -f "$ROOT/home/$user/.config/plasma-workspace/env/xgmobile-kwin.sh"
  rm -f "$ROOT/home/$user/.config/plasma-workspace/env/xgmobile-nvidia-kwin.sh"
  rm -f "$ROOT/etc/modprobe.d/nvidia-egpu.conf"
}

# xgm_write_egpu_enable <0|1> <path>: switches the eGPU off/on through asus-nb-wmi's egpu_enable.
# The write often fails with "Input/output error" even when the switch works, so the shell's
# error is dropped and one friendly line logged instead; the caller's bus check decides success.
xgm_write_egpu_enable() {
  { echo "$1" > "$2"; } 2>/dev/null && return 0
  if [ "$1" = "1" ]; then
    echo "asus-nb-wmi reported an error switching the eGPU on (usually harmless); checking for the eGPU..."
  else
    echo "asus-nb-wmi reported an error switching the eGPU off (usually harmless); checking that the eGPU dropped..."
  fi
  return 0
}

# xgm_egpu_pci_paths <data_dir> [strict]: the eGPU's PCI device dir(s) in sysfs, one per line,
# resolved in this order:
#   1. the PCI address egpu-enable recorded in <data_dir>/egpu_pci_address, if that device exists
#      and is a display controller (PCI class 0x03....)
#   2. the display controller(s) that aren't the boot VGA device (boot_vga != 1); read from the PCI
#      bus, not the DRM cards, so it works before a driver is bound (early boot)
#   3. nothing
# With "strict" (the boot safety net), a well-formed record is final: if its device is gone or
# isn't a display controller, the eGPU is absent and step 2 is skipped. On a Flow laptop step 2
# would find the internal dGPU instead.
# DRM card numbers change between boots; the PCI address of the XG Mobile slot doesn't.
xgm_egpu_pci_paths() {
  local addr dev
  addr=$(cat "$1/egpu_pci_address" 2>/dev/null)
  if [[ "$addr" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]]; then
    if [[ "$(cat "$ROOT/sys/bus/pci/devices/$addr/class" 2>/dev/null)" == 0x03* ]]; then
      readlink -f "$ROOT/sys/bus/pci/devices/$addr"
      return 0
    fi
    [ "${2:-}" = "strict" ] && return 0
  fi
  for dev in $ROOT/sys/bus/pci/devices/*; do
    [[ "$(cat "$dev/class" 2>/dev/null)" == 0x03* ]] || continue
    [ "$(cat "$dev/boot_vga" 2>/dev/null)" = "1" ] && continue
    readlink -f "$dev"
  done
}

# xgm_drm_nodes <pci dir> [card|renderD]: the DRM node names (card0, renderD129...) that belong to
# that PCI device, matched through each sys/class/drm entry's device link. Never assumes numbers.
xgm_drm_nodes() {
  local entry name
  for entry in $ROOT/sys/class/drm/${2:-}*; do
    name=$(basename "$entry")
    [[ "$name" =~ ^(card|renderD)[0-9]+$ ]] || continue
    [ "$(readlink -f "$entry/device" 2>/dev/null)" = "$1" ] && echo "$name"
  done
}

# xgm_fb_nodes <pci dir>: the framebuffer devices (fb0, fb1...) that belong to that PCI device,
# matched through each sys/class/graphics entry's device link.
xgm_fb_nodes() {
  local entry name target
  for entry in $ROOT/sys/class/graphics/fb*; do
    name=$(basename "$entry")
    [[ "$name" =~ ^fb[0-9]+$ ]] || continue
    target=$(readlink -f "$entry/device" 2>/dev/null)
    if [ -n "$target" ] && { [ "$target" = "$1" ] || [[ "$target" == "$1"/* ]]; }; then
      echo "$name"
    fi
  done
}
