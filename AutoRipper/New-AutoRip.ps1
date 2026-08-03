<#
.SYNOPSIS
    Automated DVD/Blu-ray ripping, transcoding, and library organization pipeline.

.DESCRIPTION
    New-AutoRip.ps1 is a fully automated end-to-end pipeline for getting DVDs and
    Blu-rays into a Plex/media-server-friendly library. Insert a disc, run the
    script, and it handles:

        1. RIP      — MakeMKV extracts titles from the disc as raw MKV files.
                       Movies rip all titles above a minimum length threshold.
                       Multi-feature discs query disc metadata first to identify
                       features vs extras by a configurable minimum duration, then
                       rip specific title indices. TV shows query the disc metadata
                       to detect and exclude play-all titles, then rip specific indices.
        2. TRANSCODE — Each MKV is re-encoded with HandBrakeCLI (x265, CRF 22).
                       Movies transcode the largest file (assumed to be the main
                       feature). Multi-feature transcodes each feature in disc order.
                       TV transcodes all episode files in disc order. ffprobe detects
                       source resolution: DVD sources are output at 854x480 (anamorphic
                       correction); HD/Blu-ray sources keep their native resolution.
                       ffmpeg cropdetect samples five timestamps and takes the minimum
                       crop on each side to avoid over-cropping from title cards or
                       unusual scenes.
        3. RENAME   — FileBot renames and moves the transcoded file(s) using database
                       metadata. Movies and multi-feature discs use TheMovieDB
                       ("Title (Year)/Title (Year).mkv"); multi-feature calls FileBot
                       once per feature. TV uses TheTVDB
                       ("{show}/Season {s}/{show} - {s00e00} - {t}"). Episode files
                       are pre-renamed to s##e##.mkv before FileBot so disc order is
                       preserved. The show name is prompted at runtime — press Enter
                       to auto-detect from the disc volume label.
        4. EXTRAS   — Any MKV files remaining in the raw rip folder after FileBot has
                       moved the main content are treated as extras. Single movies and
                       TV: extras are moved to an "extras" subfolder and transcoded.
                       Multi-feature: the user is prompted to assign each extra to one
                       of the renamed feature folders before transcoding.
        5. CLEANUP  — The original raw rip folder is deleted if empty. Per-step
                       transcripts are saved to $LogDir.

    At the end the script offers to loop and rip another disc.

.NOTES
    ── Configuration ────────────────────────────────────────────────────────────────
    All user-configurable paths and settings live in the Variable Configuration
    region near the top of the script — no need to hunt through the code. The
    following variables are defined there:

    $MediaDir            Root media folder (e.g. "E:/Media")
    $MakeMKVPath         Path to the MakeMKV folder
    $FfmpegPath          Path to ffmpeg.exe
    $FfProbePath         Path to ffprobe.exe
    $HandbrakeCLI        Path to HandBrakeCLI.exe
    $FileBotPath         Path to filebot.exe
    $LogDir              Base folder for per-step log files (step2_rip.log … step6_cleanup.log, filebot.log)
    $CompletionSound     Sound played on successful completion
    $AlertSound          Sound played when manual title input is needed
    $MultiMovieMinLength Default minimum feature duration in seconds for multi-feature discs (default: 3000 = 50 min)
    $MultiTVMinLength    Minimum title duration in seconds for TV rips (default: 1200 = 20 min)

    ── Resolution handling ───────────────────────────────────────────────────────────
    ffprobe auto-detects source resolution before each transcode. DVD sources
    (height <= 480) are output at 854x480 to correct for anamorphic pixels. HD
    sources (Blu-ray) are kept at native resolution. Crop math uses the detected
    dimensions, so both formats are handled correctly with no manual changes needed.

    ── Dependencies ────────────────────────────────────────────────────────────────
    MakeMKV        https://www.makemkv.com/
    ffmpeg/ffprobe https://ffmpeg.org/
    HandBrakeCLI   https://handbrake.fr/
    FileBot        https://www.filebot.net/

    ── Assumptions ──────────────────────────────────────────────────────────────────
    - Movies: the largest MKV in the rip folder is the main feature; everything
      else is treated as an extra.
    - Multi-feature discs: titles at or above $MultiMovieMinLength seconds are
      features; shorter titles are extras. Adjust $MultiMovieMinLength in the
      config to change the threshold. Each feature is renamed independently by FileBot.
    - TV shows: episodes and extras are classified by duration using MakeMKV disc
      metadata. Titles within 80% of the longest duration are episodes; shorter
      titles are extras. Play-all titles (detected via the segments map attribute)
      are excluded from ripping entirely.
    - cropdetect samples at five timestamps (1, 5, 10, 20, 30 minutes) — meaningful
      video must exist at those points. A very short title may produce a wrong crop.
    - If multiple optical drives are connected, the script prompts you to pick
      one. MakeMKV always reads from disc:0 (the first drive with a disc).
    - The first audio track on the disc is the one you want. Multi-language discs
      may need manual track selection in HandBrake after the fact.
    - The first subtitle track is the one you want (same caveat as audio).
    - FileBot writes [MOVE] log entries in a consistent format. If FileBot ever
      changes its log format, the destination folder parsing in Step 4 will break.
    - TV show name: always prompted after selecting TV. Press Enter to auto-detect from
      the disc volume label by stripping the season/disc suffix (e.g.
      "UNDER_THE_DOME_S1_D1" → "UNDER THE DOME"). Type a name to override — recommended
      when the volume label doesn't map cleanly to the show title.

    ── Remaining hardcoded values ────────────────────────────────────────────────
    These work well as-is but could be moved to the config region if needed:

      MinLength (movies)      300 s  MakeMKV skips titles shorter than 5 minutes.
      MinLength (TV)           30 s  Lower threshold so short extras are not dropped.
      CRF 22                         HandBrake quality — lower = better quality, larger file.
      Cropdetect timestamps          00:01:00, 00:05:00, 00:10:00, 00:20:00, 00:30:00
      Cropdetect window        10 s  Duration sampled at each timestamp.
      Episode threshold        80%   Titles within 80% of the longest duration = episodes.
      Feature threshold (multi) set by $MultiMovieMinLength in the config (default: 3000 s = 50 min).

    ── FileBot licensing note ──────────────────────────────────────────────────────
    FileBot requires a paid license for automated/CLI use. The script will silently
    fail the rename step if the license is missing or expired.

.EXAMPLE
    Just double-click the script or run it from a terminal — no arguments needed.
    The script prompts for media type (Movie or TV) interactively.
    .\New-AutoRip.ps1
#>

#region ── Helper functions ──────────────────────────────────────────────────────

function Sanitize-Name {
    <#
    .SYNOPSIS
        Strips characters that are illegal in Windows file/folder names.
    .DESCRIPTION
        DVD volume names sometimes contain colons, slashes, or other characters that
        Windows rejects in paths. This function removes them so the volume name can be
        used safely as a directory name.
    .PARAMETER InputDirectory
        The raw string to sanitize (typically a disc volume name from WMI).
    .OUTPUTS
        [string] The sanitized string with illegal characters removed and whitespace trimmed.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$InputDirectory
    )
    return ($InputDirectory -replace '[:\\/*?"<>|]', '').Trim()
}

function New-AutoRip {
    <#
    .SYNOPSIS
        Rips titles from an optical disc using MakeMKV.
    .DESCRIPTION
        Creates a destination folder named after the disc volume and invokes
        makemkvcon64.exe to extract MKV files into that folder.

        Movies rip all titles above the $MinLength threshold. TV shows pass
        specific title indices from Get-DiscTitleInfo, bypassing the minimum
        length filter since the title list has already been pre-screened.

        If the destination path does not exist the user is prompted for an
        alternative path at runtime.
    .PARAMETER ToDir
        Full path to the destination folder (e.g. "E:\Media\Movies"). Passed in
        from the script-level $OutputDir variable set during media type selection.
    .PARAMETER VolumeName
        Sanitized disc volume name. Detected and passed in from the drive
        detection step so the WMI lookup is only done once.
    .PARAMETER ApplicationPath
        Path to the MakeMKV folder containing makemkvcon64.exe.
    .PARAMETER MinLength
        Minimum title length in seconds for movie rips. Titles shorter than this
        are skipped by MakeMKV. Defaults to 300 (5 minutes). Not applied when
        $Titles is specified, since Get-DiscTitleInfo has already pre-screened
        the list and short extras should not be silently dropped.
    .PARAMETER Titles
        Optional array of title indices to rip individually (TV shows). When
        provided, only these specific titles are ripped with no minimum length
        filter applied.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ToDir,
        [Parameter(Mandatory = $true)]
        [string]$VolumeName,
        [Parameter(Mandatory = $true)]
        [string]$ApplicationPath,
        [Parameter(Mandatory = $false)]
        [int]$MinLength = 300,
        [Parameter(Mandatory = $false)]
        [int[]]$Titles = $null
    )

    if (!(Test-Path $ToDir)) {
        $ToDir = Read-Host -Prompt "Please enter path to save files to"
    }
    if (!(Test-Path "$ApplicationPath\makemkvcon64.exe")) {
        $ApplicationPath = Read-Host 'What is your makemkvcon64.exe folder path?'
    }
    Write-Host "Welcome to AutoRipper!" -ForegroundColor Green

    try {
        $Dir2 = Join-Path $ToDir $VolumeName
        if (!(Test-Path $Dir2)) {
            New-Item $Dir2 -Type Directory -Force
        }

        Write-Host "Beginning rip into $Dir2..." -ForegroundColor Cyan
        if ($Titles) {
            foreach ($title in $Titles) {
                & "$ApplicationPath\makemkvcon64.exe" "--minlength=$MinLength" "mkv" "disc:0" "$title" "$Dir2"
            }
        } else {
            & "$ApplicationPath\makemkvcon64.exe" "--minlength=$MinLength" "mkv" "disc:0" "all" "$Dir2"
        }
        Write-Host "Rip complete. Files saved to $Dir2" -ForegroundColor Green
    }
    catch [System.Exception] {
        Write-Error "Error ripping disc at line $($_.InvocationInfo.ScriptLineNumber): $_"
    }
}

function Convert-VideoWithCropFix {
    <#
    .SYNOPSIS
        Auto-detects letterbox crop and transcodes an MKV with HandBrakeCLI (x265).
    .DESCRIPTION
        Two-phase process:

        Phase 1 — Resolution detection (ffprobe)
            ffprobe reads the source stream dimensions. DVD sources (height <= 480)
            are encoded at 854x480 to bake in the correct display dimensions.
            HD sources pass no explicit dimensions, letting HandBrake preserve
            the native resolution automatically.

        Phase 2 — Crop detection (ffmpeg)
            ffmpeg samples 10 seconds of video at five timestamps (1, 5, 10, 20,
            and 30 minutes) using the 'cropdetect' filter to find the largest
            non-black region at each point. It outputs lines like
            "crop=704:352:8:64" (width:height:x:y), where x/y is the top-left
            corner of the crop window relative to the full frame.

            The minimum crop value on each side across all samples is used so
            that one atypical frame (title card, fade, unusual scene) cannot
            over-crop the whole encode.

            Crop values are converted to HandBrake's top:bottom:left:right format:
                top    = y
                bottom = frameHeight - cropHeight - y
                left   = x
                right  = frameWidth  - cropWidth  - x

            frameWidth/frameHeight come from the ffprobe result, so this works
            correctly for both DVD and HD sources.

        Phase 3 — Transcode (HandBrakeCLI)
            Encodes to x265 at CRF 22, copies the first audio track as-is,
            and includes the first subtitle track with chapter markers. Output file is
            named "<original_basename>-converted.mkv" in the same folder.

        After a successful encode the original file is deleted unless -KeepOriginal
        is specified. If the output file is missing or empty the original is preserved
        and a warning is shown.
    .PARAMETER MediaPath
        Full path to the input MKV file.
    .PARAMETER ffmpeg
        Path to ffmpeg.exe. Passed in from $FfmpegPath in the config region.
    .PARAMETER ffprobe
        Path to ffprobe.exe. Passed in from $FfProbePath in the config region.
    .PARAMETER handbrake
        Path to HandBrakeCLI.exe. Passed in from $HandbrakeCLI in the config region.
    .PARAMETER KeepOriginal
        If set, the source file is NOT deleted after a successful transcode.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$MediaPath,
        [Parameter(Mandatory = $true)]
        [string]$ffmpeg,
        [Parameter(Mandatory = $true)]
        [string]$ffprobe,
        [Parameter(Mandatory = $true)]
        [string]$handbrake,
        [Parameter(Mandatory = $false)]
        [switch]$KeepOriginal
    )

    if (!(Test-Path $MediaPath)) {
        Write-Error "File not found: $MediaPath"
        return
    }

    $file = Get-Item $MediaPath
    $outputPath = Join-Path $file.Directory "$($file.BaseName)-converted.mkv"

    #Detecting source resolution so crop math and output dimensions are always correct
    $probeOutput = & $ffprobe -v quiet -select_streams v:0 `
        -show_entries stream=width,height -of csv=p=0 "$MediaPath" 2>&1
    if ($probeOutput -match '(\d+),(\d+)') {
        $frameWidth  = [int]$Matches[1]
        $frameHeight = [int]$Matches[2]
    } else {
        Write-Warning "Could not detect source resolution, assuming DVD (720x480)"
        $frameWidth = 720; $frameHeight = 480
    }
    $isDVD = $frameHeight -le 480
    Write-Host "Source resolution: ${frameWidth}x${frameHeight} ($( if ($isDVD) { 'DVD' } else { 'HD' } ))" -ForegroundColor Cyan

    #Sampling at multiple timestamps and taking the minimum crop on each side so
    #that one atypical frame (title card, fade, unusual scene) cannot over-crop the whole film.
    $samplePoints = @('00:01:00', '00:05:00', '00:10:00', '00:20:00', '00:30:00')
    $topValues = @(); $bottomValues = @(); $leftValues = @(); $rightValues = @()

    Write-Host "Running cropdetect at multiple timestamps..." -ForegroundColor Cyan
    foreach ($ts in $samplePoints) {
        $result = & $ffmpeg -ss $ts -i "$MediaPath" -t 10 -vf cropdetect -an -sn -f null NUL 2>&1 |
            Select-String -Pattern 'crop=' | Select-Object -Last 1
        if ($result) {
            $parts = (($result -split 'crop=')[1].Trim()) -split ':'
            $cw = [int]$parts[0]; $ch = [int]$parts[1]
            $cx = [int]$parts[2]; $cy = [int]$parts[3]
            $topValues    += $cy
            $bottomValues += $frameHeight - $ch - $cy
            $leftValues   += $cx
            $rightValues  += $frameWidth  - $cw - $cx
            Write-Host "  $ts -> crop=${cw}:${ch}:${cx}:${cy}" -ForegroundColor DarkCyan
        }
    }

    if ($topValues.Count -eq 0) {
        Write-Warning "Crop detection failed at all timestamps — using full frame"
        $cropTop = 0; $cropBottom = 0; $cropLeft = 0; $cropRight = 0
    } else {
        $cropTop    = ($topValues    | Measure-Object -Minimum).Minimum
        $cropBottom = ($bottomValues | Measure-Object -Minimum).Minimum
        $cropLeft   = ($leftValues   | Measure-Object -Minimum).Minimum
        $cropRight  = ($rightValues  | Measure-Object -Minimum).Minimum
    }

    Write-Host "Final crop: Top=$cropTop, Bottom=$cropBottom, Left=$cropLeft, Right=$cropRight"

    #DVD: correct for anamorphic pixels (720x480 → 854x480 display).
    #HD:  keep native resolution; HandBrake picks it up automatically.
    if ($isDVD) {
        $dimensionArgs = @("--width", "854", "--height", "480")
    } else {
        $dimensionArgs = @()
    }

    $HandbrakeArgs = @(
        "-i", "$MediaPath",
        "-o", "$outputPath",
        "--encoder", "x265",
        "--quality", "22",
        "--crop", "${cropTop}:${cropBottom}:${cropLeft}:${cropRight}"
    ) + $dimensionArgs + @(
        "--optimize",
        "--audio", "1",
        "--aencoder", "copy",
        "--subtitle", "1",
        "--markers"
    )

    Write-Host "Transcoding with HandBrakeCLI..."
    & $handbrake @HandbrakeArgs 2>&1 | Write-Host

    if ((Test-Path $outputPath) -and ((Get-Item $outputPath).Length -gt 0)) {
        if (-not $KeepOriginal) {
            Remove-Item $MediaPath -Force
            Write-Host "Original deleted. Final file: $outputPath" -ForegroundColor Green
        } else {
            Write-Host "Original preserved. Final file: $outputPath" -ForegroundColor Green
        }
    } else {
        Write-Warning "Transcoding failed. Original preserved."
    }

    Write-Host "============================="
}


function Invoke-FileBot {
    <#
    .SYNOPSIS
        Renames and moves transcoded files using FileBot metadata matching.
    .DESCRIPTION
        Resolves each input file to its transcoded counterpart, then calls FileBot
        to rename and move it based on the specified database and format string.

        Two calling patterns are supported:
          Movies  — pass the original FileInfo (deleted after transcode); the
                    function appends -converted.mkv to find the actual file.
          TV      — pass pre-renamed FileInfo objects (e.g. s01e01.mkv) that
                    exist on disk; the function uses them directly.

        If FileBot finds no match, an alert sound is played and the user is
        prompted for the correct title. Movies are renamed on disk so FileBot
        can match by filename; TV shows retry with --q. Returns the destination
        folder path parsed from the FileBot log, used by Step 5 to sort extras.
    .PARAMETER InputFiles
        One or more FileInfo objects representing the files to rename. For movies,
        this is the original rip file (may be deleted); for TV it is the
        pre-renamed transcoded file.
    .PARAMETER Format
        FileBot format string (e.g. "{n} ({y})/{n} ({y})" for movies,
        "{n}/Season {s}/{n} - {s00e00} - {t}" for TV).
    .PARAMETER OutDirectory
        Root output directory. FileBot creates the show/movie subfolder structure
        beneath this path.
    .PARAMETER FBPath
        Full path to filebot.exe.
    .PARAMETER FBLog
        Path to the FileBot log file. Cleared before each run and parsed
        afterward to extract the destination folder.
    .PARAMETER MediaDB
        Database to match against: 'TheMovieDB' for movies, 'TheTVDB' for TV.
    .PARAMETER FolderDepth
        Number of path levels to walk up from the renamed file to reach the
        show/movie root folder. 1 for movies, 2 for TV (file is inside Season N).
    .PARAMETER AlertPath
        Optional path to an audio file played when FileBot fails to match and
        needs manual input.
    .PARAMETER Query
        Optional search query passed to FileBot as --q. For TV, derived from the
        disc volume label (e.g. "UNDER THE DOME") so FileBot searches by title
        rather than guessing from generic MakeMKV filenames.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo[]]$InputFiles,
        [Parameter(Mandatory = $true)]
        [string]$Format,
        [Parameter(Mandatory = $true)]
        [string]$OutDirectory,
        [Parameter(Mandatory = $true)]
        [string]$FBPath,
        [Parameter(Mandatory = $true)]
        [string]$FBLog,
        [Parameter(Mandatory = $true)]
        [string]$MediaDB,
        [Parameter(Mandatory = $true)]
        [int]$FolderDepth,
        [Parameter(Mandatory = $false)]
        [string]$AlertPath,
        [Parameter(Mandatory = $false)]
        [string]$Query = ''
    )

    #Transcoding deletes the originals, so resolve the converted path:
    #if the file itself was pre-renamed and passed directly (TV path), use it as-is; otherwise append -converted.mkv.
    $transcodedPaths = @(
        $InputFiles | ForEach-Object {
            $converted = if (Test-Path $_.FullName) { $_.FullName }
                         else { Join-Path $_.Directory "$($_.BaseName)-converted.mkv" }

            if (Test-Path $converted) {
                $converted
            } else {
                Write-Warning "Transcoded file not found for '$($_.Name)' — skipping."
            }
        }
    )

    if ($transcodedPaths.Count -eq 0) {
        Write-Error "No transcoded files found — transcode likely failed. Check the log and re-run."
        return
    }


    If (Test-Path $FBLog) { Clear-Content $FBLog }

    Write-Host "Renaming item(s)..." -ForegroundColor Cyan
    $FBArgs = @("-rename") + $transcodedPaths + @(
        "--db", $MediaDB,
        "--format", $Format,
        "--output", $OutDirectory,
        "--action", "move",
        "--conflict", "skip",
        "--log", "all",
        "--log-file", $FBLog,
        "-non-strict"
    )
    #Pass the show/movie name directly so FileBot searches by title rather than guessing from the generic MakeMKV filename
    if ($Query) { $FBArgs += @("--q", $Query) }
    & "$FBPath" @FBArgs | Out-Host

    #If FileBot finds no match there will be no [MOVE] lines in the log.
    $moveLines = Get-Content $FBLog | Where-Object { $_ -match '\[MOVE\].* to \[.*\]' }

    if (-not $moveLines) {
        If ($AlertPath) {
            Start-Process "wmplayer.exe" -ArgumentList "`"$AlertPath`"" -WindowStyle Hidden
        }

        if ($InputFiles.Count -eq 1) {
            Write-Warning "FileBot could not match '$($InputFiles[0].BaseName)'. Enter the correct title or type 'skip'."
            $FileBotQuery = (Read-Host "Title").Trim()

            if ($FileBotQuery -ieq 'skip') {
                Write-Warning "Skipping rename. Files will remain in $($InputFiles[0].Directory) and extras will not be sorted."
                return
            }

            #Renaming the file to the user-supplied title so FileBot can match it by name
            $sanitizedQuery  = Sanitize-Name $FileBotQuery
            $renamedPath     = Join-Path $InputFiles[0].Directory "$sanitizedQuery.mkv"
            Rename-Item -Path $transcodedPaths[0] -NewName "$sanitizedQuery.mkv"
            $transcodedPaths = @($renamedPath)

        } else {
            Write-Warning "FileBot could not match. Enter the show name or type 'skip'."
            $FileBotQuery = (Read-Host "Title").Trim()

            if ($FileBotQuery -ieq 'skip') {
                Write-Warning "Skipping rename. Files will remain in $($InputFiles[0].Directory) and extras will not be sorted."
                return
            }
        }

        Clear-Content $FBLog
        $RetryArgs = @("-rename") + $transcodedPaths + @(
            "--db", $MediaDB,
            "--format", $Format,
            "--output", $OutDirectory,
            "--action", "move",
            "--conflict", "skip",
            "--log", "all",
            "--log-file", $FBLog,
            "-non-strict"
        )
        if ($InputFiles.Count -gt 1) { $RetryArgs += @("--q", $FileBotQuery) }
        & "$FBPath" @RetryArgs | Out-Host

        $moveLines = Get-Content $FBLog | Where-Object { $_ -match '\[MOVE\].* to \[.*\]' }
        if (-not $moveLines) {
            Write-Warning "Still no match for '$FileBotQuery'. Check the title spelling and try again."
        }
    }

    #Parsing FileBot log to find the destination so we can locate the extras subfolder.
    $lastMoveLine = $moveLines | Select-Object -Last 1

    if ($lastMoveLine -match 'to \[(.*?)\]') {
        $RenamedFolder = $matches[1]
        for ($i = 0; $i -lt $FolderDepth; $i++) {
            $RenamedFolder = Split-Path $RenamedFolder -Parent
        }
        Write-Host "Successfully renamed! Destination: $RenamedFolder" -ForegroundColor Green
        return $RenamedFolder
    } else {
        Write-Warning "No destination path found — extras will not be sorted."
    }
}

function Get-DiscTitleInfo {
    <#
    .SYNOPSIS
        Queries MakeMKV for disc title metadata and classifies titles as features/episodes or extras.
    .DESCRIPTION
        Runs makemkvcon64.exe in robot mode (-r info) to read title metadata from the
        inserted disc without performing a full rip. Parses three pieces of information:

        1. Play-all detection (attribute 26 — segments map)
           A title whose chapter range contains a comma (e.g. "1-6,7-12,13-18") is a
           concatenation of multiple episodes and should not be ripped individually.
           These title indices are excluded from the returned TitlesToRip list.

        2. Duration (attribute 9 — H:MM:SS)
           Converted to total seconds for each title. Classification depends on mode:
           - TV / default: titles within 80% of the longest duration are episodes;
             shorter titles are extras.
           - Multi-feature ($MinFeatureLength provided): titles at or above the
             threshold are features; shorter titles are extras.

        3. Output filename (attribute 27)
           The filename MakeMKV will produce when ripping each title (e.g. C2_t00.mkv).
           Returned as EpisodeFileNames and ExtraFileNames so downstream steps can
           classify ripped files without re-running ffprobe.

    .PARAMETER ApplicationPath
        Path to the MakeMKV folder containing makemkvcon64.exe. Passed in from
        $MakeMKVPath in the Variable Configuration region.
    .PARAMETER MinFeatureLength
        Optional minimum duration in seconds for multi-feature disc classification.
        When provided, titles at or above this threshold are treated as features
        (EpisodeFileNames); shorter titles are extras. When omitted, the default
        80%-of-longest heuristic is used for TV episode classification.
    .OUTPUTS
        [PSCustomObject] with three properties:
            TitlesToRip      — [int[]]    title indices to pass to New-AutoRip
            EpisodeFileNames — [string[]] output filenames classified as episodes or features
            ExtraFileNames   — [string[]] output filenames classified as extras
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ApplicationPath,
        [Parameter(Mandatory = $false)]
        [int]$MinFeatureLength
    )

    $TitleInfo = & "$ApplicationPath\makemkvcon64.exe" -r info disc:0 2>&1

    $totalTitles = $TitleInfo | Where-Object { $_ -match '^TCOUNT:(\d+)' } |
        ForEach-Object { [int]$Matches[1] } | Select-Object -Last 1

    #Collect duration (attr 9) and filename (attr 27) for every title up front.
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

    #Play-all detection by duration: a play-all's runtime ≈ sum of all other titles combined.
    #The 0.9 threshold gives a 10% margin for minor encode-length variance.
    $totalDur       = ($allDurations.Values | Measure-Object -Sum).Sum
    $playAllIndices = @($allDurations.Keys | Where-Object {
        $dur       = $allDurations[$_]
        $sumOthers = $totalDur - $dur
        $sumOthers -gt 0 -and $dur -ge ($sumOthers * 0.9)
    })
    $titlesToRip = 0..($totalTitles - 1) | Where-Object { $_ -notin $playAllIndices -and $allDurations.ContainsKey($_) }

    #Build a lookup table for rippable titles only.
    $titleData = @{}
    foreach ($idx in $titlesToRip) {
        $titleData[$idx] = [PSCustomObject]@{ Index = $idx; Duration = $allDurations[$idx]; FileName = $allFileNames[$idx] }
    }

    #Titles within 80% of the longest duration are episodes; anything shorter is an extra.
    #80% gives enough headroom for variable-length episodes without misclassifying featurettes.
    $longestDur       = ($titleData.Values | Where-Object { $_.Duration } | Measure-Object Duration -Maximum).Maximum
    if ($MinFeatureLength) {
    $episodeFileNames = $titleData.Values | Where-Object { $_.Duration -ge $MinFeatureLength } | Sort-Object Index | Select-Object -ExpandProperty FileName
    $extraFileNames   = $titleData.Values | Where-Object { $_.Duration -lt $MinFeatureLength } | Sort-Object Index | Select-Object -ExpandProperty FileName
    } 
    else {
        $episodeFileNames = $titleData.Values | Where-Object { $_.Duration -ge ($longestDur * 0.8) } | Sort-Object Index | Select-Object -ExpandProperty FileName
        $extraFileNames   = $titleData.Values | Where-Object { $_.Duration -lt ($longestDur * 0.8) } | Sort-Object Index | Select-Object -ExpandProperty FileName
    }


    return [PSCustomObject]@{
        TitlesToRip      = $titlesToRip
        EpisodeFileNames = $episodeFileNames
        ExtraFileNames   = $extraFileNames
    }
}

#endregion ── Helper functions ───────────────────────────────────────────────────

#region ── Variable Configuration ──────────────────────────────────────────────────────
#Initializing variables
$MediaType           = $null
$OutputDir           = $null
$ManualShowName      = $null
$MediaDir            = "E:/Media"
$TVFormat            = "{n}/Season {s}/{n} - {s00e00} - {t}"
$MultiMovieMinLength = 3000
$MultiFeature        = $false
$TVRipMinLength      = 1080    #MakeMKV --minlength for TV rips (seconds)
$MovieRipMinLength   = 300   #MakeMKV --minlength for movie rips (seconds)


#Configuring Log Paths
$LogDir     = "C:\temp\log"    # Base folder — one .log file per step is written here

#Configuring Application Paths
$FileBotPath     = "C:/Program Files/FileBot/filebot.exe"
$MakeMKVPath     = 'C:\Program Files (x86)\MakeMKV'
$FfmpegPath      = 'C:\Program Files (x86)\ffmpeg\bin\ffmpeg.exe'
$FfProbePath     = 'C:\Program Files (x86)\ffmpeg\bin\ffprobe.exe'
$HandbrakeCLI    = 'C:\Program Files\HandBrake\HandBrakeCLI.exe'

#Soundbite Paths
$CompletionSound = "$PSScriptRoot\sound_files\mariomushroom.mp3"
$AlertSound      = "$PSScriptRoot\sound_files\metalgear.mp3"


#endregion ── Variable Configuration ──────────────────────────────────────────────────────

if (-not (Test-Path $LogDir)) { New-Item $LogDir -ItemType Directory -Force | Out-Null }
$FileBotLog = Join-Path $LogDir "filebot.log"

#region ── Startup validation ────────────────────────────────────────────────────
#Verify all tools exist before prompting the user or starting a rip.

$requiredTools = [ordered]@{
    'MakeMKV'     = "$MakeMKVPath\makemkvcon64.exe"
    'ffmpeg'      = $FfmpegPath
    'ffprobe'     = $FfProbePath
    'HandBrakeCLI'= $HandbrakeCLI
    'FileBot'     = $FileBotPath
}

$missing = $requiredTools.GetEnumerator() | Where-Object { !(Test-Path $_.Value) }
if ($missing) {
    foreach ($tool in $missing) {
        Write-Error "$($tool.Key) not found at: $($tool.Value)"
    }
    Write-Error "Update the paths in the Variable Configuration region and try again."
    exit 1
}

if (!(Test-Path $MediaDir)) {
    Write-Error "Media root '$MediaDir' does not exist. Update `$MediaDir in the Variable Configuration region."
    exit 1
}

Write-Host "All tools verified." -ForegroundColor Green

#endregion ── Startup validation ─────────────────────────────────────────────────

#region ── Drive detection ───────────────────────────────────────────────────────
#Find optical drives. Auto-select if only one; prompt the user to pick if multiple.

$opticalDrives = @(Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.DriveType -eq 5 })

if ($opticalDrives.Count -eq 0) {
    Write-Error "No optical drive detected. Please insert a disc and try again."
    exit 1
}

if ($opticalDrives.Count -eq 1) {
    $DiscDrive = $opticalDrives[0]
} else {
    Write-Host "Multiple optical drives detected:"
    for ($i = 0; $i -lt $opticalDrives.Count; $i++) {
        Write-Host "$($i + 1). $($opticalDrives[$i].DeviceID) — $($opticalDrives[$i].VolumeName)"
    }
    do {
        $driveChoice = Read-Host "Select drive (1-$($opticalDrives.Count))"
    } while ($driveChoice -notmatch '^\d+$' -or [int]$driveChoice -lt 1 -or [int]$driveChoice -gt $opticalDrives.Count)
    $DiscDrive = $opticalDrives[[int]$driveChoice - 1]
}

if (-not $DiscDrive.VolumeName) {
    Write-Error "The drive $($DiscDrive.DeviceID) has no disc inserted or the disc has no volume label."
    exit 1
}

$Volume = Sanitize-Name $DiscDrive.VolumeName
Write-Host "Disc detected: $($DiscDrive.DeviceID) — $Volume" -ForegroundColor Green

#endregion ── Drive detection ────────────────────────────────────────────────────

#region ── STEP 1: Prompt for media type ─────────────────────────────────────────
#Prompting user for media type so we know which destination folder to use.

do {
    Write-Host "What type of media are you ripping?"
    Write-Host "1. Movies"
    Write-Host "2. TV Shows"
    Write-Host "3. Multi-Feature Movies"
    $choice = Read-Host "Enter 1 for Movies, 2 for TV Shows, or 3 for Multi-Feature Movies"

    switch ($choice) {
        "1" {
            $MediaType    = "Movies"
            $OutputDir    = "$MediaDir\Movies"
            $valid        = $true
            $MultiFeature = $false
            Write-Host "You selected Movies."
            cls
        }
        "2" {
            $MediaType    = "TV"
            $OutputDir    = "$MediaDir\TV"
            $valid        = $true
            $MultiFeature = $false
            Write-Host "You selected TV Show."
            $ManualShowName = (Read-Host "Please enter TV show name (press Enter to auto-detect from disc label)").Trim()
            cls            
        }
        "3" {
            $MediaType    = "Movies"
            $OutputDir    = "$MediaDir\Movies"
            $valid        = $true
            $MultiFeature = $true
            Write-Host "You selected Multi-Feature Movie."
            cls            
        }
        default {
            Write-Host "Invalid choice. Please enter 1 for Movies, 2 for TV Shows, or 3 for Multi-Feature Movies"
            $valid = $false
        }
    }
} while (-not $valid)

Write-Host "Media type set to: $MediaType, beginning autorip..." -ForegroundColor Cyan

#endregion ── STEP 1 ─────────────────────────────────────────────────────────────

#region ── STEP 2: Rip disc with MakeMKV ─────────────────────────────────────────
<#
    * Clearing the previous logs and invoking New-AutoRip.
    * Media Type Behavior:
        * Movies - rip all titles above the minimum length threshold.
        * Multi-feature - query disc metadata via Get-DiscTitleInfo to classify features vs extras by duration,
          then rip specific title indices. Minimum feature length is set by $MultiMovieMinLength in the config.
        * TV - query disc metadata via Get-DiscTitleInfo to detect and exclude play-all titles, then rip specific indices.
#>

Start-Transcript -Path (Join-Path $LogDir "step2_rip.log") -Force

switch ($MediaType) {
    "Movies" {
        If ($MultiFeature -eq $false) {
            New-AutoRip -ToDir $OutputDir -VolumeName $Volume -ApplicationPath $MakeMKVPath -MinLength $MovieRipMinLength
        }
        else{
            $discInfo = Get-DiscTitleInfo -ApplicationPath $MakeMKVPath -MinFeatureLength $MultiMovieMinLength
            New-AutoRip -ToDir $OutputDir -VolumeName $Volume -ApplicationPath $MakeMKVPath -Titles $discInfo.TitlesToRip
        }
        Write-Host "================"
    }
    "TV" {
        #Query the disc for title metadata — episode/extra classification happens inside Get-DiscTitleInfo. Ripping uses 'all' mode so MakeMKV makes a single pass.
        $discInfo = Get-DiscTitleInfo -ApplicationPath $MakeMKVPath
        New-AutoRip -ToDir $OutputDir -VolumeName $Volume -ApplicationPath $MakeMKVPath -MinLength $TVRipMinLength
        Write-Host "================"
    }
}



Stop-Transcript

#endregion ── STEP 2 ─────────────────────────────────────────────────────────────

#region ── STEP 3: Transcode main feature ────────────────────────────────────────
<#
    * Transcoding the main content through Convert-VideoWithCropFix (cropdetect → HandBrake x265 CRF22).
    * Media Type Behavior:
        * Movies - transcode the largest file (assumed to be the main feature).
        * Multi-feature - transcode each feature in disc order using the classification from Get-DiscTitleInfo.
        * TV - transcode each episode in disc order.
#>

Start-Transcript -Path (Join-Path $LogDir "step3_transcode.log") -Force

#Initialize variables outside the loops to prevent scope inheritance when script is re-invoked in the same seesion
$DestinationFolder  = $null
$DestinationFolders = @()
$usedExtrasFolders  = @()
$InputDirectory     = Join-Path $OutputDir $Volume


switch ($MediaType) {
    "Movies" {
        If ($MultiFeature -eq $false) {
            #Largest file by byte size is assumed to be the main feature; everything else = extras
            $MainVideoFile = Get-ChildItem $InputDirectory -File | Sort-Object Length -Descending | Select-Object -First 1

            #Ensuring $MainVideoFile is not null and causing silent crashes
            if (-not $MainVideoFile) {
                Write-Error "No MKV files found in $InputDirectory — the rip may have failed."
                Stop-Transcript
                exit 1
            }

            #Transcoding the main movie
            Try{

                Write-Host "Beginning transcoding for $($MainVideoFile.FullName)..." -ForegroundColor Cyan
                Convert-VideoWithCropFix -MediaPath $MainVideoFile.FullName -ffmpeg $FfmpegPath -ffprobe $FfProbePath -handbrake $HandbrakeCLI
                Write-Host "Transcoding successful!" -ForegroundColor Green


            }
            Catch{

                Write-Error "Error transcoding $($MainVideoFile.FullName) at line $($_.InvocationInfo.ScriptLineNumber): $_"

            }
        }
        else{
            $AllFiles          = Get-ChildItem $InputDirectory -File
            $convertedFeatures = @()
            $featureFiles      = @()

            #Use the filename classification produced by Get-DiscTitleInfo in Step 2 to separate episodes from extras without needing a second ffprobe pass on every file.
            foreach ($fileName in $discInfo.EpisodeFileNames) {
                $match = $AllFiles | Where-Object {$_.Name -eq $fileName}
                if ($match) {
                    $featureFiles += $match
                }
            }
            $extraFiles   = $AllFiles | Where-Object { $_.Name -in $discInfo.ExtraFileNames }

            if ($extraFiles) {
                Write-Host "Detected $($extraFiles.Count) extra(s) — will transcode after rename" -ForegroundColor Yellow
            }
            
            foreach ($feature in $featureFiles) {
                Write-Host "Transcoding feature: $($feature.BaseName)..." -ForegroundColor Cyan
                Convert-VideoWithCropFix -MediaPath $feature.FullName -ffmpeg $FfmpegPath -ffprobe $FfProbePath -handbrake $HandbrakeCLI
                $convertedFeatures += Get-Item (Join-Path $feature.Directory "$($feature.BaseName)-converted.mkv") -ErrorAction SilentlyContinue
            }
        }
    }
    "TV" {
        $AllFiles          = Get-ChildItem $InputDirectory -File
        $convertedEpisodes = @()
        $episodeFiles      = @()

        #Use the filename classification produced by Get-DiscTitleInfo in Step 2 to separate episodes from extras without needing a second ffprobe pass on every file.
        foreach ($fileName in $discInfo.EpisodeFileNames) {
            $match = $AllFiles | Where-Object {$_.Name -eq $fileName}
            if ($match) {
                $episodeFiles += $match
            }
        }
        $extraFiles   = $AllFiles | Where-Object { $_.Name -in $discInfo.ExtraFileNames }

        if ($extraFiles) {
            Write-Host "Detected $($extraFiles.Count) extra(s) — will transcode after rename" -ForegroundColor Yellow
        }

        
        foreach ($episode in $episodeFiles) {
            Write-Host "Transcoding episode: $($episode.BaseName)..." -ForegroundColor Cyan
            Convert-VideoWithCropFix -MediaPath $episode.FullName -ffmpeg $FfmpegPath -ffprobe $FfProbePath -handbrake $HandbrakeCLI
            $convertedEpisodes += Get-Item (Join-Path $episode.Directory "$($episode.BaseName)-converted.mkv") -ErrorAction SilentlyContinue
        }
    }
}

Stop-Transcript

#endregion ── STEP 3 ─────────────────────────────────────────────────────────────

#region ── STEP 4: Rename and move with FileBot ──────────────────────────────────
<#
    * Media Type Behavior: 
        * Movies: FileBot matches against TheMovieDB and renames to "Title (Year)/Title (Year).mkv".
          Multi-feature: FileBot is called once per feature; destination folders are collected into
          $DestinationFolders for use by the extras assignment prompt in Step 5.
        TV: FileBot matches against TheTVDB using $showQuery — either the user-supplied show name
          ($AutoDetectShowName = $false) or the name derived from the disc volume label ($true).
          The [MOVE] log lines look like: [MOVE] /path/to/old.mkv to [/path/to/Title (Year)/Title (Year).mkv]
          We parse these to find each destination folder path, needed by Step 5 to sort extras.
#>

Start-Transcript -Path (Join-Path $LogDir "step4_rename.log") -Force

Try{
    switch ($MediaType) {
        "Movies" {
            if ($MultiFeature -eq $false) {
                $Params = @{
                    InputFiles   = $MainVideoFile
                    MediaDB      = 'TheMovieDB'
                    FolderDepth  = 1
                    Format       = "{n} ({y})/{n} ({y})"
                    OutDirectory = $OutputDir
                    FBPath       = $FileBotPath
                    FBLog        = $FileBotLog
                    AlertPath    = $AlertSound
                }
                $DestinationFolder = Invoke-FileBot @Params
            }
            else {
                foreach ($feature in $convertedFeatures) {
                    $Params = @{
                        InputFiles   = $feature
                        MediaDB      = 'TheMovieDB'
                        FolderDepth  = 1
                        Format       = "{n} ({y})/{n} ({y})"
                        OutDirectory = $OutputDir
                        FBPath       = $FileBotPath
                        FBLog        = $FileBotLog
                        AlertPath    = $AlertSound
                    }
                    $DestinationFolders += Invoke-FileBot @Params
                }
            }
        }
        "TV" {
            <#
                Show name: use what the user typed at the prompt, or if they pressed Enter,
                strip season/disc suffixes from the volume label and replace underscores with
                spaces (e.g. "UNDER_THE_DOME_S1_D1" → "UNDER THE DOME").
                FileBot's search is case-insensitive, so no title-casing needed.
            #>
            $showQuery    = if ($ManualShowName) { 
                                $ManualShowName 
                            } else { 
                                ($Volume -replace '(_S\d+)?(_D\d+|_DISC_?\d+)$') -replace '_', ' ' 
                            }
            $seasonNumber = if ($Volume -match '_S(\d+)') {
                [int]$Matches[1]
            }
            else {
                [int](Read-Host "Could not detect season from disc label. Enter season number: ")
            }
            #Build $seasonFolder from the real show name on disk, not just the derived volume label.
            #If the exact path doesn't exist, search for any Season N folder and update $showQuery so FileBot also gets the correct name — avoids a failed first attempt.
            $seasonFolder = Join-Path (Join-Path $OutputDir $showQuery) "Season $seasonNumber"
            if (-not (Test-Path $seasonFolder)) {
                $found = Get-ChildItem $OutputDir -Directory |
                    ForEach-Object { Get-ChildItem $_.FullName -Directory -Filter "Season $seasonNumber" -ErrorAction SilentlyContinue } |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($found) {
                    $seasonFolder = $found.FullName
                    $showQuery    = $found.Parent.Name
                    Write-Host "Matched existing show folder: '$showQuery'" -ForegroundColor Cyan
                }
            }
            $startEpisode = (Get-ChildItem $seasonFolder -Filter '*.mkv' -File -ErrorAction SilentlyContinue).Count + 1
            Write-Host "Show: '$showQuery'  Season: $seasonNumber  Start episode: $startEpisode" -ForegroundColor Cyan
            $renamedEpisodes = @()
            for ($i = 0; $i -lt $convertedEpisodes.Count; $i++) {
                $newName = "s{0:D2}e{1:D2}.mkv" -f [int]$seasonNumber, [int]($startEpisode + $i)
                $newPath = Join-Path $convertedEpisodes[$i].Directory $newName
                Rename-Item $convertedEpisodes[$i].FullName -NewName $newName
                $renamedEpisodes += Get-Item $newPath
            }

            Write-Host "Using show name for FileBot: '$showQuery'" -ForegroundColor Cyan
            $Params = @{
                InputFiles   = $renamedEpisodes
                MediaDB      = 'TheTVDB'
                FolderDepth  = 2
                Format       = $TVFormat
                OutDirectory = $OutputDir
                FBPath       = $FileBotPath
                FBLog        = $FileBotLog
                AlertPath    = $AlertSound
                Query        = $showQuery
            }
            $DestinationFolder = Invoke-FileBot @Params
        }
    }
}
Catch {
    Write-Error "Error renaming file(s) at line $($_.InvocationInfo.ScriptLineNumber): $_"
}

Stop-Transcript

#endregion ── STEP 4 ─────────────────────────────────────────────────────────────

#region ── STEP 5: Move and transcode extras ─────────────────────────────────────
<#
    * Any MKV files remaining in the raw rip folder after FileBot has moved the main content are treated as extras.
    * Media Type Behavior:
        * Movies - remaining files are moved to an "extras" subfolder under the renamed movie folder and transcoded.
        * Multi-feature - the user is prompted to assign each extra to one of the renamed feature folders, then all extras are transcoded.
        * TV - remaining files are moved to an "extras" subfolder under the renamed show folder and transcoded.
#>

Start-Transcript -Path (Join-Path $LogDir "step5_extras.log") -Force

If (!$DestinationFolder -and !$DestinationFolders) {

    Write-Warning "No valid destination folder — skipping extras. Check $InputDirectory manually."

}
Else {
    $AllFiles = Get-ChildItem $InputDirectory -File -Filter *.mkv
    if ($MultiFeature) {
        if ($AllFiles) {
            Write-Host "Extras found — assign each to a feature:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $DestinationFolders.Count; $i++) {
                Write-Host "  $($i + 1). $(Split-Path $DestinationFolders[$i] -Leaf)"
            }
            Write-Host "  S. Skip"

            foreach ($file in $AllFiles) {
                Write-Host "  - $($file.Name)"
                $choice = Read-Host "Which movie does this belong to?"
                if ($choice -ieq 'S') { continue }
                $Extras = Join-Path $DestinationFolders[[int]$choice - 1] "extras"
                if ($Extras -notin $usedExtrasFolders) { $usedExtrasFolders += $Extras }
                if (!(Test-Path $Extras)) {
                    Write-Host "No extras folder found, creating..." -ForegroundColor Yellow
                    New-Item $Extras -ItemType Directory -Force | Out-Null
                }
                Move-Item $file.FullName -Destination $Extras
            }

            foreach ($folder in $usedExtrasFolders) {
                Write-Host "Transcoding extras in $(Split-Path $folder -Leaf)..." -ForegroundColor Cyan
                $ExtraFiles = Get-ChildItem $folder -File -Filter *.mkv | Where-Object { $_.Name -notlike '*-converted*' }
                foreach ($Extra in $ExtraFiles) {
                    Convert-VideoWithCropFix -MediaPath $Extra.FullName -ffmpeg $FfmpegPath -ffprobe $FfProbePath -handbrake $HandbrakeCLI
                }
                Write-Host "Extras transcoded successfully!" -ForegroundColor Green
            }
        }
        else {
            Write-Host "No extra files found." -ForegroundColor Green
        }
    }
    else{
        $Extras   = Join-Path $DestinationFolder "extras"

        #Creating extras folder (if not exist) and moving extras there
        Try{

            If (!(Test-Path $Extras)){

                Write-Host "No extras folder found, creating..." -ForegroundColor Yellow
                New-Item -Path $Extras -ItemType Directory -Force | out-null

            }
            foreach ($file in $AllFiles) {
                Write-Host "Moving extras file $($file.Name)..." -ForegroundColor Cyan
                Move-Item $file.FullName -Destination $Extras
            }
            Write-Host "All extras files moved successfully!" -ForegroundColor Green
            Write-Host "================"

        }
        Catch{

            Write-Error "Error moving extras at line $($_.InvocationInfo.ScriptLineNumber): $_"

        }

        Try{

            Write-Host "Transcoding extras..." -ForegroundColor Cyan
            $ExtraFiles = Get-ChildItem $Extras -File -Filter *.mkv | Where-Object {$_.Name -notlike '*-converted*'}
            foreach ($Extra in $ExtraFiles){
                Convert-VideoWithCropFix -MediaPath $Extra.FullName -ffmpeg $FfmpegPath -ffprobe $FfProbePath -handbrake $HandbrakeCLI
            }
            Write-Host "Extras transcoded successfully!" -ForegroundColor Green

        }
        Catch{

            Write-Error "Error transcoding extras at line $($_.InvocationInfo.ScriptLineNumber): $_"

        }
    }
}

Stop-Transcript

#endregion ── STEP 5 ─────────────────────────────────────────────────────────────

#region ── STEP 6: Cleanup and finish ────────────────────────────────────────────
# If the raw rip folder is now empty (all files moved to the renamed folder/extras) delete it to avoid leaving an empty DISC_TITLE directory under E:\Path\To\Media\<type>\.

Start-Transcript -Path (Join-Path $LogDir "step6_cleanup.log") -Force

$FolderContents = Get-ChildItem -Path $InputDirectory -Force -Recurse | Where-Object { $_.FullName -notmatch "\\extras\\" }
If (-not $FolderContents) {
    Remove-Item -Path $InputDirectory -Force -Recurse
    Write-Host "Folder $InputDirectory was empty and has been deleted." -ForegroundColor Green
}
else{
    Write-Host "Not all files were moved from $InputDirectory. Check before deleting." -ForegroundColor Yellow
}

Stop-Transcript

#Playing a sound to signal completion — useful when the script is running unattended.
Start-Process "wmplayer.exe" -ArgumentList "`"$CompletionSound`"" -WindowStyle Hidden

#Offering to loop for another disc. Re-launching via $PSCommandPath keeps a clean scope instead of trying to reset all the variables from this run.
do {
    $choice = Read-Host "Rip successful. Enter 1 to rip another DVD or 2 to exit."

    switch ($choice) {
        "1" {
            Write-Host "Starting new rip..." -ForegroundColor Yellow
            Start-Sleep -seconds 1
            cls
            & "$PSCommandPath"
            exit
        }
        "2" {
            Write-Host "Exiting script!" -ForegroundColor Green
            exit
        }
        default {
            Write-Host "Invalid choice. Please enter 1 to rip another DVD or 2 to exit." -ForegroundColor Red
        }
    }
} while ($true)

#endregion ── STEP 6 ─────────────────────────────────────────────────────────────