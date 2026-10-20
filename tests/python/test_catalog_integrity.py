"""Static contract checks between main.py, bin/ and the frontend. Nothing is executed."""
import re

import pytest

from xgm_helpers import ACTION_RESULT_KEYS, REPO, STATIC, catalog_cases

# Exit codes that come from `set -e` rather than a literal `exit N`: a failing step under the
# EXIT trap leaves with that step's status (1 for nearly every command the installer runs).
IMPLICIT_EXITS = {("install-nvidia.sh", 1)}

# `exit N` in command position: line start, after ; & | ( {, or after then/else/do.
EXIT_RE = re.compile(r"(?:^\s*|[;&|({]\s*|\b(?:then|else|do)\s+)exit\s+(\d+)\b")
HEREDOC_RE = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
COMMENT_START_PREV = set(" \t;&|()")


def shell_code_lines(text):
  """
  Returns each line of a bash script with everything that isn't code removed: comments, quoted
  strings (replaced by ""), and heredoc bodies. Quotes and heredocs are tracked across lines, so
  a multi-line echo string or a heredoc body can't produce a fake `exit N`. A small scanner, not a
  full parser; good enough for the scripts in bin/.
  """
  out = []
  quote = None        # None, '"', "'" or "$'"
  heredocs = []       # pending (terminator, strip_tabs), bodies start on the next line
  for line in text.split("\n"):
    if heredocs and quote is None:
      term, strip_tabs = heredocs[0]
      if (line.lstrip("\t") if strip_tabs else line) == term:
        heredocs.pop(0)
      out.append("")
      continue

    code = []
    i = 0
    while i < len(line):
      c = line[i]
      if quote == '"' or quote == "$'":
        if c == "\\":
          i += 2
          continue
        if c == ("'" if quote == "$'" else '"'):
          quote = None
          code.append('""')
        i += 1
        continue
      if quote == "'":
        if c == "'":
          quote = None
          code.append('""')
        i += 1
        continue

      if c == "\\":
        code.append(line[i:i + 2])
        i += 2
        continue
      if c == "#" and (i == 0 or line[i - 1] in COMMENT_START_PREV):
        break
      if c == "<" and line.startswith("<<", i) and not line.startswith("<<<", i):
        m = HEREDOC_RE.match(line, i)
        if m:
          heredocs.append((m.group(3), m.group(1) == "-"))
          code.append(" ")
          i = m.end()
          continue
      if c == "$" and line.startswith("$'", i):
        quote = "$'"
        i += 2
        continue
      if c in "\"'":
        quote = c
        i += 1
        continue
      code.append(c)
      i += 1
    out.append("".join(code))
  return out


def exit_codes_in(text):
  return [int(c) for line in shell_code_lines(text) for c in EXIT_RE.findall(line)]


def literal_exit_codes(script):
  return set(exit_codes_in((REPO / "bin" / script).read_text()))


@pytest.mark.parametrize("text,codes", [
  ("  exit 4", [4]),
  ("[ -z \"$x\" ] && exit 6", [6]),
  ("if true; then exit 5; fi", [5]),
  ("else exit 2", [2]),
  ('echo "step #1"; exit 9', [9]),
  ("( exit 8 )", [8]),
  ("{ exit 1; }", [1]),
  ("exit 3 # done", [3]),
  ("cat <<-'EOF'\n\texit 4\n\tEOF\nexit 5", [5]),
  ('echo "a\nb"; exit 6', [6]),
])
def test_exit_scanner_counts_real_exits(text, codes):
  assert exit_codes_in(text) == codes


@pytest.mark.parametrize("text", [
  'echo "Retry later.\nexit 3 if it keeps failing"',
  "cat <<EOF\nexit 4\nEOF",
  "cat <<'EOF'\nexit 4\nEOF",
  'cat <<"EOF" > f\nexit 4\nEOF',
  "echo $'it\\'s; exit 7'",
  "echo 'multi\nexit 2\nline'",
  'echo "run the installer, then exit 3 and retry"',
  'echo "ERROR (exit 7)"',
  'echo "escaped \\" quote\nexit 5"',
  "# exit 1",
  "true # ; exit 2",
])
def test_exit_scanner_ignores_strings_heredocs_and_comments(text):
  assert exit_codes_in(text) == []


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


def test_every_executed_script_exists():
  live = "\n".join(l for l in (REPO / "main.py").read_text().splitlines() if not l.strip().startswith("#"))
  scripts = set(re.findall(r"_execute_script\(\s*\"([^\"]+)\"", live))
  assert scripts, "could not find any _execute_script calls"
  for script in scripts:
    assert (REPO / "bin" / script).is_file(), f"main.py runs bin/{script}, which doesn't exist"


def test_dead_repair_services_is_gone():
  assert not hasattr(STATIC.Plugin, "repair_services")
  assert "REPAIR_LOG" not in (REPO / "main.py").read_text()


def test_nvidia_sleep_warning_is_bazzite_only():
  # Sleep works with the NVIDIA eGPU on CachyOS and SteamOS; only Bazzite needs the warning.
  src = (REPO / "src" / "components" / "QuickAccessContent.tsx").read_text()
  expr = re.search(r"const showSleepWarning\s*=\s*(.*?);", src).group(1)
  assert "osType.includes('bazzite')" in expr
  assert "cachyos" not in expr and "steamos" not in expr


def test_power_profile_label_is_honest_and_dropdown_unchanged():
  src = (REPO / "src" / "components" / "QuickAccessContent.tsx").read_text()
  assert "ASUS Power Profile (Ally + XG Mobile)" in src
  assert "Active Power Profile" not in src
  assert ("Sets the Ally's ASUS profile, which also sets the XG Mobile's power limit (on the RTX 4090: "
          "Balanced 120 W, Performance 150 W). Steam's performance setting changes the same profile. "
          "Use Steam's TDP slider to limit the Ally CPU. For full XG Mobile power with a cool CPU, pick "
          "Performance and cap the CPU with Steam's TDP slider or a TDP plugin. If a TDP plugin manages the "
          "ASUS profile (e.g. SimpleDeckyTDP's \"Enable Asus Platform Profile Management\"), turn that off "
          "so this setting and the CPU limit stay separate.") in src
  # Text only: the dropdown still writes the same three profiles through set_power_profile.
  assert re.findall(r'\{ data: "(\w+)", label: "\w+" \}', src) == ["Quiet", "Balanced", "Performance"]
  assert 'call("set_power_profile", { profile: newProfile })' in src
