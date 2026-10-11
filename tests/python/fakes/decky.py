"""Test stand-in for Decky Loader's injected `decky` module."""
import logging

HOME = "/home/deck"
USER = "deck"
DECKY_VERSION = "v0.0.0-test"
DECKY_USER = "deck"
DECKY_USER_HOME = "/home/deck"
DECKY_HOME = "/home/deck/homebrew"
DECKY_PLUGIN_SETTINGS_DIR = "/home/deck/homebrew/settings/xgmobile-manager"
DECKY_PLUGIN_RUNTIME_DIR = "/home/deck/homebrew/data/xgmobile-manager"
DECKY_PLUGIN_LOG_DIR = "/home/deck/homebrew/logs/xgmobile-manager"
DECKY_PLUGIN_DIR = "/home/deck/homebrew/plugins/xgmobile-manager"
DECKY_PLUGIN_NAME = "XG Mobile Manager"
DECKY_PLUGIN_VERSION = "0.0.0"
DECKY_PLUGIN_AUTHOR = "test"
DECKY_PLUGIN_LOG = "/home/deck/homebrew/logs/xgmobile-manager/plugin.log"

logger = logging.getLogger("xgmobile-manager-test")


async def emit(event, *args):
  pass
