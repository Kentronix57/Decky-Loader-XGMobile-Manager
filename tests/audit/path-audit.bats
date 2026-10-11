#!/usr/bin/env bats
# Static safety net: every absolute system path in an in-scope bin/ script must be $ROOT-prefixed,
# so the sandboxed tests can never read or write the host. Exceptions live in tests/bin/ALLOWLIST.
# This is a gate: `pnpm test:bin` and tests/run-all.sh run it, and stop if it fails, before any
# bin/ script is executed.

setup_file() {
  load ../bin/helpers/sandbox
  refuse_root
}

setup() {
  load ../bin/helpers/sandbox
  ALLOWLIST="$XGM_REPO/tests/bin/ALLOWLIST"
}

# Prints the ALLOWLIST entries as "<script>\t<kind>\t<value>" (kind: skip|until|allow).
allowlist_entries() {
  local line script rest
  while IFS= read -r line; do
    [[ -z "${line// }" || "$line" == \#* ]] && continue
    script="${line%% *}"
    rest=""
    [[ "$line" == *" "* ]] && rest="${line#* }"
    case "$rest" in
      "") printf '%s\tskip\t\n' "$script" ;;
      "@until "*) printf '%s\tuntil\t%s\n' "$script" "${rest#@until }" ;;
      "@allow "*) printf '%s\tallow\t%s\n' "$script" "${rest#@allow }" ;;
      *) echo "bad ALLOWLIST line: $line" >&2; return 1 ;;
    esac
  done < "$ALLOWLIST"
}

# Prints "<file>:<n>: <line>" for every unprefixed absolute path in one script.
audit_script() {
  local rel="$1" until="" kind value n=0 line stripped
  local -a allows=()
  while IFS=$'\t' read -r _ kind value; do
    case "$kind" in
      until) until="$value" ;;
      allow) allows+=("$value") ;;
    esac
  done < <(allowlist_entries | awk -F'\t' -v s="$rel" '$1 == s')

  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ -n "$until" ]; then
      local trimmed="${line#"${line%%[![:space:]]*}"}"
      [ "$trimmed" = "$until" ] && break
    fi
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    stripped="$line"
    for value in "${allows[@]}"; do
      stripped="${stripped//"$value"/}"
    done
    stripped="${stripped//\$ROOT\//}"
    stripped="${stripped//\/dev\/null/}"
    if [[ "$stripped" =~ /(sys|etc|dev|usr|home)/ ]]; then
      echo "$rel:$n: $line"
    fi
  done < "$XGM_REPO/$rel"
}

in_scope_scripts() {
  local f rel
  for f in "$XGM_REPO"/bin/*; do
    rel="bin/${f##*/}"
    allowlist_entries | awk -F'\t' -v s="$rel" '$1 == s && $2 == "skip" { found=1 } END { exit !found }' && continue
    echo "$rel"
  done
}

@test "ALLOWLIST parses and only names existing scripts" {
  run allowlist_entries
  assert_success
  local script
  while IFS=$'\t' read -r script _ _; do
    assert [ -f "$XGM_REPO/$script" ]
  done <<< "$output"
}

@test "@until markers exist in their scripts" {
  local script kind value
  while IFS=$'\t' read -r script kind value; do
    [ "$kind" = "until" ] || continue
    awk -v m="$value" '{ sub(/^[[:space:]]+/, "") } $0 == m { found=1 } END { exit !found }' "$XGM_REPO/$script" \
      || fail "$script: @until marker not found: $value"
  done < <(allowlist_entries)
}

@test "no unprefixed absolute paths in in-scope bin/ scripts" {
  local rel violations=""
  while IFS= read -r rel; do
    violations+="$(audit_script "$rel")"
  done < <(in_scope_scripts)
  [ -z "$violations" ] || fail "$(printf 'absolute paths missing the $ROOT prefix:\n%s' "$violations")"
}

@test "scripts that use \$ROOT define it from XGM_ROOT" {
  local rel
  while IFS= read -r rel; do
    if grep -q '\$ROOT/' "$XGM_REPO/$rel"; then
      grep -qx 'ROOT="${XGM_ROOT:-}"' "$XGM_REPO/$rel" || fail "$rel uses \$ROOT but doesn't define ROOT=\"\${XGM_ROOT:-}\""
    fi
  done < <(in_scope_scripts)
}

@test "the audit catches a missing prefix" {
  local tmp="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmp"
  printf '%s\n' '#!/bin/bash' 'ROOT="${XGM_ROOT:-}"' '# /etc/comment is fine' 'cat $ROOT/etc/os-release' 'echo x > /dev/null' 'rm -f /etc/environment' > "$tmp/probe"
  XGM_REPO="$BATS_TEST_TMPDIR" run audit_script bin/probe
  assert_output "bin/probe:6: rm -f /etc/environment"
}
