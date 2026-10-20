#!/usr/bin/env bats
# Static safety net: every absolute system path in an in-scope bin/ script must be $ROOT-prefixed,
# so the sandboxed tests can never read or write the host. The checks live in audit.bash; the same
# checks gate every bin/ test file (helpers/sandbox.bash runs them before any script executes).
# Exceptions live in tests/bin/ALLOWLIST.

setup_file() {
  load ../bin/helpers/sandbox
  refuse_root
}

setup() {
  load ../bin/helpers/sandbox
}

@test "ALLOWLIST parses and only names existing scripts" {
  run audit_check_allowlist
  assert_success
}

@test "@until markers exist in their scripts" {
  run audit_check_until_markers
  assert_success
}

@test "no unprefixed absolute paths in in-scope bin/ scripts" {
  run audit_check_paths
  assert_success
}

@test "scripts that use \$ROOT define it from XGM_ROOT" {
  run audit_check_root_defined
  assert_success
}

@test "the audit catches a missing prefix" {
  local tmp="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmp"
  printf '%s\n' '#!/bin/bash' 'ROOT="${XGM_ROOT:-}"' '# /etc/comment is fine' 'cat $ROOT/etc/os-release' 'echo x > /dev/null' 'rm -f /etc/environment' 'cat $ROOT/usr/lib/x $DATA_DIR/system/var/y' 'touch /var/tmp/flag' 'cd /tmp' > "$tmp/probe"
  XGM_REPO="$BATS_TEST_TMPDIR" run audit_script bin/probe
  assert_output "$(printf '%s\n' 'bin/probe:6: rm -f /etc/environment' 'bin/probe:8: touch /var/tmp/flag' 'bin/probe:9: cd /tmp')"
}

# Runs the audit on a throwaway script containing one line; prints the flagged line, if any.
audit_line() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '%s\n' '#!/bin/bash' "$1" > "$BATS_TEST_TMPDIR/bin/probe"
  XGM_REPO="$BATS_TEST_TMPDIR" audit_script bin/probe
}

@test "/dev/null look-alikes are flagged" {
  local line
  for line in \
    'echo x > /dev/null2' \
    'cat $x/dev/nullfoo' \
    'cat /dev/null/../../home/x' \
    'cat /dev/nullx/../etc/passwd'; do
    run audit_line "$line"
    assert_output "bin/probe:2: $line"
  done
}

@test "plain /dev/null redirections are not flagged" {
  local line
  for line in \
    'cmd >/dev/null 2>&1' \
    'cmd 2>/dev/null || true' \
    'cmd &>/dev/null; other </dev/null' \
    'x=$(cmd 2>/dev/null)'; do
    run audit_line "$line"
    assert_output ""
  done
}

@test "a path right after a variable is flagged" {
  run audit_line 'rm -f $PREFIX/etc/x'
  assert_output "bin/probe:2: rm -f \$PREFIX/etc/x"
  run audit_line 'rm -f ${PREFIX}/etc/x'
  assert_output "bin/probe:2: rm -f \${PREFIX}/etc/x"
}
