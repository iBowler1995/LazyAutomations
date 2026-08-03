<#
.SYNOPSIS
    WPF GUI front-end for the AutoRip automated disc-ripping pipeline.

.DESCRIPTION
    AutoRip-GUI.ps1 is a WPF front-end that runs the rip, transcode, rename, extras,
    and cleanup pipeline in a background runspace. Insert a disc, select media type,
    and click Start — the GUI handles:

        1. RIP      — MakeMKV extracts titles from the disc as raw MKV files.
                       Movies rip all titles above $MovieRipMinLength seconds.
                       TV shows rip all titles above $TVRipMinLength seconds.
        2. TRANSCODE — Each MKV is re-encoded with HandBrakeCLI (x265, CRF 22).
                       Movies transcode the largest file (assumed to be the main
                       feature). TV transcodes all episode files, excluding play-all
                       titles, in disc order.
        3. RENAME   — FileBot renames and moves transcoded file(s) using database
                       metadata. Movies use TheMovieDB ("Title (Year)/Title (Year).mkv").
                       TV uses TheTVDB ("{show}/Season {s}/{show} - {s00e00} - {t}").
                       If FileBot cannot auto-match, the GUI prompts for a manual title.
        4. EXTRAS   — Any MKV files remaining after FileBot has moved the main content
                       are treated as extras, moved to an "extras" subfolder, and transcoded.
        5. CLEANUP  — The original raw rip folder is deleted if empty.

.NOTES
    ── Configuration ────────────────────────────────────────────────────────────────
    All user-configurable paths and settings live in the Variable Configuration
    region near the top of the script. The following variables are defined there:

    $MediaDir            Root media folder (e.g. "E:/Media")
    $MakeMKVPath         Path to the MakeMKV folder
    $FfmpegPath          Path to ffmpeg.exe
    $FfProbePath         Path to ffprobe.exe
    $HandbrakeCLI        Path to HandBrakeCLI.exe
    $FileBotPath         Path to filebot.exe
    $RipperLog           Path to the main rip log file
    $FileBotLog          Path to the FileBot log file
    $CompletionSound     Sound played on successful completion
    $AlertSound          Sound played when manual title input is needed
    $TVRipMinLength      Minimum title duration for TV rips in seconds (default: 30)
    $MovieRipMinLength   Minimum title duration for movie rips in seconds (default: 300)

    ── Resolution handling ───────────────────────────────────────────────────────────
    ffprobe auto-detects source resolution before each transcode. DVD sources
    (height <= 480) are output at 854x480 to correct for anamorphic pixels. HD
    sources (Blu-ray) are kept at native resolution.

    ── Dependencies ────────────────────────────────────────────────────────────────
    MakeMKV        https://www.makemkv.com/
    ffmpeg/ffprobe https://ffmpeg.org/
    HandBrakeCLI   https://handbrake.fr/
    FileBot        https://www.filebot.net/

    ── Assumptions ──────────────────────────────────────────────────────────────────
    - Movies: the largest MKV in the rip folder is the main feature; everything
      else is treated as an extra.
    - TV shows: the largest file (detected via play-all check) is excluded;
      remaining files are transcoded as episodes in disc order.
    - Episode numbering starts from the existing MKV count in the target Season N
      folder so multi-disc season rips append correctly.
#>

#region ── Bootstrap ─────────────────────────────────────────────────────────
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore

$xamlPath = "$PSScriptRoot\AutoRip-GUI.xaml"
$raw      = (Get-Content $xamlPath -Raw) -replace 'x:Name', 'Name'
[xml]$xaml = $raw
$reader    = New-Object System.Xml.XmlNodeReader $xaml
$window    = [Windows.Markup.XamlReader]::Load($reader)
#endregion

#region ── Control references ────────────────────────────────────────────────
$ComboDrive     = $window.FindName('ComboDrive')
$BtnRefresh     = $window.FindName('BtnRefresh')
$RadioMovie     = $window.FindName('RadioMovie')
$RadioTV        = $window.FindName('RadioTV')
$BtnStart       = $window.FindName('BtnStart')
$PanelFileBot   = $window.FindName('PanelFileBot')
$TxtTitle       = $window.FindName('TxtTitle')
$BtnSubmitTitle = $window.FindName('BtnSubmitTitle')
$BtnSkipTitle   = $window.FindName('BtnSkipTitle')
$ProgressBar    = $window.FindName('ProgressBar')
$TxtLog         = $window.FindName('TxtLog')
$LogScroller    = $window.FindName('LogScroller')
$PanelTVFormat    = $window.FindName('PanelTVFormat')
$CboTVFormat      = $window.FindName('CboTVFormat')
$LblFormatExample = $window.FindName('LblFormatExample')
$TxtSeason        = $window.FindName('TxtSeason')
$ChkManualTitle   = $window.FindName('ChkManualTitle')
$TxtManualTitle = $window.FindName('TxtManualTitle')
$PanelComplete  = $window.FindName('PanelComplete')
$BtnRipAnother  = $window.FindName('BtnRipAnother')
$BtnExit        = $window.FindName('BtnExit')
#endregion

#region ── Variable Configuration ────────────────────────────────────────────
$MediaDir        = 'E:/Media'
$MakeMKVPath     = 'C:\Program Files (x86)\MakeMKV'
$FfmpegPath      = 'C:\Program Files (x86)\ffmpeg\bin\ffmpeg.exe'
$FfProbePath     = 'C:\Program Files (x86)\ffmpeg\bin\ffprobe.exe'
$HandbrakeCLI    = 'C:\Program Files\HandBrake\HandBrakeCLI.exe'
$FileBotPath     = 'C:/Program Files/FileBot/filebot.exe'
$RipperLog       = 'C:\Temp\Ripper.log'
$FileBotLog      = 'C:\Temp\filebot.log'
$CompletionSound   = "$PSScriptRoot\sound_files\mariomushroom.mp3"
$AlertSound        = "$PSScriptRoot\sound_files\metalgear.mp3"
$TVRipMinLength    = 30    # MakeMKV --minlength for TV rips (seconds)
$MovieRipMinLength = 300   # MakeMKV --minlength for movie rips (seconds)
#endregion

#region ── Shared state (thread-safe) ────────────────────────────────────────
# ConcurrentQueue is used for the log because multiple threads enqueue messages
# while the UI thread dequeues them — standard Queue is not thread-safe.
$sync = [hashtable]::Synchronized(@{
    Log             = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    Progress        = [double]-1    # -1 = hide bar, 0-100 = show and fill
    FileBotNeeded   = $false        # runspace sets true when FileBot fails to match
    FileBotAlert    = $false        # runspace sets true when FileBot fails with a manual title (play sound, no panel)
    FileBotTitle    = [string]$null # UI writes the user-supplied title here
    FileBotSkip     = $false        # UI sets true when Skip is clicked
    Done            = $false
    Failed          = $false
})
#endregion

#region ── Startup validation ─────────────────────────────────────────────────
$requiredTools = [ordered]@{
    'MakeMKV'      = "$MakeMKVPath\makemkvcon64.exe"
    'ffmpeg'       = $FfmpegPath
    'ffprobe'      = $FfProbePath
    'HandBrakeCLI' = $HandbrakeCLI
    'FileBot'      = $FileBotPath
}

$missing = $requiredTools.GetEnumerator() | Where-Object { !(Test-Path $_.Value) }
if ($missing) {
    $msg = ($missing | ForEach-Object { "$($_.Key): $($_.Value)" }) -join "`n"
    [System.Windows.MessageBox]::Show(
        "The following tools were not found:`n`n$msg`n`nUpdate the paths in the Variable Configuration region.",
        'AutoRip — Missing Tools',
        'OK', 'Error'
    )
    exit 1
}

if (!(Test-Path $MediaDir)) {
    [System.Windows.MessageBox]::Show(
        "Media root '$MediaDir' does not exist.`n`nUpdate `$MediaDir in the Variable Configuration region.",
        'AutoRip — Missing Media Root',
        'OK', 'Error'
    )
    exit 1
}
#endregion

#region ── Helper: populate drive dropdown ───────────────────────────────────
function Update-DriveList {
    $ComboDrive.Items.Clear()
    $drives = @(Get-CimInstance Win32_LogicalDisk | Where-Object DriveType -eq 5)

    if ($drives.Count -eq 0) {
        $ComboDrive.Items.Add('No optical drive detected') | Out-Null
        $ComboDrive.SelectedIndex = 0
        $BtnStart.IsEnabled = $false
        return
    }

    foreach ($d in $drives) {
        $label = "$($d.DeviceID) — $($d.VolumeName)"
        $ComboDrive.Items.Add($label) | Out-Null
    }
    $ComboDrive.SelectedIndex = 0
    $BtnStart.IsEnabled = $true
}
#endregion

#region ── Dispatcher timer ──────────────────────────────────────────────────
# Runs on the UI thread every 100 ms. Drains the log queue and reacts to
# state changes set by the background runspace.
$timer          = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(100)

$timer.Add_Tick({
    # Drain log queue
    $msg = $null
    while ($sync.Log.TryDequeue([ref]$msg)) {
        $TxtLog.AppendText("$msg`n")
    }
    $LogScroller.ScrollToEnd()

    # Progress bar
    if ($sync.Progress -ge 0) {
        if ($ProgressBar.Visibility -ne 'Visible') {
            $ProgressBar.Visibility = 'Visible'
        }
        $ProgressBar.Value = $sync.Progress
    }

    # FileBot needs a title
    if ($sync.FileBotNeeded -and $PanelFileBot.Visibility -ne 'Visible') {
        $PanelFileBot.Visibility = 'Visible'
        Start-Process 'wmplayer.exe' -ArgumentList "`"$AlertSound`"" -WindowStyle Hidden
    }

    # FileBot failed with a pre-supplied title — alert only, no panel
    if ($sync.FileBotAlert) {
        $sync.FileBotAlert = $false
        Start-Process 'wmplayer.exe' -ArgumentList "`"$AlertSound`"" -WindowStyle Hidden
    }

    # Pipeline finished
    if ($sync.Done -or $sync.Failed) {
        $timer.Stop()
        $BtnStart.IsEnabled       = $true
        $PanelFileBot.Visibility  = 'Collapsed'

        if ($sync.Done) {
            $PanelComplete.Visibility = 'Visible'
            Start-Process 'wmplayer.exe' -ArgumentList "`"$CompletionSound`"" -WindowStyle Hidden
        }
    }
})
#endregion

#region ── Pipeline script (runs inside background runspace) ─────────────────
$pipelineScript = {

    function Log ([string]$m) {
        $sync.Log.Enqueue($m)
        Add-Content -Path $RipperLog -Value "$(Get-Date -Format 'HH:mm:ss')  $m" -ErrorAction SilentlyContinue
    }

    function Sanitize-Name ([string]$s) {
        return ($s -replace '[:\\/*?"<>|]', '').Trim()
    }

    function Get-DiscTitleInfo {
        param ([string]$ApplicationPath)

        $TitleInfo = & "$ApplicationPath\makemkvcon64.exe" -r info disc:0 2>&1

        $totalTitles = $TitleInfo | Where-Object { $_ -match '^TCOUNT:(\d+)' } |
            ForEach-Object { [int]$Matches[1] } | Select-Object -Last 1

        # Collect duration and filename for every title up front
        $allDurations = @{}
        $TitleInfo | Where-Object { $_ -match '^TINFO:(\d+),9,0,"(.+)"$' } | ForEach-Object {
            $index = [int]$Matches[1]
            $parts = $Matches[2] -split ':'
            $allDurations[$index] = [int]$parts[0] * 3600 + [int]$parts[1] * 60 + [int]$parts[2]
        }
        $allFileNames = @{}
        $TitleInfo | Where-Object { $_ -match '^TINFO:(\d+),27,0,"(.+)"$' } | ForEach-Object {
            $allFileNames[[int]$Matches[1]] = $Matches[2]
        }

        # Play-all detection by duration: a play-all's runtime ≈ sum of all other titles combined
        $totalDur       = ($allDurations.Values | Measure-Object -Sum).Sum
        $playAllIndices = @($allDurations.Keys | Where-Object {
            $dur       = $allDurations[$_]
            $sumOthers = $totalDur - $dur
            $sumOthers -gt 0 -and $dur -ge ($sumOthers * 0.9)
        })
        $titlesToRip = 0..($totalTitles - 1) | Where-Object { $_ -notin $playAllIndices -and $allDurations.ContainsKey($_) }

        $titleData = @{}
        foreach ($idx in $titlesToRip) {
            $titleData[$idx] = [PSCustomObject]@{ Index = $idx; Duration = $allDurations[$idx]; FileName = $allFileNames[$idx] }
        }

        $longestDur       = ($titleData.Values | Where-Object { $_.Duration } | Measure-Object Duration -Maximum).Maximum
        $episodeFileNames = $titleData.Values | Where-Object { $_.Duration -ge ($longestDur * 0.8) } | Sort-Object Index | Select-Object -ExpandProperty FileName
        $extraFileNames   = $titleData.Values | Where-Object { $_.Duration -lt ($longestDur * 0.8) } | Sort-Object Index | Select-Object -ExpandProperty FileName

        return [PSCustomObject]@{
            TitlesToRip      = $titlesToRip
            EpisodeFileNames = $episodeFileNames
            ExtraFileNames   = $extraFileNames
        }
    }

    function Convert-VideoWithCropFix {
        param(
            [string]$MediaPath,
            [string]$ffmpeg,
            [string]$ffprobe,
            [string]$handbrake,
            [switch]$KeepOriginal
        )

        if (!(Test-Path $MediaPath)) { Log "File not found: $MediaPath"; return }

        $file       = Get-Item $MediaPath
        $outputPath = Join-Path $file.Directory "$($file.BaseName)-converted.mkv"

        $probeOut = & $ffprobe -v quiet -select_streams v:0 `
            -show_entries stream=width,height -of csv=p=0 "$MediaPath" 2>&1
        if ($probeOut -match '(\d+),(\d+)') {
            $frameWidth  = [int]$Matches[1]
            $frameHeight = [int]$Matches[2]
        } else {
            Log "Could not detect resolution — assuming DVD (720x480)"
            $frameWidth = 720; $frameHeight = 480
        }
        $isDVD = $frameHeight -le 480
        Log "Source: ${frameWidth}x${frameHeight} ($( if ($isDVD) { 'DVD' } else { 'HD' } ))"

        $samplePoints = @('00:01:00', '00:05:00', '00:10:00', '00:20:00', '00:30:00')
        $topValues = @(); $bottomValues = @(); $leftValues = @(); $rightValues = @()

        Log "Running cropdetect at multiple timestamps..."
        foreach ($ts in $samplePoints) {
            $result = & $ffmpeg -ss $ts -i "$MediaPath" -t 10 -vf cropdetect -an -sn -f null NUL 2>&1 |
                Select-String 'crop=' | Select-Object -Last 1
            if ($result) {
                $parts = (($result -split 'crop=')[1].Trim()) -split ':'
                $cw = [int]$parts[0]; $ch = [int]$parts[1]
                $cx = [int]$parts[2]; $cy = [int]$parts[3]
                $topValues    += $cy
                $bottomValues += $frameHeight - $ch - $cy
                $leftValues   += $cx
                $rightValues  += $frameWidth  - $cw - $cx
                Log "  $ts -> crop=${cw}:${ch}:${cx}:${cy}"
            }
        }

        if ($topValues.Count -eq 0) {
            Log "Crop detection failed at all timestamps — using full frame"
            $cropTop = 0; $cropBottom = 0; $cropLeft = 0; $cropRight = 0
        } else {
            $cropTop    = ($topValues    | Measure-Object -Minimum).Minimum
            $cropBottom = ($bottomValues | Measure-Object -Minimum).Minimum
            $cropLeft   = ($leftValues   | Measure-Object -Minimum).Minimum
            $cropRight  = ($rightValues  | Measure-Object -Minimum).Minimum
        }
        Log "Final crop: Top=$cropTop Bottom=$cropBottom Left=$cropLeft Right=$cropRight"

        $dimensionArgs = if ($isDVD) { @('--width','854','--height','480') } else { @() }

        $hbArgs = @(
            '-i', $MediaPath, '-o', $outputPath,
            '--encoder', 'x265', '--quality', '22',
            '--crop', "${cropTop}:${cropBottom}:${cropLeft}:${cropRight}"
        ) + $dimensionArgs + @(
            '--optimize',
            '--audio', '1', '--aencoder', 'copy',
            '--subtitle', '1', '--markers'
        )

        Log "Transcoding $($file.Name)..."
        $sync.Progress = 0
        & $handbrake @hbArgs 2>&1 | ForEach-Object {
            $line = "$_"
            $sync.Log.Enqueue($line)
            if ($line -match '(\d+\.\d+) %') { $sync.Progress = [double]$Matches[1] }
        }

        if ((Test-Path $outputPath) -and (Get-Item $outputPath).Length -gt 0) {
            if (-not $KeepOriginal) { Remove-Item $MediaPath -Force }
            Log "Transcode complete: $(Split-Path $outputPath -Leaf)"
        } else {
            Log "WARNING: Output missing or empty — original preserved."
        }
        Log '============================='
    }

    try {
        $isTV = $OutputDir -match '\\TV$'

        # ── Step 1: Rip ──────────────────────────────────────────────────────
        <#
            * MakeMKV extracts titles from the disc as raw MKV files.
            * Media Type Behavior:
                * Movies - rip all titles above $MovieRipMinLength seconds.
                * TV - rip all titles above $TVRipMinLength seconds.
        #>
        $Dir2 = Join-Path $OutputDir $VolumeName
        if (!(Test-Path $Dir2)) { New-Item $Dir2 -Type Directory -Force | Out-Null }
        Log "Ripping disc into $Dir2..."

        if ($isTV) {
            & "$MakeMKVPath\makemkvcon64.exe" "--minlength=$TVRipMinLength" mkv disc:0 all "$Dir2" 2>&1 |
                ForEach-Object { $sync.Log.Enqueue("$_") }
        } else {
            & "$MakeMKVPath\makemkvcon64.exe" "--minlength=$MovieRipMinLength" mkv disc:0 all "$Dir2" 2>&1 |
                ForEach-Object { $sync.Log.Enqueue("$_") }
        }
        Log "Rip complete."
        Log '================'

        # ── Step 2: Transcode ────────────────────────────────────────────────
        <#
            * Transcoding the main content through Convert-VideoWithCropFix (cropdetect → HandBrake x265 CRF22).
            * Media Type Behavior:
                * Movies - transcode the largest file (assumed to be the main feature).
                * TV - transcode all episode files, excluding play-all titles, in disc order.
        #>
        $InputDirectory    = Join-Path $OutputDir $VolumeName
        $AllFiles          = Get-ChildItem $InputDirectory -File
        $convertedEpisodes = @()

        if ($isTV) {
            $allRipped = Get-ChildItem $InputDirectory -Filter '*.mkv' -File | Sort-Object Length -Descending
            # A genuine play-all contains all other titles — its size should be ~= sum of the rest
            if ($allRipped.Count -gt 1) {
                $totalSize   = ($allRipped | Measure-Object -Property Length -Sum).Sum
                $largestFile = $allRipped[0].Length
                $sumOfRest   = $totalSize - $largestFile
                if ($sumOfRest -gt 0 -and $largestFile -ge ($sumOfRest * 0.9)) {
                    Log "Removing suspected play-all title: $($allRipped[0].Name)"
                    Remove-Item $allRipped[0].FullName -Force
                    $allRipped = @($allRipped | Select-Object -Skip 1)
                }
            }
            $largestSize  = ($allRipped | Select-Object -First 1).Length
            $episodeFiles = @($allRipped | Where-Object { $_.Length -ge ($largestSize * 0.8) })
            $extraFiles   = @($allRipped | Where-Object { $_.Length -lt  ($largestSize * 0.8) })
            Log "Found $($episodeFiles.Count) episode(s), $($extraFiles.Count) extra(s)"
            if ($extraFiles) { Log "Extras detected — will transcode after rename" }

            foreach ($episode in $episodeFiles) {
                Log "Transcoding episode: $($episode.BaseName)..."
                Convert-VideoWithCropFix -MediaPath $episode.FullName `
                    -ffmpeg $FfmpegPath -ffprobe $FfProbePath -handbrake $HandbrakeCLI
                $convertedEpisodes += Get-Item (Join-Path $episode.Directory "$($episode.BaseName)-converted.mkv") -ErrorAction SilentlyContinue
            }
            $convertedEpisodes = @($convertedEpisodes | Where-Object { $_ -ne $null })
            if ($convertedEpisodes.Count -eq 0) { throw "All episode transcodes failed — check source disc." }
        } else {
            $MainVideoFile = $AllFiles | Sort-Object Length -Descending | Select-Object -First 1
            if (-not $MainVideoFile) { throw "No files found in $InputDirectory — rip may have failed." }
            Log "Main feature: $($MainVideoFile.Name)"
            Convert-VideoWithCropFix -MediaPath $MainVideoFile.FullName `
                -ffmpeg $FfmpegPath -ffprobe $FfProbePath -handbrake $HandbrakeCLI
        }

        # ── Step 3: FileBot rename ────────────────────────────────────────────
        <#
            * FileBot renames and moves transcoded files using database metadata.
            * Media Type Behavior:
                * Movies - FileBot matches against TheMovieDB; renames to "Title (Year)/Title (Year).mkv".
                  If FileBot cannot auto-match, the GUI prompts for a manual title, then FileBot retries.
                * TV - FileBot matches against TheTVDB using $showQuery (derived from the volume label or
                  the ManualTitle override). Episode files are pre-renamed to s##e##.mkv before FileBot so
                  disc order is preserved. $startEpisode is derived from the existing MKV count in the
                  Season N folder so multi-disc season rips append correctly.
        #>
        if (Test-Path $FileBotLog) { Clear-Content $FileBotLog }

        $RenamedFolder = $null
        $moveLines     = $null

        if ($isTV) {
            # Derive show name from volume label; ManualTitle overrides if supplied
            $showQuery = if ($ManualTitle) {
                $ManualTitle
            } else {
                ($VolumeName -replace '(_S\d+)?(_D\d+|_DISC_?\d+)$') -replace '_', ' '
            }
            $seasonNumber = if ($SeasonOverride -gt 0) { $SeasonOverride }
                           elseif ($VolumeName -match '_S(\d+)') { [int]$Matches[1] }
                           else { 1 }

            # Find the season folder from the real show name on disk.
            # If the exact path doesn't exist, search for any Season N folder and update
            # $showQuery from it so FileBot also gets the correct name.
            $seasonFolder = Join-Path (Join-Path $OutputDir $showQuery) "Season $seasonNumber"
            if (-not (Test-Path $seasonFolder)) {
                $found = Get-ChildItem $OutputDir -Directory |
                    ForEach-Object { Get-ChildItem $_.FullName -Directory -Filter "Season $seasonNumber" -ErrorAction SilentlyContinue } |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($found) {
                    $seasonFolder = $found.FullName
                    $showQuery    = $found.Parent.Name
                    Log "Matched existing show folder: '$showQuery'"
                }
            }
            $startEpisode = (Get-ChildItem $seasonFolder -Filter '*.mkv' -File -ErrorAction SilentlyContinue).Count + 1

            Log "Show: '$showQuery'  Season: $seasonNumber  Start episode: $startEpisode"
            Log "Season folder: $seasonFolder  (exists: $(Test-Path $seasonFolder))"

            $renamedEpisodes = @()
            for ($i = 0; $i -lt $convertedEpisodes.Count; $i++) {
                $newName = "s{0:D2}e{1:D2}.mkv" -f [int]$seasonNumber, [int]($startEpisode + $i)
                $newPath = Join-Path $convertedEpisodes[$i].Directory $newName
                Rename-Item $convertedEpisodes[$i].FullName -NewName $newName
                $renamedEpisodes += Get-Item $newPath
            }
            Log "Running FileBot (TheTVDB)..."
            $fbArgs = @('-rename') + @($renamedEpisodes | ForEach-Object { $_.FullName }) + @(
                '--db', 'TheTVDB',
                '--format', $TVFormat,
                '--output', $OutputDir,
                '--action', 'move',
                '--conflict', 'skip',
                '--log', 'all',
                '--log-file', $FileBotLog,
                '-non-strict',
                '--q', $showQuery
            )
            & "$FileBotPath" @fbArgs 2>&1 | ForEach-Object { $sync.Log.Enqueue("$_") }

            $skippedFiles = @($renamedEpisodes | Where-Object { Test-Path $_.FullName })
            if ($skippedFiles.Count -gt 0) {
                Log "WARNING: FileBot skipped $($skippedFiles.Count) file(s) — already exist at destination or unmatched:"
                $skippedFiles | ForEach-Object { Log "  $($_.Name)" }
            }

            $moveLines = Get-Content $FileBotLog -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '\[MOVE\].* to \[.*\]' }

            if (-not $moveLines) {
                if ($ManualTitle) {
                    Log "FileBot could not match with override title '$ManualTitle' — check files manually."
                    $sync.FileBotAlert = $true
                } else {
                $sync.FileBotNeeded = $true
                while ($sync.FileBotNeeded) { Start-Sleep -Milliseconds 200 }
                }

                if (-not $ManualTitle -and -not $sync.FileBotSkip) {
                    Clear-Content $FileBotLog
                    $fbRetryArgs = @('-rename') + @($renamedEpisodes | ForEach-Object { $_.FullName }) + @(
                        '--db', 'TheTVDB',
                        '--format', $TVFormat,
                        '--output', $OutputDir,
                        '--action', 'move',
                        '--conflict', 'skip',
                        '--log', 'all',
                        '--log-file', $FileBotLog,
                        '-non-strict',
                        '--q', $sync.FileBotTitle
                    )
                    & "$FileBotPath" @fbRetryArgs 2>&1 | ForEach-Object { $sync.Log.Enqueue("$_") }
                    $moveLines = Get-Content $FileBotLog -ErrorAction SilentlyContinue |
                        Where-Object { $_ -match '\[MOVE\].* to \[.*\]' }
                }
            }

            $lastMove = $moveLines | Select-Object -Last 1
            if ($lastMove -match 'to \[(.*?)\]') {
                # TV: depth 2 — file is inside Season N, walk up to the show root
                $RenamedFolder = Split-Path (Split-Path $Matches[1] -Parent) -Parent
                Log "Moved to: $RenamedFolder"
            }

        } else {
            $TranscodedFile = Join-Path $MainVideoFile.Directory "$($MainVideoFile.BaseName)-converted.mkv"
            if (!(Test-Path $TranscodedFile)) { throw "Transcoded file not found — transcode likely failed." }

            if ($ManualTitle) {
                $sanitized      = Sanitize-Name $ManualTitle
                $renamedPath    = Join-Path (Split-Path $TranscodedFile -Parent) "$sanitized.mkv"
                Rename-Item -Path $TranscodedFile -NewName "$sanitized.mkv"
                $TranscodedFile = $renamedPath
                Log "Title overridden to: $sanitized"
            }

            Log "Running FileBot (TheMovieDB)..."
            & "$FileBotPath" -rename $TranscodedFile `
                --db TheMovieDB `
                --format '{n} ({y})/{n} ({y})' `
                --output $OutputDir `
                --action move `
                --conflict index `
                --log all `
                --log-file $FileBotLog `
                -non-strict 2>&1 | ForEach-Object { $sync.Log.Enqueue("$_") }

            $moveLines = Get-Content $FileBotLog -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '\[MOVE\].* to \[.*\]' }

            if (-not $moveLines) {
                if ($ManualTitle) {
                    Log "FileBot could not match with override title '$ManualTitle' — check files manually."
                    $sync.FileBotAlert = $true
                } else {
                    $sync.FileBotNeeded = $true
                    while ($sync.FileBotNeeded) { Start-Sleep -Milliseconds 200 }
                }

                if (-not $ManualTitle -and -not $sync.FileBotSkip) {
                    $sanitized      = Sanitize-Name $sync.FileBotTitle
                    $renamedPath    = Join-Path (Split-Path $TranscodedFile -Parent) "$sanitized.mkv"
                    Rename-Item -Path $TranscodedFile -NewName "$sanitized.mkv"
                    $TranscodedFile = $renamedPath
                    Clear-Content $FileBotLog
                    & "$FileBotPath" -rename $TranscodedFile `
                        --db TheMovieDB `
                        --format '{n} ({y})/{n} ({y})' `
                        --output $OutputDir `
                        --action move `
                        --conflict index `
                        --log all `
                        --log-file $FileBotLog `
                        -non-strict 2>&1 | ForEach-Object { $sync.Log.Enqueue("$_") }
                    $moveLines = Get-Content $FileBotLog -ErrorAction SilentlyContinue |
                        Where-Object { $_ -match '\[MOVE\].* to \[.*\]' }
                }
            }

            $lastMove = $moveLines | Select-Object -Last 1
            if ($lastMove -match 'to \[(.*?)\]') {
                $RenamedFolder = Split-Path $Matches[1] -Parent
                Log "Moved to: $RenamedFolder"
            }
        }

        # ── Step 4: Extras ────────────────────────────────────────────────────
        <#
            * Any MKV files remaining in the raw rip folder after FileBot has moved the main content
              are treated as extras.
            * Media Type Behavior:
                * Movies - remaining files are moved to an "extras" subfolder under the renamed movie folder and transcoded.
                * TV - remaining files are moved to an "extras" subfolder under the renamed show folder and transcoded.
        #>
        if ($RenamedFolder) {
            $Extras   = Join-Path $RenamedFolder 'extras'
            $AllFiles = Get-ChildItem $InputDirectory -File -Filter *.mkv -ErrorAction SilentlyContinue

            if ($AllFiles) {
                if (!(Test-Path $Extras)) { New-Item $Extras -ItemType Directory -Force | Out-Null }

                foreach ($f in $AllFiles) {
                    Move-Item $f.FullName -Destination $Extras
                    Log "Extra moved: $($f.Name)"
                }

                $ExtraFiles = Get-ChildItem $Extras -File -Filter *.mkv -ErrorAction SilentlyContinue
                foreach ($extra in $ExtraFiles) {
                    Log "Transcoding extra: $($extra.Name)"
                    Convert-VideoWithCropFix -MediaPath $extra.FullName `
                        -ffmpeg $FfmpegPath -ffprobe $FfProbePath -handbrake $HandbrakeCLI
                }
            }
        } else {
            Log "No renamed folder found — extras skipped. Check $InputDirectory manually."
        }

        # ── Step 5: Cleanup ───────────────────────────────────────────────────
        <#
            * The original raw rip folder is deleted if empty (all content moved by FileBot/extras step).
            * If files remain, a warning is logged and the folder is left for manual review.
        #>
        $remaining = Get-ChildItem $InputDirectory -Force -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\extras\\' }
        if (-not $remaining) {
            Remove-Item $InputDirectory -Force -Recurse
            Log "Cleaned up $InputDirectory"
        } else {
            Log "Files remain in $InputDirectory — check before deleting."
        }

        $sync.Done = $true

    } catch {
        $sync.Log.Enqueue("ERROR at line $($_.InvocationInfo.ScriptLineNumber): $_")
        $sync.Failed = $true
    }
}
#endregion

#region ── Events ─────────────────────────────────────────────────────────────
$BtnRefresh.Add_Click({ Update-DriveList })

$formatExamples = @{
    '{n}/Season {s}/{n} - {s00e00} - {t}' = 'e.g.  Seinfeld / Season 4 / Seinfeld - S04E01 - The Trip'
    '{n}/Season {s}/{s00e00} - {t}'        = 'e.g.  Seinfeld / Season 4 / S04E01 - The Trip'
    '{n}/{s00e00} - {t}'                   = 'e.g.  Seinfeld / S04E01 - The Trip  (no season folders)'
    '{n}/Season {s}/{n} - {s00e00}'        = 'e.g.  Seinfeld / Season 4 / Seinfeld - S04E01  (no episode title)'
}

$CboTVFormat.Add_SelectionChanged({
    $selected = $CboTVFormat.SelectedItem.Content
    $LblFormatExample.Text = if ($formatExamples.ContainsKey($selected)) { $formatExamples[$selected] } else { '' }
})

$RadioTV.Add_Checked({
    $PanelTVFormat.Visibility = 'Visible'
    $selectedItem = $ComboDrive.SelectedItem -as [string]
    if ($selectedItem -and $selectedItem -match '_S(\d+)') { $TxtSeason.Text = "$([int]$Matches[1])" }
})
$RadioMovie.Add_Checked({ $PanelTVFormat.Visibility = 'Collapsed' })

$ComboDrive.Add_SelectionChanged({
    if ($RadioTV.IsChecked) {
        $selectedItem = $ComboDrive.SelectedItem -as [string]
        if ($selectedItem -and $selectedItem -match '_S(\d+)') { $TxtSeason.Text = "$([int]$Matches[1])" }
    }
})

$ChkManualTitle.Add_Checked({   $TxtManualTitle.IsEnabled = $true;  $TxtManualTitle.Focus() | Out-Null })
$ChkManualTitle.Add_Unchecked({ $TxtManualTitle.IsEnabled = $false; $TxtManualTitle.Clear() })

$BtnStart.Add_Click({
    # Reset shared state
    $sync.Log.Clear() | Out-Null
    Clear-Content $RipperLog -ErrorAction SilentlyContinue
    $sync.Progress      = -1
    $sync.FileBotNeeded = $false
    $sync.FileBotAlert  = $false
    $sync.FileBotTitle  = $null
    $sync.FileBotSkip   = $false
    $sync.Done          = $false
    $sync.Failed        = $false

    $TxtLog.Clear()
    $ProgressBar.Value        = 0
    $ProgressBar.Visibility   = 'Collapsed'
    $PanelComplete.Visibility = 'Collapsed'
    $PanelFileBot.Visibility  = 'Collapsed'
    $BtnStart.IsEnabled       = $false

    # Resolve drive + media type + optional manual title
    $selectedItem   = $ComboDrive.SelectedItem -as [string]
    $volumeName     = ($selectedItem -split ' — ', 2)[1].Trim()
    $mediaType      = if ($RadioMovie.IsChecked) { 'Movies' } else { 'TV' }
    $outputDir      = "$MediaDir\$mediaType"
    $manualTitle    = if ($ChkManualTitle.IsChecked -and -not [string]::IsNullOrWhiteSpace($TxtManualTitle.Text)) {
                          $TxtManualTitle.Text.Trim()
                      } else { $null }
    $tvFormat       = $CboTVFormat.Text
    $seasonOverride = [int]($TxtSeason.Text -replace '\D', '')
    if ($seasonOverride -lt 1) { $seasonOverride = 1 }

    # Build and configure runspace — CreateDefault2() is required for PS7 compatibility
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault2()
    $rs  = [runspacefactory]::CreateRunspace($iss)
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()

    $rs.SessionStateProxy.SetVariable('sync',           $sync)
    $rs.SessionStateProxy.SetVariable('VolumeName',     $volumeName)
    $rs.SessionStateProxy.SetVariable('OutputDir',      $outputDir)
    $rs.SessionStateProxy.SetVariable('MakeMKVPath',    $MakeMKVPath)
    $rs.SessionStateProxy.SetVariable('FfmpegPath',     $FfmpegPath)
    $rs.SessionStateProxy.SetVariable('FfProbePath',    $FfProbePath)
    $rs.SessionStateProxy.SetVariable('HandbrakeCLI',   $HandbrakeCLI)
    $rs.SessionStateProxy.SetVariable('FileBotPath',    $FileBotPath)
    $rs.SessionStateProxy.SetVariable('FileBotLog',     $FileBotLog)
    $rs.SessionStateProxy.SetVariable('RipperLog',      $RipperLog)
    $rs.SessionStateProxy.SetVariable('ManualTitle',    $manualTitle)
    $rs.SessionStateProxy.SetVariable('TVFormat',         $tvFormat)
    $rs.SessionStateProxy.SetVariable('SeasonOverride',   $seasonOverride)
    $rs.SessionStateProxy.SetVariable('TVRipMinLength',   $TVRipMinLength)
    $rs.SessionStateProxy.SetVariable('MovieRipMinLength',$MovieRipMinLength)

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript($pipelineScript) | Out-Null
    $ps.BeginInvoke() | Out-Null

    $timer.Start()
})

$BtnSubmitTitle.Add_Click({
    if ([string]::IsNullOrWhiteSpace($TxtTitle.Text)) { return }
    $sync.FileBotTitle  = $TxtTitle.Text.Trim()
    $sync.FileBotSkip   = $false
    $sync.FileBotNeeded = $false
    $PanelFileBot.Visibility = 'Collapsed'
    $TxtTitle.Clear()
})

$BtnSkipTitle.Add_Click({
    $sync.FileBotSkip   = $true
    $sync.FileBotNeeded = $false
    $PanelFileBot.Visibility = 'Collapsed'
})

$BtnRipAnother.Add_Click({
    $PanelComplete.Visibility = 'Collapsed'
    $ProgressBar.Visibility   = 'Collapsed'
    $ProgressBar.Value        = 0
    $TxtLog.Clear()
    Update-DriveList
})

$BtnExit.Add_Click({ $window.Close() })
#endregion

#region ── Launch ─────────────────────────────────────────────────────────────
Update-DriveList
$CboTVFormat.SelectedIndex = 0
$LblFormatExample.Text = $formatExamples[($CboTVFormat.SelectedItem.Content)]
$window.ShowDialog() | Out-Null
#endregion
