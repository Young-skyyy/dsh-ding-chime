<#
  Plays the DSH completion chime.

  Called by index.js when a turn finishes. The inline C# helper reads the Windows
  master volume and scales the chime so it lands at a comfortable level instead of
  blasting at whatever the system volume happens to be.

  The helper is compiled in memory (Add-Type -Path) on each call: ~0.6 s, before the
  first note is audible, and it avoids loading any assembly from disk.
#>
param(
    [Parameter(Mandatory = $true)][string]$Wav,
    [double]$Volume = 0.22,
    [int]$Adaptive = 1,
    [double]$MaxGain = 0.5,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'DshChime.cs'
# Each voice ships a pre-scaled twin for the case where the CoreAudio probe fails.
$fallback = $Wav -replace '\.wav$', '-soft.wav'

try {
    if (-not ('DshChime' -as [type])) {
        Add-Type -Path $source
    }
    if ($DryRun) {
        'master={0:N3}' -f [DshChime]::MasterVolume()
        return
    }
    $gain = [DshChime]::Ding($Wav, [single]$Volume, ($Adaptive -ne 0), [single]$MaxGain)
    if ($gain -lt 0) { 'silent' } else { 'gain={0:N3}' -f $gain }
}
catch {
    # No CoreAudio, or the helper did not compile: play the pre-scaled soft chime.
    if (Test-Path -LiteralPath $fallback) {
        (New-Object System.Media.SoundPlayer $fallback).PlaySync()
        'fallback: ' + $_.Exception.Message
    }
    else {
        throw
    }
}
