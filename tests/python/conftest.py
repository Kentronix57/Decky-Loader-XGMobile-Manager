import asyncio
from pathlib import Path
from types import SimpleNamespace

import pytest

from xgm_helpers import OS_RELEASES, load_main
from settings import SettingsManager


@pytest.fixture
def xgm(tmp_path, monkeypatch):
  """
  An isolated copy of the backend: main.py imported from tmp_path, bin/ holding per-test stub
  scripts, and every hardware/OS path constant pointed at a fake tree under tmp_path/sysroot.
  """
  plugin_dir = tmp_path / "homebrew" / "plugins" / "xgmobile-manager"
  mod = load_main(plugin_dir)
  Path(mod.LOG_DIR).mkdir(parents=True, exist_ok=True)

  sysroot = tmp_path / "sysroot"
  os_release = sysroot / "etc" / "os-release"
  dmi = sysroot / "sys" / "class" / "dmi" / "id" / "product_name"
  wmi = sysroot / "sys" / "devices" / "platform" / "asus-nb-wmi"
  flag = sysroot / "var" / "tmp" / "xgmobile_desktop_trigger"
  for d in (os_release.parent, dmi.parent, wmi, flag.parent):
    d.mkdir(parents=True, exist_ok=True)

  monkeypatch.setattr(mod, "OS_RELEASE_PATH", str(os_release))
  monkeypatch.setattr(mod, "DMI_PRODUCT_PATH", str(dmi))
  monkeypatch.setattr(mod, "ASUS_WMI_DIR", str(wmi))
  monkeypatch.setattr(mod, "DESKTOP_FLAG_PATH", str(flag))

  settings = SettingsManager()
  mod.Plugin.settings = settings

  def stub(script, body):
    """Writes bin/<script>; main.py runs it as `bash <path> ...`."""
    path = plugin_dir / "bin" / script
    path.write_text(f"#!/bin/bash\n{body}\n")
    return path

  def set_os(os_type):
    os_release.write_text(OS_RELEASES[os_type])

  def set_product(name):
    dmi.write_text(name + "\n")

  return SimpleNamespace(
    mod=mod,
    plugin=mod.Plugin(),
    settings=settings,
    plugin_dir=plugin_dir,
    bin=plugin_dir / "bin",
    os_release=os_release,
    dmi=dmi,
    wmi=wmi,
    flag=flag,
    tmp=tmp_path,
    stub=stub,
    set_os=set_os,
    set_product=set_product,
    run=asyncio.run,
  )


@pytest.fixture
def plugin(xgm):
  return xgm.plugin
