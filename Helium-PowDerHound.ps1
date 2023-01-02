$scriptTitle = @'
##########################################################################################################################
#  / \__                       _                           ___               ___                                     _   #
#  (    r\___        /\  /\___| (_)_   _ _ __ ___         / _ \_____      __/   \___ _ __ /\  /\___  _   _ _ __   __| |  #
#  /         O      / /_/ / _ \ | | | | | '_ ` _ \ _____ / /_)/ _ \ \ /\ / / /\ / _ \ '__/ /_/ / _ \| | | | '_ \ / _` |  #
#  /   (_____/     / __  /  __/ | | |_| | | | | | |_____/ ___/ (_) \ V  V / /_//  __/ | / __  / (_) | |_| | | | | (_| |  #
#  /_____/   U     \/ /_/ \___|_|_|\__,_|_| |_| |_|     \/    \___/ \_/\_/___,' \___|_| \/ /_/ \___/ \__,_|_| |_|\__,_|  #
#                                                                                                                        #
##########################################################################################################################

'@                                                                                                                  
#     Helium-PowDerHound

#     This is (Helium) (Power)Shell script is ultimately made to
#     create (D)ashboards by fetching (Hound) the necessary data
#     via the API of Helium and returning JSON that can be easily
#     ingested into Elasticsearch.

#     License: MIT

#     Created by: Nicholas Penning



############################################ - Core Functions for Helium-PowDerHound - Start! ############################################
Write-Host $scriptTitle -ForegroundColor DarkMagenta

#Basic needed variables
$heliumURL = "https://api.helium.io/v1/"
$elasticsearchURL = $configurationSettings.elasticsearchURL
$elasticsearchAPIKey = $configurationSettings.elasticsearchAPIKey
$kibanaURL = $configurationSettings.kibanaURL
$indexName = "helium-enriched"
$baseIndexName = "helium"

# Check for existing .env file for setup
# Get Elasticsearch password from .env file
if (Test-Path .\docker\.env) {
    #Write-Host "Docker .env file found! Which likely means you have configured docker for use. Going to extract password to perform initilization."
    $env = Get-Content .\docker\.env
    $regExEnv = $env | Select-String -AllMatches -Pattern "ELASTIC_PASSWORD='(.*)'"
    $elasticsearchPassword = $regExEnv.Matches.Groups[1].Value
    if ($elasticsearchPassword) {
    #Write-Host "Password for user elastic has been found and will be used." -ForegroundColor Green
    $elasticsearchPasswordSecure = ConvertTo-SecureString -String "$elasticsearchPassword" -AsPlainText -Force
    $elasticCreds = New-Object System.Management.Automation.PSCredential -ArgumentList "elastic", $elasticsearchPasswordSecure
    }
} else {
    Write-Host "No .env file detected in \docker\.env"
}

# Configure Elasticsearch credentials for creating the Elasticsearch ingest pipelines and importing saved objects into Kibana.
# Force usage of elastic user by trying genereated creds first, then manual credential harvest
if ($elasticCreds) {
    #Write-Host "Generated credentials detected! Going to use those for the setup process." -ForegroundColor Blue
} else {
    Write-Host "No generated credentials were found! Going to need the password for the elastic user." -ForegroundColor Yellow
    # When no passwords were generated, then prompt for credentials
    $elasticCreds = Get-Credential elastic
}

# Set passwords via automated configuration or manual input
# Base64 Encoded elastic:secure_password for Kibana auth
$elasticCredsBase64 = [convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($($elasticCreds.UserName+":"+$($elasticCreds.Password | ConvertFrom-SecureString -AsPlainText)).ToString()))
$kibanaAuth = "Basic $elasticCredsBase64"

function Invoke-HeliumAPIRequest {
    param (
        $uri,
        $method,
        $cursor
    )
    
    $requestAttempts = 1
    $maxAttempts = 50
    $ErrorActionPreferenceToRestore = $ErrorActionPreference
    $ErrorActionPreference = "Stop"

    $result = ''
    do {
        try{
            if ($cursor) {
                $cursor = @{"cursor" = "$cursor"}
                $result = Invoke-RestMethod -Uri $heliumURL$uri -Method $method -body $cursor
            } else {
                $result = Invoke-RestMethod -Uri $heliumURL$uri -Method $method
            }
        
        }catch {
            Write-Debug $_.Exception
            Write-Debug "Could not fetch data, trying again. $uri"
            if($result){Write-Host "Something is wrong. Result = "$result -ForegroundColor Yellow}
            #Store current cursor in $cursor value to be re-used.
            if($cursor){
                if($result){Write-Host "Something is wrong. Result = "$result -ForegroundColor Yellow}
                $cursor = $($cursor.cursor)
            }
            $requestAttempts++
        }
        
        #Retrying scripts for calls that will do exponential backoff when the script fails to return data from an API call. 
        #This will better handle 429 error codes which denote too many requests. This function will backoff exponentially
        #after each unsuccessful call then reset to 0 after a successful API call.

        if (($requestAttempts -le $maxAttempts) -and ($null -eq $result)) {
            $retryDelaySeconds = [math]::Pow(2, $requestAttempts)
            $retryDelaySeconds = $retryDelaySeconds - 1  # Exponential Backoff Max == (2^n)-1
            Write-Host("API request failed. Waiting " + $retryDelaySeconds + " milliseconds before attempt " + $requestAttempts + " of " + $maxAttempts + ".")
            Start-Sleep -Milliseconds $retryDelaySeconds            
        } elseif(($requestAttempts -gt $maxAttempts) -and ($null -eq $result)) {
            $ErrorActionPreference = $ErrorActionPreferenceToRestore
            Write-Host "Tried to many times to get data, pausing to allow for investigating."
            Write-Error $_.Exception.Message
            Pause
        }else{
            Write-Debug "Data successfully retrieved!"
        }
    } until ($result)

    return $result
}

#Store the results into Elasticsearch
function Import-ToElasticsearch {
    param (
        $jsonBody,
        $enrichmentTrueOrFalse
    )
    $enrichmentPipeline = "Helium_Enrichment"
    if($elasticsearchAPIKey -and ($null -eq $enrichmentTrueOrFalse -or $enrichmentTrueOrFalse -eq "true")) {
        $elasticsearchAuth = @{"Authorization" = "ApiKey $elasticsearchAPIKey"}
        $ingest = Invoke-RestMethod -Uri "$elasticsearchURL/$indexName/_doc?pipeline=$enrichmentPipeline" -Method "POST" -ContentType "application/json" -Headers $elasticsearchAuth -Body $jsonBody -SkipCertificateCheck
    } elseif($null -eq $elasticsearchAPIKey -and $enrichmentTrueOrFalse -eq "true") {
        $ingest = Invoke-RestMethod -Uri "$elasticsearchURL/$indexName/_doc?pipeline=$enrichmentPipeline" -Method "POST" -ContentType "application/json" -Body $jsonBody -SkipCertificateCheck
    } elseif($elasticsearchAPIKey -and ($enrichmentTrueOrFalse -eq "false")) {
        $elasticsearchAuth = @{"Authorization" = "ApiKey $elasticsearchAPIKey"}
        $ingest = Invoke-RestMethod -Uri "$elasticsearchURL/$indexName/_doc" -Method "POST" -ContentType "application/json" -Headers $elasticsearchAuth -Body $jsonBody -SkipCertificateCheck
    } else {
        $ingest = Invoke-RestMethod -Uri "$elasticsearchURL/$indexName/_doc" -Method "POST" -ContentType "application/json" -Body $jsonBody -SkipCertificateCheck
    }
    
    if($ingest.result -eq "created"){
        $docsSuccess = $ingest._shards.successful
        $docsFailed = $ingest._shards.failed
        $ingestedToIndex = $ingest._index
        Write-Host "Documents successfully created in the $ingestedToIndex index : $docsSuccess"
        if($docsFailed -gt 0){
            Write-Host "Documents failed to be created in the $ingestedToIndex index : $docsFailed" -ForegroundColor Yellow
        }
    }
    return $ingest
}

#Bulk store the results into Elasticsearch
function Import-ToElasticsearch_Bulk {
    param (
        $jsonBody
    )
    $elasticsearchAuth = @{"Authorization" = "ApiKey $elasticsearchAPIKey"}
    $ingest = Invoke-RestMethod -Uri "$elasticsearchURL/_bulk" -Method "POST" -ContentType "application/json; charset=utf-8" -Headers $elasticsearchAuth -Body $jsonBody -SkipCertificateCheck
    if($ingest.result -eq "created"){
        $docsSuccess = $ingest._shards.successful
        $docsFailed = $ingest._shards.failed
        $ingestedToIndex = $ingest._index
        Write-Host "Documents successfully created in the $ingestedToIndex index : $docsSuccess"
        if($docsFailed -gt 0){
            Write-Host "Documents failed to be created in the $ingestedToIndex index : $docsFailed" -ForegroundColor Yellow
        }
    }
    return $ingest
}

#Retrieve and Build the JSON Object from the request
function Get-DataFromAPI {
    $data = Invoke-HeliumAPIRequest $uri $method $cursor
    $data | Add-Member -NotePropertyMembers @{source=$uri} -Force

    $jsonBody = $data | ConvertTo-Json -Depth 50
    $data = $null
    return $jsonBody
}

#Import custom index patterns for Kibana that provides special formatting and HNT to USD conversions
function Import-IndexPattern {
    Param (
        $filename
    )
    
    $importSavedObjectsURL = $kibanaURL+"/api/saved_objects/_import?overwrite=true"
    $kibanaHeader = @{"kbn-xsrf" = "true"; "Authorization" = "$kibanaAuth"}
    $savedObjectsFilePath =  Resolve-Path $filename

    $fileBytes = [System.IO.File]::ReadAllBytes($savedObjectsFilePath.path);
    $fileEnc = [System.Text.Encoding]::GetEncoding('UTF-8').GetString($fileBytes);
    $boundary = [System.Guid]::NewGuid().ToString(); 
    $LF = "`r`n";

    $bodyLines = ( 
        "--$boundary",
        "Content-Disposition: form-data; name=`"file`"; filename=`"index_pattern_for_dynamic_updates.ndjson`"",
        "Content-Type: application/octet-stream$LF",
        $fileEnc,
        "--$boundary--$LF" 
    ) -join $LF

    $result = Invoke-RestMethod -Method POST -Uri $importSavedObjectsURL -Headers $kibanaHeader -ContentType "multipart/form-data; boundary=`"$boundary`"" -Body $bodyLines -AllowUnencryptedAuthentication
    if($result.errors -or $null -eq $result){
        Write-Host "There was an error trying to import $filename"
        $result.errors
    }
}

############################################ - Core Functions for Helium-PowDerHound - End! - ############################################

# All Endpoints copied from the left hand side of this page: https://docs.helium.com/api/blockchain/introduction/
$endpoints = @"
Stats
Blocks
Accounts
Validators
Hotspots
Cities
Locations
Transactions
Pending Transactions
Oracle Prices
Chain Variables
OUIs
Rewards
DC Burns
State Channels
Assert Locations
"@

# Magical RegEx to find all the right things from the API Docs
$regExForAPIs = '<h2 class=".*?" id=".*?">(.*?)<a.*?<\/h2>[\s\S]*?<span class="token plain">((.*?) https:\/\/api.helium.io\/v1\/(.*?))<\/span>'
$regExForParameter = '\/:([a-z3_]*)|:([a-z3_]*)|:([a-z3_]*):([a-z3_]*)\/.*:([a-z3_]*)'
$regExForSearchTerm = '\?(.*)=(.*)'

# Basic text formating object that is really unecessary but the OCD was kicking
$TextInfo = (Get-Culture).TextInfo

# Fetch the the latest API calls!
function Get-LatestDocumentation {
    param (
        $endpointCategory
    )
    $apiDocumenationURL = "https://docs.helium.com/api/blockchain/$endpointCategory/"
    try{
        $apiFetch = Invoke-WebRequest $apiDocumenationURL -UseBasicParsing
    } catch{
        #Temp Bug Fix for inconsitent URL (- vs _)
        $endpointCategory = $endpointCategory.Replace("_","-")
        $apiDocumenationURL = "https://docs.helium.com/api/blockchain/$endpointCategory/"
        $apiFetch = Invoke-WebRequest $apiDocumenationURL -UseBasicParsing
    }
    BuildMyScript $endpointCategory $apiFetch
}

# Build out all of the code based on the data that was fetched from the API docs, it just need the endpoint category and 
function BuildMyScript {
    param (
        $endpointCategory,
        $apiFetch
    )
    $allParameters = ""
    $apiFound = $apiFetch.Content | Select-String -Pattern $regExForAPIs -AllMatches

    $apiFound.Matches | ForEach-Object {
        $title = $_.Groups[1].Value
        $comment = $_.Groups[2].Value.Replace('&lt;','<').Replace('&gt;','>')
        $requestType = $TextInfo.ToTitleCase($_.Groups[3].Value.ToLower())
        $uriEndpoint = $_.Groups[4].Value.Replace('&lt;','<').Replace('&gt;','>')

        $functionName = $title.Replace(" ","_")
        $parentEndpoint = $TextInfo.ToTitleCase($endpointCategory.ToLower()).Replace(" ","_")
        if(($uriEndpoint -match $regExForParameter) -or ($uriEndpoint -match $regExForSearchTerm)) { 
            $paramFound = $uriEndpoint | Select-String -Pattern $regExForParameter -AllMatches
            if($paramFound){
                $requiredParameters += if($paramFound.Matches.Groups[1].Value -ne ""){"`n`t`t"+'$'+$paramFound.Matches.Groups[1].Value}else{$null}
                $requiredParameters += if($paramFound.Matches.Groups[2].Value -ne ""){"`n`t`t"+'$'+$paramFound.Matches.Groups[2].Value}else{$null}
                $requiredParameters += if($paramFound.Matches.Groups[3].Value -ne ""){"`n`t`t"+'$'+$paramFound.Matches.Groups[3].Value}else{$null}    
                $uriEndpoint = $($uriEndpoint.Replace(':','$'))
            }else{$null}
            
            $searchTermFound = $uriEndpoint | Select-String -Pattern $regExForSearchTerm -AllMatches
            $searchParam = if($searchTermFound){$($searchTermFound.Matches.groups[2].value).Replace('<','').Replace('>','')}else{$null}
            if($searchParam) {
                $requiredParameters += "`n`t"+'$'+$searchParam
                $uriEndpoint = $($uriEndpoint.Replace('<','$')).Replace('>','')
            }else{$null}
            
            #Add optional path query and cursor parameters for large data sets.
            $requiredParameters += ",`n`t`t"+'$query'+",`n`t`t"+'$cursor'

            $allParameters = "param (`t$requiredParameters`n`t)"
            $requiredParameters = ''
        }else{
            #Add optional cursor parameter for large data sets.
            $requiredParameters = "`n`t`t"+'$cursor'
            $allParameters = "param (`t$requiredParameters`n`t)"
            $requiredParameters = ''
            #Write-Host "No required parameters found for this API request so just adding cursor pagination parameter." -ForegroundColor Blue
        }

$allFunctions += @"

#$title
#$comment
function Invoke-Helium-$parentEndpoint-$functionName {
    $allParameters
    `$method = "$requestType"
    `$uri = "$uriEndpoint`$query"
    `$cursor = "`$cursor"
    return Get-DataFromAPI
}
    
"@
    
    }
    return $allFunctions
}

# This will generate a file called bones.ps1 that will contain all the bones (API calls) that were fetched
# and their respective required parameters if necessary
function FetchBones {
    #Check to see if the bones (latest code) has been fetched or not then too them out if they are found.
    if((Test-Path bones.ps1) -eq "true") {
        Write-Host "Old bones.ps1 was found, removing this for a a new set of bones!" -ForegroundColor Yellow
        Remove-Item bones.ps1 
    }

    $endpoints.Split("`n") | ForEach-Object {
        $currentEndpoint = $_.ToLower().Replace(" ","_")
        Write-Host "Getting latest API calls from $heliumURL and creating PowerShell Functions! Currently retrieving: $currentEndpoint"  
        Write-Host "Fetching new bone.ps1!" -ForegroundColor Blue
        try{
            Get-LatestDocumentation $currentEndpoint | Out-File bones.ps1 -Append
            Write-Debug "Bone fetched. Good boy!"
            $goodBoy = @'
                     ,-~~~~-,
               .-~~~;        ;~~~-.
              /    /          \    \
             {   .'{  O    O  }'.   }
              `~`  { .-~~~~-. }  `~`
                   ;/        \;
                  /'._  ()  _.'\
                 /    `~~~~`    \
                ;                ;
                {                }
                {     }    {     }
                {     }    {     }
                /     \    /     \
               { { {   }~~{   } } }
           jgs  `~~~~~`    `~~~~~`
                   (`"======="`)
                   (_.=======._)
'@
            Write-Debug $goodBoy
        } catch {
            Write-Host "The poor hound couldn't retrieve the bones. :("
            $_
        }
    }
}

#FetchBones

# Once bones.ps1 has been created you can simply use the import-module bones.ps1 to load all of the API calls to use. Have fun!
#Import-Module ./bones.ps1

# Now you may begin fetching some data and storing into Elasticsearch (or other JSON document store!)

# Use case #1: Ingest all hostspots across the globe! This is useful for metadata such as the hotspot name and geolocation info.
function Get-AllHotspots {

    $initialRequest = Invoke-Helium-Hotspots-List_Hotspots | ConvertFrom-Json

    $x = 0
    $totalHotspots = 0
    $startOfRollingIngest = "true"
    $cursor = $initialRequest.cursor
    do {
        if($null -ne $cursor -and $startOfRollingIngest -eq "false") {
            $currentData = ''
            do {
                try{
                    $currentData = Invoke-Helium-Hotspots-List_Hotspots -cursor $cursor | ConvertFrom-Json
                } catch {
                    Write-Host "Error: $_"
                    Start-Sleep -Seconds 3
                    Pause
                }
            } until ($currentData)
        } elseif ($null -ne $cursor -and $startOfRollingIngest -eq "true") {
        #Initial run, continue on to ingest
        $currentData = $initialRequest
        $startOfRollingIngest = "false"
        }else {
            $x = 1
        }
        $hash = @()
        #Write-Host "Time to ingest, please wait for this to finish, there are $($currentData.data.count) docs that need to be ingested."
        $currentData | ForEach-Object { $_.data } | ForEach-Object {
            $_ | Add-Member -NotePropertyMembers @{source=$initialRequest[0].source} -Force
            $id = $_.address
            $currentDoc = $($_ | ConvertTo-Json -Depth 4 -Compress )
            $hash += "{`"index`":{`"_index`":`"$baseIndexName`",`"_id`":`"$id`"}}`r`n$currentDoc`r`n"
            # Add all hotspots to text file
            $id >> allTheHotspots.txt
        }
        try {
            $result = Import-ToElasticsearch_Bulk $hash
        }
        catch {
            Write-Host "There was an error trying to ingest into Elasticsearch - Data may be missing or corrupt." -ForegroundColor Yellow
            $_
        }
        # Print out any errors!
        if ($result.items.index.errors -eq "False") {
            Write-Host $result.items.index.error
        }
        $cursor = $currentData.cursor
        $totalHotspots += $currentData.data.count
        Write-Host "Current hotspots found and index into Elasticsearch (This number will get to be over 919,000): $totalHotspots" -ForegroundColor Blue
    } until ($x -eq 1)    
}
#Get-AllHostspots

# Use case #2: Get rewards for a hotspot!
function Get-HotspotRewards {
    [CmdletBinding()]
    [Alias()]
    Param
    (
        # Addressess
        [Parameter(Mandatory=$true,
                    ValueFromPipelineByPropertyName=$true,
                    Position=0)]
        $addresses,
        # Min Time
        [Parameter(Mandatory=$true,
                    ValueFromPipelineByPropertyName=$true,
                    Position=1)]
        $min_time,
        # Max Time
        [Parameter(Mandatory=$true,
                    ValueFromPipelineByPropertyName=$true,
                    Position=2)]
        $max_time
    )
  

    Write-Host "Fetching hotspot data from one Helium endpoint at a time (Total Hotspots: $($addresses.count), please be patient." -ForegroundColor DarkMagenta
    $rewardsInfo = @()
    $hotspotCount = 0
    $addresses | Foreach-object -Parallel {
        Write-Host "Sending hotspot address $_ to get ingested."
        #Write-Host "On hotspot number $hotspotCount | $percentComplete% complete"
        $projectDirectory = $(Get-Location).path
        pwsh -WorkingDirectory $projectDirectory -Command {
            #Place current address from arument in variable
            $currentAddress = $Args[0]

            # Extract custom settings from configuration.json
            $configurationSettings = Get-Content ./configuration.json | ConvertFrom-Json
            $heliumURL = "https://api.helium.io/v1/"
            $elasticsearchURL = $configurationSettings.elasticsearchURL
            $elasticsearchAPIKey = $configurationSettings.elasticsearchAPIKey
            $kibanaURL = $configurationSettings.kibanaURL
            $indexName = "helium-enriched"
            $baseIndexName = "helium"

            # Check for existing .env file for setup
            # Get Elasticsearch password from .env file
            if (Test-Path .\docker\.env) {
                Write-Host "Docker .env file found! Which likely means you have configured docker for use. Going to extract password to perform initilization."
                $env = Get-Content .\docker\.env
                $regExEnv = $env | Select-String -AllMatches -Pattern "ELASTIC_PASSWORD='(.*)'"
                $elasticsearchPassword = $regExEnv.Matches.Groups[1].Value
                if ($elasticsearchPassword) {
                    #Write-Host "Password for user elastic has been found and will be used." -ForegroundColor Green
                    $elasticsearchPasswordSecure = ConvertTo-SecureString -String "$elasticsearchPassword" -AsPlainText -Force
                    $elasticCreds = New-Object System.Management.Automation.PSCredential -ArgumentList "elastic", $elasticsearchPasswordSecure
                }
            } else {
                Write-Host "No .env file detected in \docker\.env"
            }

            # Configure Elasticsearch credentials for creating the Elasticsearch ingest pipelines and importing saved objects into Kibana.
            # Force usage of elastic user by trying genereated creds first, then manual credential harvest
            if ($elasticCreds) {
                Write-Host "Generated credentials detected! Going to use those for the setup process." -ForegroundColor Blue
            } else {
                Write-Host "No generated credentials were found! Going to need the password for the elastic user." -ForegroundColor Yellow
                # When no passwords were generated, then prompt for credentials
                $elasticCreds = Get-Credential elastic
            }
            
            # Set passwords via automated configuration or manual input
            # Base64 Encoded elastic:secure_password for Kibana auth
            $elasticCredsBase64 = [convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($($elasticCreds.UserName+":"+$($elasticCreds.Password | ConvertFrom-SecureString -AsPlainText)).ToString()))
            $kibanaAuth = "Basic $elasticCredsBase64"
            Import-Module ./bones.ps1
            function Fetch-Hotspot_Rewards {
                Param
                (
                    $address,
                    $min_time,
                    $max_time
                )
        
                #Build query for max and min time
                if($min_time -or $max_time){
                    $query = "?max_time=$max_time&min_time=$min_time"
                }else {
                    Write-Host "Error finding min_time: $min_time or max_time: $max_time - Request will likely never complete." -ForegroundColor Red
                    pause
                    $query = $null
                }
                #Write-Host "Running initial query for Hotspot address...Please wait - Params - Address: $address"
                $initialRequest = Invoke-Helium-Hotspots-Rewards_for_a_Hotspot -address $address -query $query | ConvertFrom-Json
                $count = 0
                $x = 0
                $allData = @()
                $allData += $initialRequest
                $cursor = $initialRequest.cursor
                do {
                    if($null -ne $cursor) {
                        $currentData = ''
                        $currentData = Invoke-Helium-Hotspots-Rewards_for_a_Hotspot -address $address -cursor $cursor | ConvertFrom-Json
                        $allData += $currentData
                        #"Running query number: $count"
                        $count += $currentData.data.count
                        $cursor = $currentData.cursor
                    } else {
                        $x = 1
                    }
                } until ($x -eq 1)
        
                return $allData
            }

            #Perform request to Helium's API
            function Invoke-HeliumAPIRequest {
                param (
                    $uri,
                    $method,
                    $cursor
                )
                
                $requestAttempts = 1
                $maxAttempts = 50
                $ErrorActionPreferenceToRestore = $ErrorActionPreference
                $ErrorActionPreference = "Stop"

                $result = ''
                do {
                    try{
                        if ($cursor) {
                            $cursor = @{"cursor" = "$cursor"}
                            $result = Invoke-RestMethod -Uri $heliumURL$uri -Method $method -body $cursor
                        } else {
                            $result = Invoke-RestMethod -Uri $heliumURL$uri -Method $method
                        }
                    
                    }catch {
                        #Write-Host $_.Exception
                        #Write-Host "Could not fetch data, trying again. $uri"
                        if($result){Write-Host "Something is wrong. Result = "$result -ForegroundColor Yellow}
                        #Store current cursor in $cursor value to be re-used.
                        if($cursor){
                            if($result){Write-Host "Something is wrong. Result = "$result -ForegroundColor Yellow}
                            $cursor = $($cursor.cursor)
                        }
                        $requestAttempts++
                    }
                    
                    #Retrying scripts for calls that will do exponential backoff when the script fails to return data from an API call. 
                    #This will better handle 429 error codes which denote too many requests. This function will backoff exponentially
                    #after each unsuccessful call then reset to 0 after a successful API call.

                    if (($requestAttempts -le $maxAttempts) -and ($null -eq $result)) {
                        $retryDelaySeconds = [math]::Pow(2, $requestAttempts)
                        $retryDelaySeconds = $retryDelaySeconds - 1  # Exponential Backoff Max == (2^n)-1
                        Write-Host("API request failed. Waiting " + $retryDelaySeconds + " milliseconds before attempt " + $requestAttempts + " of " + $maxAttempts + ".")
                        Start-Sleep -Milliseconds $retryDelaySeconds            
                    } elseif(($requestAttempts -gt $maxAttempts) -and ($null -eq $result)) {
                        $ErrorActionPreference = $ErrorActionPreferenceToRestore
                        Write-Host "Tried to many times to get data, pausing to allow for investigating."
                        Write-Error $_.Exception.Message
                        Pause
                    }else{
                        #Write-Host "Data successfully retrieved!"
                    }
                } until ($result)

                return $result
            }

            #Retrieve and Build the JSON Object from the request
            function Get-DataFromAPI {
                $data = Invoke-HeliumAPIRequest $uri $method $cursor
                $data | Add-Member -NotePropertyMembers @{source=$uri} -Force

                $jsonBody = $data | ConvertTo-Json -Depth 50
                $data = $null
                return $jsonBody
            }

            #Bulk store the results into Elasticsearch with Pipeline
            function Import-ToElasticsearch_Bulk_Pipeline {
                param (
                    $jsonBody
                )
                $enrichmentPipeline = "Helium_Enrichment"
                $elasticsearchAuth = @{"Authorization" = "ApiKey $elasticsearchAPIKey"}
                $ingest = Invoke-RestMethod -Uri "$elasticsearchURL/_bulk?pipeline=$enrichmentPipeline" -Method "POST" -ContentType "application/json; charset=utf-8" -Headers $elasticsearchAuth -Body $jsonBody -SkipCertificateCheck
                if($ingest.result -eq "created"){
                    $docsSuccess = $ingest._shards.successful
                    $docsFailed = $ingest._shards.failed
                    $ingestedToIndex = $ingest._index
                    Write-Host "Documents successfully created in the $ingestedToIndex index : $docsSuccess"
                    if($docsFailed -gt 0){
                        Write-Host "Documents failed to be created in the $ingestedToIndex index : $docsFailed" -ForegroundColor Yellow
                    }
                } elseif($ingest.result) {
                    Write-Host "Some documents were not created. Pausing to investigate what happened."
                    $ingest
                    $ingest.result
                    pause
                }
                return $ingest
            }

            $min_time = Get-Content ./checkpoint.json | ConvertFrom-Json | Get-Date -Format "o"
            $max_time = Get-Date -Format "o"

            $hotspotCount++;
            #Write-Host "Ingesting hotspot $hotspotCount of $($addresses.count)"
            $rewardsInfo = Fetch-Hotspot_Rewards -address $currentAddress -min_time $min_time -max_time $max_time
            #Start-Sleep -Seconds 5
            #Sample Format: -min_time "2020-11-05T14:07:15.5001260-05:00" -max_time "2021-11-05T14:07:15.5001260-05:00"

            # Iterate through each object and add the source and @timestamp for indexing!
            if($rewardsInfo.data){
                $hash = @()
                #Write-Host "Time to ingest, please wait for this to finish, there are $($rewardsInfo.data.count) docs that need to be ingested for address: $_."
                if($rewardsInfo.data){
                    $rewardsInfo.data | ForEach-Object {
                        $_ | Add-Member -NotePropertyMembers @{source=$rewardsInfo.source[0]} -Force 
                        $currentDoc = $($_ | ConvertTo-Json -Depth 4 -Compress )
                        #$rewardsId = $_.hash
                        $hash += "{`"index`":{`"_index`":`"$indexName`"}}`r`n$currentDoc`r`n"
                    }
                }
                $result = Import-ToElasticsearch_Bulk_Pipeline $hash
            } else {
                Write-Host "No data found, not attempting to ingest for address $_"
            }
        } -args $_
    } -ThrottleLimit 10
}

#Use Case #3 - Get Current HNT Price from Oracle and Update Kibana
function Get-Current_HNT_Price_Oracle {
    $price = Invoke-Helium-Oracle-Prices-Current_Oracle_Price
    $result = Import-ToElasticsearch $price

    return $price
}

function Update-Index_Pattern_with_Current_HNT_Price_Oracle {
    $indexPatternObject = Get-Content "./setup/index_pattern_for_dynamic_updates.ndjson" | ConvertFrom-Json
    $indexPatternObjectAttribuesRuntimeFieldMap = $indexPatternObject.attributes.runtimeFieldMap | convertfrom-json

    #Update Last Month in Runtime Field
    #Set new month inside of script source
    $hnt = Get-Current_HNT_Price_Oracle | ConvertFrom-Json
    $hntUSDNormalized = $hnt.data.price / 100000000
    $indexPatternObjectAttribuesRuntimeFieldMap.hnt_price.script.source = @"
if (doc.containsKey('amount')) {
    double hnt_to_usd = $hntUSDNormalized;
        if (doc['amount'].size()!=0) {
        double hnt_amount = (long)doc['amount'].value;
        double hnt_price_usd = (hnt_amount/100000000) * hnt_to_usd;
        emit(hnt_price_usd);
        }
}
"@

    $indexPatternObjectAttribuesRuntimeFieldMap.hnt_to_usd.script.source = @"
double hnt_to_usd = $hntUSDNormalized;

emit(hnt_to_usd);
"@

    #Field to update
    $fieldToUpdate = $indexPatternObject | Where-Object {$_.attributes.runtimeFieldMap -ne $null}

    #Store new runtime field map back into source object
    foreach ($record in $fieldToUpdate) {
        $record.attributes.runTimeFieldMap = $indexPatternObjectAttribuesRuntimeFieldMap | ConvertTo-Json -Compress
    }

    #Write modified index pattern to file
    $indexPatternObject[0] | ConvertTo-Json -Compress -depth 5 | Out-File "./setup/index_pattern_for_dynamic_updates.ndjson"
    $indexPatternObject[1] | ConvertTo-Json -Compress -depth 5 | Out-File "./setup/index_pattern_for_dynamic_updates.ndjson" -Append

    $indexPatternFile = "./setup/index_pattern_for_dynamic_updates.ndjson"

    Import-IndexPattern $indexPatternFile
}

#Use Case #4 - Get End of Month HNT Price from Binance and Update Kibana
function Get-End_of_Month_HNT_Price_Binance {
    #Get 12PM on last day or last month
    $lastDayofLastMonth = $((Get-Date -Day 1 -Hour 0 -Minute 0 -Second 0 -Millisecond 0).AddDays(-1)).AddHours(12)
    $lastDayofLastMonthHNTUniversal = $lastDayofLastMonth.ToUniversalTime() | Get-Date -uformat %s000
    $prices = @()
    $binanceURI = "https://www.binance.us/api/v1/klines?symbol=HNTUSD&interval=1h&startTime=$lastDayofLastMonthHNTUniversal&endTime=$lastDayofLastMonthHNTUniversal"
    $prices = $(Invoke-RestMethod -Uri $binanceURI) | Out-String
    $pricesArray = $prices.split("`n")

    $pricesObjectJSON = [PSCustomObject]@{
        Open_Time = $pricesArray[0]
        Open = $pricesArray[1]
        High = $pricesArray[2]
        Low = $pricesArray[3]
        Close = $pricesArray[4]
        Volume = $pricesArray[5]
        Close_time = $pricesArray[6]
        Quote_asset_volume = $pricesArray[7]
        Number_of_trades = $pricesArray[8]
        Taker_buy_base_asset_volume = $pricesArray[9]
        Taker_buy_quote_asset_volume = $pricesArray[10]
        Ignore = $pricesArray[11]
        '@timestamp' = $pricesArray[0]
        Custom_Date_Close_Central_Time = $lastDayofLastMonthHNTUniversal
        source = $binanceURI

    } | ConvertTo-Json

    $result = Import-ToElasticsearch $pricesObjectJSON "false"
    $result.error

    return $pricesArray[4]
}

function Update-Index_Pattern_with_End_of_Month_Price_Binance{

    $endOfMonthPrice = Get-End_of_Month_HNT_Price_Binance
    $indexPatternObject = Get-Content "./setup/index_pattern_for_dynamic_updates.ndjson" | ConvertFrom-Json
    $indexPatternObjectAttribuesRuntimeFieldMap = $indexPatternObject.attributes.runtimeFieldMap | convertfrom-json

    #Update Last Month in Runtime Field
    #Set new month inside of script source
    $month = $((Get-Date -Day 1 -Hour 0 -Minute 0 -Second 0).AddDays(-1)).AddHours(12).Month
    $year = $((Get-Date -Day 1 -Hour 0 -Minute 0 -Second 0).AddDays(-1)).AddHours(12).Year
    $indexPatternObjectAttribuesRuntimeFieldMap.last_month.script.source = @"
String last_month = '$month-$year';

emit(last_month);
"@

    $indexPatternObjectAttribuesRuntimeFieldMap.last_month_hnt_price.script.source = @"
if (doc.containsKey('amount')) {
    double hnt_to_usd = $endOfMonthPrice;
        if (doc['amount'].size()!=0) {
        double hnt_amount = (long)doc['amount'].value;
        double hnt_price_usd = (hnt_amount/100000000) * hnt_to_usd;
        emit(hnt_price_usd);
        }
}
"@

    $indexPatternObjectAttribuesRuntimeFieldMap.last_month_hnt_to_usd.script.source = @"
double hnt_to_usd = $endOfMonthPrice;

emit(hnt_to_usd);
"@

    #Field to update
    $fieldToUpdate = $indexPatternObject | Where-Object {$_.attributes.runtimeFieldMap -ne $null}

    #Store new runtime field map back into source object
    foreach ($record in $fieldToUpdate) {
        $record.attributes.runTimeFieldMap = $indexPatternObjectAttribuesRuntimeFieldMap | ConvertTo-Json -Compress
    }

    #Write modified index pattern to file
    $indexPatternObject[0] | ConvertTo-Json -Compress -depth 5 | Out-File "./setup/index_pattern_for_dynamic_updates.ndjson"
    $indexPatternObject[1] | ConvertTo-Json -Compress -depth 5 | Out-File "./setup/index_pattern_for_dynamic_updates.ndjson" -Append

    $indexPatternFile = "./setup/index_pattern_for_dynamic_updates.ndjson"

    Import-IndexPattern $indexPatternFile
}

#Use Case #5 Get all addresses from a wallet/account
function Get-Hotspot_Addresses_from_Account {
    param (
        $walletAddress
    )
    Invoke-Helium-Accounts-Hotspots_for_Account -address $walletAddress
}

function Export-Hotspots_from_Wallets {
    param (
        $allWallets
    )

    $allWalletResults = @()
    $result = ""
    $allWallets.split("`n") | ForEach-Object {
        $result = Get-Hotspot_Addresses_from_Account $_ | ConvertFrom-Json
        $allWalletResults += $result
        Write-Host "$_ has $($result.data.count)"
    }
    Write-Host "Total addressed found: $($allWalletResults.data.count)"
    Write-Host "Exporting all hotspots to file: hotspots.txt"

    #Export all hotspot results to 1 file called ./hotspots.txt
    if($false -eq $(Test-Path ./hotspots.txt)){
        Write-Host "No file found, generating hotspots.txt" -ForegroundColor Blue
        $allWalletResults.data | Foreach-Object {
            $_.address | Out-File -Append "hotspots.txt"
        }
    }else{
        Write-Host "File already exists. Going to remove hotspots.txt and create it with the hotspots found from the wallet(s)."
        try{
            Remove-Item ./hotspots.txt
            $allWalletResults.data | Foreach-Object {
                $_.address | Out-File -Append "hotspots.txt"
            }
        }catch{
            Write-Host "Could not remove file." -ForegroundColor Yellow
            $_
        }
    }
    
    return Write-Host "./hostpots.txt file created!"
}
