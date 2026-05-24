[CmdletBinding(SupportsShouldProcess=$true)]
param (
    [Parameter(Mandatory=$false, HelpMessage="Path to search for videos. Defaults to the current directory.")]
    [ValidateScript({Test-Path -Path $_ -PathType Container})]
    [string]$Path = ".",

    [Parameter(Mandatory=$false, HelpMessage="Name of the directory to save output files.")]
    [string]$OutputDir = "output",

    [Parameter(Mandatory=$false, HelpMessage="The target number of frames to extract. If smart analysis finds fewer, it falls back to evenly-spaced extraction.")]
    [int]$NumFrames = 8,

    [Parameter(Mandatory=$false, HelpMessage="Video file extensions to process.")]
    [string[]]$Extensions = @(".mp4"),

    [Parameter(Mandatory=$false, HelpMessage="Set to false to disable scene change detection. (Default: true)")]
    [bool]$ExtractScenes = $true,

    [Parameter(Mandatory=$false, HelpMessage="Sensitivity for scene detection (0.0 to 1.0). Lower is more sensitive, finding more scenes.")]
    [ValidateRange(0.0, 1.0)]
    [double]$SceneThreshold = 0.4,

    [Parameter(Mandatory=$false, HelpMessage="Set to false to disable extracting static/frozen shots. (Default: true)")]
    [bool]$ExtractFreezeFrames = $true,

    [Parameter(Mandatory=$false, HelpMessage="Minimum duration in seconds for a shot to be considered frozen.")]
    [double]$FreezeDuration = 2.0,

    [Parameter(Mandatory=$false, HelpMessage="Set to false to disable extracting all keyframes. (Default: true)")]
    [bool]$ExtractKeyframes = $true,

    [Parameter(Mandatory=$false, HelpMessage="Set to false to disable extracting the first and last non-black frames. (Default: true)")]
    [bool]$ExtractNonBlackExtremes = $true,

    [Parameter(Mandatory=$false, HelpMessage="Minimum duration in seconds for a black section to be detected.")]
    [double]$BlackDetectDuration = 1.0,

    [Parameter(Mandatory=$false, HelpMessage="Threshold for what is considered a 'black' pixel (0.0 to 1.0).")]
    [ValidateRange(0.0, 1.0)]
    [double]$BlackPixelThreshold = 0.98
)

# Check if ffmpeg and ffprobe are available in the system's PATH
foreach ($command in @("ffmpeg", "ffprobe")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' was not found in your PATH. Please install ffmpeg and ensure it's accessible."
    }
}

# Helper function to run ffmpeg/ffprobe, check for errors, and return output
function Invoke-MediaTool {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Command,
        [Parameter(Mandatory=$true)]
        [string[]]$Arguments,
        [Parameter(Mandatory=$false)]
        [string]$WarningMessage
    )
    $output = & $Command @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errorMessage = if ($WarningMessage) { $WarningMessage } else { "$Command command failed." }
        Write-Warning $errorMessage
    }
    return $output
}

$VideoFiles = Get-ChildItem -Path $Path -File | Where-Object { $Extensions -contains $_.Extension }
$numFiles = $VideoFiles.Count

if ($numFiles -eq 0) {
    Write-Warning "No video files found with the specified extensions in '$Path'."
    return
}

if (-not (Test-Path -Path $OutputDir)) {
    Write-Host "Creating output directory: $OutputDir"
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

Write-Host "Found $numFiles file(s) to process..."

$i = 0
$activity = "Extracting Frames from Videos"

foreach ($videoFile in $VideoFiles) {
    $i++
    $percentComplete = [int](($i / $numFiles) * 100)
    $status = "Processing file $i of ${numFiles}: $($videoFile.Name)"
    Write-Progress -Activity $activity -Status $status -PercentComplete $percentComplete

    Write-Host "`nProcessing '$($videoFile.Name)'..."

    # Define output file patterns using Join-Path for robustness
    $baseName = $videoFile.BaseName

    # --- Phase 1: Analysis ---
    Write-Host "Analyzing video for interesting frames..."
    $timestampsToExtract = [System.Collections.Generic.HashSet[double]]::new()

    # Get video duration first, it's useful for multiple checks
    $durationProbeArgs = @(
        "-v", "error"
        "-show_entries", "format=duration"
        "-of", "default=noprint_wrappers=1:nokey=1"
        "-i", $videoFile.FullName
    )
    $durationStr = Invoke-MediaTool -Command "ffprobe" -Arguments $durationProbeArgs
    if (-not [double]::TryParse($durationStr, [ref]$null)) {
        Write-Warning "Could not determine video duration for '$($videoFile.Name)'. Skipping some smart extractions."
        $duration = $null
    } else {
        $duration = [double]$durationStr
    }

    # 1. Scene Change Detection
    if ($ExtractScenes) {
        # Use ffprobe with showinfo filter to get timestamps
        $sceneDetectArgs = @(
            "-v", "error", "-f", "lavfi"
            "-i", "movie='$($videoFile.FullName.Replace('\', '/'))',select='gt(scene,$SceneThreshold)',showinfo"
            "-show_entries", "frame=pts_time"
            "-of", "csv=p=0"
        )
        $sceneOutput = Invoke-MediaTool -Command "ffprobe" -Arguments $sceneDetectArgs
        $sceneOutput -split '\r?\n' | ForEach-Object {
            if ([double]::TryParse($_, [ref]$null)) { [void]$timestampsToExtract.Add([double]$_) }
        }
    }

    # 2. Freeze Frame Detection
    if ($ExtractFreezeFrames) {
        $freezeDetectArgs = @(
            "-i", $videoFile.FullName
            "-vf", "freezedetect=n=-50dB:d=$FreezeDuration" # n=noise tolerance, d=duration
            "-f", "null", "-"
        )
        $freezeOutput = Invoke-MediaTool -Command "ffmpeg" -Arguments $freezeDetectArgs
        $freezeOutput | Select-String -Pattern 'lavfi.freezedetect.freeze_start: (\d+\.?\d*)' | ForEach-Object {
            $ts = [double]$_.Matches.Groups[1].Value
            [void]$timestampsToExtract.Add($ts)
        }
    }

    # 3. Keyframe Detection
    if ($ExtractKeyframes) {
        $keyframeArgs = @(
            "-v", "error", "-select_streams", "v:0"
            "-show_entries", "frame=key_frame,pts_time"
            "-of", "csv=p=0"
            "-i", $videoFile.FullName
        )
        $keyframeOutput = Invoke-MediaTool -Command "ffprobe" -Arguments $keyframeArgs
        $keyframeOutput -split '\r?\n' | ForEach-Object {
            $line = $_
            if ($line.StartsWith("1,")) {
                $tsStr = ($line -split ',')[1]
                if ([double]::TryParse($tsStr, [ref]$null)) {
                    [void]$timestampsToExtract.Add([double]$tsStr)
                }
            }
        }
    }

    # 4. First and Last Non-Black Frame Detection
    if ($ExtractNonBlackExtremes -and $duration) {
        $blackDetectArgs = @(
            "-i", $videoFile.FullName
            "-vf", "blackdetect=d=$BlackDetectDuration:pic_th=$BlackPixelThreshold"
            "-f", "null", "-"
        )
        $blackDetectOutput = Invoke-MediaTool -Command "ffmpeg" -Arguments $blackDetectArgs
        
        $blackSegments = $blackDetectOutput | Select-String -Pattern 'black_start:(\d+\.?\d*).*black_end:(\d+\.?\d*)' | ForEach-Object {
            [PSCustomObject]@{
                Start = [double]$_.Matches.Groups[1].Value
                End   = [double]$_.Matches.Groups[2].Value
            }
        }

        # Add first frame (timestamp 0) and last frame by default. These will be refined if black is detected.
        [void]$timestampsToExtract.Add(0.0)
        if ($duration) { [void]$timestampsToExtract.Add($duration) }

        if ($blackSegments) {
            # If video starts with black, replace timestamp 0 with the end of the black segment
            $firstSegment = $blackSegments[0]
            if ($firstSegment.Start -lt 0.1) { # Using a small tolerance for the start
                [void]$timestampsToExtract.Remove(0.0)
                [void]$timestampsToExtract.Add($firstSegment.End)
            }

            # If video ends with black, replace the duration timestamp with the start of the black segment
            if ($duration) {
                $lastSegment = $blackSegments[-1]
                if ($duration - $lastSegment.End -lt 0.1) { # Using a small tolerance for the end
                    [void]$timestampsToExtract.Remove($duration)
                    [void]$timestampsToExtract.Add($lastSegment.Start)
                }
            }
        }
    }

    # --- Phase 2: Extraction ---
    Write-Host "Analysis complete. Found $($timestampsToExtract.Count) unique candidate frames."

    # 2a. Smart Extraction: Extract all unique frames found during analysis.
    if ($timestampsToExtract.Count -gt 0) {
        Write-Host "Performing smart extraction of $($timestampsToExtract.Count) frames."

        # Sort timestamps for sequential file naming
        $sortedTimestamps = $timestampsToExtract | Sort-Object

        # Build a complex filter string for ffmpeg. This selects frames based on their presentation timestamp (t).
        $selectFilter = ($sortedTimestamps | ForEach-Object { "eq(t,$_)" }) -join '+'

        $outputFileSmart = Join-Path -Path $OutputDir -ChildPath ($baseName + "-smart-%03d.jpg")

        $extractArgs = @(
            "-v", "quiet", "-y", "-hide_banner",
            "-i", $videoFile.FullName,
            "-vf", "select='$selectFilter'",
            "-vsync", "vfr", # Variable Frame Rate to handle non-sequential timestamps
            $outputFileSmart
        )
        Invoke-MediaTool -Command "ffmpeg" -Arguments $extractArgs -WarningMessage "ffmpeg failed during smart extraction for '$($videoFile.Name)'."
    }

    # 2b. Supplemental Extraction: If not enough frames were found, add evenly-spaced ones to meet the target.
    $framesStillNeeded = $NumFrames - $timestampsToExtract.Count
    if ($framesStillNeeded -gt 0) {
        if ($timestampsToExtract.Count -gt 0) {
            Write-Host "Found only $($timestampsToExtract.Count) smart frames. Adding $framesStillNeeded evenly-spaced frames to supplement."
        }
        else {
            Write-Host "No smart frames found. Falling back to extracting $NumFrames evenly-spaced frames."
        }

        # Get total frame count for the supplemental/fallback method
        $frameCountProbeArgs = @(
            "-v", "error",
            "-select_streams", "v:0",
            "-count_frames",
            "-show_entries", "stream=nb_read_frames",
            "-of", "default=noprint_wrappers=1:nokey=1",
            "-i", $videoFile.FullName
        )
        $totalFramesStr = Invoke-MediaTool -Command "ffprobe" -Arguments $frameCountProbeArgs
        if (-not [int]::TryParse($totalFramesStr, [ref]$null)) {
            Write-Warning "Could not determine frame count for '$($videoFile.Name)'. Skipping fallback extraction."
            continue
        }
        $totalFrames = [int]$totalFramesStr

        # Check if we can extract the *needed* number of additional frames.
        if ($totalFrames -lt $framesStillNeeded) {
            Write-Warning "Video has only $totalFrames total frames, which is not enough to extract the remaining $framesStillNeeded frames."
        } else {
            # The rate should be calculated based on the number of frames we still need to extract.
            $rate = [math]::Floor($totalFrames / $framesStillNeeded)
            if ($rate -eq 0) { $rate = 1 } # Prevent rate of 0

            $outputFileEven = Join-Path -Path $OutputDir -ChildPath ($baseName + "-even-%03d.jpg")
            $fallbackArgs = @(
                "-v", "quiet", "-y", "-hide_banner",
                "-i", $videoFile.FullName,
                "-vf", "select='not(mod(n,$rate))'",
                # We only want to extract the frames we still need.
                "-vframes", $framesStillNeeded,
                "-vsync", "vfr",
                $outputFileEven
            )
            Invoke-MediaTool -Command "ffmpeg" -Arguments $fallbackArgs -WarningMessage "ffmpeg failed during supplemental/fallback extraction for '$($videoFile.Name)'."
        }
    }

    # --- Phase 3: Move Processed File ---
    $destinationDir = Resolve-Path $OutputDir
    if ($pscmdlet.ShouldProcess($videoFile.FullName, "Move to '$destinationDir'")) {
        try {
            Write-Host "Moving processed file '$($videoFile.Name)' to '$OutputDir'..."
            Move-Item -Path $videoFile.FullName -Destination $destinationDir -ErrorAction Stop
        }
        catch {
            Write-Warning "Failed to move '$($videoFile.Name)' to '$OutputDir'. Error: $($_.Exception.Message)"
        }
    }
}

Write-Progress -Activity $activity -Completed
Write-Host "`nProcessing complete."
