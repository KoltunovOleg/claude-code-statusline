#!/usr/bin/env bash
# Claude Code status line installer for macOS and Linux (bash, no dependencies).
#
# Quick install:
#   curl -fsSL https://raw.githubusercontent.com/KoltunovOleg/claude-code-statusline/main/install.sh | bash
# Or download and run:
#   bash install.sh

# Everything runs inside main(), so a partially downloaded script never executes.

write_statusline() {
cat <<'STATUSLINE_EOF'
#!/usr/bin/env bash
# Claude Code status line (bash version for macOS and Linux).
# Reads the session JSON from stdin and prints two colored lines.
# No dependencies beyond bash, sed, awk and (optionally) git.

# Options (set by the installer)
cwd_own_line=0   # 1: show the folder on a third line
max_branch=0     # above 0: shorten longer git branch names to this length

input=$(cat)
[ -z "${input//[[:space:]]/}" ] && exit 0

# --- Parse JSON --------------------------------------------------------------
# Prints one "path=value" line per scalar inside objects, e.g.
# "model.display_name=Opus". Values inside arrays and nulls are skipped.
# Control characters are removed from strings, so a value can never start a new
# line here or send escape sequences to the terminal.
fields=$(printf '%s' "$input" | LC_ALL=C awk '
  function clean(s) {
    gsub(/[\001-\037\177]/, "", s)
    gsub(/\302[\200-\237]/, "", s)   # C1 control characters (U+0080-U+009F) in UTF-8
    return s
  }
  function hexval(h,   k, v) {
    v = 0
    for (k = 1; k <= 4; k++) v = v * 16 + index("0123456789abcdef", tolower(substr(h, k, 1))) - 1
    return v
  }
  function read_string(   out, c, cp) {
    out = ""; i++
    while (i <= n) {
      c = substr(S, i, 1)
      if (c == "\"") { i++; return clean(out) }
      if (c == "\\") {
        c = substr(S, i + 1, 1); i += 2
        if (c == "u") {
          cp = hexval(substr(S, i, 4)); i += 4
          if (cp >= 32 && cp < 127) out = out sprintf("%c", cp)
          else if (cp >= 160) out = out "?"   # non-ASCII arrives unescaped from Claude Code
        }
        else if (c == "n" || c == "t" || c == "r") out = out " "
        else if (c == "\"" || c == "\\" || c == "/") out = out c
        continue
      }
      out = out c; i++
    }
    return clean(out)
  }
  # Dotted path of the current value, or "" if it is inside an array or a key is unusual
  function path(   k, p) {
    if (d < 1) return ""
    p = ""
    for (k = 1; k <= d; k++) {
      if (typ[k] != "{" || key[k] !~ /^[A-Za-z0-9_]+$/) return ""
      p = (k == 1) ? key[k] : p "." key[k]
    }
    return p
  }
  function emit(v,   p) {
    p = path()
    if (p != "" && !(p in seen)) { seen[p] = 1; print p "=" v }
  }
  { S = S $0 "\n" }
  END {
    n = length(S); i = 1; d = 0
    while (i <= n) {
      c = substr(S, i, 1)
      if (c == "{" || c == "[") { d++; typ[d] = c; key[d] = ""; want_key[d] = (c == "{"); i++ }
      else if (c == "}" || c == "]") { if (d > 0) d--; i++ }
      else if (c == ",") { if (d > 0 && typ[d] == "{") want_key[d] = 1; i++ }
      else if (c == ":" || c == " " || c == "\t" || c == "\r" || c == "\n") i++
      else if (c == "\"") {
        v = read_string()
        if (d > 0 && typ[d] == "{" && want_key[d]) { key[d] = v; want_key[d] = 0 }
        else emit(v)
      } else {
        j = i
        while (j <= n && substr(S, j, 1) !~ /[],} \t\r\n]/) j++
        v = clean(substr(S, i, j - i)); i = (j > i) ? j : i + 1
        if (v != "null") emit(v)
      }
    }
  }')

sid=""; model_name=""; model_id=""; cwd=""; cwd_top=""; effort=""; effort_level=""
total_cost=""; total_cost_alt=""; last_turn_cost=""; last_turn_cost_alt=""; api_ms=""; ctx_size=""
in_tok=""; cache_read=""; cache_new=""; u_in_tok=""; u_cache_read=""; u_cache_new=""
pc_warm=""; pc_exp=""; pc_ttl=""; pc_obs=""
while IFS='=' read -r k v; do
  case "$k" in
    session_id) sid=$v ;;
    model.display_name) model_name=$v ;;
    model.id) model_id=$v ;;
    workspace.current_dir) cwd=$v ;;
    cwd) cwd_top=$v ;;
    effort) effort=$v ;;
    effort.level) effort_level=$v ;;
    cost.total_cost_usd) total_cost=$v ;;
    cost.totalCost) total_cost_alt=$v ;;
    cost.last_turn_cost_usd) last_turn_cost=$v ;;
    cost.lastTurnCost) last_turn_cost_alt=$v ;;
    cost.total_api_duration_ms) api_ms=$v ;;
    context_window.context_window_size) ctx_size=$v ;;
    context_window.current_usage.input_tokens) in_tok=$v ;;
    context_window.current_usage.cache_read_input_tokens) cache_read=$v ;;
    context_window.current_usage.cache_creation_input_tokens) cache_new=$v ;;
    usage.input_tokens) u_in_tok=$v ;;
    usage.cache_read_input_tokens) u_cache_read=$v ;;
    usage.cache_creation_input_tokens) u_cache_new=$v ;;
    prompt_cache.warm) pc_warm=$v ;;
    prompt_cache.expires_at) pc_exp=$v ;;
    prompt_cache.ttl) pc_ttl=$v ;;
    prompt_cache.caching_observed) pc_obs=$v ;;
  esac
done <<EOF
$fields
EOF

[ -n "$effort_level" ] && effort=$effort_level
model=${model_name:-${model_id:-Claude}}
cwd=${cwd:-${cwd_top:-$PWD}}
folder=$(basename -- "$cwd")
total_cost=${total_cost:-$total_cost_alt}
last_turn_cost=${last_turn_cost:-$last_turn_cost_alt}
# Older Claude Code versions send usage instead of context_window.current_usage
if [ -z "$in_tok$cache_read$cache_new" ]; then
  in_tok=$u_in_tok; cache_read=$u_cache_read; cache_new=$u_cache_new
fi
# The session id becomes part of temp file names, so allow only id characters
case "$sid" in *[!A-Za-z0-9-]*) sid="" ;; esac
tmp=${TMPDIR:-/tmp}; tmp=${tmp%/}

branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
# Long branch names push the last fields off screen, so keep the start only
[ "$max_branch" -gt 0 ] && [ ${#branch} -gt "$max_branch" ] && branch="${branch:0:max_branch-1}…"

# --- Cost of the last turn (from the previous total) ------------------------
prev_cost=""
if [ -n "$sid" ]; then
  cost_file="$tmp/claude_cost_$sid.txt"
  [ -f "$cost_file" ] && prev_cost=$(cat "$cost_file" 2>/dev/null)
  printf '%s' "${total_cost:-0}" > "$cost_file" 2>/dev/null
fi

# --- Session duration --------------------------------------------------------
duration=0
if [ -n "$sid" ]; then
  time_file="$tmp/claude_session_$sid.time"
  now=$(date +%s)
  start=""
  [ -f "$time_file" ] && start=$(cat "$time_file" 2>/dev/null)
  case "$start" in ''|*[!0-9]*) start=$now; printf '%s' "$now" > "$time_file" 2>/dev/null ;; esac
  duration=$(( now - start ))
fi

# --- Last request duration (from cumulative API time) ------------------------
last_api=0
if [ -n "$sid" ] && [ -n "$api_ms" ]; then
  api_file="$tmp/claude_api_$sid.txt"
  saved=""
  [ -f "$api_file" ] && saved=$(cat "$api_file" 2>/dev/null)
  result=$(LC_ALL=C awk -v total="$api_ms" -v saved="$saved" 'BEGIN {
    n = split(saved, a, ";"); prev = (n >= 1) ? a[1] + 0 : 0; last = (n >= 2) ? a[2] + 0 : 0
    total += 0
    if (total > prev) { last = total - prev; printf "W %d;%d %d\n", total, last, last }
    else printf "K - %d\n", last
  }')
  set -- $result
  [ "$1" = "W" ] && printf '%s' "$2" > "$api_file" 2>/dev/null
  last_api=$3
fi

# --- Prompt cache expiry as local HH:MM (GNU date, then BSD date) ----------
pc_until=""
case "$pc_exp" in
  ''|*[!0-9]*) ;;
  *) pc_until=$(date -d "@$pc_exp" +%H:%M 2>/dev/null || date -r "$pc_exp" +%H:%M 2>/dev/null) ;;
esac

# --- Render ------------------------------------------------------------------
# Values go through the environment, not awk -v, because -v turns backslash
# sequences such as \033 in a folder name into real control characters.
SL_EFFORT=$effort SL_MODEL=$model SL_FOLDER=$folder SL_BRANCH=$branch SL_SID=$sid \
SL_TOTAL=${total_cost:-0} SL_LAST_TURN=${last_turn_cost:-0} SL_PREV=$prev_cost \
SL_IN_TOK=${in_tok:-0} SL_CREAD=${cache_read:-0} SL_CNEW=${cache_new:-0} SL_CTX_SIZE=${ctx_size:-0} \
SL_DURATION=$duration SL_LAST_API=$last_api SL_CWD_OWN_LINE=$cwd_own_line \
SL_PC_WARM=$pc_warm SL_PC_UNTIL=$pc_until SL_PC_TTL=$pc_ttl SL_PC_OBS=$pc_obs \
LC_ALL=C awk '
function clean(s) {
  gsub(/[\001-\037\177]/, "", s)
  gsub(/\302[\200-\237]/, "", s)
  return s
}
function rgb(r, g, b) { return sprintf("\033[38;2;%d;%d;%dm", r, g, b) }
function tint(r, g, b) { return rgb(int(r*0.35 + 30*0.65 + 0.5), int(g*0.35 + 37*0.65 + 0.5), int(b*0.35 + 48*0.65 + 0.5)) }
function rep(s, n,   out, i) { out = ""; for (i = 0; i < n; i++) out = out s; return out }
function bar(ratio, color, track,   f) {
  if (ratio < 0) ratio = 0; if (ratio > 1) ratio = 1
  f = int(ratio * 8 + 0.5)
  return rep(BLOCK, f) track rep(BLOCK, 8 - f) color
}
function fk(n) { return (n >= 1000) ? sprintf("%.1fk", n / 1000) : sprintf("%d", n) }
function join(arr, n,   s, i) { s = arr[1]; for (i = 2; i <= n; i++) s = s " | " arr[i]; return s }
BEGIN {
  effort = clean(ENVIRON["SL_EFFORT"]); model = clean(ENVIRON["SL_MODEL"])
  folder = clean(ENVIRON["SL_FOLDER"]); branch = clean(ENVIRON["SL_BRANCH"]); sid = ENVIRON["SL_SID"]
  total = ENVIRON["SL_TOTAL"]; last_turn = ENVIRON["SL_LAST_TURN"]; prev = ENVIRON["SL_PREV"]
  in_tok = ENVIRON["SL_IN_TOK"] + 0; cread = ENVIRON["SL_CREAD"] + 0; cnew = ENVIRON["SL_CNEW"] + 0
  ctx_size = ENVIRON["SL_CTX_SIZE"]; duration = ENVIRON["SL_DURATION"] + 0; last_api = ENVIRON["SL_LAST_API"] + 0
  cwd_own_line = ENVIRON["SL_CWD_OWN_LINE"] + 0
  pc_warm = ENVIRON["SL_PC_WARM"]; pc_until = clean(ENVIRON["SL_PC_UNTIL"])
  pc_ttl = clean(ENVIRON["SL_PC_TTL"]); pc_obs = ENVIRON["SL_PC_OBS"]

  BLOCK = "\342\226\207"   # U+2587 lower seven eighths block
  cyan = rgb(86,182,194); magenta = rgb(198,120,221); yellow = rgb(229,192,123)
  blue = rgb(97,175,239); green = rgb(152,195,121); red = rgb(224,85,97)
  gray = rgb(139,146,156); pink = rgb(224,108,117); reset = "\033[0m"

  # Short session id
  short = (sid == "") ? "none" : substr(sid, 1, 6)

  # Cost
  total += 0; lt = last_turn + 0
  p = (prev == "" || prev + 0 == 0) ? total : prev + 0
  if (lt == 0 && total >= p) lt = total - p
  cost = sprintf("$%.2f (+$%.3f)", total, lt)

  # Context
  limit = (ctx_size + 0 > 0) ? ctx_size + 0 : 200000
  used = in_tok + cread + cnew
  ratio = used / limit
  pct = int(ratio * 100 + 0.5)
  ccol = green; ctrack = tint(152,195,121)
  if (pct >= 85)      { ccol = red;    ctrack = tint(224,85,97) }
  else if (pct >= 60) { ccol = yellow; ctrack = tint(229,192,123) }

  # Cache
  ctot = cread + cnew
  cratio = (ctot > 0) ? cread / ctot : 0

  # Duration
  h = int(duration / 3600); m = int((duration % 3600) / 60); s = duration % 60
  if (h > 0) dur = h "h " m "m"; else if (m > 0) dur = m "m " s "s"; else dur = s "s"

  # Last request
  lastq = ""
  if (last_api > 0) {
    secs = last_api / 1000
    if (secs >= 60) lastq = int(secs / 60) "m " int(secs % 60) "s"
    else lastq = sprintf("%.1fs", secs)
  }

  n = 0
  if (effort != "") l1[++n] = pink effort reset
  l1[++n] = cyan model reset
  l1[++n] = ccol "ctx " bar(ratio, ccol, ctrack) " " pct "% (" fk(used) "/" fk(limit) ")" reset
  l1[++n] = blue "cache " bar(cratio, blue, tint(97,175,239)) " r:" fk(cread) " (+" fk(cnew) " new)" reset
  l1[++n] = red cost reset
  print join(l1, n)

  n = 0
  cwd_part = magenta "cwd:" folder reset
  if (cwd_own_line != 1) l2[++n] = cwd_part
  if (branch != "") l2[++n] = yellow "git:" branch reset
  l2[++n] = gray "sid:" short reset
  l2[++n] = gray "time: " dur reset
  if (lastq != "") l2[++n] = cyan "last: " lastq reset
  # Prompt cache state (Claude Code re-runs the status line when the cache expires)
  if (pc_obs != "false") {
    if (pc_warm == "true") {
      pc = "cache warm"
      if (pc_until != "") pc = pc " until " pc_until
      if (pc_ttl != "" && pc_ttl != "null") pc = pc " (" pc_ttl ")"
      l2[++n] = green pc reset
    } else if (pc_warm == "false") l2[++n] = yellow "cache cold" reset
  }
  print join(l2, n)
  if (cwd_own_line == 1) print cwd_part
}'
STATUSLINE_EOF
}

# Status line script with the chosen options filled in: render_statusline <cwd_own_line> <max_branch>
render_statusline() {
  write_statusline | sed -e "s/^cwd_own_line=0 /cwd_own_line=$1 /" -e "s/^max_branch=0 /max_branch=$2 /"
}

yes_no() { [ "$1" != 0 ] && echo yes || echo no; }

# --- Output helpers ------------------------------------------------------------
c_info=$'\033[36m'; c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_off=$'\033[0m'
info() { printf '%s%s%s\n' "$c_info" "$1" "$c_off"; }
ok()   { printf '%s%s%s\n' "$c_ok" "$1" "$c_off"; }
warn() { printf '%s%s%s\n' "$c_warn" "$1" "$c_off"; }
err()  { printf '%s%s%s\n' "$c_err" "$1" "$c_off"; }

# Ask a y/n question. Reads from the terminal, so it works with "curl ... | bash".
confirm() {
  local answer
  printf '%s (y/n): ' "$1"
  if ! read -r answer < /dev/tty; then
    echo
    err 'No terminal available to answer the question.'
    return 1
  fi
  case "$answer" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

# Run a status line script with sample data and print its output
run_sample() {
  local script=$1 sid tmpdir
  sid="sample$$$(date +%s)"
  tmpdir=${TMPDIR:-/tmp}; tmpdir=${tmpdir%/}
  printf '{"session_id":"%s","effort":{"level":"medium"},"model":{"display_name":"Sonnet 4.6"},"workspace":{"current_dir":"%s"},"cost":{"total_cost_usd":0.12,"total_api_duration_ms":14200},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":5000,"cache_read_input_tokens":20000,"cache_creation_input_tokens":3000}}}' \
    "$sid" "$PWD" | bash "$script"
  rm -f "$tmpdir"/claude_*"$sid"* 2>/dev/null
}

# --- settings.json editing (awk only, string-aware) ---------------------------
# Modes:
#   get <file>          print the current top-level statusLine value (one line)
#   set <file> <json>   print the file with the top-level "statusLine" set to <json>
# Exit code 2 means the file does not look like a JSON object we can edit safely.
settings_edit() {
  local mode=$1 file=$2 value=${3:-}
  LC_ALL=C awk -v mode="$mode" -v value="$value" '
    function scan(s,   i, c, n, depth, instr, esc) {
      # Sets globals: OPEN, CLOSE (outer braces), KEY (position of top-level "statusLine"), BAD
      OPEN = 0; CLOSE = 0; KEY = 0; BAD = 0; depth = 0; instr = 0; esc = 0; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (instr) {
          if (esc) esc = 0
          else if (c == "\\") esc = 1
          else if (c == "\"") instr = 0
          continue
        }
        if (c == "\"") {
          if (depth == 1 && KEY == 0 && substr(s, i, 12) == "\"statusLine\"") KEY = i
          instr = 1
        } else if (c == "{" || c == "[") {
          depth++
          if (depth == 1) { if (OPEN) BAD = 1; else if (c == "{") OPEN = i; else BAD = 1 }
        } else if (c == "}" || c == "]") {
          depth--
          if (depth < 0) BAD = 1
          if (depth == 0 && CLOSE == 0) CLOSE = i
        } else if (depth == 0 && c !~ /[ \t\r\n]/) BAD = 1
      }
      if (depth != 0 || instr || !OPEN || !CLOSE) BAD = 1
    }
    function value_end(s, i,   n, c, depth, instr, esc) {
      # i points at the first character of a JSON value; returns its last position
      n = length(s); c = substr(s, i, 1)
      if (c == "{" || c == "[") {
        depth = 0; instr = 0; esc = 0
        for (; i <= n; i++) {
          c = substr(s, i, 1)
          if (instr) { if (esc) esc = 0; else if (c == "\\") esc = 1; else if (c == "\"") instr = 0; continue }
          if (c == "\"") instr = 1
          else if (c == "{" || c == "[") depth++
          else if (c == "}" || c == "]") { depth--; if (depth == 0) return i }
        }
        return 0
      }
      if (c == "\"") {
        esc = 0
        for (i++; i <= n; i++) {
          c = substr(s, i, 1)
          if (esc) esc = 0; else if (c == "\\") esc = 1; else if (c == "\"") return i
        }
        return 0
      }
      for (; i <= n; i++) { c = substr(s, i + 1, 1); if (c ~ /[],} \t\r\n]/ || c == "") return i }
      return 0
    }
    { S = S $0 "\n" }
    END {
      scan(S)
      if (BAD) exit 2
      if (KEY) {
        i = KEY + 12
        while (substr(S, i, 1) ~ /[ \t\r\n]/) i++
        if (substr(S, i, 1) != ":") exit 2
        i++
        while (substr(S, i, 1) ~ /[ \t\r\n]/) i++
        e = value_end(S, i)
        if (!e) exit 2
        if (mode == "get") { v = substr(S, i, e - i + 1); gsub(/[ \t\r\n]+/, " ", v); print v; exit 0 }
        out = substr(S, 1, KEY - 1) value substr(S, e + 1)
      } else {
        if (mode == "get") exit 0
        inner = substr(S, OPEN + 1, CLOSE - OPEN - 1)
        if (inner ~ /^[ \t\r\n]*$/) out = substr(S, 1, OPEN) "\n  " value "\n" substr(S, CLOSE)
        else out = substr(S, 1, OPEN) "\n  " value "," substr(S, OPEN + 1)
      }
      scan(out)
      if (BAD) exit 2
      printf "%s", out
    }' "$file"
}

main() {
  echo
  info '=== Claude Code status line installer ==='
  echo

  # 1. Check that Claude Code is installed
  local claude_dir="$HOME/.claude"
  if ! command -v claude >/dev/null 2>&1 && [ ! -d "$claude_dir" ]; then
    err 'Claude Code is not installed on this machine (neither the "claude" command nor the ~/.claude folder was found).'
    err 'The status line was not installed.'
    exit 1
  fi
  ok 'Claude Code found.'

  local script_path="$claude_dir/statusline.sh"
  local settings_path="$claude_dir/settings.json"
  local command="bash $script_path"
  case "$script_path" in *[[:space:]]*) command="bash \"$script_path\"" ;; esac
  # JSON-escape the command (backslashes and quotes)
  local command_json=${command//\\/\\\\}
  command_json=${command_json//\"/\\\"}
  local statusline_json
  statusline_json=$(printf '"statusLine": {\n    "type": "command",\n    "command": "%s"\n  }' "$command_json")

  # 2. Existing statusline.sh
  if [ -e "$script_path" ]; then
    echo
    warn "WARNING: file already exists: $script_path"
    warn 'The installer will overwrite it and will NOT make a backup.'
    warn 'If you want to keep your current status line, back it up yourself first, e.g.:'
    printf '  cp "%s" "%s.bak"\n\n' "$script_path" "$script_path"
    if ! confirm 'Replace the existing statusline.sh?'; then
      warn 'Cancelled. Nothing was changed.'
      exit 0
    fi
  fi

  # 3. Option: folder on its own line
  local cwd_own_line=0
  echo
  info 'Option 1 of 2: folder on a separate line'
  echo '  By default the folder (cwd) is the first field of line 2. A long folder name'
  echo '  can push the last fields (last, cache warm/cold) off screen.'
  echo '  Moving it to a third line keeps line 2 short.'
  confirm 'Show the folder on a third line?' && cwd_own_line=1

  # 4. Option: shorten long git branch names
  local branch_limit=24 max_branch=0
  echo
  info 'Option 2 of 2: shorten long git branch names'
  echo "  Branch names longer than $branch_limit characters can push the last fields off screen."
  echo "  If shortened, only the first $branch_limit characters are shown, ending with '…'."
  confirm 'Shorten long git branch names?' && max_branch=$branch_limit

  # 5. Preview
  echo
  info 'Preview of the status line (sample data, not your real session):'
  echo
  local preview
  preview=$(mktemp "${TMPDIR:-/tmp}/statusline-preview.XXXXXX") || { err 'Could not create a temp file.'; exit 1; }
  render_statusline "$cwd_own_line" "$max_branch" > "$preview"
  run_sample "$preview" | sed 's/^/  /'
  rm -f "$preview"

  echo
  info 'What will be done:'
  echo "  - write file: $script_path"
  echo "      folder on a third line: $(yes_no "$cwd_own_line")"
  echo "      shorten long git branch names: $(yes_no "$max_branch")"
  echo "  - set statusLine in $settings_path to:"
  echo "      $command"

  local current=""
  if grep -q '[^[:space:]]' "$settings_path" 2>/dev/null; then
    current=$(settings_edit get "$settings_path")
    if [ $? -eq 2 ]; then
      err "Could not safely edit $settings_path (unexpected format)."
      warn 'Nothing was changed. You can install manually: save the status line as ~/.claude/statusline.sh'
      warn 'and add this to settings.json:'
      printf '  %s\n' "$statusline_json"
      exit 1
    fi
    case "$current" in
      ''|*"\"command\": \"$command_json\""*|*"\"command\":\"$command_json\""*) ;;
      *) warn "  - the current statusLine will be replaced: $current" ;;
    esac
  fi

  echo
  if ! confirm 'Continue with the installation?'; then
    warn 'Cancelled. Nothing was changed.'
    exit 0
  fi

  # 6. Install
  mkdir -p "$claude_dir" || { err "Could not create $claude_dir"; exit 1; }
  render_statusline "$cwd_own_line" "$max_branch" > "$script_path" && chmod +x "$script_path" || { err "Could not write $script_path"; exit 1; }

  local new_settings
  if [ -s "$settings_path" ] && ! grep -q '[^[:space:]]' "$settings_path"; then
    : > "$settings_path"   # whitespace-only file counts as empty
  fi
  if [ -s "$settings_path" ]; then
    new_settings=$(settings_edit set "$settings_path" "$statusline_json") || {
      err "Could not update $settings_path. The status line file was written, but settings.json was not changed."
      exit 1
    }
  else
    new_settings=$(printf '{\n  %s\n}' "$statusline_json")
  fi
  local tmp_settings
  tmp_settings=$(mktemp "$claude_dir/settings.json.XXXXXX") || { err 'Could not create a temp file.'; exit 1; }
  printf '%s\n' "$new_settings" > "$tmp_settings"
  [ -f "$settings_path" ] && chmod "$(stat -c %a "$settings_path" 2>/dev/null || stat -f %Lp "$settings_path")" "$tmp_settings" 2>/dev/null
  mv "$tmp_settings" "$settings_path" || { err "Could not write $settings_path"; rm -f "$tmp_settings"; exit 1; }

  ok 'Files written.'

  # 7. Verify
  echo
  info 'Checking the installed status line:'
  echo
  local check
  check=$(run_sample "$script_path")
  printf '%s\n' "$check" | sed 's/^/  /'

  local lines settings_ok=0
  lines=$(printf '%s\n' "$check" | grep -c .)
  grep -qF "\"command\": \"$command_json\"" "$settings_path" && settings_ok=1

  echo
  if [ "$settings_ok" -eq 1 ] && [ "$lines" -ge 2 ]; then
    ok 'Done! The status line is installed. Start a new Claude Code session to see it.'
  else
    [ "$settings_ok" -eq 1 ] || err 'Error: statusLine in settings.json does not match the expected value.'
    [ "$lines" -ge 2 ] || err 'Error: the status line did not print the expected two lines.'
    exit 1
  fi
}

main "$@"
