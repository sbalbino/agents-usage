# Agents Usage: semi-transparent, always-on-top overlay with Claude and Codex usage and limits.
# Usage: powershell -WindowStyle Hidden -ExecutionPolicy Bypass -File overlay.ps1
# Sources (internal, undocumented endpoints; they may change):
#   Claude: api.anthropic.com/api/oauth/usage      token in ~/.claude/.credentials.json
#   Codex:  chatgpt.com/backend-api/wham/usage     token in ~/.codex/auth.json
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
  [DllImport("user32.dll")] public static extern bool ReleaseCapture();
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int m, int w, int l);
}
"@

$Opacity = 0.85        # 0.0 to 1.0
$PollSeconds = 60
$PW = 236; $Height = 166     # $PW = width of each panel

# visible panels (saved to settings.json from the tray menu), in Claude, Codex order
$Panels = 'Claude', 'Codex'
$settingsPath = Join-Path $PSScriptRoot 'settings.json'
$script:show = $Panels
try { $saved = @((Get-Content $settingsPath -Raw -ErrorAction Stop | ConvertFrom-Json).show | Where-Object { $Panels -contains $_ }); if ($saved.Count) { $script:show = $saved } } catch {}
$Width = $PW * $script:show.Count
$GWL_EXSTYLE = -20; $TRANSPARENT = 0x20; $TOOLWINDOW = 0x80; $NOACTIVATE = 0x08000000

# credentials JSON: Windows first, then WSL
function Read-Json($rel) {
  $paths = @("$env:USERPROFILE\$rel") + (Get-ChildItem "\\wsl.localhost\*\home\*\$rel" -ErrorAction SilentlyContinue).FullName
  foreach ($p in $paths) { if ($p -and (Test-Path $p)) { return Get-Content $p -Raw | ConvertFrom-Json } }
}

function Get-Row($label, $b, $hours) {
  if (-not $b) { return @{ Label = $label; Pct = 0; Elapsed = 0; Reset = '--' } }
  $r = $b.resets_at
  if ($r -is [datetime]) { $r = $r.ToUniversalTime() } else { $r = [DateTimeOffset]::Parse([string]$r).UtcDateTime }
  $left = $r - [datetime]::UtcNow
  $t = if ($left.TotalHours -ge 24) { '{0}d {1}h' -f [int]$left.Days, $left.Hours } else { '{0}h {1:00}m' -f [int]$left.TotalHours, $left.Minutes }
  $elapsed = [Math]::Min(100, [Math]::Max(0, 100 * (1 - $left.TotalHours / $hours)))
  @{ Label = $label; Pct = [double]$b.utilization; Elapsed = $elapsed; Reset = "resets in $t" }
}

# each Get-* returns @{ Rows = ... } or @{ Error = ... }
function Get-Claude {
  $tok = (Read-Json '.claude\.credentials.json').claudeAiOauth.accessToken
  if (-not $tok) { return @{ Error = 'no credentials - open Claude Code' } }
  try {
    # ponytail: synchronous calls (UI freezes up to 15s if the network drops), move to a runspace if it bothers
    $u = Invoke-RestMethod 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec 15 `
         -Headers @{ Authorization = "Bearer $tok"; 'anthropic-beta' = 'oauth-2025-04-20' }
    @{ Rows = @((Get-Row '5h session' $u.five_hour 5), (Get-Row 'Week' $u.seven_day 168)) }
  } catch { @{ Error = "error: $($_.Exception.Message.Split("`n")[0])" } }
}

function ConvertTo-Bucket($w, $defaultHours) {
  if (-not $w) { return $null }
  $reset = if ($null -ne $w.reset_after_seconds) { [datetime]::UtcNow.AddSeconds([double]$w.reset_after_seconds) }
           else { [DateTimeOffset]::FromUnixTimeSeconds([long]$w.reset_at).UtcDateTime }
  $h = if ($w.limit_window_seconds) { [double]$w.limit_window_seconds / 3600 } else { $defaultHours }
  [pscustomobject]@{ utilization = [double]$w.used_percent; resets_at = $reset; hours = $h }
}

function Get-Codex {
  $a = Read-Json '.codex\auth.json'
  $tok = $a.tokens.access_token
  if (-not $tok) { return @{ Error = 'no credentials - sign in to Codex (codex login)' } }
  try {
    $h = @{ Authorization = "Bearer $tok" }
    if ($a.tokens.account_id) { $h['ChatGPT-Account-Id'] = $a.tokens.account_id }
    $u = Invoke-RestMethod 'https://chatgpt.com/backend-api/wham/usage' -TimeoutSec 15 -Headers $h
    $p = ConvertTo-Bucket $u.rate_limit.primary_window 5
    $s = ConvertTo-Bucket $u.rate_limit.secondary_window 168
    @{ Rows = @((Get-Row '5h session' $p $(if ($p) { $p.hours } else { 5 })), (Get-Row 'Week' $s $(if ($s) { $s.hours } else { 168 })))
       Resets = $u.rate_limit_reset_credits.available_count }
  } catch { @{ Error = "error: $($_.Exception.Message.Split("`n")[0])" } }
}

function New-RoundRect($x, $y, $w, $h, $r) {
  $d = $r * 2; $p = New-Object Drawing.Drawing2D.GraphicsPath
  $p.AddArc($x, $y, $d, $d, 180, 90); $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure(); $p
}

# usage ahead of time: yellow; ahead and >= 80%: red; behind: green
function Get-Accent($row) {
  if ($row.Pct -le $row.Elapsed) { ,@('#34D399', '#6EE7B7') }
  elseif ($row.Pct -ge 80) { ,@('#F87171', '#FCA5A5') }
  else { ,@('#FBBF24', '#FDE68A') }
}
function C($hex) { [Drawing.ColorTranslator]::FromHtml($hex) }

$script:data = @{ Claude = @{ Error = 'loading...' }; Codex = @{ Error = 'loading...' } }

$form = New-Object Windows.Forms.Form
$form.FormBorderStyle = 'None'; $form.ShowInTaskbar = $false; $form.TopMost = $true
$form.BackColor = C '#14161C'; $form.Opacity = $Opacity
$form.StartPosition = 'Manual'; $form.ClientSize = New-Object Drawing.Size($Width, $Height)
$wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object Drawing.Point(($wa.Right - $Width - 12), ($wa.Top + 12))
[Windows.Forms.Form].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($form, $true)

# optional official logos: claude-logo.png / codex-logo.png (transparent background) next to this script
function Get-Logo($name) { $p = Join-Path $PSScriptRoot $name; if (Test-Path $p) { [Drawing.Image]::FromFile($p) } }
$logoClaude = Get-Logo 'claude-logo.png'; $logoCodex = Get-Logo 'codex-logo.png'
$SparkLen = 10.5, 8.5, 9.5, 8, 10.5, 8.5, 9.5, 8, 10, 8.5, 9.5, 8.5
$SparkJitter = 0, 3, -2, 2, -3, 2, 0, -2, 3, -2, 2, -3
$fTitle = New-Object Drawing.Font('Segoe UI Semibold', 11)
$fLabel = New-Object Drawing.Font('Segoe UI Semibold', 9)
$fSmall = New-Object Drawing.Font('Segoe UI', 8)
$fPct = New-Object Drawing.Font('Segoe UI Semibold', 13)
$fBadge = New-Object Drawing.Font('Segoe UI Semibold', 7.5)
$fMono = New-Object Drawing.Font('Consolas', 9, [Drawing.FontStyle]::Bold)
$right = New-Object Drawing.StringFormat; $right.Alignment = 'Far'

function Draw-Icon($g, $ox, $kind) {
  $logo = if ($kind -eq 'Claude') { $logoClaude } else { $logoCodex }
  if ($logo) {
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.DrawImage($logo, (New-Object Drawing.Rectangle(($ox + 13), 10, 22, 22)))
  } elseif ($kind -eq 'Claude') {
    # fallback: rays of uneven length and angle, like the brand spark
    $sp = New-Object Drawing.Pen((C '#D97757'), 2.0); $sp.StartCap = 'Round'; $sp.EndCap = 'Round'
    for ($i = 0; $i -lt 12; $i++) {
      $a = ($i * 30 + $SparkJitter[$i]) * [Math]::PI / 180
      $g.DrawLine($sp, ($ox + 24), 21, ($ox + 24 + $SparkLen[$i] * [Math]::Cos($a)), (21 + $SparkLen[$i] * [Math]::Sin($a)))
    }
  } else {
    # Codex fallback: rounded square with a ">_" prompt
    $g.FillPath((New-Object Drawing.SolidBrush (C '#2A2E38')), (New-RoundRect ($ox + 13) 10 22 22 6))
    $g.DrawString('>_', $fMono, (New-Object Drawing.SolidBrush (C '#F3F4F6')), ($ox + 14.5), 14.5)
  }
}

function Draw-Panel($g, $ox, $kind, $d) {
  $inner = $PW - 28; $x = $ox + 14
  Draw-Icon $g $ox $kind
  $g.DrawString($kind, $fTitle, (New-Object Drawing.SolidBrush (C '#F3F4F6')), ($ox + 38), 9)
  if ($null -ne $d.Resets) {
    # badge with available resets, right of the name
    $bx = $ox + 38 + $g.MeasureString($kind, $fTitle).Width + 6
    $txt = "$([char]0x21BB) $($d.Resets) $(if ($d.Resets -eq 1) { 'reset' } else { 'resets' })"
    $bw = $g.MeasureString($txt, $fBadge).Width + 10
    $pill = New-RoundRect $bx 12.5 $bw 17 8.5
    $fill = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.RectangleF($bx, 12, $bw, 18)),
            [Drawing.Color]::FromArgb(90, 99, 102, 241), [Drawing.Color]::FromArgb(40, 139, 92, 246), 0.0)
    $g.FillPath($fill, $pill)
    $g.DrawPath((New-Object Drawing.Pen([Drawing.Color]::FromArgb(160, 129, 140, 248), 1)), $pill)
    $g.DrawString($txt, $fBadge, (New-Object Drawing.SolidBrush (C '#E0E7FF')), ($bx + 5), 14)
  }
  $g.DrawLine((New-Object Drawing.Pen((C '#262A33'), 1)), $x, 36, ($x + $inner), 36)
  if ($d.Error) {
    $g.DrawString($d.Error, $fLabel, (New-Object Drawing.SolidBrush (C '#F87171')),
                  (New-Object Drawing.RectangleF($x, 44, $inner, ($Height - 56))))
    return
  }
  $y = 46
  foreach ($row in $d.Rows) {
    $accent = Get-Accent $row
    $g.DrawString($row.Label, $fLabel, (New-Object Drawing.SolidBrush (C '#E5E7EB')), $x, $y)
    $g.DrawString($row.Reset, $fSmall, (New-Object Drawing.SolidBrush (C '#8B93A1')), $x, ($y + 16))
    $g.DrawString(('{0:0}%' -f $row.Pct), $fPct, (New-Object Drawing.SolidBrush (C $accent[0])),
                  (New-Object Drawing.RectangleF($x, $y, $inner, 24)), $right)
    # usage bar
    $by = $y + 34
    $g.FillPath((New-Object Drawing.SolidBrush (C '#262A33')), (New-RoundRect $x $by $inner 6 3))
    $fw = [Math]::Min($inner, [Math]::Max(0, $inner * $row.Pct / 100))
    if ($fw -ge 6) {
      $br = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.RectangleF($x, $by, $inner, 6)), (C $accent[0]), (C $accent[1]), 0.0)
      $g.FillPath($br, (New-RoundRect $x $by $fw 6 3))
    }
    # elapsed-time bar of the window
    $ty = $by + 9
    $g.FillPath((New-Object Drawing.SolidBrush (C '#262A33')), (New-RoundRect $x $ty $inner 4 2))
    $tw = $inner * $row.Elapsed / 100
    if ($tw -ge 4) { $g.FillPath((New-Object Drawing.SolidBrush (C '#60A5FA')), (New-RoundRect $x $ty $tw 4 2)) }
    # pipe crosses both bars at the usage position
    $px = $x + [Math]::Min($inner - 1, [Math]::Max(1, $fw))
    $pp = New-Object Drawing.Pen((C '#F9FAFB'), 2); $pp.StartCap = 'Round'; $pp.EndCap = 'Round'
    $g.DrawLine($pp, $px, ($by - 3), $px, ($ty + 7))
    $y += 54
  }
}

$form.Add_Paint({
  $g = $_.Graphics; $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'
  $g.DrawPath((New-Object Drawing.Pen((C '#2A2E38'), 1)), (New-RoundRect 0.5 0.5 ($Width - 1) ($Height - 1) 14))
  $ox = 0
  foreach ($k in $script:show) {
    if ($ox) { $g.DrawLine((New-Object Drawing.Pen((C '#262A33'), 1)), $ox, 12, $ox, ($Height - 12)) }
    Draw-Panel $g $ox $k $script:data[$k]
    $ox += $PW
  }
})

# drag with the left button (only when click-through is off)
$form.Add_MouseDown({ if ($_.Button -eq 'Left') { [W]::ReleaseCapture() | Out-Null; [W]::SendMessage($form.Handle, 0xA1, 2, 0) | Out-Null } })

function Set-ClickThrough($on) {
  $s = [W]::GetWindowLong($form.Handle, $GWL_EXSTYLE) -bor $TOOLWINDOW -bor $NOACTIVATE
  if ($on) { $s = $s -bor $TRANSPARENT } else { $s = $s -band (-bnot $TRANSPARENT) }
  [W]::SetWindowLong($form.Handle, $GWL_EXSTYLE, $s) | Out-Null
}
function Update-Overlay { foreach ($k in $script:show) { $script:data[$k] = & "Get-$k" }; $form.Invalidate() }

# resize keeping the right edge in place
function Set-Layout {
  $edge = $form.Left + $form.Width
  $script:Width = $PW * $script:show.Count
  $form.ClientSize = New-Object Drawing.Size($Width, $Height)
  $form.Left = $edge - $Width
  $form.Region = New-Object Drawing.Region (New-RoundRect 0 0 $Width $Height 14)
  $form.Invalidate()
}

$form.Add_Shown({
  $form.Region = New-Object Drawing.Region (New-RoundRect 0 0 $Width $Height 14)
  Set-ClickThrough $false
  Update-Overlay
})

# tray icon: the only way to close/toggle while the overlay is click-through
$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = [Drawing.SystemIcons]::Information; $tray.Text = 'Agents Usage'; $tray.Visible = $true
$menu = New-Object Windows.Forms.ContextMenuStrip
foreach ($k in $Panels) {
  $it = New-Object Windows.Forms.ToolStripMenuItem("Show $k")
  $it.Tag = $k; $it.Checked = $script:show -contains $k
  $it.Add_Click({
    $k = $this.Tag
    $on = @($Panels | Where-Object { if ($_ -eq $k) { -not ($script:show -contains $_) } else { $script:show -contains $_ } })
    # validator: at least one visible panel
    if ($on.Count -eq 0) { $tray.ShowBalloonTip(2000, 'Agents Usage', 'At least one panel must stay visible.', 'Info'); return }
    $script:show = $on; $this.Checked = $on -contains $k
    @{ show = $on } | ConvertTo-Json | Set-Content $settingsPath -Encoding UTF8
    Set-Layout; Update-Overlay
  })
  $menu.Items.Add($it) | Out-Null
}
$menu.Items.Add('-') | Out-Null
$ct = $menu.Items.Add('Click-through (mouse passes through)'); $ct.CheckOnClick = $true
$ct.Add_CheckedChanged({ Set-ClickThrough $ct.Checked })
$menu.Items.Add('Refresh now').Add_Click({ Update-Overlay })
$menu.Items.Add('Quit').Add_Click({ $tray.Visible = $false; $form.Close() })
$tray.ContextMenuStrip = $menu

$timer = New-Object Windows.Forms.Timer
$timer.Interval = $PollSeconds * 1000
$timer.Add_Tick({ Update-Overlay })
$timer.Start()

[Windows.Forms.Application]::Run($form)
$tray.Dispose()
