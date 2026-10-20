"""get_telemetry: runs bin/get-gpu-stats off the event loop and always returns the numeric keys."""
import json
import time

import pytest

NUMERIC_KEYS = {"temp_c", "util_pct", "vram_mb", "vram_total_mb", "power_w", "power_limit_w"}


def stats_script(xgm, body):
  # get_telemetry runs the script directly, not through bash
  xgm.stub("get-gpu-stats", body).chmod(0o755)


def test_get_telemetry_returns_the_script_json(xgm):
  stats = {"vendor": "nvidia", "temp": "61°C", "util": "87%", "vram": "5120MB", "power": "142.30W",
           "temp_c": 61, "util_pct": 87, "vram_mb": 5120, "vram_total_mb": 16376, "power_w": 142.3,
           "power_limit_w": 150.0}
  stats_script(xgm, f"echo '{json.dumps(stats)}'")
  assert xgm.run(xgm.plugin.get_telemetry()) == stats


def test_get_telemetry_runs_through_to_thread(xgm, monkeypatch):
  stats_script(xgm, 'echo \'{"vendor": "none"}\'')
  in_thread = []
  direct = []
  calls = []
  real_run = xgm.mod.subprocess.run

  def run(argv, **kwargs):
    (in_thread if in_thread and in_thread[-1] == "open" else direct).append(list(argv))
    calls.append(kwargs)
    return real_run(argv, **kwargs)

  async def to_thread(func, *args, **kwargs):
    in_thread.append("open")
    try:
      return func(*args, **kwargs)
    finally:
      in_thread.append("closed")

  monkeypatch.setattr(xgm.mod.subprocess, "run", run)
  monkeypatch.setattr(xgm.mod.asyncio, "to_thread", to_thread)
  assert xgm.run(xgm.plugin.get_telemetry()) == {"vendor": "none"}
  assert direct == []
  # The data dir is the first argument, as for the other scripts: it holds the eGPU's PCI address.
  assert in_thread == ["open", [str(xgm.bin / "get-gpu-stats"), xgm.mod.DATA_DIR], "closed"]
  assert calls[0]["timeout"] == xgm.mod.TELEMETRY_TIMEOUT == 5
  assert calls[0]["encoding"] == "utf-8"


@pytest.mark.parametrize("body,text", [
  ("exit 1", "Err"),              # the script failed
  ("echo 'not json'", "--"),      # unparsable output
])
def test_get_telemetry_fallbacks_include_the_numeric_keys(xgm, body, text):
  stats_script(xgm, body)
  result = xgm.run(xgm.plugin.get_telemetry())
  assert result == {"vendor": "none", "temp": text, "util": text, "vram": text, "power": text,
                    **{key: None for key in NUMERIC_KEYS}}


def test_get_telemetry_times_out_to_the_fallback(xgm, monkeypatch):
  # A hung nvidia-smi must not stall the 3 s poll.
  stats_script(xgm, "sleep 10")
  monkeypatch.setattr(xgm.mod, "TELEMETRY_TIMEOUT", 0.2)
  start = time.monotonic()
  result = xgm.run(xgm.plugin.get_telemetry())
  assert time.monotonic() - start < 5
  assert result == {"vendor": "none", "temp": "--", "util": "--", "vram": "--", "power": "--",
                    **{key: None for key in NUMERIC_KEYS}}
