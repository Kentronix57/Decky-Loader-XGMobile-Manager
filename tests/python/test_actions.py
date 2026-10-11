"""Guards and small actions in main.py that don't need hardware."""
import pytest

from xgm_helpers import ACTION_RESULT_KEYS


def marker_stub(xgm, script):
  """A stub that leaves a marker file, so tests can tell whether the script ran."""
  marker = xgm.tmp / f"ran-{script}"
  xgm.stub(script, f'touch "{marker}"\nexit 0')
  return marker


@pytest.mark.parametrize("method,script", [
  ("enable_egpu", "egpu-enable"),
  ("hybrid_supergfxctl", "supergfx-hybrid"),
])
def test_nvidia_on_plain_bazzite_gives_wrong_image(xgm, method, script):
  xgm.set_os("bazzite")
  xgm.settings.setSetting("gpu_vendor", "nvidia")
  marker = marker_stub(xgm, script)

  res = xgm.run(getattr(xgm.plugin, method)())

  assert set(res) == ACTION_RESULT_KEYS
  assert res["ok"] is False
  assert res["title"] == xgm.mod.WRONG_BAZZITE_TITLE
  assert res["message"] == xgm.mod.WRONG_BAZZITE_MESSAGE
  assert res["hint"] == xgm.mod.WRONG_BAZZITE_HINT
  assert not marker.exists()


@pytest.mark.parametrize("method,script", [
  ("enable_egpu", "egpu-enable"),
  ("hybrid_supergfxctl", "supergfx-hybrid"),
])
@pytest.mark.parametrize("os_type,vendor", [("bazzite-nvidia", "nvidia"), ("bazzite", "amd"), ("steamos", "nvidia")])
def test_other_combinations_run_the_script(xgm, method, script, os_type, vendor):
  xgm.set_os(os_type)
  xgm.settings.setSetting("gpu_vendor", vendor)
  marker = marker_stub(xgm, script)

  res = xgm.run(getattr(xgm.plugin, method)())

  assert res["ok"] is True
  assert marker.exists()


@pytest.mark.parametrize("os_type", ["bazzite", "bazzite-nvidia", "cachyos", "unsupported"])
def test_install_nvidia_blocked_off_steamos(xgm, os_type):
  xgm.set_os(os_type)
  marker = marker_stub(xgm, "install-nvidia.sh")

  res = xgm.run(xgm.plugin.install_nvidia())

  assert set(res) == ACTION_RESULT_KEYS
  assert res["ok"] is False
  assert res["status"] == "error"
  assert res["title"] == "NVIDIA Install Unavailable"
  assert res["hint"] != ""
  assert not marker.exists()


def test_install_nvidia_runs_on_steamos(xgm):
  xgm.set_os("steamos")
  marker = marker_stub(xgm, "install-nvidia.sh")
  res = xgm.run(xgm.plugin.install_nvidia())
  assert res["ok"] is True
  assert marker.exists()


# --- power profile ---

@pytest.mark.parametrize("profile,value,label", [
  ("balanced", "0", "Balanced"),
  ("Performance", "1", "Performance"),
  ("  QUIET ", "2", "Quiet"),
  ("turbo", "0", "Balanced"),  # unrecognised input falls back to Balanced
])
def test_set_power_profile_writes_wmi_value(xgm, profile, value, label):
  res = xgm.run(xgm.plugin.set_power_profile(profile))
  assert set(res) == ACTION_RESULT_KEYS
  assert res["ok"] is True
  assert res["message"] == f"Power profile set to {label}."
  assert (xgm.wmi / "throttle_thermal_policy").read_text() == value


def test_set_power_profile_unwritable_gives_failure(xgm, monkeypatch):
  monkeypatch.setattr(xgm.mod, "ASUS_WMI_DIR", str(xgm.tmp / "no-such-dir"))
  res = xgm.run(xgm.plugin.set_power_profile("performance"))
  assert set(res) == ACTION_RESULT_KEYS
  assert res["ok"] is False
  assert res["status"] == "error"
  assert res["message"] == "Couldn't set the power profile to Performance."
  assert "asus-nb-wmi" in res["hint"]


@pytest.mark.parametrize("value,label", [("0", "Balanced"), ("1", "Performance"), ("2", "Quiet"), ("7", "Unknown"), ("junk", "Unknown")])
def test_get_power_profile_labels(xgm, value, label):
  (xgm.wmi / "throttle_thermal_policy").write_text(value + "\n")
  assert xgm.run(xgm.plugin.get_power_profile()) == label


def test_get_power_profile_missing_file(xgm):
  assert xgm.run(xgm.plugin.get_power_profile()) == "Unknown"


# --- desktop transition flag ---

def test_set_desktop_transition_flag_success(xgm):
  res = xgm.run(xgm.plugin.set_desktop_transition_flag())
  assert set(res) == ACTION_RESULT_KEYS
  assert res["ok"] is True
  assert xgm.flag.read_text() == "transition_requested"

  assert xgm.run(xgm.plugin.check_and_clear_desktop_flag()) is True
  assert not xgm.flag.exists()
  assert xgm.run(xgm.plugin.check_and_clear_desktop_flag()) is False


def test_set_desktop_transition_flag_failure(xgm, monkeypatch):
  monkeypatch.setattr(xgm.mod, "DESKTOP_FLAG_PATH", str(xgm.tmp / "no-such-dir" / "flag"))
  res = xgm.run(xgm.plugin.set_desktop_transition_flag())
  assert set(res) == ACTION_RESULT_KEYS
  assert res["ok"] is False
  assert res["status"] == "error"
  assert res["message"] == "Couldn't schedule the Desktop Mode switch. Enabling without it."
  assert "Power menu" in res["hint"]


def test_get_version_reads_package_json(xgm):
  import json
  expected = json.loads((xgm.plugin_dir / "package.json").read_text())["version"]
  assert xgm.run(xgm.plugin.get_version()) == expected
