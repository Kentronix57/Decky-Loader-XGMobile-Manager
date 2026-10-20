"""Test stand-in for Decky Loader's injected `decky` module."""
import logging
import os
import tempfile

HOME = "/home/deck"
USER = "deck"
DECKY_VERSION = "v0.0.0-test"
DECKY_USER = "deck"
DECKY_USER_HOME = "/home/deck"
DECKY_HOME = "/home/deck/homebrew"
DECKY_PLUGIN_SETTINGS_DIR = "/home/deck/homebrew/settings/xgmobile-manager"
DECKY_PLUGIN_RUNTIME_DIR = "/home/deck/homebrew/data/xgmobile-manager"
# From a test-only variable, never Decky's own DECKY_PLUGIN_LOG_DIR: a shell started from the plugin
# inherits that one, with the real log folder, and the pruning below runs on every import. The
# default can't exist.
DECKY_PLUGIN_LOG_DIR = os.environ.get("XGM_FAKE_DECKY_PLUGIN_LOG_DIR", "/nonexistent/xgm-tests/homebrew/logs/xgmobile-manager")
DECKY_PLUGIN_DIR = "/home/deck/homebrew/plugins/xgmobile-manager"
DECKY_PLUGIN_NAME = "XG Mobile Manager"
DECKY_PLUGIN_VERSION = "0.0.0"
DECKY_PLUGIN_AUTHOR = "test"
DECKY_PLUGIN_LOG = os.path.join(DECKY_PLUGIN_LOG_DIR, "plugin.log")

# Decky deletes all but the newest 4 *.log files at the top of the plugin log dir whenever this
# module is imported, i.e. on every plugin load. Verbatim from decky-loader v3.2.10:
# https://github.com/SteamDeckHomebrew/decky-loader/blob/v3.2.10/backend/decky_loader/plugin/imports/decky.py
# Safety net (not Decky's): only ever inside the temp dir, where pytest's tmp_path lives.
_TMP_ROOT = os.path.realpath(tempfile.gettempdir())
if os.path.realpath(DECKY_PLUGIN_LOG_DIR).startswith(_TMP_ROOT + os.sep):
  try:
      for x in [entry.name for entry in sorted(os.scandir(DECKY_PLUGIN_LOG_DIR),key=lambda x: x.stat().st_mtime, reverse=True) if entry.name.endswith(".log")][4:]:
          os.unlink(os.path.join(DECKY_PLUGIN_LOG_DIR, x))
  except Exception as e:
      print(f"Failed to delete old logs: {str(e)}")

logger = logging.getLogger("xgmobile-manager-test")


async def emit(event, *args):
  pass
