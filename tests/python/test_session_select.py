"""steamos-session-select arguments: the _session_select_calls table and the 3 call sites that use it."""
import json
import os
import subprocess
from types import SimpleNamespace

import pytest

from xgm_helpers import ACTION_RESULT_KEYS, STATIC

SESSION_SELECT = "/usr/bin/steamos-session-select"


@pytest.mark.parametrize("os_type,desktop_default,target,calls", [
  # CachyOS's steamos-session-select only knows persistent, oneshot, gamescope and plasma.
  ("cachyos", "0", "desktop", [["plasma"]]),
  ("cachyos", "1", "desktop", [["persistent"], ["plasma"]]),
  ("cachyos", "1", "gamescope", [["oneshot"], ["gamescope"]]),
  ("cachyos", "0", "gamescope", [["gamescope"]]),
  # Every other OS: exactly the strings the plugin sent before the helper existed.
  ("steamos", "0", "desktop", [["plasma-wayland"]]),
  ("steamos", "1", "desktop", [["plasma-wayland-persistent"]]),
  ("bazzite", "0", "desktop", [["plasma"]]),
  ("bazzite", "1", "desktop", [["plasma-wayland-persistent"]]),
  ("bazzite-nvidia", "0", "desktop", [["plasma"]]),
  ("bazzite-nvidia", "1", "desktop", [["plasma-wayland-persistent"]]),
  ("unsupported", "0", "desktop", [["plasma"]]),
  ("unsupported", "1", "desktop", [["plasma-wayland-persistent"]]),
  ("steamos", "0", "gamescope", [["gamescope"]]),
  ("steamos", "1", "gamescope", [["gamescope"]]),
  ("bazzite", "0", "gamescope", [["gamescope"]]),
  ("bazzite-nvidia", "1", "gamescope", [["gamescope"]]),
  ("unsupported", "1", "gamescope", [["gamescope"]]),
])
def test_session_select_calls_table(os_type, desktop_default, target, calls):
  assert STATIC._session_select_calls(os_type, desktop_default, target) == calls


class StopWatcher(Exception):
  """Raised by the fake asyncio.sleep to end a watcher's `while True` loop after one pass."""


class Calls(list):
  """The recorded argvs, plus what the fake `loginctl list-sessions` prints (loginctl_out)."""
  loginctl_out = ""


# `loginctl list-sessions --no-legend` as systemd 257 prints it: SESSION UID USER SEAT LEADER CLASS TTY IDLE SINCE.
LOGINCTL_OUT = (
  "2 64999 xgmtest - 1203 manager - no -\n"
  "5 64999 xgmtest seat0 1180 user tty2 no -\n"
  "c1 1001 other seat0 900 user tty3 no -\n"
)


@pytest.fixture
def session_env(xgm, monkeypatch):
  """
  Fakes everything the session-switch code touches outside the sandbox: the user lookup, the
  watcher request files in /tmp, asyncio.sleep, and subprocess.run (which records each argv and
  succeeds; `loginctl` prints calls.loginctl_out). Returns the recorded argvs (Calls).
  """
  mod = xgm.mod
  user = SimpleNamespace(pw_name="xgmtest", pw_dir="/nonexistent/xgmtest", pw_uid=64999)
  monkeypatch.setenv("DECKY_USER", "xgmtest")
  monkeypatch.setattr(mod.pwd, "getpwnam", lambda name: user)

  requests = {"/tmp/xgmobile_eject_request", "/tmp/xgmobile_enable_request"}
  pending = set(requests)
  real_exists = os.path.exists

  def fake_exists(path):
    if path in requests:
      return path in pending
    return real_exists(path)

  def fake_remove(path):
    assert path in requests, f"unexpected os.remove({path!r})"
    pending.discard(path)

  monkeypatch.setattr(mod.os.path, "exists", fake_exists)
  monkeypatch.setattr(mod.os, "remove", fake_remove)

  async def fake_sleep(seconds):
    if seconds == 2:  # the watcher's poll interval: one pass is enough
      raise StopWatcher()

  monkeypatch.setattr(mod.asyncio, "sleep", fake_sleep)

  calls = Calls()

  def fake_run(argv, **kwargs):
    calls.append(list(argv))
    stdout = calls.loginctl_out if argv[0] == "loginctl" else ""
    return subprocess.CompletedProcess(argv, 0, stdout=stdout, stderr="")

  monkeypatch.setattr(mod.subprocess, "run", fake_run)
  return calls


def session_selects(calls):
  """The steamos-session-select calls, as the arguments after the command, in order."""
  out = []
  for argv in calls:
    if SESSION_SELECT in argv:
      assert argv[:argv.index(SESSION_SELECT)] == ["sudo", "-E", "-u", "xgmtest"]
      out.append(argv[argv.index(SESSION_SELECT) + 1:])
  return out


def without_loginctl(calls):
  """The recorded argvs without the desktop Eject link's `loginctl list-sessions`."""
  return [argv for argv in calls if argv[0] != "loginctl"]


def run_watcher(xgm, coro):
  with pytest.raises(StopWatcher):
    xgm.run(coro)


@pytest.mark.parametrize("os_type,desktop_default,expected", [
  ("steamos", "0", [["plasma-wayland"]]),
  ("steamos", "1", [["plasma-wayland-persistent"]]),
  ("bazzite-nvidia", "0", [["plasma"]]),
  ("bazzite-nvidia", "1", [["plasma-wayland-persistent"]]),
  ("bazzite", "0", [["plasma"]]),
  ("unsupported", "1", [["plasma-wayland-persistent"]]),
  ("cachyos", "0", [["plasma"]]),
  ("cachyos", "1", [["persistent"], ["plasma"]]),
])
def test_trigger_desktop_mode_session_calls(xgm, session_env, os_type, desktop_default, expected):
  xgm.set_os(os_type)
  xgm.settings.setSetting("desktop_default", desktop_default)
  assert xgm.run(xgm.plugin.trigger_desktop_mode()) is True
  assert session_selects(session_env) == expected
  log = open(xgm.mod.TRANSITION_LOG).read()
  assert log.count("Command exited with code: 0") == len(expected)


# watch_enable_request hardcodes desktopdefault = "0", so the setting doesn't matter there.
@pytest.mark.parametrize("os_type,expected", [
  ("steamos", [["plasma-wayland"]]),
  ("bazzite-nvidia", [["plasma"]]),
  ("bazzite", [["plasma"]]),
  ("unsupported", [["plasma"]]),
  ("cachyos", [["plasma"]]),
])
@pytest.mark.parametrize("desktop_default", ["0", "1"])
def test_watch_enable_request_session_calls(xgm, session_env, os_type, expected, desktop_default):
  xgm.set_os(os_type)
  xgm.settings.setSetting("desktop_default", desktop_default)
  run_watcher(xgm, xgm.plugin.watch_enable_request())
  assert session_env[0][0].endswith("/bin/egpu-enable")
  assert session_selects(session_env) == expected
  log = open(xgm.mod.ENABLEDESKTOP_LOG).read()
  assert log.count("Transition Code: 0") == len(expected)


def test_watch_enable_request_failed_enable_skips_session_select(xgm, session_env, monkeypatch):
  xgm.set_os("cachyos")

  def failing_run(argv, **kwargs):
    session_env.append(list(argv))
    return subprocess.CompletedProcess(argv, 2, stdout="", stderr="")

  monkeypatch.setattr(xgm.mod.subprocess, "run", failing_run)
  run_watcher(xgm, xgm.plugin.watch_enable_request())
  assert session_selects(session_env) == []


@pytest.mark.parametrize("os_type,desktop_default,expected", [
  ("steamos", "0", [["gamescope"]]),
  ("steamos", "1", [["gamescope"]]),
  ("bazzite-nvidia", "1", [["gamescope"]]),
  ("bazzite", "0", [["gamescope"]]),
  ("unsupported", "1", [["gamescope"]]),
  ("cachyos", "0", [["gamescope"]]),
  ("cachyos", "1", [["oneshot"], ["gamescope"]]),
])
def test_watch_eject_request_session_calls(xgm, session_env, os_type, desktop_default, expected):
  xgm.set_os(os_type)
  xgm.settings.setSetting("desktop_default", desktop_default)
  run_watcher(xgm, xgm.plugin.watch_eject_request())
  assert without_loginctl(session_env)[0][0].endswith("/bin/egpu-eject")
  assert session_selects(session_env) == expected
  log = open(xgm.mod.EJECTDESKTOP_LOG).read()
  assert log.count("Command exited with code: 0") == len(expected)


def eject_link_steps(calls):
  """The desktop Eject link's calls after egpu-eject, as "clean" or the session-select arguments."""
  steps = []
  for argv in calls:
    if argv[0].endswith("/bin/clean-session-env"):
      steps.append("clean")
    elif SESSION_SELECT in argv:
      steps.append(argv[argv.index(SESSION_SELECT) + 1:])
  return steps


@pytest.mark.parametrize("os_type,desktop_default,expected", [
  ("cachyos", "1", ["clean", ["oneshot"], "clean", ["gamescope"]]),
  ("cachyos", "0", ["clean", ["gamescope"]]),
  ("steamos", "1", ["clean", ["gamescope"]]),
  ("bazzite", "0", ["clean", ["gamescope"]]),
])
def test_watch_eject_request_cleans_session_env_before_each_select(xgm, session_env, os_type, desktop_default, expected):
  xgm.set_os(os_type)
  xgm.settings.setSetting("desktop_default", desktop_default)
  run_watcher(xgm, xgm.plugin.watch_eject_request())
  assert eject_link_steps(session_env) == expected
  clean = [argv for argv in session_env if argv[0].endswith("/bin/clean-session-env")][0]
  assert clean == [str(xgm.bin / "clean-session-env"), "xgmtest", xgm.mod.LOG_DIR, ""]
  log = open(xgm.mod.EJECTDESKTOP_LOG).read()
  assert log.count("Clearing the eGPU variables from the session managers for xgmtest...") == expected.count("clean")
  assert "Switching anyway" not in log


@pytest.mark.parametrize("failure", ["exit", "exception"])
def test_watch_eject_request_cleanup_failure_still_switches(xgm, session_env, monkeypatch, failure):
  xgm.set_os("cachyos")
  xgm.settings.setSetting("desktop_default", "1")

  def run(argv, **kwargs):
    session_env.append(list(argv))
    if argv[0].endswith("/bin/clean-session-env"):
      if failure == "exception":
        raise FileNotFoundError(2, "No such file or directory", argv[0])
      return subprocess.CompletedProcess(argv, 9, stdout="ERROR: xgm-common.sh is missing. Reinstall XG Mobile Manager.\n", stderr="")
    return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

  monkeypatch.setattr(xgm.mod.subprocess, "run", run)
  run_watcher(xgm, xgm.plugin.watch_eject_request())
  assert eject_link_steps(session_env) == ["clean", ["oneshot"], "clean", ["gamescope"]]
  log = open(xgm.mod.EJECTDESKTOP_LOG).read()
  if failure == "exit":
    assert log.count("clean-session-env failed with exit code 9. Switching anyway.") == 2
    assert "ERROR: xgm-common.sh is missing." in log
  else:
    assert log.count("clean-session-env couldn't run: ") == 2
  assert log.count("Command exited with code: 0") == 2


def test_watch_eject_request_failed_eject_skips_cleanup_and_select(xgm, session_env, monkeypatch):
  xgm.set_os("cachyos")

  def failing_run(argv, **kwargs):
    session_env.append(list(argv))
    return subprocess.CompletedProcess(argv, 7, stdout="", stderr="")

  monkeypatch.setattr(xgm.mod.subprocess, "run", failing_run)
  run_watcher(xgm, xgm.plugin.watch_eject_request())
  calls = without_loginctl(session_env)
  assert len(calls) == 1 and calls[0][0].endswith("/bin/egpu-eject")
  assert eject_link_steps(session_env) == []


def test_user_session_ids_with_a_fake_loginctl(xgm, tmp_path, monkeypatch):
  fake_bin = tmp_path / "fake-bin"
  fake_bin.mkdir()
  loginctl = fake_bin / "loginctl"
  loginctl.write_text("#!/bin/sh\n[ \"$*\" = \"list-sessions --no-legend\" ] || exit 1\ncat <<'EOF'\n" + LOGINCTL_OUT + "EOF\n")
  loginctl.chmod(0o755)
  monkeypatch.setenv("PATH", f"{fake_bin}:{os.environ['PATH']}")
  assert xgm.mod._user_session_ids("xgmtest") == ["2", "5"]
  assert xgm.mod._user_session_ids("other") == ["c1"]
  assert xgm.mod._user_session_ids("nobody") == []
  loginctl.write_text("#!/bin/sh\nexit 1\n")
  assert xgm.mod._user_session_ids("xgmtest") == []


def test_user_session_ids_loginctl_missing(xgm, monkeypatch):
  def missing(argv, **kwargs):
    raise FileNotFoundError(2, "No such file or directory", argv[0])
  monkeypatch.setattr(xgm.mod.subprocess, "run", missing)
  assert xgm.mod._user_session_ids("xgmtest") == []


def test_watch_eject_request_records_sessions_before_eject_and_passes_them(xgm, session_env):
  xgm.set_os("steamos")
  session_env.loginctl_out = LOGINCTL_OUT
  run_watcher(xgm, xgm.plugin.watch_eject_request())
  assert session_env[0] == ["loginctl", "list-sessions", "--no-legend"]
  assert session_env[1][0].endswith("/bin/egpu-eject")
  clean = [argv for argv in session_env if argv[0].endswith("/bin/clean-session-env")]
  assert clean == [[str(xgm.bin / "clean-session-env"), "xgmtest", xgm.mod.LOG_DIR, "2 5"]]
  assert "Login sessions before the eject: 2 5" in open(xgm.mod.EJECTDESKTOP_LOG).read()


def eject_with_session_select_results(xgm, session_env, monkeypatch, os_type, results):
  """
  Runs the desktop Eject link with steamos-session-select returning (code, stderr) from results,
  in order (then 0). Returns the asyncio.sleep calls.
  """
  xgm.set_os(os_type)
  results = list(results)
  sleeps = []

  def run(argv, **kwargs):
    session_env.append(list(argv))
    if SESSION_SELECT in argv and results:
      code, stderr = results.pop(0)
      return subprocess.CompletedProcess(argv, code, stdout="", stderr=stderr)
    return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

  async def sleep(seconds):
    if seconds == 2:
      raise StopWatcher()
    sleeps.append(seconds)

  monkeypatch.setattr(xgm.mod.subprocess, "run", run)
  monkeypatch.setattr(xgm.mod.asyncio, "sleep", sleep)
  run_watcher(xgm, xgm.plugin.watch_eject_request())
  return sleeps


def pending_result(xgm):
  try:
    with open(xgm.mod.PENDING_RESULT_PATH) as f:
      return json.load(f)["result"]
  except FileNotFoundError:
    return None


# As logged in pass 3 (SteamOS) and Step 0, exp 2.
NAME_HAS_NO_OWNER = ("Error: org.freedesktop.DBus.Error.NameHasNoOwner: Could not activate remote peer "
                     "'com.steampowered.SteamOSManager1': activation request failed: a concurrent deactivation "
                     "request is already in progress")


@pytest.mark.parametrize("stderr", [
  NAME_HAS_NO_OWNER,
  "Error: I/O error: No such file or directory (os error 2)",
  "Error: org.freedesktop.DBus.Error.Failed: org.freedesktop.systemd1.TransactionIsDestructive: Transaction for "
  "graphical-session.target/stop is destructive (gamescope-session.target has 'start' job queued, but 'stop' is "
  "included in transaction).",
])
def test_eject_session_select_transient_error_then_success(xgm, session_env, monkeypatch, stderr):
  sleeps = eject_with_session_select_results(xgm, session_env, monkeypatch, "steamos", [(1, stderr)])
  assert eject_link_steps(session_env) == ["clean", ["gamescope"], "clean", ["gamescope"]]
  assert sleeps == [xgm.mod.SESSION_SELECT_RETRY_DELAY]
  log = open(xgm.mod.EJECTDESKTOP_LOG).read()
  assert log.count("Command exited with code: 1") == 1
  assert log.count("Command exited with code: 0") == 1
  assert "attempt 2 of 3" in log
  assert pending_result(xgm) is None


@pytest.mark.parametrize("os_type,expected_steps,parenthesis", [
  ("steamos", ["clean", ["gamescope"]] * 3, True),
  ("cachyos", ["clean", ["oneshot"]] + ["clean", ["gamescope"]] * 3, False),
  ("bazzite", ["clean", ["gamescope"]] * 3, False),
])
def test_eject_session_select_keeps_failing_records_pending_result(xgm, session_env, monkeypatch, os_type, expected_steps, parenthesis):
  xgm.settings.setSetting("desktop_default", "1")
  failures = [(1, NAME_HAS_NO_OWNER)] * 3
  if os_type == "cachyos":
    failures = [(0, "")] + failures  # oneshot works, gamescope keeps failing
  sleeps = eject_with_session_select_results(xgm, session_env, monkeypatch, os_type, failures + [(0, "")] * 5)
  assert eject_link_steps(session_env) == expected_steps
  assert sleeps.count(xgm.mod.SESSION_SELECT_RETRY_DELAY) == 2
  res = pending_result(xgm)
  assert res is not None and res["ok"] is False
  assert res["title"] == "Couldn't Switch Back to Game Mode"
  assert res["log_key"] == "ejectdesktop"
  assert set(res) == ACTION_RESULT_KEYS
  base = ("The XG Mobile was ejected, but switching back to Game Mode failed. In Desktop Mode, "
          "open Konsole and run: steamos-session-select gamescope")
  if parenthesis:
    assert res["message"] == base + ' ("Return to Gaming Mode" doesn\'t clear the "Set Desktop to Default" setting).'
  else:
    assert res["message"] == base + "."


def test_eject_session_select_non_transient_error_no_retry(xgm, session_env, monkeypatch):
  sleeps = eject_with_session_select_results(xgm, session_env, monkeypatch, "steamos",
                                             [(1, "Error: unknown session type 'gamescope'")])
  assert eject_link_steps(session_env) == ["clean", ["gamescope"]]
  assert sleeps == []
  assert pending_result(xgm)["message"].startswith("The XG Mobile was ejected, but switching back to Game Mode failed.")


def test_eject_link_subprocess_calls_go_through_to_thread(xgm, session_env, monkeypatch):
  xgm.set_os("cachyos")
  xgm.settings.setSetting("desktop_default", "1")
  in_thread = []
  direct = []
  real_run = xgm.mod.subprocess.run

  def run(argv, **kwargs):
    (in_thread if in_thread and in_thread[-1] == "open" else direct).append(list(argv))
    return real_run(argv, **kwargs)

  async def to_thread(func, *args, **kwargs):
    in_thread.append("open")
    try:
      return func(*args, **kwargs)
    finally:
      in_thread.append("closed")

  monkeypatch.setattr(xgm.mod.subprocess, "run", run)
  monkeypatch.setattr(xgm.mod.asyncio, "to_thread", to_thread)
  run_watcher(xgm, xgm.plugin.watch_eject_request())
  assert direct == []
  assert eject_link_steps(session_env) == ["clean", ["oneshot"], "clean", ["gamescope"]]
  assert in_thread.count("open") == 6  # loginctl, egpu-eject, 2 x (clean-session-env, session select)
