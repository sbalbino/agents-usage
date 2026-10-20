# Agents Usage

A Windows overlay that shows your **Claude** (Claude Code) and **Codex** usage and limits in a small, semi-transparent window that stays on top of everything else, like the FPS and CPU meters used in games.

It is a single PowerShell script (`overlay.ps1`) with no dependencies: it uses WinForms and GDI+, which ship with Windows.

## What it shows

Each panel (Claude and Codex) shows two limit windows:

- **5h session**: the 5-hour window.
- **Week**: the 7-day window.

For each window:

- **Usage %**: the large number on the right.
- **Usage bar**: the thicker bar.
- **Time bar**: the thin blue bar below it, showing how much of the window has elapsed.
- **Pipe**: the white vertical line that crosses both bars at the usage position. If the pipe is right of the end of the blue bar, you are spending faster than time is passing.
- **"resets in"**: the time until the window resets.

Colors of the usage bar and the %:

| Color | When |
| --- | --- |
| Green | usage at or behind the elapsed time |
| Yellow | usage ahead of the elapsed time |
| Red | usage ahead of the elapsed time and at 80% or more |

On Codex, a badge next to the name shows the **available rate-limit resets** (for example, `↻ 2 resets`) when the account has any.

## Requirements

- Windows 10 or 11, with the built-in Windows PowerShell 5.1.
- Signed in to **Claude Code** and/or the **Codex CLI** on this machine, either on Windows or inside WSL.

## How it works

Every 60 seconds the script reads each tool's sign-in token and queries that tool's usage endpoint:

| Panel | Credential read | Endpoint |
| --- | --- | --- |
| Claude | `~/.claude/.credentials.json` | `https://api.anthropic.com/api/oauth/usage` |
| Codex | `~/.codex/auth.json` | `https://chatgpt.com/backend-api/wham/usage` |

Each credential is looked up in the Windows profile (`%USERPROFILE%`) first, then in the WSL distributions (`\\wsl.localhost\<distro>\home\<user>\`).

A token only leaves the machine in the request to the service that issued it. The script writes nothing except `settings.json`, which stores the visible panels.

> **Note:** both endpoints are internal and undocumented; they are the same ones the tools use to show usage. They may change without notice. If a panel shows `error: ...`, the format has probably changed.

If a token has expired, the panel shows the error until you use the tool again, since the tool is what refreshes the token.

## Usage

Run it once:

```powershell
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File .\overlay.ps1
```

- **Move:** drag the overlay with the left mouse button.
- **Menu:** right-click the icon in the system tray.
  - **Show Claude** / **Show Codex**: choose the visible panels. At least one must stay on. The choice is saved to `settings.json`.
  - **Click-through**: lets the mouse pass through the overlay. While it is on, the tray menu is the only way to interact with the overlay.
  - **Refresh now**: queries right away instead of waiting the 60 seconds.
  - **Quit**: closes the overlay.

The process runs hidden, so Ctrl+C in a terminal does not stop it. Use **Quit** in the tray, or, as a last resort:

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object CommandLine -like '*overlay.ps1*' |
  ForEach-Object { Stop-Process -Id $_.ProcessId }
```

## Shortcuts

Run the block below from the project folder. It creates an **Agents Usage** shortcut on the desktop and in the Startup folder, so the overlay opens on its own when you sign in to Windows:

```powershell
$script = Join-Path (Get-Location) 'overlay.ps1'
$ws = New-Object -ComObject WScript.Shell
foreach ($dir in [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Startup')) {
  $lnk = $ws.CreateShortcut((Join-Path $dir 'Agents Usage.lnk'))
  $lnk.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  $lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
  $lnk.WorkingDirectory = Split-Path $script
  $lnk.WindowStyle = 7   # minimized
  $lnk.IconLocation = "$env:WINDIR\System32\imageres.dll,150"
  $lnk.Save()
}
```

To create only one of them, keep just `'Desktop'` or `'Startup'` in the list.

To stop it from opening automatically, delete `Agents Usage.lnk` from the Startup folder. To open that folder, press `Win + R` and type `shell:startup`. You can also disable it in Task Manager → Startup apps.

If you move the project folder, the shortcuts stop working. Run the block again from the new location.

## Customizing

At the top of `overlay.ps1`:

| Variable | Default | What it does |
| --- | --- | --- |
| `$Opacity` | `0.85` | opacity (0 to 1) |
| `$PollSeconds` | `60` | seconds between queries. Avoid going below 30 to avoid being rate limited. |
| `$PW` | `236` | width of each panel, in pixels |
| `$Height` | `166` | window height, in pixels |

The logos come from `claude-logo.png` and `codex-logo.png` next to the script, as PNGs with a transparent background. Without these files, the script draws a simple icon instead.

## Limitations

- Games in **exclusive** fullscreen hide the overlay. It shows over windowed and borderless fullscreen games.
- Queries are synchronous: if the network drops, the window can freeze for up to 15 seconds.
- The window's rounded corners can look slightly jagged at the edges, a WinForms limitation.

## Trademarks

Claude is a trademark of Anthropic. Codex and OpenAI are trademarks of OpenAI. The logos were taken from Wikimedia Commons and are used only to label each panel. This project is not affiliated with either company.
