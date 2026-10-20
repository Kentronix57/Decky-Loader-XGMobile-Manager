"""steamos-session-select arguments: the _session_select_calls table and the 3 call sites that use it."""
import os
import subprocess
from types import SimpleNamespace

import pytest

from xgm_helpers import STATIC

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


@pytest.fixture
def session_env(xgm, monkeypatch):
  """
  Fakes everything the session-switch code touches outside the sandbox: the user lookup, the
  watcher request files in /tmp, asyncio.sleep, and subprocess.run (which records each argv and
  succeeds). Returns the list of recorded argvs.
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

  calls = []

  def fake_run(argv, **kwargs):
    calls.append(list(argv))
    return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")

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
  assert session_env[0][0].endswith("/bin/egpu-eject")
  assert session_selects(session_env) == expected
  log = open(xgm.mod.EJECTDESKTOP_LOG).read()
  assert log.count("Command exited with code: 0") == len(expected)
