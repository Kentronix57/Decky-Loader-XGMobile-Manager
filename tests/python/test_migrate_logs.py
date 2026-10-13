"""_main runs bin/migrate-logs once per plugin load, and a failure never stops the plugin loading."""
import asyncio
import os
import shutil

import pytest

from xgm_helpers import REPO


@pytest.fixture
def loading(xgm, monkeypatch):
  """
  Runs _main with the desktop-link watchers replaced by recorders. Every event (the migrate-logs
  stub's arguments, a watcher starting) is appended to xgm.events in order.
  """
  monkeypatch.setenv("DECKY_PLUGIN_SETTINGS_DIR", str(xgm.tmp / "settings"))
  # The real migrate-logs globs $ROOT/home; keep it in the sandbox.
  monkeypatch.setenv("XGM_ROOT", str(xgm.tmp / "sysroot"))
  events = xgm.tmp / "events"
  events.touch()

  def watcher(name):
    async def watch(self):
      with open(events, "a") as f:
        f.write(f"watcher {name}\n")
    return watch

  monkeypatch.setattr(xgm.mod.Plugin, "watch_eject_request", watcher("eject"))
  monkeypatch.setattr(xgm.mod.Plugin, "watch_enable_request", watcher("enable"))

  async def load():
    await xgm.plugin._main()
    await asyncio.sleep(0)  # let the watcher tasks start

  def run():
    xgm.run(load())
    return events.read_text().splitlines()

  xgm.events = events
  xgm.load = run
  return xgm


def crash_log(xgm):
  path = xgm.mod.PYTHONERROR_LOG
  return open(path).read() if os.path.exists(path) else ""


def test_main_runs_migrate_logs_before_the_watchers(loading):
  loading.stub("migrate-logs", f'echo "migrate-logs $*" >> "{loading.events}"')
  events = loading.load()
  homebrew = loading.tmp / "homebrew"
  assert events[0] == f"migrate-logs {homebrew / 'logs'} {homebrew / 'logs' / 'xgmobile-manager' / 'activity'}"
  assert sorted(events[1:]) == ["watcher eject", "watcher enable"]
  assert loading.mod.LEGACY_LOGS_ROOT == str(homebrew / "logs")
  assert crash_log(loading) == ""


def test_failure_is_logged_and_loading_continues(loading):
  loading.stub("migrate-logs", 'echo "ERROR: couldn\'t move x"\nexit 1')
  events = loading.load()
  assert sorted(events) == ["watcher eject", "watcher enable"]
  log = crash_log(loading)
  assert "migrate-logs failed (exit code 1)" in log
  assert "ERROR: couldn't move x" in log


def test_launch_exception_is_logged_and_loading_continues(loading, monkeypatch):
  async def boom(*args, **kwargs):
    raise OSError("no bash")
  monkeypatch.setattr(loading.mod.asyncio, "create_subprocess_exec", boom)
  events = loading.load()
  assert sorted(events) == ["watcher eject", "watcher enable"]
  assert "migrate-logs couldn't run: no bash" in crash_log(loading)


def test_hang_is_stopped_and_loading_continues(loading, monkeypatch):
  monkeypatch.setattr(loading.mod, "MIGRATE_LOGS_TIMEOUT", 0.2)
  loading.stub("migrate-logs", "exec sleep 30")
  events = loading.load()
  assert sorted(events) == ["watcher eject", "watcher enable"]
  assert "migrate-logs didn't finish within 0.2s" in crash_log(loading)


def test_cancel_stops_the_script_and_reraises(loading):
  pid_file = loading.tmp / "migrate.pid"
  loading.stub("migrate-logs", f'echo $$ > "{pid_file}"\nexec sleep 30')

  async def cancel_mid_run():
    task = asyncio.ensure_future(loading.plugin._migrate_logs())
    for _ in range(200):
      if pid_file.exists() and pid_file.read_text().strip():
        break
      await asyncio.sleep(0.01)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
      await task
    return int(pid_file.read_text())

  pid = loading.run(cancel_mid_run())
  # Killed and reaped: the pid is gone.
  with pytest.raises(ProcessLookupError):
    os.kill(pid, 0)
  assert crash_log(loading) == ""


def test_real_script_migrates_on_load(loading):
  for name in ("migrate-logs", "xgm-common.sh"):
    shutil.copy2(REPO / "bin" / name, loading.bin / name)
  legacy = loading.tmp / "homebrew" / "logs"
  (legacy / "xgmobile_manager_enable_nvidia.log").write_text("old enable\n")
  os.symlink(legacy / "xgmobile_manager_enable_nvidia.log", legacy / "xgmobile_manager_enable_latest.log")

  loading.load()
  log_dir = loading.mod.LOG_DIR
  assert open(os.path.join(log_dir, "enable_nvidia.log")).read() == "old enable\n"
  assert os.readlink(loading.mod.ENABLE_LOG) == os.path.join(log_dir, "enable_nvidia.log")
  assert loading.run(loading.plugin.get_latest_logs("enable")) == "old enable\n"
  assert sorted(os.listdir(legacy)) == ["xgmobile-manager"]
  assert sorted(os.listdir(legacy / "xgmobile-manager")) == ["activity"]
  assert os.path.exists(os.path.join(log_dir, "migrate.log"))
  assert crash_log(loading) == ""
