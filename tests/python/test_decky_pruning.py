"""
Decky deletes all but the newest 4 *.log files at the top of DECKY_PLUGIN_LOG_DIR on every plugin
load (fakes/decky.py runs its exact loop at import). Our logs live in activity/, so a reload must
keep every one of them, and the _latest links.
"""
import importlib
import os
import time

import decky
import pytest

from xgm_helpers import load_main


@pytest.fixture
def monkeypatch(monkeypatch):
  """Re-imports the fake decky once the environment is restored, so later tests get its defaults."""
  yield monkeypatch
  monkeypatch.undo()
  importlib.reload(decky)


def plugin_load(monkeypatch, plugin_dir, decky_dir):
  """What Decky does on a plugin load: a fresh `decky` import (which prunes), then main.py."""
  monkeypatch.setenv("DECKY_PLUGIN_LOG_DIR", str(decky_dir))
  importlib.reload(decky)
  return load_main(plugin_dir)


def test_reload_keeps_every_activity_log(tmp_path, monkeypatch):
  plugin_dir = tmp_path / "homebrew" / "plugins" / "xgmobile-manager"
  decky_dir = tmp_path / "homebrew" / "logs" / "xgmobile-manager"
  mod = plugin_load(monkeypatch, plugin_dir, decky_dir)

  # Every log the plugin and its scripts write, as they write them, and the _latest links.
  ours = [path for path, _label in mod.LOG_MAP.values() if not path.endswith("_latest.log")]
  ours += [os.path.join(mod.LOG_DIR, f"{kind}_{vendor}.log")
           for kind in ("enable", "eject") for vendor in ("nvidia", "amd")]
  ours += [os.path.join(mod.LOG_DIR, name) for name in ("migrate.log", "nuke.log", "nuke_dry.log")]
  for path in ours:
    with open(path, "w") as f:
      f.write(os.path.basename(path))
  os.symlink(os.path.join(mod.LOG_DIR, "enable_nvidia.log"), mod.ENABLE_LOG)
  os.symlink(os.path.join(mod.LOG_DIR, "eject_amd.log"), mod.EJECT_LOG)

  # Decky's own timestamped logs, newer than ours.
  now = time.time()
  decky_logs = [f"2026-10-1{i} 21.04.33.log" for i in range(6)]
  for i, name in enumerate(decky_logs):
    path = decky_dir / name
    path.write_text("decky\n")
    os.utime(path, (now + 60 + i, now + 60 + i))

  mod = plugin_load(monkeypatch, plugin_dir, decky_dir)

  # The pruning ran: only Decky's newest 4 are left at the top level.
  assert sorted(p.name for p in decky_dir.glob("*.log")) == sorted(decky_logs[2:])
  for path in ours:
    assert open(path).read() == os.path.basename(path), path
  assert os.readlink(mod.ENABLE_LOG) == os.path.join(mod.LOG_DIR, "enable_nvidia.log")
  assert os.readlink(mod.EJECT_LOG) == os.path.join(mod.LOG_DIR, "eject_amd.log")
