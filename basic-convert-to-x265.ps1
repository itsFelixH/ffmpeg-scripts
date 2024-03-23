
Write-Host "`n"
Write-Host "-----------------------"
Write-Host "--- CONVERT TO HEVC ---"
Write-Host "-----------------------"
Write-Host "`n"

# count files in input folder
$VideoFiles=(Get-ChildItem * -recurse | Where-Object {$_.extension -in ".mp4", ".mov", ".wmv", ".avi", ".flv", ".mkv"});
$numFiles=($VideoFiles | Measure-Object).Count;
Write-Host "Converting $numFiles file(s)..."

# converting/compressing files
$VideoFiles | ForEach-Object {

	Write-Host "`n"
	Write-Host "Processing '$_'"

	# input and output file names
	$outputFile=$_.BaseName + "_x265.mkv"

	ffmpeg -v quiet -stats -y -hide_banner -i $_ -c:v libx265 -x265-params log-level=error -pix_fmt yuv420p10le -profile:v main10 -map 0 -c:1 copy $outputFile
	# ffmpeg -v quiet -stats -y -hide_banner -i $inputFile -c:v libx265 -x265-params log-level=error -crf 23 -pix_fmt yuv420p10le -profile:v main10 $outputFile

	Write-Host "Finished converting '$_'"
}

Write-Host "`n"
Write-Host "All files converted!"
Read-Host "Press ENTER to exit..."