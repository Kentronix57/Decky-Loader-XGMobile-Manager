"""Enable/eject results that outlive the frontend: get_pending_result and the desktop Eject link."""
import json
import os
import pwd
import subprocess
import time

import pytest

from xgm_helpers import STATIC


def pending(xgm):
  return xgm.run(xgm.plugin.get_pending_result())


def execute(xgm, script):
  log_path = xgm.mod.LOG_MAP[STATIC.SCRIPT_META[script]["log_key"]][0]
  return xgm.run(xgm.plugin._execute_script(script, log_path))


def write_marker(xgm, age=0):
  with open(xgm.mod.EJECT_CANCELLED_MARKER, "w") as f:
    f.write(f"{int(time.time() - age)}\n")


@pytest.mark.parametrize("script", ["egpu-enable", "egpu-eject"])
def test_failure_is_persisted_and_returned_once(xgm, script):
  xgm.stub(script, "exit 97")
  res = execute(xgm, script)
  assert res["ok"] is False

  saved = json.load(open(xgm.mod.PENDING_RESULT_PATH))
  assert saved["result"] == res
  assert abs(saved["timestamp"] - time.time()) < 60

  assert pending(xgm) == res
  assert pending(xgm) is None
  assert not os.path.exists(xgm.mod.PENDING_RESULT_PATH)


def test_other_scripts_are_not_persisted(xgm):
  xgm.stub("create-shortcuts", "exit 97")
  execute(xgm, "create-shortcuts")
  assert not os.path.exists(xgm.mod.PENDING_RESULT_PATH)
  assert pending(xgm) is None


def test_success_clears_an_older_failure(xgm):
  xgm.stub("egpu-eject", "exit 97")
  execute(xgm, "egpu-eject")
  write_marker(xgm)
  xgm.stub("egpu-eject", "exit 0")
  assert execute(xgm, "egpu-eject")["ok"] is True
  assert not os.path.exists(xgm.mod.PENDING_RESULT_PATH)
  assert not os.path.exists(xgm.mod.EJECT_CANCELLED_MARKER)
  assert pending(xgm) is None


def test_expired_result_is_dropped(xgm):
  with open(xgm.mod.PENDING_RESULT_PATH, "w") as f:
    json.dump({"timestamp": time.time() - xgm.mod.PENDING_RESULT_MAX_AGE - 5,
               "result": STATIC._result(False, "error", "t", "m")}, f)
  assert pending(xgm) is None
  assert not os.path.exists(xgm.mod.PENDING_RESULT_PATH)


def test_unreadable_result_is_dropped(xgm):
  with open(xgm.mod.PENDING_RESULT_PATH, "w") as f:
    f.write("{not json")
  assert pending(xgm) is None
  assert not os.path.exists(xgm.mod.PENDING_RESULT_PATH)


def test_cancel_marker_becomes_the_catalogued_exit_7(xgm):
  write_marker(xgm)
  res = pending(xgm)
  message, hint = STATIC.SCRIPT_ERROR_CATALOG["egpu-eject"][7]
  assert res["ok"] is False
  assert res["code"] == 7
  assert res["script"] == "egpu-eject"
  assert res["message"] == message
  assert res["hint"] == hint
  assert res["log_key"] == "eject"
  assert not os.path.exists(xgm.mod.EJECT_CANCELLED_MARKER)
  assert pending(xgm) is None


def test_expired_cancel_marker_is_dropped(xgm):
  write_marker(xgm, age=xgm.mod.PENDING_RESULT_MAX_AGE + 5)
  assert pending(xgm) is None
  assert not os.path.exists(xgm.mod.EJECT_CANCELLED_MARKER)


def test_saved_result_wins_over_the_marker(xgm):
  xgm.stub("egpu-eject", "exit 7")
  res = execute(xgm, "egpu-eject")
  write_marker(xgm)
  assert pending(xgm) == res
  assert not os.path.exists(xgm.mod.EJECT_CANCELLED_MARKER)


# The desktop Eject link runs egpu-eject itself (watch_eject_request -> _handle_eject_request).
@pytest.fixture
def desktop_eject(xgm, monkeypatch):
  monkeypatch.setenv("DECKY_USER", pwd.getpwuid(os.getuid()).pw_name)
  xgm.set_os("steamos")
  calls = []
  state = {"eject_rc": 0}

  def fake_run(cmd, *args, **kwargs):
    calls.append(cmd)
    rc = state["eject_rc"] if cmd[0].endswith("/bin/egpu-eject") else 0
    return subprocess.CompletedProcess(cmd, rc, stdout="", stderr="")

  monkeypatch.setattr(xgm.mod.subprocess, "run", fake_run)

  def run(rc):
    state["eject_rc"] = rc
    xgm.run(xgm.plugin._handle_eject_request())
    return calls

  return run


def session_switches(calls):
  return [c for c in calls if c[0] == "sudo"]


def test_desktop_eject_failure_skips_the_session_switch_and_is_kept(xgm, desktop_eject):
  calls = desktop_eject(7)
  assert any(c[0].endswith("/bin/egpu-eject") for c in calls)
  assert session_switches(calls) == []
  log = open(xgm.mod.EJECTDESKTOP_LOG).read()
  assert "Eject failed with exit code 7. Staying in Desktop Mode" in log
  res = pending(xgm)
  assert res["code"] == 7
  assert res["message"] == STATIC.SCRIPT_ERROR_CATALOG["egpu-eject"][7][0]


def test_desktop_eject_success_switches_to_game_mode(xgm, desktop_eject):
  calls = desktop_eject(0)
  assert session_switches(calls), "expected steamos-session-select"
  assert pending(xgm) is None


# The desktop Enable link runs egpu-enable itself (watch_enable_request -> _handle_enable_request).
@pytest.fixture
def desktop_enable(xgm, monkeypatch):
  monkeypatch.setenv("DECKY_USER", pwd.getpwuid(os.getuid()).pw_name)
  xgm.set_os("steamos")
  calls = []
  state = {"enable_rc": 0}

  def fake_run(cmd, *args, **kwargs):
    calls.append(cmd)
    rc = state["enable_rc"] if cmd[0].endswith("/bin/egpu-enable") else 0
    return subprocess.CompletedProcess(cmd, rc, stdout="", stderr="")

  monkeypatch.setattr(xgm.mod.subprocess, "run", fake_run)

  def run(rc):
    state["enable_rc"] = rc
    xgm.run(xgm.plugin._handle_enable_request())
    return calls

  return run


def test_desktop_enable_failure_is_kept_and_skips_the_session_switch(xgm, desktop_enable):
  calls = desktop_enable(5)
  assert any(c[0].endswith("/bin/egpu-enable") for c in calls)
  assert session_switches(calls) == []
  res = pending(xgm)
  assert res["code"] == 5
  assert res["script"] == "egpu-enable"


def test_desktop_enable_success_clears_an_older_eject_failure(xgm, desktop_enable):
  xgm.stub("egpu-eject", "exit 97")
  execute(xgm, "egpu-eject")
  write_marker(xgm)
  calls = desktop_enable(0)
  assert session_switches(calls), "expected steamos-session-select"
  assert not os.path.exists(xgm.mod.PENDING_RESULT_PATH)
  assert not os.path.exists(xgm.mod.EJECT_CANCELLED_MARKER)
  assert pending(xgm) is None
