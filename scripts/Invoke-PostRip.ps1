<#
.SYNOPSIS
    Post-rip pipeline: transcode, rename, extras, and cleanup for manually ripped MKV files.

.DESCRIPTION
    Invoke-PostRip.ps1 runs the transcode → rename → extras → cleanup pipeline on an
    existing folder of MKV files, skipping the MakeMKV rip step entirely. Use this when
    you have already ripped a disc manually — for example, TV discs that split seasons
    across titles, branching titles that need manual selection, or any disc with unusual
    structure that doesn't play well with the automated rip.

    Provide the path to your pre-ripped folder when prompted. All MKV files found there
    are treated as the main content (episodes for TV, features for multi-feature, largest
    file for movies). The pipeline then:

        1. TRANSCODE — Each MKV is re-encoded with HandBrakeCLI (x265, CRF 22).
                       ffprobe detects source resolution: DVD sources are output at
                       854x480 (anamorphic correction); HD/Blu-ray keeps native resolution.
                       ffmpeg cropdetect samples five timestamps and takes the minimum
                       crop on each side to avoid over-cropping.
        2. RENAME    — FileBot renames and moves the transcoded file(s) using database
                       metadata. Movies use TheMovieDB; TV uses TheTVDB. Episode files
                       are pre-renamed to s##e##.mkv before FileBot so folder order is
                       preserved. $startEpisode is derived from the existing MKV count in
                       the target Season N folder so runs append correctly.
        3. EXTRAS    — Any MKV files remaining after FileBot has moved the main content
                       are treated as extras, moved to an "extras" subfolder, and transcoded.
        4. CLEANUP   — The source folder is deleted if empty.

.NOTES
    ── Configuration ────────────────────────────────────────────────────────────────
    Reads config.json from the AutoRipper directory (one level up from this script).
    See that file for all configurable paths and settings. MakeMKV is not required
    and is not validated on startup.

    ── Dependencies ────────────────────────────────────────────────────────────────
    ffmpeg/ffprobe https://ffmpeg.org/
    HandBrakeCLI   https://handbrake.fr/
    FileBot        https://www.filebot.net/

    ── Assumptions ──────────────────────────────────────────────────────────────────
    - Movies: the largest MKV in the folder is the main feature; everything else is
      treated as an extra.
    - Multi-feature / TV: all MKV files in the folder are treated as features/episodes,
      sorted by filename (MakeMKV names them t00.mkv, t01.mkv… in disc order).
    - You are responsible for ensuring only the desired titles are in the folder before
      running this script.

.EXAMPLE
    .\Invoke-PostRip.ps1
#>

#region ── Helper functions ──────────────────────────────────────────────────────

function Sanitize-Name {
    <#
    .SYNOPSIS
        Strips characters that are illegal in Windows file/folder names.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$InputDirectory
    )
    return ($InputDirectory -replace '[:\\/*?"<>|]', '').Trim()
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
            non-black region at each point. The minimum crop value on each side
            across all samples is used so that one atypical frame cannot over-crop
            the whole encode.

        Phase 3 — Transcode (HandBrakeCLI)
            Encodes to x265 at CRF 22, copies the first audio track as-is,
            and includes the first subtitle track with chapter markers. Output file is
            named "<original_basename>-converted.mkv" in the same folder.
            After a successful encode the original file is deleted.
    .PARAMETER MediaPath
        Full path to the input MKV file.
    .PARAMETER ffmpeg
        Path to ffmpeg.exe.
    .PARAMETER ffprobe
        Path to ffprobe.exe.
    .PARAMETER handbrake
        Path to HandBrakeCLI.exe.
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

    $file       = Get-Item $MediaPath
    $outputPath = Join-Path $file.Directory "$($file.BaseName)-converted.mkv"

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
        If FileBot finds no match, an alert sound is played and the user is prompted
        for the correct title. Returns the destination folder path parsed from the
        FileBot log.
    .PARAMETER InputFiles
        One or more FileInfo objects. For movies, the original rip file (may be deleted);
        the function appends -converted.mkv to find the actual file. For TV, pass the
        pre-renamed transcoded FileInfo objects directly.
    .PARAMETER Format
        FileBot format string.
    .PARAMETER OutDirectory
        Root output directory — FileBot creates the subfolder structure beneath this.
    .PARAMETER FBPath
        Full path to filebot.exe.
    .PARAMETER FBLog
        Path to the FileBot log file.
    .PARAMETER MediaDB
        'TheMovieDB' for movies, 'TheTVDB' for TV.
    .PARAMETER FolderDepth
        Path levels to walk up from the renamed file to reach the root folder.
        1 for movies, 2 for TV (file is inside Season N).
    .PARAMETER AlertPath
        Optional audio file played when FileBot fails to match.
    .PARAMETER Query
        Optional search query passed to FileBot as --q.
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

    $transcodedPaths = @(
        $InputFiles | ForEach-Object {
            $converted = if (Test-Path $_.FullName) { $_.FullName }
                         else { Join-Path $_.Directory "$($_.BaseName)-converted.mkv" }
            if (Test-Path $converted) { $converted }
            else { Write-Warning "Transcoded file not found for '$($_.Name)' — skipping." }
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
        "--action", "rename",
        "--conflict", "skip",
        "--log", "all",
        "--log-file", $FBLog,
        "-non-strict"
    )
    if ($Query) { $FBArgs += @("--q", $Query) }
    & "$FBPath" @FBArgs | Out-Host

    $moveLines = Get-Content $FBLog | Where-Object { $_ -match '\[MOVE\].* to \[.*\]' }

    if (-not $moveLines) {
        If ($AlertPath) { Start-Process "wmplayer.exe" -ArgumentList "`"$AlertPath`"" -WindowStyle Hidden }

        if ($InputFiles.Count -eq 1) {
            Write-Warning "FileBot could not match '$($InputFiles[0].BaseName)'. Enter the correct title or type 'skip'."
            $FileBotQuery = (Read-Host "Title").Trim()
            if ($FileBotQuery -ieq 'skip') {
                Write-Warning "Skipping rename. Files will remain in $($InputFiles[0].Directory)."
                return
            }
            $sanitizedQuery  = Sanitize-Name $FileBotQuery
            $renamedPath     = Join-Path $InputFiles[0].Directory "$sanitizedQuery.mkv"
            Rename-Item -Path $transcodedPaths[0] -NewName "$sanitizedQuery.mkv"
            $transcodedPaths = @($renamedPath)
        } else {
            Write-Warning "FileBot could not match. Enter the show name or type 'skip'."
            $FileBotQuery = (Read-Host "Title").Trim()
            if ($FileBotQuery -ieq 'skip') {
                Write-Warning "Skipping rename. Files will remain in $($InputFiles[0].Directory)."
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

    $lastMoveLine = $moveLines | Select-Object -Last 1
    if ($lastMoveLine -match 'to \[(.*?)\]') {
        $RenamedFolder = $matches[1]
        for ($i = 0; $i -lt $FolderDepth; $i++) { $RenamedFolder = Split-Path $RenamedFolder -Parent }
        Write-Host "Successfully renamed! Destination: $RenamedFolder" -ForegroundColor Green
        return $RenamedFolder
    } else {
        Write-Warning "No destination path found — extras will not be sorted."
    }
}

#endregion ── Helper functions ───────────────────────────────────────────────────

#region ── Variable Configuration ──────────────────────────────────────────────────────
#Runtime state — not user-configurable
$MediaType      = $null
$OutputDir      = $null
$ManualShowName = $null
$SeasonNumber   = $null
$MultiFeature   = $false

#Load user configuration from AutoRipper\config.json
$configPath = Join-Path $PSScriptRoot "..\AutoRipper\config.json"
if (-not (Test-Path $configPath)) {
    Write-Host "ERROR: config.json not found at $configPath" -ForegroundColor Red
    Write-Host "Ensure config.json exists in the AutoRipper directory." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit
}
$config = Get-Content $configPath -Raw | ConvertFrom-Json

$MediaDir     = $config.MediaDir     # Root media folder (e.g. "E:\Media")
$TVFormat     = $config.TVFormat     # FileBot format string for TV episode renaming
$FileBotPath  = $config.FileBotPath  # Path to filebot.exe
$FfmpegPath   = $config.FfmpegPath   # Path to ffmpeg.exe
$FfProbePath  = $config.FfProbePath  # Path to ffprobe.exe
$HandbrakeCLI = $config.HandbrakeCLI # Path to HandBrakeCLI.exe
$LogDir       = $config.LogDir       # Base folder for per-step log files

#Sound file paths — shared with AutoRipper
$CompletionSound = Join-Path $PSScriptRoot "..\AutoRipper\sound_files\mariomushroom.mp3"
$AlertSound      = Join-Path $PSScriptRoot "..\AutoRipper\sound_files\metalgear.mp3"

#endregion ── Variable Configuration ──────────────────────────────────────────────────────

if (-not (Test-Path $LogDir)) { New-Item $LogDir -ItemType Directory -Force | Out-Null }
$FileBotLog = Join-Path $LogDir "filebot.log"

#region ── Startup validation ────────────────────────────────────────────────────
#MakeMKV is not required — this script processes already-ripped files.

$requiredTools = [ordered]@{
    'ffmpeg'      = $FfmpegPath
    'ffprobe'     = $FfProbePath
    'HandBrakeCLI'= $HandbrakeCLI
    'FileBot'     = $FileBotPath
}

$missing = $requiredTools.GetEnumerator() | Where-Object { !(Test-Path $_.Value) }
if ($missing) {
    foreach ($tool in $missing) { Write-Error "$($tool.Key) not found at: $($tool.Value)" }
    Write-Error "Update the paths in config.json and try again."
    exit 1
}

if (!(Test-Path $MediaDir)) {
    Write-Error "Media root '$MediaDir' does not exist. Update MediaDir in config.json."
    exit 1
}

Write-Host "All tools verified." -ForegroundColor Green

#endregion ── Startup validation ─────────────────────────────────────────────────

#region ── STEP 1: Prompt for media type ─────────────────────────────────────────
#For TV, show name and season number are always prompted here since there is no disc label to derive them from.

do {
    Write-Host "What type of media are you processing?"
    Write-Host "1. Movies"
    Write-Host "2. TV Shows"
    Write-Host "3. Multi-Feature Movies"
    $choice = Read-Host "Enter 1, 2, or 3"

    switch ($choice) {
        "1" {
            $MediaType    = "Movies"
            $OutputDir    = "$MediaDir\Movies"
            $MultiFeature = $false
            $valid        = $true
            Write-Host "You selected Movies."
            cls
        }
        "2" {
            $MediaType    = "TV"
            $OutputDir    = "$MediaDir\TV"
            $MultiFeature = $false
            $valid        = $true
            Write-Host "You selected TV Show."
            $ManualShowName = (Read-Host "TV show name").Trim()
            $SeasonNumber   = [int](Read-Host "Season number")
            cls
        }
        "3" {
            $MediaType    = "Movies"
            $OutputDir    = "$MediaDir\Movies"
            $MultiFeature = $true
            $valid        = $true
            Write-Host "You selected Multi-Feature Movie."
            cls
        }
        default {
            Write-Host "Invalid choice. Please enter 1, 2, or 3." -ForegroundColor Red
            $valid = $false
        }
    }
} while (-not $valid)

Write-Host "Media type set to: $MediaType" -ForegroundColor Cyan

#endregion ── STEP 1 ─────────────────────────────────────────────────────────────

#region ── STEP 2: Select input folder ───────────────────────────────────────────
<#
    * Prompt for the folder containing manually ripped MKV files.
    * All MKV files found are treated as the main content — you are responsible for
      ensuring only the desired titles are present before running.
    * $Volume is derived from the folder name for log messages and cleanup.
#>

do {
    $InputDirectory = (Read-Host "Path to folder containing ripped MKV files").Trim()
    if (-not (Test-Path $InputDirectory)) {
        Write-Host "Path not found. Please try again." -ForegroundColor Red
    }
} while (-not (Test-Path $InputDirectory))

$mkvCount = (Get-ChildItem $InputDirectory -Filter '*.mkv' -File -ErrorAction SilentlyContinue).Count
if ($mkvCount -eq 0) {
    Write-Error "No MKV files found in '$InputDirectory'. Exiting."
    exit 1
}
Write-Host "Found $mkvCount MKV file(s) in '$InputDirectory'." -ForegroundColor Green

$Volume = Split-Path $InputDirectory -Leaf
Write-Host "Processing folder: $Volume" -ForegroundColor Cyan

#endregion ── STEP 2 ─────────────────────────────────────────────────────────────

#region ── STEP 3: Transcode main feature ────────────────────────────────────────
<#
    * Transcoding the main content through Convert-VideoWithCropFix (cropdetect → HandBrake x265 CRF22).
    * Media Type Behavior:
        * Movies - transcode the largest file (assumed to be the main feature).
        * Multi-feature - transcode all files in disc order (sorted by filename).
        * TV - transcode all files in disc order (sorted by filename).
#>

Start-Transcript -Path (Join-Path $LogDir "step3_transcode.log") -Force

$DestinationFolder  = $null
$DestinationFolders = @()
$usedExtrasFolders  = @()

switch ($MediaType) {
    "Movies" {
        if ($MultiFeature -eq $false) {
            $MainVideoFile = Get-ChildItem $InputDirectory -Filter '*.mkv' -File |
                Sort-Object Length -Descending | Select-Object -First 1

            if (-not $MainVideoFile) {
                Write-Error "No MKV files found in $InputDirectory."
                Stop-Transcript
                exit 1
            }

            Try {
                Write-Host "Beginning transcoding for $($MainVideoFile.FullName)..." -ForegroundColor Cyan
                Convert-VideoWithCropFix -MediaPath $MainVideoFile.FullName `
                    -ffmpeg $FfmpegPath -ffprobe $FfProbePath -handbrake $HandbrakeCLI
                Write-Host "Transcoding successful!" -ForegroundColor Green
            }
            Catch {
                Write-Error "Error transcoding $($MainVideoFile.FullName) at line $($_.InvocationInfo.ScriptLineNumber): $_"
            }
        }
        else {
            $featureFiles      = Get-ChildItem $InputDirectory -Filter '*.mkv' -File | Sort-Object Name
            $convertedFeatures = @()

            foreach ($feature in $featureFiles) {
                Write-Host "Transcoding feature: $($feature.BaseName)..." -ForegroundColor Cyan
                Convert-VideoWithCropFix -MediaPath $feature.FullName `
                    -ffmpeg $FfmpegPath -ffprobe $FfProbePath -handbrake $HandbrakeCLI
                $convertedFeatures += Get-Item (Join-Path $feature.Directory "$($feature.BaseName)-converted.mkv") `
                    -ErrorAction SilentlyContinue
            }
        }
    }
    "TV" {
        $episodeFiles      = Get-ChildItem $InputDirectory -Filter '*.mkv' -File | Sort-Object Name
        $convertedEpisodes = @()

        foreach ($episode in $episodeFiles) {
            Write-Host "Transcoding episode: $($episode.BaseName)..." -ForegroundColor Cyan
            Convert-VideoWithCropFix -MediaPath $episode.FullName `
                -ffmpeg $FfmpegPath -ffprobe $FfProbePath -handbrake $HandbrakeCLI
            $convertedEpisodes += Get-Item (Join-Path $episode.Directory "$($episode.BaseName)-converted.mkv") `
                -ErrorAction SilentlyContinue
        }
    }
}

Stop-Transcript

#endregion ── STEP 3 ─────────────────────────────────────────────────────────────

#region ── STEP 4: Rename and move with FileBot ──────────────────────────────────
<#
    * FileBot renames and moves transcoded files using database metadata.
    * Media Type Behavior:
        * Movies - FileBot matches against TheMovieDB; renames to "Title (Year)/Title (Year).mkv".
        * Multi-feature - FileBot is called once per feature.
        * TV - FileBot matches against TheTVDB using the show name and season entered in Step 1.
          Episode files are pre-renamed to s##e##.mkv before FileBot so order is preserved.
          $startEpisode is derived from the existing MKV count in the Season N folder so
          multi-run rips of the same season append correctly.
#>

Start-Transcript -Path (Join-Path $LogDir "step4_rename.log") -Force

Try {
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
            #Show name always comes from the prompt in Step 1 — no disc label to derive it from.
            $showQuery = $ManualShowName

            #Build $seasonFolder from the real show name on disk.
            #If the exact path doesn't exist, search for a matching Season N folder so FileBot gets the correct folder-name spelling.
            $seasonFolder = Join-Path (Join-Path $OutputDir $showQuery) "Season $SeasonNumber"
            if (-not (Test-Path $seasonFolder)) {
                $found = Get-ChildItem $OutputDir -Directory |
                    ForEach-Object { Get-ChildItem $_.FullName -Directory -Filter "Season $SeasonNumber" -ErrorAction SilentlyContinue } |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                #Bug fix: only override $showQuery when the found folder is the same show.
                #Without this check, ripping Show B after Show A at the same season would find
                #Show A's folder and silently swap the FileBot query to Show A's name.
                if ($found) {
                    $derivedClean = ($showQuery         -replace '[\s_]').ToLower()
                    $foundClean   = ($found.Parent.Name -replace '[\s_]').ToLower()
                    if ($foundClean -like "*$derivedClean*" -or $derivedClean -like "*$foundClean*") {
                        $seasonFolder = $found.FullName
                        $showQuery    = $found.Parent.Name
                        Write-Host "Matched existing show folder: '$showQuery'" -ForegroundColor Cyan
                    }
                }
            }
            $startEpisode = (Get-ChildItem $seasonFolder -Filter '*.mkv' -File -ErrorAction SilentlyContinue).Count + 1
            Write-Host "Show: '$showQuery'  Season: $SeasonNumber  Start episode: $startEpisode" -ForegroundColor Cyan

            $renamedEpisodes = @()
            for ($i = 0; $i -lt $convertedEpisodes.Count; $i++) {
                $newName = "s{0:D2}e{1:D2}.mkv" -f [int]$SeasonNumber, [int]($startEpisode + $i)
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
    * Any MKV files remaining in the input folder after FileBot has moved the main content are treated as extras.
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
    else {
        $Extras = Join-Path $DestinationFolder "extras"

        Try {
            If (!(Test-Path $Extras)) {
                Write-Host "No extras folder found, creating..." -ForegroundColor Yellow
                New-Item -Path $Extras -ItemType Directory -Force | Out-Null
            }
            foreach ($file in $AllFiles) {
                Write-Host "Moving extras file $($file.Name)..." -ForegroundColor Cyan
                Move-Item $file.FullName -Destination $Extras
            }
            Write-Host "All extras files moved successfully!" -ForegroundColor Green
            Write-Host "================"
        }
        Catch {
            Write-Error "Error moving extras at line $($_.InvocationInfo.ScriptLineNumber): $_"
        }

        Try {
            Write-Host "Transcoding extras..." -ForegroundColor Cyan
            $ExtraFiles = Get-ChildItem $Extras -File -Filter *.mkv | Where-Object { $_.Name -notlike '*-converted*' }
            foreach ($Extra in $ExtraFiles) {
                Convert-VideoWithCropFix -MediaPath $Extra.FullName -ffmpeg $FfmpegPath -ffprobe $FfProbePath -handbrake $HandbrakeCLI
            }
            Write-Host "Extras transcoded successfully!" -ForegroundColor Green
        }
        Catch {
            Write-Error "Error transcoding extras at line $($_.InvocationInfo.ScriptLineNumber): $_"
        }
    }
}

Stop-Transcript

#endregion ── STEP 5 ─────────────────────────────────────────────────────────────

#region ── STEP 6: Cleanup and finish ────────────────────────────────────────────
# If the input folder is now empty (all files moved to the renamed folder/extras) delete it.

Start-Transcript -Path (Join-Path $LogDir "step6_cleanup.log") -Force

$FolderContents = Get-ChildItem -Path $InputDirectory -Force -Recurse | Where-Object { $_.FullName -notmatch "\\extras\\" }
If (-not $FolderContents) {
    Remove-Item -Path $InputDirectory -Force -Recurse
    Write-Host "Folder $InputDirectory was empty and has been deleted." -ForegroundColor Green
}
else {
    Write-Host "Not all files were moved from $InputDirectory. Check before deleting." -ForegroundColor Yellow
}

Stop-Transcript

#Playing a sound to signal completion.
Start-Process "wmplayer.exe" -ArgumentList "`"$CompletionSound`"" -WindowStyle Hidden

do {
    $choice = Read-Host "Process complete. Enter 1 to process another folder or 2 to exit."

    switch ($choice) {
        "1" {
            Write-Host "Starting new run..." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            cls
            & "$PSCommandPath"
            exit
        }
        "2" {
            Write-Host "Exiting script!" -ForegroundColor Green
            exit
        }
        default {
            Write-Host "Invalid choice. Please enter 1 or 2." -ForegroundColor Red
        }
    }
} while ($true)

#endregion ── STEP 6 ─────────────────────────────────────────────────────────────
