# Parameters
param (
	# batch size for converting
    [int]$batchSize = 3,
	# input & output folders
    [string]$inputFolder,
	[string]$outputFolder
)

function Format-FileSize {
    param([long]$size)
    if ($size -gt 1GB) {
        "{0:N2} GB" -f ($size / 1GB)
    } elseif ($size -gt 1MB) {
        "{0:N2} MB" -f ($size / 1MB)
    } elseif ($size -gt 1KB) {
        "{0:N2} KB" -f ($size / 1KB)
    } else {
        "$size bytes"
    }
}

Write-Host "`n"
Write-Host "-----------------------"
Write-Host "--- CONVERT TO HEVC ---"
Write-Host "-----------------------"
Write-Host "`n"

# switch to input folder
Set-Location $inputFolder

# count files in input folder
$VideoFiles=(Get-ChildItem * -recurse | Where-Object {$_.extension -in ".mp4", ".mov", ".wmv", ".avi", ".flv"});
$numFiles=($VideoFiles | Measure-Object).Count;
Write-Host "Converting $numFiles file(s)..."

# count number of converted files
$numConverted=0

# converting/compressing files
$VideoFiles | ForEach-Object {

	Write-Host "`n"
	Write-Host "Processing '$_'"

	# input and output file names
	$inputFile="$inputFolder\$_"
	$baseOutputFile=$outputFolder + "\" + $_.BaseName
	$outputFile=$baseOutputFile + "_x265.mkv"

	# file size of original video
	$fileSize = Format-FileSize -size $_.Length
	Write-Host "Original file size: $fileSize"

	# measure execution time
	$Measurement = Measure-Command -Expression {
		ffmpeg -v quiet -stats -y -hide_banner -i $inputFile -c:v libx265 -x265-params log-level=error -pix_fmt yuv420p10le -profile:v main10 $outputFile
		# ffmpeg -v quiet -stats -y -hide_banner -i $inputFile -c:v libx265 -x265-params log-level=error -crf 23 -pix_fmt yuv420p10le -profile:v main10 $outputFile
	} | Select-Object TotalSeconds
	Write-Host "Time: $($Measurement.TotalSeconds) Seconds"

	# file size of converted video
	$file = Get-Item -Path $outputFile
	$fileSize = Format-FileSize -size $file.Length
	Write-Host "File size: $fileSize"

	Write-Host "Finished converting '$_'"

	# update counters
	$numConverted+=1
	$numRemaining=$numFiles-$numConverted
	$pauseCheck=$numConverted%$batchSize

	# ask to continue
	if ($pauseCheck -eq 0 -And $numRemaining -ge 0) {
		Write-Host "`n"
		Write-Host "Converted $numConverted/$numFiles files"
		Read-Host "Press ENTER to continue..."
	}

}

Write-Host "`n"
Write-Host "All files converted!"
Read-Host "Press ENTER to exit..."