# Claude Code Status Line

A two-line status line for [Claude Code](https://claude.com/claude-code) that shows the model, context usage, cache, cost, git branch and timing, plus a one-file installer for Windows, macOS and Linux.

![Status line preview](preview.svg)

| Field | Meaning |
|---|---|
| `medium` | Current effort level |
| `Sonnet 4.6` | Active model |
| `ctx` | Context window usage (green < 60%, yellow < 85%, red above) |
| `cache` | Cache reads vs. newly cached tokens |
| `$0.12 (+$0.004)` | Session cost (and cost of the last turn) |
| `cwd` / `git` | Current folder and git branch |
| `sid` | Short session ID |
| `time` | Session duration |
| `last` | Duration of the last model request |

## Install

Requires Claude Code and PowerShell. PowerShell is built into Windows. On macOS install it once with `brew install powershell`.

**Windows**
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-statusline.ps1
```

**macOS / Linux**
```bash
pwsh -NoProfile -File ./install-statusline.ps1
```

Run it from a regular PowerShell or terminal window. Git Bash on Windows may not handle the y/n prompts.

### What the installer does

1. Checks that Claude Code is installed. If it isn't, it stops without creating anything.
2. If `~/.claude/statusline.ps1` already exists, warns you and asks before replacing it. **No backup is made**, so copy the file yourself first if you want to keep it.
3. Shows a preview with sample data and asks whether to continue.
4. Writes the status line and runs a check to show the result.

### Where it installs

| File | Change |
|---|---|
| `~/.claude/statusline.ps1` | The status line script |
| `~/.claude/settings.json` | Only the `statusLine` entry is set. Other settings are kept. |

These are user-level settings, so the status line applies to **all projects** on the machine. Start a new Claude Code session to see it.

## Display notes

How the status line looks depends on your terminal, so it may differ slightly from the preview above:

- **Font.** Bars use the `▇` block character. Its height, and whether bar cells join seamlessly, depend on the terminal font. Fonts such as Cascadia Code, JetBrains Mono or Menlo render it best.
- **Colors.** The script uses 24-bit (true color) ANSI codes. Windows Terminal, VS Code, iTerm2 and most modern terminals support them. Older terminals, such as the legacy Windows console or macOS Terminal.app, show approximate colors.
- **Line spacing.** The gap between the two lines is controlled by the terminal, not the script (e.g. `terminal.integrated.lineHeight` in VS Code, **Line height** in Windows Terminal).
- **Background.** Colors are tuned for dark and blue (PowerShell) backgrounds. On light themes some fields may look pale.

Some values also depend on the session:

- `medium` (effort) appears only when Claude Code reports an effort level.
- `cache` shows `r:0` on the first request of a session, because everything is being written to the cache for the first time.
- `last` appears after the first model request.
- Cost and timing are tracked with small files in the system temp folder (`claude_*`), which the OS cleans up over time.

## Uninstall

Remove the `statusLine` entry from `~/.claude/settings.json` (or restore your own backup) and delete `~/.claude/statusline.ps1`.

## License

[MIT](LICENSE)
