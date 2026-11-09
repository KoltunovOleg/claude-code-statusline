# Claude Code status line installer for Windows (PowerShell).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install-statusline.ps1
#
# On macOS and Linux use install.sh instead (bash, nothing to install).
# This script also runs there under PowerShell 7 if you already have it:
#   pwsh -NoProfile -File ./install-statusline.ps1

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---------------------------------------------------------------------------
# Embedded status line (written to ~/.claude/statusline.ps1)
# ---------------------------------------------------------------------------
$StatusLineContent = @'
# Options (set by the installer)
$CwdOnOwnLine = $false   # $true: show the folder on a third line
$MaxBranch    = 0        # above 0: shorten longer git branch names to this length

$ErrorActionPreference = 'SilentlyContinue'
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$inv = [System.Globalization.CultureInfo]::InvariantCulture

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }
$data = $raw | ConvertFrom-Json

$FULL  = [string][char]0x2587   # lower seven eighths block: a slightly thinner bar

function Round-Half($x) { [math]::Floor([double]$x + 0.5) }

# Bar: filled cells in the segment color, empty cells as a dark tint of it
function Make-Bar($ratio, $color, $track, $total = 8) {
  $r = [double]$ratio
  if ($r -lt 0) { $r = 0 }
  if ($r -gt 1) { $r = 1 }
  $filled = [int](Round-Half ($r * $total))
  return ($FULL * $filled) + $track + ($FULL * ($total - $filled)) + $color
}

function Format-K($n) {
  if ($n -ge 1000) { return ($n / 1000).ToString('0.0', $inv) + 'k' }
  return "$n"
}

# Remove control characters, so values from JSON cannot send escape sequences to the terminal
function Remove-Control($s) {
  if ($null -eq $s) { return $null }
  return ([string]$s) -replace '[\t\r\n]', ' ' -replace '[\x00-\x1F\x7F-\x9F]', ''
}

$tmp = [System.IO.Path]::GetTempPath()

# 1. Session ID (part of temp file names, so allow only id characters)
$sid = if ("$($data.session_id)" -match '^[A-Za-z0-9-]+$') { [string]$data.session_id } else { 'unknown' }
$shortSid = if ($sid -ne 'unknown') { $sid.Substring(0, [math]::Min(6, $sid.Length)) } else { 'none' }

# 2. Cost (total + last turn)
[double]$totalCost = 0
if ($data.cost.total_cost_usd) { $totalCost = [double]$data.cost.total_cost_usd }
elseif ($data.cost.totalCost) { $totalCost = [double]$data.cost.totalCost }

[double]$lastCost = 0
if ($data.cost.last_turn_cost_usd) { $lastCost = [double]$data.cost.last_turn_cost_usd }
elseif ($data.cost.lastTurnCost) { $lastCost = [double]$data.cost.lastTurnCost }

if ($sid -ne 'unknown') {
  $costFile = Join-Path $tmp "claude_cost_$sid.txt"
  $prev = $totalCost
  if (Test-Path $costFile) {
    [double]$p = 0
    $txt = "$(Get-Content $costFile -Raw)".Trim()
    if ([double]::TryParse($txt, [System.Globalization.NumberStyles]::Float, $inv, [ref]$p) -and $p -ne 0) { $prev = $p }
  }
  if ($lastCost -eq 0 -and $totalCost -ge $prev) { $lastCost = $totalCost - $prev }
  Set-Content -Path $costFile -Value $totalCost.ToString($inv) -NoNewline
}
$costDisplay = '$' + $totalCost.ToString('0.00', $inv) + ' (+$' + $lastCost.ToString('0.000', $inv) + ')'

# 3. Session duration
$durationStr = '0s'
if ($sid -ne 'unknown') {
  $timeFile = Join-Path $tmp "claude_session_$sid.time"
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $start = $now
  if (Test-Path $timeFile) {
    [long]$st = 0
    $txt = "$(Get-Content $timeFile -Raw)".Trim()
    if ([long]::TryParse($txt, [ref]$st) -and $st -ne 0) { $start = $st }
  } else {
    Set-Content -Path $timeFile -Value "$now" -NoNewline
  }
  $diff = [long][math]::Floor(($now - $start) / 1000)
  $h = [math]::Floor($diff / 3600)
  $m = [math]::Floor(($diff % 3600) / 60)
  $s = $diff % 60
  if ($h -gt 0) { $durationStr = "${h}h ${m}m" }
  elseif ($m -gt 0) { $durationStr = "${m}m ${s}s" }
  else { $durationStr = "${s}s" }
}

# 4. Model, folder, git branch
$model = if ($data.model.display_name) { $data.model.display_name } elseif ($data.model.id) { $data.model.id } else { 'Claude' }
$model = Remove-Control $model
$cwd = if ($data.workspace.current_dir) { $data.workspace.current_dir } else { (Get-Location).Path }
$folder = Remove-Control (Split-Path $cwd -Leaf)

$branch = ''
try {
  $b = & git -C "$cwd" rev-parse --abbrev-ref HEAD 2>$null
  if ($LASTEXITCODE -eq 0 -and $b) { $branch = Remove-Control ("$b".Trim()) }
} catch {}

# Long branch names push the last fields off screen, so keep the start only
if ($MaxBranch -gt 0 -and $branch.Length -gt $MaxBranch) { $branch = $branch.Substring(0, $MaxBranch - 1) + [char]0x2026 }

# 5. Context
$u = $data.context_window.current_usage
if (-not $u) { $u = $data.usage }
$inTok      = [long]$u.input_tokens
$cacheRead  = [long]$u.cache_read_input_tokens
$cacheNew   = [long]$u.cache_creation_input_tokens
$ctxLimit   = if ($data.context_window.context_window_size) { [long]$data.context_window.context_window_size } else { 200000 }

$ctxUsed    = $inTok + $cacheRead + $cacheNew
$ctxRatio   = $ctxUsed / $ctxLimit
$ctxPercent = [int](Round-Half ($ctxRatio * 100))

# Colors: light 24-bit tones that stay readable on dark and on blue backgrounds
$e = [char]27
function Rgb($r, $g, $b) { return "$e[38;2;$r;$g;${b}m" }
# Dark tint of a color (35% color + 65% dark base), used for empty bar cells
function Tint($r, $g, $b) {
  return Rgb ([int]($r * 0.35 + 30 * 0.65)) ([int]($g * 0.35 + 37 * 0.65)) ([int]($b * 0.35 + 48 * 0.65))
}
$cyan    = Rgb 86 182 194
$magenta = Rgb 198 120 221
$yellow  = Rgb 229 192 123
$blue    = Rgb 97 175 239
$green   = Rgb 152 195 121
$red     = Rgb 224 85 97
$gray    = Rgb 139 146 156
$reset   = "$e[0m"

$ctxColor = $green;  $ctxTrack = Tint 152 195 121
if ($ctxPercent -ge 85) { $ctxColor = $red; $ctxTrack = Tint 224 85 97 }
elseif ($ctxPercent -ge 60) { $ctxColor = $yellow; $ctxTrack = Tint 229 192 123 }
$blueTrack = Tint 97 175 239

# 6. Cache
$cacheTotal = $cacheRead + $cacheNew
$cacheRatio = if ($cacheTotal -gt 0) { $cacheRead / $cacheTotal } else { 0 }
$cacheDisplay = "cache $(Make-Bar $cacheRatio $blue $blueTrack) r:$(Format-K $cacheRead) (+$(Format-K $cacheNew) new)"

# Line 1: effort | model | ctx | cache | cost
$effort = if ($data.effort.level) { $data.effort.level } elseif ($data.effort -is [string]) { $data.effort } else { $null }
$effort = Remove-Control $effort
$pink = "$e[38;2;224;108;117m"

$parts1 = @()
if ($effort) { $parts1 += "$pink$effort$reset" }
$parts1 += "$cyan$model$reset"
$parts1 += "${ctxColor}ctx $(Make-Bar $ctxRatio $ctxColor $ctxTrack) $ctxPercent% ($(Format-K $ctxUsed)/$(Format-K $ctxLimit))$reset"
$parts1 += "$blue$cacheDisplay$reset"
$parts1 += "$red$costDisplay$reset"
$line1 = $parts1 -join ' | '

# Last request duration (from cumulative API time)
$lastReqStr = ''
$apiTotal = [long]$data.cost.total_api_duration_ms
if ($sid -ne 'unknown' -and $apiTotal -gt 0) {
  $apiFile = Join-Path $tmp "claude_api_$sid.txt"
  [long]$prevApi = 0
  [long]$lastApi = 0
  if (Test-Path $apiFile) {
    $vals = "$(Get-Content $apiFile -Raw)".Trim() -split ';'
    [long]::TryParse($vals[0], [ref]$prevApi) | Out-Null
    if ($vals.Count -gt 1) { [long]::TryParse($vals[1], [ref]$lastApi) | Out-Null }
  }
  if ($apiTotal -gt $prevApi) {
    $lastApi = $apiTotal - $prevApi
    Set-Content -Path $apiFile -Value "$apiTotal;$lastApi" -NoNewline
  }
  if ($lastApi -gt 0) {
    $secs = $lastApi / 1000
    if ($secs -ge 60) {
      $lm = [math]::Floor($secs / 60)
      $lsec = [math]::Floor($secs % 60)
      $lastReqStr = "${lm}m ${lsec}s"
    } else {
      $lastReqStr = $secs.ToString('0.0', $inv) + 's'
    }
  }
}

# Line 2: cwd | git | sid | time | last (cwd goes to line 3 if $CwdOnOwnLine)
$cwdPart = "${magenta}cwd:$folder$reset"
$parts2 = @()
if (-not $CwdOnOwnLine) { $parts2 += $cwdPart }
if ($branch) { $parts2 += "${yellow}git:$branch$reset" }
$parts2 += "${gray}sid:$shortSid$reset"
$parts2 += "${gray}time: $durationStr$reset"
if ($lastReqStr) { $parts2 += "${cyan}last: $lastReqStr$reset" }

# Prompt cache state (Claude Code re-runs the status line when the cache expires)
$pc = $data.prompt_cache
if ($pc -and $pc.caching_observed -ne $false) {
  if ($pc.warm -eq $true) {
    $until = ''
    if ($pc.expires_at) {
      $until = ' until ' + [DateTimeOffset]::FromUnixTimeSeconds([long]$pc.expires_at).ToLocalTime().ToString('HH:mm')
    }
    $ttl = if ($pc.ttl) { " ($(Remove-Control $pc.ttl))" } else { '' }
    $parts2 += "${green}cache warm$until$ttl$reset"
  } elseif ($pc.warm -eq $false) {
    $parts2 += "${yellow}cache cold$reset"
  }
}
$line2 = $parts2 -join ' | '

Write-Output $line1
Write-Output $line2
if ($CwdOnOwnLine) { Write-Output $cwdPart }
'@

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Info($msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host $msg -ForegroundColor Green }
function Write-Warn($msg) { Write-Host $msg -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host $msg -ForegroundColor Red }

function Confirm-Step($question) {
  $answer = Read-Host "$question (y/n)"
  return ($answer -match '^\s*(y|yes)\s*$')
}

function Stop-Install($msg) {
  Write-Warn $msg
  exit 0
}

# Wrap a path in double quotes if it contains spaces
function Format-Arg($value) {
  if ($value -match '\s') { return '"' + $value + '"' }
  return $value
}

# Status line script with the chosen options filled in
function Get-StatusLineContent($cwdOnOwnLine, $maxBranch) {
  $content = $StatusLineContent
  if ($cwdOnOwnLine) { $content = $content.Replace('$CwdOnOwnLine = $false', '$CwdOnOwnLine = $true ') }
  if ($maxBranch -gt 0) { $content = $content.Replace('$MaxBranch    = 0 ', '$MaxBranch    = ' + "$maxBranch".PadRight(2)) }
  return $content
}

function Format-YesNo($value) { if ($value) { 'yes' } else { 'no' } }

# --- settings.json editing (text based, so the rest of the file stays as it is) ---
function Skip-JsonSpace($s, $i) {
  while ($i -lt $s.Length -and " `t`r`n".IndexOf($s[$i]) -ge 0) { $i++ }
  return $i
}

# $s[$i] is the opening quote; returns the position after the closing quote, or -1
function Skip-JsonString($s, $i) {
  for ($i++; $i -lt $s.Length; $i++) {
    if ($s[$i] -eq '\') { $i++ }
    elseif ($s[$i] -eq '"') { return $i + 1 }
  }
  return -1
}

# $s[$i] is the first character of a value; returns the position after it, or -1
function Skip-JsonValue($s, $i) {
  if ($i -ge $s.Length) { return -1 }
  $c = $s[$i]
  if ($c -eq '"') { return Skip-JsonString $s $i }
  if ($c -eq '{' -or $c -eq '[') {
    $depth = 0
    while ($i -lt $s.Length) {
      $c = $s[$i]
      if ($c -eq '"') { $i = Skip-JsonString $s $i; if ($i -lt 0) { return -1 }; continue }
      if ($c -eq '{' -or $c -eq '[') { $depth++ }
      elseif ($c -eq '}' -or $c -eq ']') { $depth--; if ($depth -eq 0) { return $i + 1 } }
      $i++
    }
    return -1
  }
  while ($i -lt $s.Length -and ",}] `t`r`n".IndexOf($s[$i]) -lt 0) { $i++ }
  return $i
}

# Set the top-level "statusLine" value in settings.json text and keep everything else.
# Returns $null if the text is not a JSON object that can be edited safely.
function Set-StatusLineEntry($text, $valueJson) {
  $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
  $valueJson = $valueJson -replace "`n", $nl
  $i = Skip-JsonSpace $text 0
  if ($i -ge $text.Length -or $text[$i] -ne '{') { return $null }
  $open = $i
  $i = Skip-JsonSpace $text ($i + 1)
  while ($i -lt $text.Length -and $text[$i] -ne '}') {
    if ($text[$i] -ne '"') { return $null }
    $keyEnd = Skip-JsonString $text $i
    if ($keyEnd -lt 0) { return $null }
    $key = $text.Substring($i + 1, $keyEnd - $i - 2)
    $i = Skip-JsonSpace $text $keyEnd
    if ($i -ge $text.Length -or $text[$i] -ne ':') { return $null }
    $valueStart = Skip-JsonSpace $text ($i + 1)
    $valueEnd = Skip-JsonValue $text $valueStart
    if ($valueEnd -lt 0) { return $null }
    if ($key -eq 'statusLine') {
      return $text.Substring(0, $valueStart) + $valueJson + $text.Substring($valueEnd)
    }
    $i = Skip-JsonSpace $text $valueEnd
    if ($i -lt $text.Length -and $text[$i] -eq ',') { $i = Skip-JsonSpace $text ($i + 1) }
  }
  if ($i -ge $text.Length) { return $null }

  # No statusLine yet: add it as the first entry
  $entry = $nl + '  "statusLine": ' + $valueJson
  if ($text.Substring($open + 1, $i - $open - 1).Trim() -eq '') {
    return $text.Substring(0, $open + 1) + $entry + $nl + $text.Substring($i)
  }
  return $text.Substring(0, $open + 1) + $entry + ',' + $text.Substring($open + 1)
}

# PowerShell executable that runs this installer (pwsh or powershell)
$PsExe = (Get-Process -Id $PID).Path

# Windows PowerShell 5.1 has no $IsWindows variable, but it only runs on Windows
$OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows

# Run a status line script with sample data and return its output
function Invoke-StatusLine($scriptPath) {
  $sid = [guid]::NewGuid().ToString('N')
  $cwd = (Get-Location).Path -replace '\\', '/'
  $sample = @{
    session_id     = $sid
    effort         = @{ level = 'medium' }
    model          = @{ display_name = 'Sonnet 4.6' }
    workspace      = @{ current_dir = $cwd }
    cost           = @{ total_cost_usd = 0.12; total_api_duration_ms = 14200 }
    context_window = @{
      context_window_size = 200000
      current_usage = @{ input_tokens = 5000; cache_read_input_tokens = 20000; cache_creation_input_tokens = 3000 }
    }
  } | ConvertTo-Json -Depth 10 -Compress

  $output = $sample | & $PsExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath

  # Remove temp files the status line created for the sample session
  $tmp = [System.IO.Path]::GetTempPath()
  Get-ChildItem -Path $tmp -Filter "claude_*$sid*" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

  return $output
}

# ---------------------------------------------------------------------------
# 1. Check that Claude Code is installed
# ---------------------------------------------------------------------------
Write-Host ''
Write-Info '=== Claude Code status line installer ==='
Write-Host ''

$claudeDir     = Join-Path $HOME '.claude'
$claudeCommand = Get-Command claude -ErrorAction SilentlyContinue

if (-not $claudeCommand -and -not (Test-Path $claudeDir)) {
  Write-Err 'Claude Code is not installed on this machine (neither the "claude" command nor the ~/.claude folder was found).'
  Write-Err 'The status line was not installed.'
  exit 1
}
Write-Ok 'Claude Code found.'

$statusLinePath = Join-Path $claudeDir 'statusline.ps1'
$settingsPath   = Join-Path $claudeDir 'settings.json'
$scriptArg      = Format-Arg ($statusLinePath -replace '\\', '/')

if ($OnWindows) {
  # Windows PowerShell is always present on Windows
  $command = 'powershell -NoProfile -ExecutionPolicy Bypass -File ' + $scriptArg
} else {
  # Full path to pwsh, so it works even if Claude Code's PATH lacks it
  $command = (Format-Arg $PsExe) + ' -NoProfile -File ' + $scriptArg
}

# ---------------------------------------------------------------------------
# 2. Check for an existing statusline.ps1
# ---------------------------------------------------------------------------
if (Test-Path $statusLinePath) {
  Write-Host ''
  Write-Warn "WARNING: file already exists: $statusLinePath"
  Write-Warn 'The installer will overwrite it and will NOT make a backup.'
  Write-Warn 'If you want to keep your current status line, back it up yourself first, e.g.:'
  Write-Host "  Copy-Item `"$statusLinePath`" `"$statusLinePath.bak`""
  Write-Host ''
  if (-not (Confirm-Step 'Replace the existing statusline.ps1?')) {
    Stop-Install 'Cancelled. Nothing was changed.'
  }
}

# ---------------------------------------------------------------------------
# 3. Option: folder on its own line
# ---------------------------------------------------------------------------
Write-Host ''
Write-Info 'Option 1 of 2: folder on a separate line'
Write-Host '  By default the folder (cwd) is the first field of line 2. A long folder name'
Write-Host '  can push the last fields (last, cache warm/cold) off screen.'
Write-Host '  Moving it to a third line keeps line 2 short.'
$cwdOnOwnLine = Confirm-Step 'Show the folder on a third line?'

# ---------------------------------------------------------------------------
# 4. Option: shorten long git branch names
# ---------------------------------------------------------------------------
$BranchLimit = 24
Write-Host ''
Write-Info 'Option 2 of 2: shorten long git branch names'
Write-Host "  Branch names longer than $BranchLimit characters can push the last fields off screen."
Write-Host "  If shortened, only the first $BranchLimit characters are shown, ending with '...'."
$maxBranch = if (Confirm-Step 'Shorten long git branch names?') { $BranchLimit } else { 0 }

$content = Get-StatusLineContent $cwdOnOwnLine $maxBranch

# ---------------------------------------------------------------------------
# 5. Preview
# ---------------------------------------------------------------------------
Write-Host ''
Write-Info 'Preview of the status line (sample data, not your real session):'
Write-Host ''

$previewFile = Join-Path ([System.IO.Path]::GetTempPath()) ('statusline-preview-' + [guid]::NewGuid().ToString('N') + '.ps1')
try {
  [System.IO.File]::WriteAllText($previewFile, $content, (New-Object System.Text.UTF8Encoding $false))
  Invoke-StatusLine $previewFile | ForEach-Object { Write-Host "  $_" }
} finally {
  Remove-Item $previewFile -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Info 'What will be done:'
Write-Host "  - write file: $statusLinePath"
Write-Host "      folder on a third line: $(Format-YesNo $cwdOnOwnLine)"
Write-Host "      shorten long git branch names: $(Format-YesNo ($maxBranch -gt 0))"
Write-Host "  - set statusLine in $settingsPath to:"
Write-Host "      $command"

# New statusLine value as JSON text
$commandJson = $command.Replace('\', '\\').Replace('"', '\"')
$statusLineJson = "{`n    `"type`": `"command`",`n    `"command`": `"$commandJson`"`n  }"

# Prepare the new settings.json text now, so nothing is changed if it cannot be edited
$settings = $null
$newSettings = "{`n  `"statusLine`": $statusLineJson`n}`n"
if (Test-Path $settingsPath) {
  $rawSettings = Get-Content $settingsPath -Raw -Encoding UTF8
  if (-not [string]::IsNullOrWhiteSpace($rawSettings)) {
    try {
      $settings = $rawSettings | ConvertFrom-Json
    } catch {
      Write-Err "Could not read $settingsPath : the file contains invalid JSON."
      Stop-Install 'Fix settings.json and run the installer again. Nothing was changed.'
    }
    $newSettings = Set-StatusLineEntry $rawSettings $statusLineJson
    $edited = $null
    if ($newSettings) { try { $edited = $newSettings | ConvertFrom-Json } catch {} }
    if (-not $edited -or $edited.statusLine.command -ne $command) {
      Write-Err "Could not safely edit $settingsPath (unexpected format)."
      Write-Warn 'Nothing was changed. You can install manually: save the status line as ~/.claude/statusline.ps1'
      Write-Warn 'and add this to settings.json:'
      Write-Host "  `"statusLine`": $statusLineJson"
      exit 1
    }
  }
}

# Warn if settings.json already points to a different status line
if ($settings -and $settings.statusLine -and $settings.statusLine.command -and $settings.statusLine.command -ne $command) {
  Write-Warn "  - the current statusLine will be replaced: $($settings.statusLine.command)"
}

Write-Host ''
if (-not (Confirm-Step 'Continue with the installation?')) {
  Stop-Install 'Cancelled. Nothing was changed.'
}

# ---------------------------------------------------------------------------
# 6. Install
# ---------------------------------------------------------------------------
if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir | Out-Null }

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($statusLinePath, $content, $utf8NoBom)

[System.IO.File]::WriteAllText($settingsPath, $newSettings, $utf8NoBom)

Write-Ok 'Files written.'

# ---------------------------------------------------------------------------
# 7. Verify
# ---------------------------------------------------------------------------
Write-Host ''
Write-Info 'Checking the installed status line:'
Write-Host ''

$checkOutput = Invoke-StatusLine $statusLinePath
$checkOutput | ForEach-Object { Write-Host "  $_" }

$saved = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$settingsOk = ($saved.statusLine.command -eq $command)
$outputOk   = (@($checkOutput).Count -ge 2)

Write-Host ''
if ($settingsOk -and $outputOk) {
  Write-Ok 'Done! The status line is installed. Start a new Claude Code session to see it.'
} else {
  if (-not $settingsOk) { Write-Err 'Error: statusLine in settings.json does not match the expected value.' }
  if (-not $outputOk)   { Write-Err 'Error: the status line did not print the expected two lines.' }
  exit 1
}
