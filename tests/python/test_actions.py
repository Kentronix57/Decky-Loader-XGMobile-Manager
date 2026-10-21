"""Guards and small actions in main.py that don't need hardware."""
import builtins

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


@pytest.mark.parametrize("os_type", ["bazzite", "bazzite-nvidia", "unsupported"])
def test_install_nvidia_blocked_off_steamos_and_cachyos(xgm, os_type):
  xgm.set_os(os_type)
  markers = [marker_stub(xgm, s) for s in ("install-nvidia.sh", "install-nvidia-cachyos.sh")]

  res = xgm.run(xgm.plugin.install_nvidia())

  assert set(res) == ACTION_RESULT_KEYS
  assert res["ok"] is False
  assert res["status"] == "error"
  assert res["title"] == "NVIDIA Install Unavailable"
  assert res["hint"] == "Bazzite's deck-nvidia image includes the drivers."
  assert not any(m.exists() for m in markers)


@pytest.mark.parametrize("os_type,script,other", [
  ("steamos", "install-nvidia.sh", "install-nvidia-cachyos.sh"),
  ("cachyos", "install-nvidia-cachyos.sh", "install-nvidia.sh"),
])
def test_install_nvidia_dispatches_by_os(xgm, os_type, script, other):
  xgm.set_os(os_type)
  marker = marker_stub(xgm, script)
  other_marker = marker_stub(xgm, other)
  res = xgm.run(xgm.plugin.install_nvidia())
  assert res["ok"] is True
  assert res["script"] == script
  assert res["log_key"] == "install"
  assert marker.exists()
  assert not other_marker.exists()


# --- power profile ---

@pytest.mark.parametrize("profile,value,label", [
  ("balanced", "0", "Balanced"),
  ("Performance", "1", "Performance"),
  ("  QUIET ", "2", "Quiet"),
  ("performance mode", "1", "Performance"),
])
def test_set_power_profile_writes_wmi_value(xgm, profile, value, label):
  res = xgm.run(xgm.plugin.set_power_profile(profile))
  assert set(res) == ACTION_RESULT_KEYS
  assert res["ok"] is True
  assert res["message"] == f"Power profile set to {label}."
  assert (xgm.wmi / "throttle_thermal_policy").read_text() == value


def _policy_open(monkeypatch, policy, fail_mode):
  """Makes open() of the policy file raise when its mode contains fail_mode ("w" or "r")."""
  real_open = builtins.open
  calls = []

  def fake_open(file, mode="r", *args, **kwargs):
    if str(file) == str(policy):
      calls.append(mode)
      if fail_mode in mode:
        raise PermissionError(f"policy opened with mode {mode!r}")
    return real_open(file, mode, *args, **kwargs)

  monkeypatch.setattr(builtins, "open", fake_open)
  return calls


@pytest.mark.parametrize("profile,value,label", [
  ("balanced", "0", "Balanced"),
  ("Performance", "1", "Performance"),
  ("quiet", "2", "Quiet"),
])
def test_set_power_profile_unchanged_is_not_rewritten(xgm, monkeypatch, profile, value, label):
  # Each write makes the EC re-apply the profile (issue #25), so the same value isn't written again.
  policy = xgm.wmi / "throttle_thermal_policy"
  policy.write_text(value + "\n")
  calls = _policy_open(monkeypatch, policy, "w")
  res = xgm.run(xgm.plugin.set_power_profile(profile))
  assert set(res) == ACTION_RESULT_KEYS
  assert res["ok"] is True
  assert res["status"] == "success"
  assert res["message"] == f"Power profile is already {label}."
  assert not any("w" in m for m in calls)
  assert policy.read_text() == value + "\n"


def test_set_power_profile_different_value_is_written(xgm):
  policy = xgm.wmi / "throttle_thermal_policy"
  policy.write_text("0\n")
  res = xgm.run(xgm.plugin.set_power_profile("performance"))
  assert res["ok"] is True
  assert res["message"] == "Power profile set to Performance."
  assert policy.read_text() == "1"


@pytest.mark.parametrize("profile", ["turbo", ""])
def test_set_power_profile_unknown_name_gives_failure(xgm, monkeypatch, profile):
  policy = xgm.wmi / "throttle_thermal_policy"
  policy.write_text("1\n")
  calls = _policy_open(monkeypatch, policy, "w")
  res = xgm.run(xgm.plugin.set_power_profile(profile))
  assert set(res) == ACTION_RESULT_KEYS
  assert res["ok"] is False
  assert res["status"] == "error"
  assert res["title"] == "ASUS Power Profile"
  assert res["message"] == f'Unknown power profile "{profile}".'
  assert res["hint"] == "Pick Quiet, Balanced or Performance."
  assert not any("w" in m for m in calls)
  assert policy.read_text() == "1\n"


def test_set_power_profile_unreadable_is_still_written(xgm, monkeypatch):
  policy = xgm.wmi / "throttle_thermal_policy"
  policy.write_text("2\n")
  calls = _policy_open(monkeypatch, policy, "r")
  res = xgm.run(xgm.plugin.set_power_profile("quiet"))
  assert res["ok"] is True
  assert res["message"] == "Power profile set to Quiet."
  assert "w" in calls
  assert policy.read_text() == "2"


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
