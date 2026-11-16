"""collect_usb4_diagnostics: runs bin/xgm-usb4-diag with the label, and maps its results."""
import os
import re

import pytest

from xgm_helpers import ACTION_RESULT_KEYS


def args_stub(xgm, body="exit 0"):
  """A stub xgm-usb4-diag that records its arguments, one per line."""
  args_file = xgm.tmp / "usb4diag-args"
  xgm.stub("xgm-usb4-diag", f'printf "%s\\n" "$@" > "{args_file}"\n{body}')
  return args_file


@pytest.mark.parametrize("label", ["unplugged", "plugged", "boot-plugged"])
def test_runs_the_script_with_the_log_dir_and_the_label(xgm, label):
  args_file = args_stub(xgm)

  res = xgm.run(xgm.plugin.collect_usb4_diagnostics(label))

  assert args_file.read_text().splitlines() == ["--log-dir", xgm.mod.LOG_DIR, "--", label]
  assert set(res) == ACTION_RESULT_KEYS
  assert res["ok"] is True
  assert res["status"] == "success"
  assert res["title"] == "USB4 Diagnostics"
  assert res["script"] == "xgm-usb4-diag"
  assert res["log_key"] == "usb4diag"


def test_a_label_that_looks_like_an_option_stays_a_label(xgm):
  args_file = args_stub(xgm)
  xgm.run(xgm.plugin.collect_usb4_diagnostics("--log-dir"))
  assert args_file.read_text().splitlines()[-2:] == ["--", "--log-dir"]


def test_a_dict_argument_is_unwrapped(xgm):
  # @decky/api call() with an object, as set_power_profile is called
  args_file = args_stub(xgm)
  xgm.run(xgm.plugin.collect_usb4_diagnostics({"label": "plugged"}))
  assert args_file.read_text().splitlines()[-1] == "plugged"


def test_success_message_names_the_log_path(xgm):
  args_stub(xgm)
  res = xgm.run(xgm.plugin.collect_usb4_diagnostics("plugged"))
  assert "~/homebrew/logs/xgmobile-manager/activity/usb4_diagnostics.log" in res["message"]
  assert "#15" in res["message"] and "#16" in res["message"]


def test_the_log_key_maps_to_the_snapshot_log(xgm):
  path = os.path.join(xgm.mod.LOG_DIR, "usb4_diagnostics.log")
  assert xgm.mod.LOG_MAP["usb4diag"] == (path, "USB4 Diagnostics Log")
  with open(path, "w") as f:
    f.write("===== Snapshot 1 =====\n")
  assert xgm.run(xgm.plugin.get_latest_logs("usb4diag")) == "===== Snapshot 1 =====\n"


def test_the_script_output_doesnt_truncate_the_snapshot_log(xgm):
  # _run_script truncates the log it's given; the snapshots must survive a second run.
  snapshots = os.path.join(xgm.mod.LOG_DIR, "usb4_diagnostics.log")
  xgm.stub("xgm-usb4-diag", f'echo "===== Snapshot" >> "{snapshots}"\necho stdout copy')
  xgm.run(xgm.plugin.collect_usb4_diagnostics("unplugged"))
  xgm.run(xgm.plugin.collect_usb4_diagnostics("plugged"))
  with open(snapshots) as f:
    assert f.read() == "===== Snapshot\n===== Snapshot\n"
  with open(xgm.mod.USB4DIAG_RUN_LOG) as f:
    assert "stdout copy" in f.read()


def test_the_exit_3_hint_is_a_cli_run_with_a_writable_folder(xgm):
  # The panel already runs as root, so "run it with sudo" alone wouldn't help: the hint names
  # another folder and the file to attach.
  _message, hint = xgm.mod.SCRIPT_ERROR_CATALOG["xgm-usb4-diag"][3]
  assert "sudo ~/homebrew/plugins/xgmobile-manager/bin/xgm-usb4-diag --log-dir /tmp/xgm-usb4 plugged" in hint
  assert "attach /tmp/xgm-usb4/usb4_diagnostics.log" in hint


@pytest.mark.parametrize("code", [3, 4, 9])
def test_a_failure_maps_to_the_catalog_entry(xgm, code):
  args_stub(xgm, f"exit {code}")
  res = xgm.run(xgm.plugin.collect_usb4_diagnostics("plugged"))
  message, hint = xgm.mod.SCRIPT_ERROR_CATALOG["xgm-usb4-diag"][code]
  assert res["ok"] is False
  assert res["status"] == "error"
  assert res["code"] == code
  assert res["title"] == "USB4 Diagnostics Failed"
  assert (res["message"], res["hint"]) == (message, hint)
  assert res["log_key"] == "usb4diag"


def test_an_uncatalogued_failure_gets_the_generic_copy(xgm):
  args_stub(xgm, "exit 42")
  res = xgm.run(xgm.plugin.collect_usb4_diagnostics("plugged"))
  assert res["ok"] is False
  assert res["message"] == "Collecting the USB4 diagnostics failed (exit code 42)."
  assert "USB4 Diagnostics Log" in res["hint"]


# --- The panel (static: nothing is rendered) ---

from xgm_helpers import REPO  # noqa: E402

PANEL = (REPO / "src" / "components" / "QuickAccessContent.tsx").read_text()


def _maintenance_block():
  start = PANEL.index("{showMaintenance && (")
  end = PANEL.index("{/* Universal Debug Tools */}")
  return PANEL[start:end]


def test_the_button_is_in_setup_and_maintenance_and_not_gated_on_the_asus_interface():
  # Hosts without asus-nb-wmi (Ally X, Legion Go 2) get get_gpu_status errors, connected/active
  # false and no power profile. The row must not depend on any of them, or on the OS/device rows.
  block = _maintenance_block()
  assert "Collect USB4 / Thunderbolt Diagnostics" in block
  usb4 = block[block.index("{/* USB4 / Thunderbolt diagnostics"):]
  assert "rows.includes" not in usb4
  for gate in ("gpuStatus", "statusError", "powerProfile", "osType", "deviceType"):
    assert gate not in usb4, gate
  assert "disabled={isLoading}" in usb4
  # Setup & Maintenance itself is always rendered: its toggle isn't inside any condition.
  toggle = PANEL.index("Setup & Maintenance\n")
  options = PANEL.index('<PanelSection title="Options">')
  assert options < toggle
  assert "&&" not in PANEL[options:PANEL.index("{showMaintenance && (")].split("About Desktop Mode")[1]


def test_the_label_dropdown_resets_the_click_guard_and_the_call_passes_the_label():
  usb4 = _maintenance_block()
  assert re.search(r"onChange=\{\(option: any\) => \{\s*mainButtonGuard\.current = guardUntil\(Date\.now\(\)\);", usb4)
  assert 'call("collect_usb4_diagnostics", usb4DiagLabel)' in PANEL


def test_setup_and_maintenance_stays_open_across_a_re_mount():
  # A pick in the label dropdown re-mounts the panel; the open state comes from module state.
  assert "const [showMaintenance, setShowMaintenance] = useState(rememberedMaintenanceOpen());" in PANEL
  assert "onClick={() => setShowMaintenance(rememberMaintenanceOpen(!showMaintenance))}" in PANEL
  assert "useState(false)" not in PANEL.split("const [showMaintenance")[1].split("\n")[0]
