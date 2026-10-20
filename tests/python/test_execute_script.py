"""_execute_script: exit code -> ActionResult mapping, run against stub scripts in a temp plugin dir."""
import os

import pytest

from xgm_helpers import STATIC, catalog_cases

# Spelled out on purpose: the frontend's ActionResult interface depends on exactly these names.
ACTION_RESULT_KEYS = {"ok", "status", "code", "script", "title", "message", "hint", "log_key"}


def execute(xgm, script):
  log_path = xgm.mod.LOG_MAP[STATIC.SCRIPT_META[script]["log_key"]][0]
  return xgm.run(xgm.plugin._execute_script(script, log_path))


@pytest.mark.parametrize("script,code", catalog_cases())
def test_catalog_codes_map_to_catalog_copy(xgm, script, code):
  xgm.stub(script, f"exit {code}")
  res = execute(xgm, script)

  message, hint = STATIC.SCRIPT_ERROR_CATALOG[script][code]
  assert set(res) == ACTION_RESULT_KEYS
  assert res["message"] == message
  assert res["hint"] == hint
  assert len(res["message"]) <= 120
  assert res["code"] == code
  assert res["script"] == script
  assert res["log_key"] == STATIC.SCRIPT_META[script]["log_key"]
  if (script, code) in {("install-nvidia.sh", 10), ("install-nvidia-cachyos.sh", 10)}:
    assert res["ok"] is True
    assert res["status"] == "already_installed"
  else:
    assert res["ok"] is False
    assert res["status"] == "error"
    assert res["title"] == STATIC.SCRIPT_META[script]["fail_title"]


@pytest.mark.parametrize("script", sorted(STATIC.SCRIPT_META))
def test_exit_zero_gives_success_copy(xgm, script):
  xgm.stub(script, "exit 0")
  res = execute(xgm, script)

  meta = STATIC.SCRIPT_META[script]
  assert set(res) == ACTION_RESULT_KEYS
  assert res["ok"] is True
  assert res["status"] == "success"
  assert res["code"] == 0
  assert res["title"] == meta["title"]
  assert res["message"] == meta["message"]
  assert res["hint"] == ""
  assert res["log_key"] == meta["log_key"]


@pytest.mark.parametrize("script", sorted(STATIC.SCRIPT_META))
def test_unknown_code_gives_generic_fallback_naming_log(xgm, script):
  xgm.stub(script, "exit 97")
  res = execute(xgm, script)

  meta = STATIC.SCRIPT_META[script]
  label = STATIC.LOG_MAP[meta["log_key"]][1]
  assert set(res) == ACTION_RESULT_KEYS
  assert res["ok"] is False
  assert res["status"] == "error"
  assert res["code"] == 97
  assert res["title"] == meta["fail_title"]
  assert res["message"] == f"{meta['action']} failed (exit code 97)."
  assert len(res["message"]) <= 120
  assert label in res["hint"]
  assert res["log_key"] == meta["log_key"]


def test_uncatalogued_eject_code_is_generic(xgm):
  xgm.stub("egpu-eject", "exit 1")
  res = execute(xgm, "egpu-eject")
  assert res["message"] == "Ejecting the XG Mobile failed (exit code 1)."
  assert "Eject Log" in res["hint"]


def test_missing_script_gives_plugin_file_missing(xgm):
  res = execute(xgm, "egpu-enable")  # no stub written

  assert set(res) == ACTION_RESULT_KEYS
  assert res["ok"] is False
  assert res["status"] == "error"
  assert res["code"] is None
  assert res["message"].startswith("Plugin file missing: bin/egpu-enable.")
  assert res["hint"] != ""
  assert res["log_key"] == ""


def test_script_output_lands_in_its_log(xgm):
  xgm.stub("egpu-enable", 'echo "hello from stub"\nexit 0')
  execute(xgm, "egpu-enable")
  log = open(xgm.mod.ENABLE_LOG).read()
  assert "--- Script Started: egpu-enable" in log
  assert "hello from stub" in log


@pytest.mark.parametrize("script,kind", [("egpu-enable", "enable"), ("egpu-eject", "eject")])
def test_previous_run_log_behind_latest_link_is_not_truncated(xgm, script, kind):
  # enable_latest.log / eject_latest.log link to the last run's log, which the script keeps as
  # .prev.log before writing its own; opening the link with "w" would empty it first.
  log_dir = xgm.mod.LOG_DIR
  previous = f"{log_dir}/{kind}_nvidia.log"
  with open(previous, "w") as f:
    f.write("previous run\n")
  latest = xgm.mod.LOG_MAP[kind][0]
  os.symlink(previous, latest)
  seen = xgm.tmp / "seen.txt"
  xgm.stub(script, f'cp "{previous}" "{seen}"\necho "this run"')
  xgm.run(xgm.plugin._execute_script(script, latest, "nvidia", "steamos", log_dir, "/d"))
  assert seen.read_text().startswith("previous run\n")
  assert "this run" in open(latest).read()


def test_regular_log_file_is_still_truncated(xgm):
  with open(xgm.mod.INSTALL_LOG, "w") as f:
    f.write("old install\n")
  xgm.stub("install-nvidia.sh", 'echo "new install"')
  execute(xgm, "install-nvidia.sh")
  log = open(xgm.mod.INSTALL_LOG).read()
  assert "old install" not in log
  assert "new install" in log


def rotating_stub(xgm, script, kind):
  """A stub that logs like egpu-enable/egpu-eject: keeps the last run's <kind>_<vendor>.log as
  .prev.log, writes its own, and points <kind>_latest.log at it."""
  xgm.stub(script, "\n".join([
    f'log="$3/{kind}_$1.log"',
    f'[ -f "$log" ] && mv -f "$log" "$3/{kind}_$1.prev.log"',
    'exec > "$log" 2>&1',
    'echo "run 2 ($1)"',
    f'ln -sf "$log" "$3/{kind}_latest.log"',
  ]))


@pytest.mark.parametrize("script,kind", [("egpu-enable", "enable"), ("egpu-eject", "eject")])
def test_prev_log_holds_only_the_previous_run(xgm, script, kind):
  log_dir = xgm.mod.LOG_DIR
  with open(f"{log_dir}/{kind}_nvidia.log", "w") as f:
    f.write("run 1\n")
  latest = xgm.mod.LOG_MAP[kind][0]
  os.symlink(f"{log_dir}/{kind}_nvidia.log", latest)
  rotating_stub(xgm, script, kind)
  res = xgm.run(xgm.plugin._execute_script(script, latest, "nvidia", "steamos", log_dir, "/d"))
  assert res["ok"] is True
  assert open(f"{log_dir}/{kind}_nvidia.prev.log").read() == "run 1\n"
  assert open(f"{log_dir}/{kind}_nvidia.log").read() == "run 2 (nvidia)\n"
  assert os.readlink(latest) == f"{log_dir}/{kind}_nvidia.log"


@pytest.mark.parametrize("script,kind", [("egpu-enable", "enable"), ("egpu-eject", "eject")])
def test_vendor_switch_leaves_the_other_vendors_log_alone(xgm, script, kind):
  log_dir = xgm.mod.LOG_DIR
  with open(f"{log_dir}/{kind}_nvidia.log", "w") as f:
    f.write("nvidia run\n")
  latest = xgm.mod.LOG_MAP[kind][0]
  os.symlink(f"{log_dir}/{kind}_nvidia.log", latest)
  rotating_stub(xgm, script, kind)
  xgm.run(xgm.plugin._execute_script(script, latest, "amd", "steamos", log_dir, "/d"))
  assert open(f"{log_dir}/{kind}_nvidia.log").read() == "nvidia run\n"
  assert open(f"{log_dir}/{kind}_amd.log").read() == "run 2 (amd)\n"
  assert not os.path.exists(f"{log_dir}/{kind}_amd.prev.log")
  assert os.readlink(latest) == f"{log_dir}/{kind}_amd.log"


def test_header_is_the_first_line_of_a_regular_log(xgm):
  xgm.stub("install-nvidia.sh", 'echo "line 1 from the script"\necho "line 2 from the script"')
  execute(xgm, "install-nvidia.sh")
  lines = open(xgm.mod.INSTALL_LOG).read().splitlines()
  assert lines[0].startswith("--- Script Started: install-nvidia.sh at ")
  assert lines[0].endswith(" ---")
  assert lines[1:] == ["line 1 from the script", "line 2 from the script"]


@pytest.mark.parametrize("script", ["install-nvidia.sh", "install-nvidia-cachyos.sh"])
def test_install_exit_10_is_already_installed(xgm, script):
  xgm.stub(script, "exit 10")
  res = execute(xgm, script)
  assert res["ok"] is True
  assert res["status"] == "already_installed"
  assert res["code"] == 10


def test_exit_10_from_other_scripts_is_an_error(xgm):
  xgm.stub("egpu-enable", "exit 10")
  res = execute(xgm, "egpu-enable")
  assert res["ok"] is False
  assert res["status"] == "error"


def test_install_exit_1_is_error_not_already_installed(xgm):
  xgm.stub("install-nvidia.sh", "exit 1")
  res = execute(xgm, "install-nvidia.sh")
  assert res["ok"] is False
  assert res["status"] == "error"
  assert res["code"] == 1
  assert res["message"] == STATIC.SCRIPT_ERROR_CATALOG["install-nvidia.sh"][1][0]


def test_args_are_passed_through(xgm):
  out = xgm.tmp / "args.txt"
  xgm.stub("egpu-enable", f'echo "$@" > "{out}"')
  xgm.run(xgm.plugin._execute_script("egpu-enable", xgm.mod.ENABLE_LOG, "nvidia", "steamos", "/l", "/d"))
  assert out.read_text().strip() == "nvidia steamos /l /d"


def test_steamos_installer_unsupported_os_hint_is_bazzite_only():
  # CachyOS is dispatched to its own installer, so this copy is only ever seen on Bazzite.
  message, hint = STATIC.SCRIPT_ERROR_CATALOG["install-nvidia.sh"][2]
  assert "CachyOS" not in message + hint
  assert "bazzite-deck-nvidia" in hint


@pytest.mark.parametrize("code", [3, 4])
def test_enable_config_hints_cover_steamos_and_cachyos(code):
  _, hint = STATIC.SCRIPT_ERROR_CATALOG["egpu-enable"][code]
  assert "On SteamOS, run Advanced → Install NVIDIA Drivers" in hint
  assert "sudo pacman -S nvidia-utils" in hint


def test_cachyos_pending_updates_hint_names_both_update_routes():
  _, hint = STATIC.SCRIPT_ERROR_CATALOG["install-nvidia-cachyos.sh"][3]
  assert "In Game Mode, go to Settings → System → Check for Updates" in hint
  assert "sudo pacman -Syu" in hint
  assert "The install log names the package that didn't match." in hint
