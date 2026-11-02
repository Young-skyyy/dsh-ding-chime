<#
  Convert real sound sources into the plugin's WAV format.

  Source: the sounds shipped with this Windows installation (C:\Windows\Media).
  They are licensed to the machine, so they may be used locally but must not be
  redistributed with the plugin. Each output is mono 44.1 kHz 16-bit PCM,
  silence-trimmed, peak-normalised to -0.5 dBFS, with a 30 ms fade-out.

  Run: powershell -File plugins/ding-chime/tools/import-sources.ps1
#>

# Native tools write progress to stderr; keep that from aborting the script and
# check exit codes explicitly instead.
$ErrorActionPreference = 'Continue'
$media = 'C:\Windows\Media'
$outDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\sounds'

$ffmpeg = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if (-not $ffmpeg) { throw 'ffmpeg not found on PATH' }
$ffprobe = Join-Path (Split-Path $ffmpeg) 'ffprobe.exe'
if (-not (Test-Path $ffprobe)) { throw 'ffprobe not found next to ffmpeg' }

$sources = [ordered]@{
    'win-generic'  = 'Windows Notify System Generic.wav'
    'win-calendar' = 'Windows Notify Calendar.wav'
    'win-email'    = 'Windows Notify Email.wav'
    'win-message'  = 'Windows Notify Messaging.wav'
    'win-ding'     = 'Windows Ding.wav'
    'win-chime'    = 'chimes.wav'
    'win-nudge'    = 'Windows Message Nudge.wav'
}

function Get-PeakDb([string]$path) {
    $log = & $ffmpeg -hide_banner -nostats -i $path -af volumedetect -f null NUL 2>&1
    $match = [regex]::Match(($log -join "`n"), 'max_volume:\s*(-?\d+(?:\.\d+)?) dB')
    if (-not $match.Success) { throw "cannot read peak of $path" }
    return [double]$match.Groups[1].Value
}

foreach ($id in $sources.Keys) {
    $src = Join-Path $media $sources[$id]
    if (-not (Test-Path -LiteralPath $src)) { Write-Host "skip $id (missing source)"; continue }

    $tmp = Join-Path $env:TEMP "$id-trim.wav"
    # Trim leading/trailing silence, then make it mono 44.1k PCM with a short fade.
    & $ffmpeg -y -hide_banner -loglevel error -i $src `
        -af "silenceremove=start_periods=1:start_duration=0.005:start_threshold=-55dB:detection=peak,areverse,silenceremove=start_periods=1:start_duration=0.005:start_threshold=-55dB:detection=peak,areverse" `
        -ac 1 -ar 44100 -c:a pcm_s16le $tmp
    if ($LASTEXITCODE -ne 0) { throw "trim failed for $id" }

    $duration = [double](& $ffprobe -v error -show_entries format=duration -of csv=p=0 $tmp)
    $fadeStart = [Math]::Max(0.0, $duration - 0.03)
    $peak = Get-PeakDb $tmp
    $gain = [Math]::Round(-0.5 - $peak, 2)

    $master = Join-Path $outDir "$id.wav"
    (& $ffmpeg -y -hide_banner -loglevel error -i $tmp `
        -af "volume=${gain}dB,afade=t=out:st=$([Math]::Round($fadeStart,3)):d=0.03" `
        -ac 1 -ar 44100 -c:a pcm_s16le $master)
    if ($LASTEXITCODE -ne 0) { throw "encode failed for $id" }

    $soft = Join-Path $outDir "$id-soft.wav"
    (& $ffmpeg -y -hide_banner -loglevel error -i $master -af "volume=-13.5dB" `
        -ac 1 -ar 44100 -c:a pcm_s16le $soft)
    if ($LASTEXITCODE -ne 0) { throw "soft encode failed for $id" }

    Remove-Item -LiteralPath $tmp -Force
    Write-Host ("{0,-13} {1,5:N2}s  peak {2,6:N1} dB  gain {3,6:N2} dB" -f $id, $duration, $peak, $gain)
}

Write-Host "done -> $outDir"
