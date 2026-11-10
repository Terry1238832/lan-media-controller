# Windows Media & Network Bridge (WinRT GSMTC + User32 Media Keys)
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName System.Runtime.WindowsRuntime

$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSession, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]

# C# Helper for hardware media key simulation fallback
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class MediaKeyFallback {
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    private const int KEYEVENTF_EXTENDEDKEY = 0x0001;
    private const int KEYEVENTF_KEYUP = 0x0002;

    public const byte VK_MEDIA_NEXT_TRACK = 0xB0;
    public const byte VK_MEDIA_PREV_TRACK = 0xB1;
    public const byte VK_MEDIA_STOP = 0xB2;
    public const byte VK_MEDIA_PLAY_PAUSE = 0xB3;

    public static void TapKey(byte vk) {
        keybd_event(vk, 0, KEYEVENTF_EXTENDEDKEY, UIntPtr.Zero);
        keybd_event(vk, 0, KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP, UIntPtr.Zero);
    }
}
"@

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

function Await-WinRT($WinRtTask, $ResultType) {
    if ($null -eq $WinRtTask) { return $null }
    $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($WinRtTask))
    $netTask.Wait(1500) | Out-Null
    if ($netTask.IsCompleted -and -not $netTask.IsFaulted -and -not $netTask.IsCanceled) {
        return $netTask.Result
    }
    return $null
}

$script:sessionManager = $null
function Get-Manager {
    if ($null -eq $script:sessionManager) {
        try {
            $script:sessionManager = Await-WinRT ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
        } catch {
            $script:sessionManager = $null
        }
    }
    return $script:sessionManager
}

function Get-LanName {
    try {
        $profile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
        if ($null -ne $profile -and -not [string]::IsNullOrWhiteSpace($profile.ProfileName)) {
            return $profile.ProfileName
        }
    } catch {}
    return "Local Network"
}

function Format-AppName([string]$appId) {
    if ([string]::IsNullOrWhiteSpace($appId)) { return "Windows Player" }
    $clean = $appId -replace '\.exe$', ''
    if ($clean -match 'Spotify') { return 'Spotify' }
    if ($clean -match 'cloudmusic') { return 'NetEase Music' }
    if ($clean -match 'QQMusic') { return 'QQ Music' }
    if ($clean -match 'AppleMusic|iTunes') { return 'Apple Music' }
    if ($clean -match 'msedge') { return 'Microsoft Edge' }
    if ($clean -match 'chrome') { return 'Google Chrome' }
    if ($clean -match 'firefox') { return 'Firefox' }
    if ($clean -match 'ZuneMusic|MediaPlayer') { return 'Windows Media Player' }
    $parts = $clean -split '[\\!]'
    return $parts[$parts.Length - 1]
}

function Get-StateJson {
    $lanName = Get-LanName
    $players = @()
    $mgr = Get-Manager

    if ($null -ne $mgr) {
        try {
            $sessions = $mgr.GetSessions()
            foreach ($s in $sessions) {
                $appId = $s.SourceAppUserModelId
                $info = $s.GetPlaybackInfo()
                $tl = $s.GetTimelineProperties()
                $title = ""
                $artist = ""
                try {
                    $props = Await-WinRT ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
                    if ($null -ne $props) {
                        $title = [string]$props.Title
                        $artist = [string]$props.Artist
                    }
                } catch {}

                $isPlaying = ($info.PlaybackStatus -eq [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionPlaybackStatus]::Playing)
                $pos = 0.0
                $dur = 0.0
                if ($null -ne $tl) {
                    $pos = [math]::Max(0.0, $tl.Position.TotalSeconds)
                    $dur = [math]::Max(0.0, $tl.EndTime.TotalSeconds)
                    if ($isPlaying -and $tl.LastUpdatedTime.Year -gt 2000) {
                        $elapsed = ([DateTimeOffset]::UtcNow - $tl.LastUpdatedTime).TotalSeconds
                        if ($elapsed -gt 0 -and $elapsed -lt 36000) {
                            $pos = $pos + $elapsed
                        }
                    }
                    if ($dur -gt 0 -and $pos -gt $dur) {
                        $pos = $dur
                    }
                }

                $players += @{
                    playerId  = $appId
                    appName   = (Format-AppName $appId)
                    title     = $title
                    artist    = [string]$artist
                    isPlaying = [bool]$isPlaying
                    position  = [math]::Round($pos, 1)
                    duration  = if ($dur -gt 0) { [math]::Round($dur, 1) } else { 300 }
                }
            }
        } catch {}
    }

    if ($players.Count -eq 0) {
        $players += @{
            playerId  = "system"
            appName   = "Windows Player"
            title     = ""
            artist    = ""
            isPlaying = $false
            position  = 0
            duration  = 300
        }
    }

    $result = @{
        lanName = $lanName
        players = $players
    }
    return ($result | ConvertTo-Json -Compress -Depth 5)
}

function Invoke-MediaCommand($cmdObj) {
    $action = [string]$cmdObj.action
    $playerId = [string]$cmdObj.playerId
    $pos = [double]($cmdObj.position)

    $mgr = Get-Manager
    $targetSession = $null

    if ($null -ne $mgr) {
        try {
            $sessions = $mgr.GetSessions()
            foreach ($s in $sessions) {
                if ($s.SourceAppUserModelId -eq $playerId) {
                    $targetSession = $s
                    break
                }
            }
            if ($null -eq $targetSession) {
                $targetSession = $mgr.GetCurrentSession()
            }
            if ($null -eq $targetSession -and $sessions.Count -gt 0) {
                $targetSession = $sessions[0]
            }
        } catch {}
    }

    if ($null -ne $targetSession) {
        try {
            switch ($action) {
                "play" {
                    $null = Await-WinRT ($targetSession.TryPlayAsync()) ([bool])
                    return
                }
                "pause" {
                    $null = Await-WinRT ($targetSession.TryPauseAsync()) ([bool])
                    return
                }
                "toggle" {
                    $null = Await-WinRT ($targetSession.TryTogglePlayPauseAsync()) ([bool])
                    return
                }
                "prev" {
                    $null = Await-WinRT ($targetSession.TrySkipPreviousAsync()) ([bool])
                    return
                }
                "next" {
                    $null = Await-WinRT ($targetSession.TrySkipNextAsync()) ([bool])
                    return
                }
                "seek" {
                    $ticks = [long]($pos * 10000000)
                    $null = Await-WinRT ($targetSession.TryChangePlaybackPositionAsync($ticks)) ([bool])
                    $info = $targetSession.GetPlaybackInfo()
                    if ($info.PlaybackStatus -ne [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionPlaybackStatus]::Playing) {
                        $null = Await-WinRT ($targetSession.TryPlayAsync()) ([bool])
                    }
                    return
                }
            }
        } catch {}
    }

    # Universal hardware media key fallback
    switch ($action) {
        "play"   { [MediaKeyFallback]::TapKey([MediaKeyFallback]::VK_MEDIA_PLAY_PAUSE) }
        "pause"  { [MediaKeyFallback]::TapKey([MediaKeyFallback]::VK_MEDIA_PLAY_PAUSE) }
        "toggle" { [MediaKeyFallback]::TapKey([MediaKeyFallback]::VK_MEDIA_PLAY_PAUSE) }
        "prev"   { [MediaKeyFallback]::TapKey([MediaKeyFallback]::VK_MEDIA_PREV_TRACK) }
        "next"   { [MediaKeyFallback]::TapKey([MediaKeyFallback]::VK_MEDIA_NEXT_TRACK) }
        "seek"   { [MediaKeyFallback]::TapKey([MediaKeyFallback]::VK_MEDIA_PLAY_PAUSE) }
    }
}

while ($null -ne ($line = [Console]::ReadLine())) {
    $line = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
        $req = $line | ConvertFrom-Json
        if ($req.op -eq "state") {
            $out = Get-StateJson
            [Console]::WriteLine($out)
        } elseif ($req.op -eq "cmd") {
            Invoke-MediaCommand $req
            $out = Get-StateJson
            [Console]::WriteLine($out)
        }
    } catch {
        [Console]::WriteLine('{"lanName":"Local Network","players":[]}')
    }
}
