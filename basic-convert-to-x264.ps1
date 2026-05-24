
Write-Host "`n"
Write-Host "-----------------------"
Write-Host "--- CONVERT TO X264 ---"
Write-Host "-----------------------"
Write-Host "`n"

# count files in input folder
$VideoFiles = (Get-ChildItem * -recurse | Where-Object { $_.extension -in ".mkv", ".mp4", ".mov", ".wmv", ".avi", ".flv" });
$numFiles = ($VideoFiles | Measure-Object).Count;
Write-Host "Converting $numFiles file(s)..."

# converting/compressing files
$VideoFiles | ForEach-Object {

	Write-Host "`n"
	Write-Host "Processing '$_'"

	# output file name
	$outputFile = $_.BaseName + "_x264.mkv"

	ffmpeg -v quiet -stats -y -hide_banner -i $_ -map 0 -map_chapters -1 -c copy -c:v libx264 -crf 18 $outputFile

	Write-Host "Finished converting '$_'"
}

Write-Host "`n"
Write-Host "All files converted!"
Read-Host "Press ENTER to exit..."