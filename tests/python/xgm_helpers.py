"""Shared helpers for the backend tests: safe import of main.py and fixture data."""
import atexit
import importlib.util
import itertools
import shutil
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FAKES = Path(__file__).resolve().parent / "fakes"

# decky, decky_plugin and settings are injected by Decky Loader at runtime.
if str(FAKES) not in sys.path:
  sys.path.insert(0, str(FAKES))

import decky  # noqa: E402  (the fake, from FAKES)

_counter = itertools.count()
# The fake's own value (/home/deck/...), restored after every load so nothing imports it by accident.
_FAKE_DECKY_LOG_DIR = decky.DECKY_PLUGIN_LOG_DIR

# Representative /etc/os-release contents per OS.
OS_RELEASES = {
  "steamos": 'NAME="SteamOS"\nPRETTY_NAME="SteamOS"\nID=steamos\nID_LIKE=arch\nVARIANT_ID=steamdeck\n',
  "bazzite": 'NAME="Bazzite"\nPRETTY_NAME="Bazzite"\nID=bazzite\nID_LIKE="fedora"\nVARIANT_ID=bazzite-deck\n',
  "bazzite-nvidia": 'NAME="Bazzite"\nPRETTY_NAME="Bazzite"\nID=bazzite\nID_LIKE="fedora"\nVARIANT_ID=bazzite-deck-nvidia\n',
  "cachyos": 'NAME="CachyOS Linux"\nPRETTY_NAME="CachyOS"\nID=cachyos\nID_LIKE=arch\n',
  "unsupported": 'NAME="Fedora Linux"\nPRETTY_NAME="Fedora Linux 41"\nID=fedora\n',
}


def load_main(plugin_dir, decky_log_dir=True):
  """
  Copies main.py and package.json into <tmp>/homebrew/plugins/xgmobile-manager and imports the copy.
  main.py derives DATA_DIR from its own location, takes LOG_DIR from decky.DECKY_PLUGIN_LOG_DIR,
  and runs os.makedirs at import time, so importing the repo copy would create directories outside
  the repo. The fake decky's DECKY_PLUGIN_LOG_DIR is pointed at the copy's homebrew, as Decky does;
  decky_log_dir=None removes it (main.py's fallback).
  """
  plugin_dir = Path(plugin_dir)
  plugin_dir.mkdir(parents=True, exist_ok=True)
  (plugin_dir / "bin").mkdir(exist_ok=True)
  shutil.copy2(REPO / "main.py", plugin_dir / "main.py")
  shutil.copy2(REPO / "package.json", plugin_dir / "package.json")
  homebrew = plugin_dir.parent.parent.resolve()

  if decky_log_dir is None:
    if hasattr(decky, "DECKY_PLUGIN_LOG_DIR"):
      delattr(decky, "DECKY_PLUGIN_LOG_DIR")
  else:
    decky.DECKY_PLUGIN_LOG_DIR = str(homebrew / "logs" / plugin_dir.name)

  name = f"xgm_main_{next(_counter)}"
  spec = importlib.util.spec_from_file_location(name, plugin_dir / "main.py")
  mod = importlib.util.module_from_spec(spec)
  try:
    spec.loader.exec_module(mod)
  finally:
    decky.DECKY_PLUGIN_LOG_DIR = _FAKE_DECKY_LOG_DIR

  assert Path(mod.DATA_DIR).resolve().is_relative_to(homebrew), mod.DATA_DIR
  assert Path(mod.LOG_DIR).resolve().is_relative_to(homebrew), mod.LOG_DIR
  return mod


def _load_static():
  tmp = Path(tempfile.mkdtemp(prefix="xgm-static-"))
  atexit.register(shutil.rmtree, tmp, ignore_errors=True)
  return load_main(tmp / "homebrew" / "plugins" / "xgmobile-manager")


# Imported once per session, for parametrization and static checks (never executes anything).
STATIC = _load_static()

ACTION_RESULT_KEYS = frozenset(STATIC._result(True, "success", "t", "m").keys())


def catalog_cases():
  return sorted(
    (script, code)
    for script, codes in STATIC.SCRIPT_ERROR_CATALOG.items()
    for code in codes
  )
