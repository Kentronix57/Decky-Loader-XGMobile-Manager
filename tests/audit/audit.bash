# shellcheck shell=bash
# Path audit: every absolute system path in an in-scope bin/ script must be $ROOT-prefixed, so the
# sandboxed bin/ tests can never read or write the host. Exceptions live in tests/bin/ALLOWLIST.
#
# Used two ways: path-audit.bats tests each check (with self-tests), and helpers/sandbox.bash runs
# audit_all as a gate before any bin/ script executes. Requires $XGM_REPO.

XGM_ALLOWLIST="$XGM_REPO/tests/bin/ALLOWLIST"

# An absolute path starting at a system top-level directory, not in the middle of a longer path.
ABS_PATH_RE='(^|[^A-Za-z0-9_.}/~-])/(sys|etc|dev|usr|home|tmp|var|run|opt|lib)([^A-Za-z0-9_]|$)'

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
  done < "$XGM_ALLOWLIST"
}

# Prints "<file>:<n>: <line>" for every unprefixed absolute path in one script.
audit_script() {
  local rel="$1" until="" kind value n=0 line stripped trimmed
  local -a allows=()
  while IFS=$'\t' read -r _ kind value; do
    case "$kind" in
      until) until="$value" ;;
      allow) allows+=("$value") ;;
    esac
  done < <(allowlist_entries | awk -F'\t' -v s="$rel" '$1 == s || ($1 == "*" && $2 == "allow")')

  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ -n "$until" ]; then
      trimmed="${line#"${line%%[![:space:]]*}"}"
      [ "$trimmed" = "$until" ] && break
    fi
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    stripped="$line"
    for value in "${allows[@]}"; do
      stripped="${stripped//"$value"/}"
    done
    stripped="${stripped//\$ROOT\//}"
    if [[ "$stripped" =~ $ABS_PATH_RE ]]; then
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

# Each check prints its problems and returns 1 if there are any.

audit_check_allowlist() {
  local entries script kind status=0
  entries="$(allowlist_entries)" || return 1
  while IFS=$'\t' read -r script kind _; do
    [ -n "$script" ] || continue
    if [ "$script" = "*" ]; then
      [ "$kind" = "allow" ] || { echo "ALLOWLIST: '*' only supports @allow"; status=1; }
    elif [ ! -f "$XGM_REPO/$script" ]; then
      echo "ALLOWLIST names a missing script: $script"
      status=1
    fi
  done <<< "$entries"
  return "$status"
}

audit_check_until_markers() {
  local script kind value status=0
  while IFS=$'\t' read -r script kind value; do
    [ "$kind" = "until" ] || continue
    awk -v m="$value" '{ sub(/^[[:space:]]+/, "") } $0 == m { found=1 } END { exit !found }' "$XGM_REPO/$script" \
      || { echo "$script: @until marker not found: $value"; status=1; }
  done < <(allowlist_entries)
  return "$status"
}

audit_check_paths() {
  local rel v violations=""
  while IFS= read -r rel; do
    while IFS= read -r v; do
      violations+="$v"$'\n'
    done < <(audit_script "$rel")
  done < <(in_scope_scripts)
  [ -z "$violations" ] && return 0
  printf 'absolute paths missing the $ROOT prefix:\n%s' "$violations"
  return 1
}

audit_check_root_defined() {
  local rel status=0
  while IFS= read -r rel; do
    if grep -q '\$ROOT/' "$XGM_REPO/$rel" && ! grep -qx 'ROOT="${XGM_ROOT:-}"' "$XGM_REPO/$rel"; then
      echo "$rel uses \$ROOT but doesn't define ROOT=\"\${XGM_ROOT:-}\""
      status=1
    fi
  done < <(in_scope_scripts)
  return "$status"
}

# Runs every check; prints all problems and returns 1 if any check failed.
audit_all() {
  local status=0
  audit_check_allowlist || status=1
  audit_check_until_markers || status=1
  audit_check_paths || status=1
  audit_check_root_defined || status=1
  return "$status"
}
