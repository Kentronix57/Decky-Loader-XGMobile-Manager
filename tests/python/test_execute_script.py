"""_execute_script: exit code -> ActionResult mapping, run against stub scripts in a temp plugin dir."""
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
  if (script, code) == ("install-nvidia.sh", 10):
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


def test_install_exit_10_is_already_installed(xgm):
  xgm.stub("install-nvidia.sh", "exit 10")
  res = execute(xgm, "install-nvidia.sh")
  assert res["ok"] is True
  assert res["status"] == "already_installed"
  assert res["code"] == 10


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
