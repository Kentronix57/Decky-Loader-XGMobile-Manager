"""Static contract checks between main.py, bin/ and the frontend. Nothing is executed."""
import re

import pytest

from xgm_helpers import ACTION_RESULT_KEYS, REPO, STATIC, catalog_cases

# Exit codes that come from `set -e` rather than a literal `exit N`: a failing step under the
# EXIT trap leaves with that step's status (1 for nearly every command the installer runs).
IMPLICIT_EXITS = {("install-nvidia.sh", 1)}

# `exit N` in command position only (line start, after ; & | or then/else/do). Quoted strings are
# removed first, so the words "exit 3" inside an echo don't count.
EXIT_RE = re.compile(r"(?:^\s*|[;&|]\s*|\b(?:then|else|do)\s+)exit\s+(\d+)\b")
QUOTED_RE = re.compile(r"\"(?:[^\"\\]|\\.)*\"|'[^']*'")


def exit_codes_in(line):
  return [int(c) for c in EXIT_RE.findall(QUOTED_RE.sub('""', line))]


def literal_exit_codes(script):
  codes = set()
  for line in (REPO / "bin" / script).read_text().splitlines():
    if line.lstrip().startswith("#"):
      continue
    codes.update(exit_codes_in(line.split(" #", 1)[0]))
  return codes


@pytest.mark.parametrize("line,codes", [
  ("  exit 4", [4]),
  ("[ -z \"$x\" ] && exit 6", [6]),
  ("if true; then exit 5; fi", [5]),
  ("else exit 2", [2]),
  ('echo "run the installer, then exit 3 and retry"', []),
  ('echo "ERROR (exit 7)"', []),
])
def test_exit_regex_only_matches_command_position(line, codes):
  assert exit_codes_in(line) == codes


@pytest.mark.parametrize("script,code", catalog_cases())
def test_catalog_code_has_matching_exit_in_script(script, code):
  assert (REPO / "bin" / script).is_file(), f"bin/{script} is missing"
  if (script, code) in IMPLICIT_EXITS:
    text = (REPO / "bin" / script).read_text()
    assert re.search(r"^set -e$", text, re.M), f"{script}: exit {code} relies on set -e"
    assert re.search(r"^trap cleanup_on_exit EXIT", text, re.M), f"{script}: exit {code} relies on the EXIT trap"
    return
  assert code in literal_exit_codes(script), f"SCRIPT_ERROR_CATALOG[{script!r}][{code}] has no `exit {code}` in bin/{script}"


def test_implicit_exits_are_still_in_the_catalog():
  assert IMPLICIT_EXITS <= set(catalog_cases())


def test_catalog_scripts_have_meta():
  assert set(STATIC.SCRIPT_ERROR_CATALOG) <= set(STATIC.SCRIPT_META)


def test_catalog_messages_fit_a_toast():
  for script, codes in STATIC.SCRIPT_ERROR_CATALOG.items():
    for code, (message, _hint) in codes.items():
      assert len(message) <= 120, (script, code)


@pytest.mark.parametrize("script", sorted(STATIC.SCRIPT_META))
def test_script_meta_points_at_real_script_and_log(script):
  assert (REPO / "bin" / script).is_file()
  assert STATIC.SCRIPT_META[script]["log_key"] in STATIC.LOG_MAP


def parse_log_options():
  src = (REPO / "src" / "components" / "LogViewerModal.tsx").read_text()
  block = re.search(r"const LOG_OPTIONS[^=]*=\s*\[(.*?)\];", src, re.S).group(1)
  live = "\n".join(l for l in block.splitlines() if not l.strip().startswith("//"))
  return dict(re.findall(r"\{\s*data:\s*'([^']+)',\s*label:\s*'([^']+)'\s*\}", live))


def test_log_map_matches_log_viewer_dropdown():
  options = parse_log_options()
  assert options, "could not parse LOG_OPTIONS"
  assert {key: label for key, (_path, label) in STATIC.LOG_MAP.items()} == options


def parse_action_result_interface():
  src = (REPO / "src" / "lib" / "notify.tsx").read_text()
  body = re.search(r"export interface ActionResult\s*\{(.*?)\}", src, re.S).group(1)
  return set(re.findall(r"^\s*(\w+)\s*:", body, re.M))


def test_result_keys_match_frontend_action_result():
  fields = parse_action_result_interface()
  assert fields, "could not parse interface ActionResult"
  assert set(ACTION_RESULT_KEYS) == fields
