"""bin/install-nvidia.sh: the exit codes after the EXIT trap is set.

The trap reports any code not recorded in EXPLICIT_EXIT as 1 ("rolled back"), so every deliberate
`exit N` after it must set EXPLICIT_EXIT=N first, or the plugin would show the generic message.
"""
import re

from test_catalog_integrity import shell_code_lines
from xgm_helpers import REPO

SCRIPT = REPO / "bin" / "install-nvidia.sh"
TRAP_LINE = "trap cleanup_on_exit EXIT"


def code_after_trap():
  lines = shell_code_lines(SCRIPT.read_text())
  start = next(i for i, line in enumerate(lines) if line.strip() == TRAP_LINE)
  return lines[start + 1:]


def test_trap_is_exit_only_and_signals_exit_through_it():
  lines = [l.strip() for l in shell_code_lines(SCRIPT.read_text())]
  assert TRAP_LINE in lines
  assert "trap 'exit 130' INT" in SCRIPT.read_text()
  assert "trap 'exit 143' TERM" in SCRIPT.read_text()


def test_every_exit_after_the_trap_is_recorded():
  exits = []
  for line in code_after_trap():
    for m in re.finditer(r"\bexit\s+(\d+)\b", line):
      exits.append(m.group(1))
      assert re.search(rf"EXPLICIT_EXIT={m.group(1)};\s*exit\s+{m.group(1)}\b", line), line
  assert sorted(exits) == ["11", "5", "6"]


def test_dkms_failure_has_its_own_code():
  text = SCRIPT.read_text()
  assert re.search(r'if ! dkms install nvidia/"\$\{NV_VERSION%-\*\}"; then', text)
