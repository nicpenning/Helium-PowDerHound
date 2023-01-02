# Extract custom settings from configuration.json
$configurationSettings = Get-Content ./configuration.json | ConvertFrom-Json
$addressFileLocation = $configurationSettings.hotspotFileLocation

# Update to the latest enrich pipeline using custom Helium Addresses from a file.
# Check to see if the Initialize-Elastic_Stack.ps1 was run before ingesting reward data.
if ($configurationSettings.initializedElasticStack -eq "false") {
    Import-Module ./Initialize-Elastic_Stack.ps1 -Force
} else {
    Write-Host "Excellent, the Elastic Stack has already been prepped and is ready to ingest data." -ForegroundColor Green
}

# Import the Helium-PowDerHound.ps1 script to leverage use cases.
Import-Module ./Helium-PowDerHound.ps1 -Force

# Import latest code for use based on API documentation from Helium
Import-Module ./bones.ps1 -Force

# Get all addresses from a text file
$addresses = Get-Content $addressFileLocation

# Initialize for first time rewards ingest (This is different then setting up the Elastic stack.)
# The initialization is getting the all of the data from when the hotspot came online.
# Starting point to ingest transactions from.
if ($(Test-Path ./checkpoint.json)) {
    # If the checkpoint exists, start from there.
    $start_time = Get-Content ./checkpoint.json | ConvertFrom-Json | Get-Date -Format "o"
}else {
    # Otherwise, start back in 2015.
    $start_time = Get-Date 2015-01-01T00:00:00Z -format "o"
}
# Store start time in file as a checkpoint
$start_time | ConvertTo-JSON | Out-File checkpoint.json -Force
# Get current time in the correct time format
$end_time = Get-Date -Format "o"
$result = Measure-Command {
    Get-HotspotRewards -addresses $addresses -min_time $start_time -max_time $end_time
    # Get Current HNT Price and Update Kibana
    Update-Index_Pattern_with_Current_HNT_Price_Oracle

    # Always set last months index price
    Update-Index_Pattern_with_End_of_Month_Price_Binance
}
Write-Host "Took $($result.TotalMinutes) minutes to execute!" -ForegroundColor Blue

# Ingest every hour from here and out
$x = 1
do {
    # Store start time in file as a checkpoint
    $start_time | ConvertTo-JSON | Out-File checkpoint.json -Force
    # Sleep for 1 hour
    Write-Host "Sleeping for 1 hour."
    Start-Sleep -Seconds 3600
    # Get 1 hour ago in the correct time format - 2021-11-10T17:56:08.1755050-06:00
    # But then also add 2 hours as a buffer just in case their are rewards that can
    # not be retrieved by the API yet. This is just a theory.

    $start_time = Get-Date $(Get-Date $end_time).Addhours(-2) -Format "o"
    # Get current time in the correct time format
    $end_time = Get-Date -Format "o"
    $result = Measure-Command {
        Get-HotspotRewards -addresses $addresses -min_time $start_time -max_time $end_time
    }
    Write-Host "Took $($result.TotalMinutes) minutes to execute!" -ForegroundColor Blue
    
    # Get Current HNT Price and Update Kibana
    Update-Index_Pattern_with_Current_HNT_Price_Oracle

    # Always set last months index price
    Update-Index_Pattern_with_End_of_Month_Price_Binance

} while ($x -eq 1)
