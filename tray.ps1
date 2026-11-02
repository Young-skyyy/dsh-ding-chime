<#
  Notification-area icon for the DSH completion chime.

  Started once by the Host half (index.js). Shows whether the chime is audible,
  toggles mute on click, and pops a balloon when a turn finishes.

  State lives in state.json (written by this icon and by the Host route);
  the Host writes events.json on every chime so this icon can react.
#>
param(
    [Parameter(Mandatory = $true)][string]$StateFile,
    [Parameter(Mandatory = $true)][string]$EventsFile,
    [Parameter(Mandatory = $true)][string]$IconOn,
    [Parameter(Mandatory = $true)][string]$IconOff,
    [Parameter(Mandatory = $true)][string]$IconRing,
    [string]$PreviewScript,
    [string]$SoundsDir,
    [int]$ParentPid = 0
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Flash the DSH window's taskbar button — the classic "something finished" hint.
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class TaskbarFlash
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool FlashWindowEx(ref FLASHWINFO info);

    [StructLayout(LayoutKind.Sequential)]
    private struct FLASHWINFO
    {
        public uint cbSize;
        public IntPtr hwnd;
        public uint dwFlags;
        public uint uCount;
        public uint dwTimeout;
    }

    private const uint FlashAll = 3;        // caption + taskbar button
    private const uint FlashTimerNoForeground = 12;

    private static IntPtr FindWindow(string processNamePrefix)
    {
        IntPtr found = IntPtr.Zero;
        Process[] processes;
        try { processes = Process.GetProcesses(); }
        catch { return IntPtr.Zero; }

        foreach (Process process in processes)
        {
            string name;
            uint target;
            try
            {
                name = process.ProcessName;
                target = (uint)process.Id;
            }
            catch { continue; }

            if (!name.StartsWith(processNamePrefix, StringComparison.OrdinalIgnoreCase)) continue;

            EnumWindows(delegate (IntPtr hWnd, IntPtr lParam)
            {
                if (!IsWindowVisible(hWnd)) return true;
                uint owner;
                GetWindowThreadProcessId(hWnd, out owner);
                if (owner == target) { found = hWnd; return false; }
                return true;
            }, IntPtr.Zero);

            if (found != IntPtr.Zero) break;
        }
        return found;
    }

    /// <summary>1 = flashed, 0 = no window found, -1 = call failed.</summary>
    public static int Flash(string processNamePrefix)
    {
        IntPtr window = FindWindow(processNamePrefix);
        if (window == IntPtr.Zero) return 0;
        FLASHWINFO info = new FLASHWINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
        info.hwnd = window;
        info.dwFlags = FlashAll | FlashTimerNoForeground;
        info.uCount = 0;
        info.dwTimeout = 0;
        return FlashWindowEx(ref info) ? 1 : -1;
    }
}
'@

$logFile = Join-Path (Split-Path -Parent $StateFile) 'tray.log'
function Write-Log([string]$message) {
    try { "$(Get-Date -Format 'HH:mm:ss.fff') $message" | Add-Content -LiteralPath $logFile -Encoding UTF8 } catch { }
}
trap {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
Write-Log "start pid=$PID sta=$([System.Threading.Thread]::CurrentThread.GetApartmentState())"

# Single instance: a reload may start this script while the old icon is alive.
$pidFile = Join-Path (Split-Path -Parent $StateFile) 'tray.pid'
try {
    $previous = Get-Content -LiteralPath $pidFile -Raw -ErrorAction Stop
    $previousId = [int]$previous.Trim()
    if ($previousId -gt 0 -and $previousId -ne $PID) {
        $previousProcess = Get-Process -Id $previousId -ErrorAction SilentlyContinue
        if ($previousProcess -and $previousProcess.ProcessName -like 'powershell*') {
            Write-Log "another instance is alive ($previousId); leaving it alone"
            exit 0
        }
    }
}
catch { }

$script:bitmaps = @()
function Get-TrayIcon([string]$path) {
    $bitmap = [System.Drawing.Bitmap]::FromFile($path)
    $script:bitmaps += $bitmap
    return [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
}

$iconNormal = Get-TrayIcon $IconOn
$iconMuted = Get-TrayIcon $IconOff
$iconRinging = Get-TrayIcon $IconRing
Write-Log "icons loaded"

function Read-State {
    try {
        $raw = Get-Content -LiteralPath $StateFile -Raw -ErrorAction Stop
        $parsed = $raw | ConvertFrom-Json
        return [pscustomobject]@{
            muted = ($parsed.muted -eq $true)
            sound = $parsed.sound
        }
    }
    catch {
        return [pscustomobject]@{ muted = $false; sound = $null }
    }
}

function Write-State([bool]$muted, [string]$sound) {
    $dir = Split-Path -Parent $StateFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    (@{ muted = $muted; sound = $sound } | ConvertTo-Json -Compress) | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Read-Muted { return (Read-State).muted }

$voices = @(
    @{ id = 'win-generic'; label = '系统通知（默认）'; group = 'system' },
    @{ id = 'win-calendar'; label = '日历'; group = 'system' },
    @{ id = 'win-email'; label = '邮件'; group = 'system' },
    @{ id = 'win-message'; label = '消息'; group = 'system' },
    @{ id = 'win-ding'; label = '经典 Ding'; group = 'system' },
    @{ id = 'win-chime'; label = '风铃'; group = 'system' },
    @{ id = 'win-nudge'; label = '轻推'; group = 'system' },
    @{ id = 'bell'; label = '木质铃（合成）'; group = 'synth' },
    @{ id = 'deep'; label = '低音钟（合成）'; group = 'synth' },
    @{ id = 'tech'; label = '电子（合成）'; group = 'synth' }
)
$script:soundItems = @{}

$notify = New-Object System.Windows.Forms.NotifyIcon
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$toggleItem = New-Object System.Windows.Forms.ToolStripMenuItem '静音提示音'
$soundMenu = New-Object System.Windows.Forms.ToolStripMenuItem '音效'
$previewItem = New-Object System.Windows.Forms.ToolStripMenuItem '试听'
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem '从托盘移除'

$lastGroup = $null
foreach ($voice in $voices) {
    if ($lastGroup -and $voice.group -ne $lastGroup) {
        [void]$soundMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    }
    $lastGroup = $voice.group

    $item = New-Object System.Windows.Forms.ToolStripMenuItem $voice.label
    $item.Tag = $voice.id
    $item.add_Click({
            param($sender, $eventArgs)
            Select-Sound ([string]$sender.Tag)
        })
    [void]$soundMenu.DropDownItems.Add($item)
    $script:soundItems[$voice.id] = $item
}

[void]$menu.Items.Add($toggleItem)
[void]$menu.Items.Add($soundMenu)
[void]$menu.Items.Add($previewItem)
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$menu.Items.Add($exitItem)
$notify.ContextMenuStrip = $menu

function Start-Preview([string]$id) {
    if (-not $PreviewScript -or -not $SoundsDir) { return }
    $wav = Join-Path $SoundsDir "$id.wav"
    if (-not (Test-Path -LiteralPath $wav)) { return }
    try {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', $PreviewScript,
            '-Wav', $wav,
            '-Volume', '0.22', '-Adaptive', '1', '-MaxGain', '0.5'
        ) | Out-Null
    }
    catch { }
}

function Select-Sound([string]$id) {
    $state = Read-State
    Write-State ([bool]$state.muted) $id
    Update-Ui
    Start-Preview $id
}

function Update-Ui {
    $state = Read-State
    if ($state.muted) {
        $notify.Icon = $iconMuted
        $notify.Text = 'DSH 提示音：已静音'
        $toggleItem.Text = '开启提示音'
    }
    else {
        $notify.Icon = $iconNormal
        $notify.Text = 'DSH 提示音：开'
        $toggleItem.Text = '静音提示音'
    }

    $active = if ($state.sound) { [string]$state.sound } else { 'win-generic' }
    foreach ($key in $script:soundItems.Keys) {
        $script:soundItems[$key].Checked = ($key -eq $active)
    }
}

function Toggle-Mute {
    $state = Read-State
    Write-State (-not $state.muted) ([string]$state.sound)
    Update-Ui
}

$toggleItem.add_Click({ Toggle-Mute })
$notify.add_MouseClick({
        param($sender, $eventArgs)
        if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Toggle-Mute }
    })

$previewItem.add_Click({
        $state = Read-State
        $active = if ($state.sound) { [string]$state.sound } else { 'win-generic' }
        Start-Preview $active
    })

$exitItem.add_Click({
        $notify.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })

# Remember this instance so the Host can replace it on the next reload.
try { Set-Content -LiteralPath $pidFile -Value $PID -Encoding UTF8 } catch { Write-Log "pid file write failed: $($_.Exception.Message)" }
Write-Log "pid file written"

# Only react to chimes that happen after this icon starts: seed the last seen
# stamp from the file so a DSH restart does not flash the taskbar by itself.
$script:lastDing = 0
try {
    $seed = Get-Content -LiteralPath $EventsFile -Raw -ErrorAction Stop
    $script:lastDing = [int64](($seed | ConvertFrom-Json).lastDing)
}
catch { }
$script:ringUntil = [DateTime]::MinValue

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 600
$timer.add_Tick({
        try {
            # Leave with the Host: an orphan bell in the tray is worse than no bell.
            if ($ParentPid -gt 0) {
                $parent = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
                if (-not $parent) {
                    Write-Log "parent $ParentPid is gone; exiting"
                    $notify.Visible = $false
                    [System.Windows.Forms.Application]::Exit()
                    return
                }
            }

            # A fresh chime happened: flash the DSH taskbar button and ring the icon.
            try {
                $raw = Get-Content -LiteralPath $EventsFile -Raw -ErrorAction Stop
                $stamp = [int64](($raw | ConvertFrom-Json).lastDing)
                if ($stamp -gt $script:lastDing) {
                    $script:lastDing = $stamp
                    $script:ringUntil = (Get-Date).AddSeconds(3)
                    try {
                        $flashed = [TaskbarFlash]::Flash('DeepSeek')
                        Write-Log "flash result=$flashed"
                    }
                    catch { Write-Log "flash error: $($_.Exception.Message)" }
                }
            }
            catch { }

            if ((Get-Date) -lt $script:ringUntil) {
                $notify.Icon = $iconRinging
            }
            else {
                Update-Ui
            }
        }
        catch {
            Write-Log "tick error: $($_.Exception.Message)"
        }
    })

$notify.Visible = $true
Write-Log "notify visible"
Update-Ui
$timer.Start()
Write-Log "timer started, entering message loop"

try {
    [System.Windows.Forms.Application]::Run()
}
finally {
    Write-Log "message loop ended"
    $timer.Stop()
    $notify.Visible = $false
    $notify.Dispose()
    try { if (Test-Path -LiteralPath $pidFile) { Remove-Item -LiteralPath $pidFile -Force } } catch { }
}
