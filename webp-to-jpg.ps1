# count files in input folder
$VideoFiles=(Get-ChildItem * -recurse | Where-Object {$_.extension -in ".webp"});
$numFiles=($VideoFiles | Measure-Object).Count;
Write-Host "Converting $numFiles file(s)..."

# converting/compressing files
$VideoFiles | ForEach-Object {

	Write-Host "`n"
	Write-Host "Processing '$_'"

	# input and output file names
	$inputFile="$_"
	$outputFile=$_.BaseName + ".jpg"

	ffmpeg -v quiet -stats -y -hide_banner -i $inputFile -vframes 1 -update true $outputFile

	Write-Host "Finished converting '$_'"
}