#!/usr/bin/env bash
# Runs both status line versions (from install.sh and install-statusline.ps1) on
# the JSON samples in tests/fixtures and checks their output.
#
#   bash tests/compare.sh            run the checks
#   bash tests/compare.sh --update   rewrite the .expected files from the bash output
#
# For each fixture NAME.json:
#   - the bash output must match NAME.expected
#   - the PowerShell output must match NAME.ps.expected if it exists, else NAME.expected
#   - with gawk installed, bash with "gawk --posix" must print the same as plain awk
#   - no output may contain control characters other than the color codes
# Colors are removed and the session time is masked before comparing.
# PowerShell is skipped if neither powershell nor pwsh is installed.

root=$(cd "$(dirname "$0")/.." && pwd) || exit 1
fixtures="$root/tests/fixtures"
update=0
[ "${1:-}" = "--update" ] && update=1

work=$(mktemp -d "${TMPDIR:-/tmp}/statusline-test.XXXXXX") || { echo 'Could not create a temp folder.'; exit 1; }
trap 'rm -rf "${work:?}"' EXIT

# Extract the embedded status line scripts
sed -n "/^cat <<'STATUSLINE_EOF'/,/^STATUSLINE_EOF/p" "$root/install.sh" | sed '1d;$d' > "$work/statusline.sh"
sed -n "/^\$StatusLineContent = @'/,/^'@/p" "$root/install-statusline.ps1" | sed '1d;$d' > "$work/statusline.ps1"
if [ ! -s "$work/statusline.sh" ] || [ ! -s "$work/statusline.ps1" ]; then
  echo 'Could not extract the status line scripts from the installers.'
  exit 1
fi

ps_exe=""
if command -v powershell >/dev/null 2>&1; then ps_exe=powershell
elif command -v pwsh >/dev/null 2>&1; then ps_exe=pwsh
fi

# "awk" that runs gawk in POSIX mode, to catch gawk-only features
posix_bin=""
if command -v gawk >/dev/null 2>&1; then
  posix_bin="$work/posix-bin"
  mkdir -p "$posix_bin"
  printf '#!/bin/sh\nexec gawk --posix "$@"\n' > "$posix_bin/awk"
  chmod +x "$posix_bin/awk"
fi

# Every run gets an empty temp folder, so cost and timing start fresh
run_bash() {
  local t; t=$(mktemp -d "$work/tmp.XXXXXX")
  TMPDIR=$t bash "$work/statusline.sh" < "$1"
}
run_bash_posix() {
  local t; t=$(mktemp -d "$work/tmp.XXXXXX")
  TMPDIR=$t PATH="$posix_bin:$PATH" bash "$work/statusline.sh" < "$1"
}
run_ps() {
  local t; t=$(mktemp -d "$work/tmp.XXXXXX")
  TMPDIR=$t TMP=$t TEMP=$t "$ps_exe" -NoProfile -ExecutionPolicy Bypass -File "$work/statusline.ps1" < "$1"
}

# Remove Windows line endings and color codes
strip_colors() { sed -e 's/\r$//' -e 's/\x1b\[[0-9;]*m//g'; }
normalize() { strip_colors | sed -E 's/time: [0-9]+[hms]( [0-9]+[ms])?/time: T/'; }
# Count control characters left after removing color codes (C0, DEL, C1 in UTF-8)
count_control() { strip_colors | LC_ALL=C tr -d '\n' | LC_ALL=C grep -c $'[\x01-\x1f\x7f]\|\xc2[\x80-\x9f]'; }

failures=0
fail() { echo "  FAIL: $1"; failures=$((failures + 1)); }

check_output() {   # check_output <label> <raw output> <expected file>
  local label=$1 out=$2 expected=$3
  if [ "$(printf '%s\n' "$out" | count_control)" != 0 ]; then
    fail "$label output contains control characters"
  fi
  if [ "$(printf '%s\n' "$out" | normalize)" != "$(cat "$expected")" ]; then
    fail "$label output differs from $(basename "$expected")"
    diff <(cat "$expected") <(printf '%s\n' "$out" | normalize) | sed 's/^/    /'
  fi
}

for json in "$fixtures"/*.json; do
  name=$(basename "$json" .json)
  expected="$fixtures/$name.expected"
  echo "$name"

  bash_out=$(run_bash "$json")
  if [ "$update" = 1 ]; then
    printf '%s\n' "$bash_out" | normalize > "$expected"
    echo "  updated $name.expected"
  fi
  [ -f "$expected" ] || { fail "missing $name.expected (run with --update)"; continue; }
  check_output bash "$bash_out" "$expected"

  if [ -n "$posix_bin" ] && [ "$(run_bash_posix "$json")" != "$bash_out" ]; then
    fail 'bash output with gawk --posix differs from plain awk'
  fi

  if [ -n "$ps_exe" ]; then
    ps_expected="$fixtures/$name.ps.expected"
    [ -f "$ps_expected" ] || ps_expected=$expected
    check_output PowerShell "$(run_ps "$json")" "$ps_expected"
  fi
done

echo
[ -n "$ps_exe" ] || echo 'Note: PowerShell not found, only the bash version was checked.'
[ -n "$posix_bin" ] || echo 'Note: gawk not found, the POSIX awk check was skipped.'
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed."
  exit 1
fi
echo 'All checks passed.'
