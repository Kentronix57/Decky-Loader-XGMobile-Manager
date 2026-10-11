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
