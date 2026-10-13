"""OS/device detection, GPU status and log path resolution against a fake sysfs tree."""
import os
import subprocess
from pathlib import Path

import pytest

from xgm_helpers import load_main


@pytest.mark.parametrize("os_type", ["steamos", "bazzite", "bazzite-nvidia", "cachyos", "unsupported"])
def test_get_os_type(xgm, os_type):
  xgm.set_os(os_type)
  assert xgm.plugin.get_os_type() == os_type


def test_get_os_type_missing_file_is_unsupported(xgm):
  assert not xgm.os_release.exists()
  assert xgm.plugin.get_os_type() == "unsupported"


def test_get_os_status_wraps_get_os_type(xgm):
  xgm.set_os("cachyos")
  assert xgm.run(xgm.plugin.get_os_status()) == "cachyos"


@pytest.mark.parametrize("product,expected", [
  ("RC71L", "handheld"),
  ("ROG Ally RC71L_RC71L", "handheld"),
  ("ROG Ally X RC72LA", "handheld"),
  ("ROG Flow Z13 GZ301ZE", "laptop"),
  ("ROG Flow X13 GV301QH", "laptop"),
  ("ROG Flow X16 GV601VV", "laptop"),
  ("GZ301ZE", "laptop"),
  ("GV301QH", "laptop"),
  ("Jupiter", "unknown"),
  ("", "unknown"),
])
def test_get_device_type(xgm, product, expected):
  xgm.set_product(product)
  assert xgm.run(xgm.plugin.get_device_type()) == expected


def test_get_device_type_missing_file_is_unknown(xgm):
  assert xgm.run(xgm.plugin.get_device_type()) == "unknown"


# --- get_gpu_status ---

STATUS_KEYS = {"connected", "active", "vendor", "error"}


def write_wmi(xgm, connected=None, enable=None):
  if connected is not None:
    (xgm.wmi / "egpu_connected").write_text(f"{connected}\n")
  if enable is not None:
    (xgm.wmi / "egpu_enable").write_text(f"{enable}\n")


@pytest.fixture
def lspci(xgm, monkeypatch):
  """Controls the `lspci -n -d 10de:` call and the /dev/dri/card1 fallback check."""
  state = {"output": None, "card1": False}

  def fake_check_output(cmd, *a, **kw):
    assert cmd[0] == "lspci"
    if state["output"] is None:
      raise subprocess.CalledProcessError(1, cmd)
    return state["output"].encode()

  real_exists = os.path.exists

  def fake_exists(path):
    if path == "/dev/dri/card1":
      return state["card1"]
    return real_exists(path)

  monkeypatch.setattr(xgm.mod.subprocess, "check_output", fake_check_output)
  monkeypatch.setattr(xgm.mod.os.path, "exists", fake_exists)
  return state


def test_gpu_status_connected_active_nvidia(xgm, lspci):
  write_wmi(xgm, connected=1, enable=1)
  lspci["output"] = "03:00.0 0300: 10de:2717 (rev a1)\n"
  status = xgm.run(xgm.plugin.get_gpu_status())
  assert status == {"connected": True, "active": True, "vendor": "nvidia", "error": ""}


def test_gpu_status_amd_falls_back_to_card1(xgm, lspci):
  write_wmi(xgm, connected=1, enable=1)
  lspci["card1"] = True
  status = xgm.run(xgm.plugin.get_gpu_status())
  assert status == {"connected": True, "active": True, "vendor": "amd", "error": ""}


def test_gpu_status_disconnected(xgm, lspci):
  write_wmi(xgm, connected=0, enable=0)
  status = xgm.run(xgm.plugin.get_gpu_status())
  assert status == {"connected": False, "active": False, "vendor": "none", "error": ""}


def test_gpu_status_missing_connected_file(xgm, lspci):
  write_wmi(xgm, enable=1)
  status = xgm.run(xgm.plugin.get_gpu_status())
  assert set(status) == STATUS_KEYS
  assert status["connected"] is False
  assert "egpu_connected missing" in status["error"]


def test_gpu_status_missing_enable_file(xgm, lspci):
  write_wmi(xgm, connected=1)
  status = xgm.run(xgm.plugin.get_gpu_status())
  assert set(status) == STATUS_KEYS
  assert status["connected"] is True
  assert status["active"] is False
  assert "egpu_enable missing" in status["error"]


def test_gpu_status_exception_still_returns_dict(xgm, lspci):
  (xgm.wmi / "egpu_connected").mkdir()  # open() raises IsADirectoryError
  status = xgm.run(xgm.plugin.get_gpu_status())
  assert set(status) == STATUS_KEYS
  assert status["error"].startswith("Status check failed:")
  assert "CRITICAL ERROR" in open(xgm.mod.DEBUG_LOG).read()


# --- log folder ---

def test_log_dir_is_deckys_plugin_log_dir(xgm):
  # load_main points the fake decky.DECKY_PLUGIN_LOG_DIR at the copy's homebrew, as Decky does.
  expected = xgm.tmp / "homebrew" / "logs" / "xgmobile-manager"
  assert xgm.mod.LOG_DIR == str(expected)
  assert expected.is_dir()


def test_log_dir_fallback_without_decky_value(tmp_path):
  mod = load_main(tmp_path / "homebrew" / "plugins" / "xgmobile-manager", decky_log_dir=None)
  expected = (tmp_path / "homebrew" / "logs" / "xgmobile-manager").resolve()
  assert Path(mod.LOG_DIR).resolve() == expected
  assert expected.is_dir()


def test_every_log_is_in_the_folder_without_prefix(xgm):
  for key, (path, _label) in xgm.mod.LOG_MAP.items():
    assert os.path.dirname(path) == xgm.mod.LOG_DIR, key
    assert not os.path.basename(path).startswith("xgmobile"), key
  assert os.path.basename(xgm.mod.ENABLE_LOG) == "enable_latest.log"
  assert os.path.basename(xgm.mod.EJECT_LOG) == "eject_latest.log"
  assert os.path.basename(xgm.mod.PYTHONERROR_LOG) == "python_crash.log"


def test_state_files_stay_in_data_dir(xgm):
  for path in (xgm.mod.PENDING_RESULT_PATH, xgm.mod.EJECT_CANCELLED_MARKER):
    assert os.path.dirname(path) == xgm.mod.DATA_DIR


# --- _resolve_log_path ---

def vendor_log(xgm, kind, vendor):
  return os.path.join(xgm.mod.LOG_DIR, f"{kind}_{vendor}.log")


@pytest.mark.parametrize("kind", ["enable", "eject"])
def test_resolve_prefers_existing_vendor_log(xgm, kind):
  xgm.settings.setSetting("gpu_vendor", "amd")
  path = vendor_log(xgm, kind, "amd")
  open(path, "w").close()
  assert xgm.plugin._resolve_log_path(kind) == path


@pytest.mark.parametrize("kind", ["enable", "eject"])
def test_resolve_falls_back_to_latest(xgm, kind):
  xgm.settings.setSetting("gpu_vendor", "amd")
  open(vendor_log(xgm, kind, "nvidia"), "w").close()  # other vendor's log doesn't count
  assert xgm.plugin._resolve_log_path(kind) == xgm.mod.LOG_MAP[kind][0]
  assert xgm.mod.LOG_MAP[kind][0].endswith(f"{kind}_latest.log")


def test_resolve_unknown_key_uses_enable(xgm):
  assert xgm.plugin._resolve_log_path("bogus") == xgm.mod.ENABLE_LOG


@pytest.mark.parametrize("key", ["install", "uninstall", "hybrid", "python", "debug"])
def test_resolve_plain_keys_use_log_map(xgm, key):
  assert xgm.plugin._resolve_log_path(key) == xgm.mod.LOG_MAP[key][0]


def test_resolve_without_settings_defaults_to_nvidia(xgm):
  del xgm.mod.Plugin.settings  # _main hasn't run yet
  path = vendor_log(xgm, "enable", "nvidia")
  open(path, "w").close()
  assert xgm.plugin._resolve_log_path("enable") == path


def test_get_latest_logs_reads_resolved_file(xgm):
  open(xgm.mod.INSTALL_LOG, "w").write("install output\n")
  assert xgm.run(xgm.plugin.get_latest_logs("install")) == "install output\n"


def test_get_latest_logs_missing_file(xgm):
  assert xgm.run(xgm.plugin.get_latest_logs("install")).startswith("No log file found at ")
