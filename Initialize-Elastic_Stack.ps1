# Core functions for checking the current status

function Invoke-CheckForEnv {
  # Check for existing .env file for setup
  # Get Elasticsearch password from .env file
  if (Test-Path .\docker\.env) {
    Write-Host "Docker .env file found! Which likely means you have configured docker for use. Going to extract password to perform initilization."
    $env = Get-Content .\docker\.env
    $regExEnv = $env | Select-String -AllMatches -Pattern "ELASTIC_PASSWORD='(.*)'"
    $global:elasticsearchPassword = $regExEnv.Matches.Groups[1].Value
    if ($elasticsearchPassword) {
      Write-Host "Password for user elastic has been found and will be used." -ForegroundColor Green
      return "True"
    }
  } else {
    Write-Debug "No .env file detected in \docker\.env"
    return "False"
  }
}

function Invoke-CheckForDockerInUse {
  # Check to see if docker compose job is already running before starting it up again
  Write-Host "Checking to make sure Docker isn't already running."
  $jobs = Get-Job
  $dockerInUse = $($jobs.Command | ForEach-Object { $_ | select-string "docker compose up" })
  if ($dockerInUse) {
    Write-Host "Docker found to be running" -ForegroundColor Yellow
    return "True"
  } else {
    Write-Debug "Docker was not found to be running"
    return "False"
  }
}

function Invoke-CheckForElasticsearchStatus {
  # Check for Elastic stack connectivity to a healthy cluster
  Write-Host "Waiting for Elastic stack to be accessible." -ForegroundColor Blue

  $healthAPI = $elasticsearchURL+"/_cluster/health"
  # Keep checking for a healthy cluster that can be used for the initialization process!
  do {
    try {
      Write-Debug "Checking to see if the cluster is accessible. Please wait."
      $status = Invoke-RestMethod -Method Get -Uri $healthAPI -ContentType "application/json" -Credential $elasticCreds -AllowUnencryptedAuthentication -SkipCertificateCheck  
    } catch {
      Write-Debug "Waiting for healthy cluster for 5 seconds. Then checking again."
      Start-Sleep -Seconds 5
    }
  } until ("green" -eq $status.status)

  if ("green" -eq $status.status) {
    Write-Host "Elastic cluster is $($status.status), continuing through the setup process." -ForegroundColor Green
    Start-Sleep -Seconds 2
  }
}

function Invoke-StartDocker {
  Write-Host "Starting up the Elastic stack with docker, please be patient as this can take over 10 minutes to download and deploy the entire stack if this is the first time you executed this step.`nOtherwise this will take just a couple of minutes."
  Set-Location .\docker
  try {
    docker compose up &
  } catch {
    "docker compose up failed - trying docker-compose up"
    try {
      docker-compose up &
    } catch {
      Write-Host "docker compose up or docker-compose up did not work. Check that you have dockerand docker composed installed."
    }
  }
  Set-Location ..\
}

function Invoke-StopDocker {
  Write-Debug "Shutting down docker containers for the Elastic stack."
  Set-Location .\docker
  try { 
    docker compose down
  } catch {
    Write-Host "Failed to use docker compose down, so trying docker-compose down."
    docker-compose down
  }
  Set-Location ..\
}

# Check to see if various parts of the project have already been configured to reduce the need for user input.
# 1. Check to see if .env file exists with credentials.
if ($(Invoke-CheckForEnv) -eq "False") {
  # Choose to use docker or not. If no .env is found, then ask.
  $dockerChoice = Read-Host "Would you like to use docker with this project? `
1. Yes, please generate a secure .env file. (Recommended) `
2. No thanks, I know what I am doing or I already have a .env file ready to go.`
Please Choose (1 or 2)"

  if ($dockerChoice -eq "1") {
    # Generate a .env file with random passwords for Elasticsearch and Kibana. Also generate secure Kibana key for reporting funcationality.
    $env = Get-Content .\docker\.env_template
    
    # Replace $elasticsearchPassword
    $elasticsearchPassword = $(-Join (@('0'..'9';'A'..'Z';'a'..'z';'!';'@';'#') | Get-Random -Count 32))
    $env = $env.Replace('$elasticsearchPassword', $elasticsearchPassword) 
    
    # Replace $kibanaPassword
    $kibanaPassword = $(-Join (@('0'..'9';'A'..'Z';'a'..'z';'!';'@';'#') | Get-Random -Count 32))
    $env = $env.Replace('$kibanaPassword', $kibanaPassword)

    # Replace $kibanaEncryptionKey
    $kibanaEncryptionKey = $(-Join (@('0'..'9';'A'..'Z';'a'..'z';'!';'@';'#') | Get-Random -Count 32))
    $env = $env.Replace('$kibanaEncryptionKey', $kibanaEncryptionKey)

    $env | Out-File .\docker\.env

    Write-Host "New file has been created (.env) and is ready for use." -ForegroundColor Green
    Write-Host "The following credentials will be used for setup and access to your Elastic stack so keep it close." -ForegroundColor Blue
    Write-Host "Username : elastic`nPassword : $elasticsearchPassword"
    Pause
  } else {
    Write-Debug "Did not choose to use docker so ignoring docker setup."
  }
} else {
  Write-Debug "Docker .env file already exists with password skipping to next section."
}

# 2. Check to see if docker compose has been executed.
if (Invoke-CheckForDockerInUse -eq "False") {
  # Choose to start docker.
  $startStack = Read-Host "Would you like to start up the Elastic stack with docker? `
1. Yes, please run the docker commands to start the Elastic stack for me (Recommended) `
2. No thanks, I will get my cluster up and running without your help and then continue the process `
Please Choose (1 or 2)"

  if ($startStack -eq "1") {
    Invoke-StartDocker
  } elseif ($startStack -eq "2") {
    Write-Debug "Skipping to next part of the process."
  } else {
    Write-Debug "Not a valid option. Exiting."
    Exit
  }
} elseif (Invoke-CheckForDockerInUse -eq "True") {
  Write-Host "Docker found to be running. Would you like to stop and then start Docker?"
  $restartDocker = Read-Host "1. Yes, please restart Docker`n2. No, please leave it running.`nPlease Choose (1 or 2)"
  if ($restartDocker -eq 1) {
    Write-Host "Stopping current docker instances by bringing them down with docker compose down."
    Invoke-StopDocker
    Write-Host "Starting docker containers back upw tih docker compose up &"
    Invoke-StartDocker
  } else {
    Write-Debug "Continuing with current docker instance running."
  }
} else {
  Write-Host "Something is amiss, couldn't check to see if Docker was in use or not. Exiting." -ForegroundColor Yellow
  Exit
}


# Configure Elasticsearch credentials for creating the Elasticsearch ingest pipelines and importing saved objects into Kibana.
# Force usage of elastic user by trying genereated creds first, then manual credential harvest
if ($elasticsearchPassword) {
  Write-Host "Elastic credentials detected! Going to use those for the setup process." -ForegroundColor Blue
  $elasticsearchPasswordSecure = ConvertTo-SecureString -String "$elasticsearchPassword" -AsPlainText -Force
  $elasticCreds = New-Object System.Management.Automation.PSCredential -ArgumentList "elastic", $elasticsearchPasswordSecure
} else {
  Write-Host "No generated credentials were found! Going to need the password for the elastic user." -ForegroundColor Yellow
  # When no passwords were generated, then prompt for credentials
  $elasticCreds = Get-Credential elastic
}

# Set passwords via automated configuration or manual input
# Base64 Encoded elastic:secure_password for Kibana auth
$elasticCredsBase64 = [convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($($elasticCreds.UserName+":"+$($elasticCreds.Password | ConvertFrom-SecureString -AsPlainText)).ToString()))
$kibanaAuth = "Basic $elasticCredsBase64"

# Extract custom settings from configuration.json
$configurationSettings = Get-Content ./configuration.json | ConvertFrom-Json

$elasticsearchURL = $configurationSettings.elasticsearchURL
$elasticsearchAPIKey = $configurationSettings.elasticsearchAPIKey
$kibanaURL = $configurationSettings.kibanaURL
$tag = $configurationSettings.tag
$hotspotFileLocation = $configurationSettings.hotspotFileLocation
$walletFileLocation = $configurationSettings.walletFileLocation
$initializationComplete = $configurationSettings.initializedElasticStack


# 3. Check to see if Elasticsearch is available for use.
Invoke-CheckForElasticsearchStatus

# Create API Key if not found in the config.
if ("" -eq $elasticsearchAPIKey){
  Write-Host "No API key found, going to generate a key for the helium indices nows."
  #POST _security/api_key
  $apiKey = Get-Content ./setup/api_key_creation.json

  # API Key URL
  $apiKeyCreationIndexURL = $elasticsearchURL+"/_security/api_key"
  try {
    $apiKey = Invoke-RestMethod -Method POST -Uri $apiKeyCreationIndexURL -body $apiKey -ContentType "application/json" -Credential $elasticCreds -AllowUnencryptedAuthentication -SkipCertificateCheck
    
    # Store API key in Elastic
    $configurationSettings.elasticsearchAPIKey = $apiKey.encoded

    $configurationSettings | Convertto-JSON | Out-File ./configuration.json -Force
  } catch {
    Write-Host "Couldn't bootstrap helium index, likely because it already exists. Check kibana to see if the helium index exists."
    Write-Debug "$_"
  }
}

# Static and Constant core variables needed for initialization and usage of this product. 
# Please don't modify unless you know what you are doing.
$heliumURL = "https://api.helium.io/v1/"
$indexName = "helium-enriched"
$baseIndexName = "helium"
$pipelineName = "Helium_Enrichment"

Import-Module ./Helium-PowDerHound.ps1 -Force

# Get latest code from Helium Blockchain API Website - https://docs.helium.com/api/blockchain/introduction/
if (!$(Test-Path .\bones.ps1)){
  $result = Measure-Command {
    Write-Host "Bones (API Endpoints) not found, pulling latest API snippets from https://docs.helium.com/api/blockchain/introduction/" -ForegroundColor Yellow
    FetchBones
  }
  Write-Host "Took "$($result.TotalMinutes)"minutes to execute!"
} else {
  Write-Host "Bones.ps1 (API Endpoints) found, proceeding!" -ForegroundColor Green
}
# Import the code that was created based off the latest Blockchain API documenation
Import-Module ./bones.ps1

# Choose hotspot addresses or wallets.
$addressesOrWallets = Read-Host "Currently, you can either use a list of hotspots or generate hotspots from a wallet address. `
1. Wallet Address List (Recommended) `
2. Hotspot Address List `
Please Choose (1 or 2)"

if($addressesOrWallets -eq 1){
  # Get all wallet addresses from a text file
  Write-Host "Getting all wallet addresses fom a text file." -ForegroundColor Blue
  try{
    $addresses = Get-Content $walletFileLocation
    Export-Hotspots_from_Wallets $addresses
    Write-Host "Wallets added: $($addresses.count)"
    $addresses = Get-Content './hotspots.txt'
    Write-Host "Using automatically generated hotspots.txt file for ingest which has $($addresses.count) hotspots." -ForegroundColor Green
  
  }catch{
    Write-Host "Could not find wallet addresses in file. Exiting" -ForegroundColor Yellow
    Exit
  }
} elseif ($addressesOrWallets -eq 2) {
  # Get all hotspot addresses from a text file
  Write-Host "Getting all hotspot addresses fom a text file." -ForegroundColor Blue
  try{
    $addresses = Get-Content './hotspots.txt'
    Write-Host "Hotspots found: $($addresses.count)" -ForegroundColor DarkGreen
  }catch{
    Write-Host "Could not find hotspot addresses in file. Exiting" -ForegroundColor Yellow
    Exit
  }
  
}else{
  Write-Host "Not a valid option. Exiting"
  exit
}

# Setup index template in Elasticsearch PUT _index_template/helium-enriched
Write-Host "Setting up index template in Elasticsearch." -ForegroundColor Blue
$indexTemplate = Get-Content ./setup/index_template_helium_enriched.json
$indexTemplateURL = $elasticsearchURL+"/_index_template/helium-enriched"
try {
  Invoke-RestMethod -Method PUT -Uri $indexTemplateURL -Body $indexTemplate -ContentType "application/json" -Credential $elasticCreds -AllowUnencryptedAuthentication -SkipCertificateCheck
} catch {
  Write-Host "Couldn't add index template, likely because it already exists. Check kibana to see if the helium-enrich template exists." -ForegroundColor Yellow
  Write-Host "$_"
}

# Bootstrap helium index
Write-Host "Bootstrapping helium index in preparation for data ingest." -ForegroundColor Blue
$bootstrapIndexURL = $elasticsearchURL+"/helium"
try {
  Invoke-RestMethod -Method PUT -Uri $bootstrapIndexURL -ContentType "application/json" -Credential $elasticCreds -AllowUnencryptedAuthentication -SkipCertificateCheck
} catch {
  Write-Host "Couldn't bootstrap helium index, likely because it already exists. Check kibana to see if the helium index exists." -ForegroundColor Yellow
  Write-Debug "$_"
}

# Create the enrich policy
Write-Host "Creating the enrich policy in Elasticsearch for richer data sets." -ForegroundColor Blue
$enrichPolicy = Get-Content ./setup/enrich_policy_helium.json
$enrichPolicyURL = $elasticsearchURL+"/_enrich/policy/enrich_hotspot_name_and_geo_location"
try {
  Invoke-RestMethod -Method PUT -Uri $enrichPolicyURL -Body $enrichPolicy -ContentType "application/json" -Credential $elasticCreds -AllowUnencryptedAuthentication -SkipCertificateCheck
} catch {
  Write-Host "Couldn't add enrich policy, likely because it already exists. Check kibana to see if the policy enrich_hotspot_name_and_geo_location exists." -ForegroundColor Yellow
  Write-Debug "$_"
}
# Executing enrich policy is required but needs the index to be created with the data needed for enriching.
# This means that the Get-AllHotspots needs to be invoked.

# Ingest all hotspots known which will be needed for future enrichments for hotspot rewards data
$result = Measure-Command {
  Write-Host "Querying for all known hotspots, this could take over 10-20 minutes, please wait. `nThis is the baseline data to map hotspot addresses to names, locations, etc." -ForegroundColor Blue
  Get-AllHotspots
}
Write-Host "Took "$($result.TotalMinutes)"minutes to ingest all hotspot baseline data!" -ForegroundColor Green

# Execute Policy so that new documents can be enriched with name and geo location.
Write-Host "Executing the enrich policy so that new documents can be enriched with name and geo location attributes." -ForegroundColor Blue
$enrichPolicyExecuteURL = $elasticsearchURL+"/_enrich/policy/enrich_hotspot_name_and_geo_location/_execute"
try {
  Invoke-RestMethod -Method PUT -Uri $enrichPolicyExecuteURL -ContentType "application/json" -Credential $elasticCreds -AllowUnencryptedAuthentication -SkipCertificateCheck
} catch {
  Write-Host "Couldn't execute enrich policy." -ForegroundColor Yellow
  Write-Debug "$_"
}

# Create the ingest pipeline customized with the Helium Addresses specified for tagging and further enrichment
Write-Host "Creating customized helium ingest pipeline with the Helium addresses specified for tagging and further enrichment." -ForegroundColor Blue
$allAddressesFormatted = @()
$addresses | ForEach-Object {
    $allAddressesFormatted += '\"'+$_+'\"'
}
$finalFormatting = $allAddressesFormatted -join ",\n  "
$ingestPipeline = $(Get-Content ./setup/pipeline_helium_enrichment.json).Replace('$finalFormatting',$finalFormatting)

# Swap out tag with what is found in the configuration file.
$ingestPipeline = $ingestPipeline.Replace('$tag', $tag)

# Create the customized ingest pipeline in Elasticsearch. Special permissions are required to perform this action.
Write-Host "Setting up customized Elasticsearch ingest pipeline in Elasticsearch." -ForegroundColor Blue
$ingestPipelineURL = $elasticsearchURL+"/_ingest/pipeline/"+$pipelineName
try { 
  Invoke-RestMethod -Method PUT -Uri $ingestPipelineURL -Body $ingestPipeline -ContentType "application/json" -Credential $elasticCreds -AllowUnencryptedAuthentication -SkipCertificateCheck
} catch {
  Write-Host "Couldn't add ingest pipeline, likely because it already exists. Check kibana to see if the ingest pipeline $pipelineName exists." -ForegroundColor Yellow
}
# Reindex helium data into helium-enriched
Write-Host "Taking raw ingested helium data and reindexing with the new customized pipeline for use of customized tag. This could take 5-10 minutes." -ForegroundColor Blue
$reindexHelium = $(Get-Content ./setup/reindex_helium.json).Replace('$pipelineName',$pipelineName)
$reindexURL = $elasticsearchURL+"/_reindex?wait_for_completion=false"
try {
  $taskId = Invoke-RestMethod -Method POST -Uri $reindexURL -Body $reindexHelium -ContentType "application/json" -Credential $elasticCreds -AllowUnencryptedAuthentication -SkipCertificateCheck
} catch {
  Write-Host "Could not reindex." -ForegroundColor Yellow
  Write-Debug "$_"
}

$taskAPI = $elasticsearchURL+"/_tasks/"+$taskId.task
# Keep checking for the reindex to complete, and once it does, initializing the Elastic stack will be complete and it's almost time to get rewards!
do {
  Write-Debug "Checking to see if the reindex is complete. Please wait."
  $status = Invoke-RestMethod -Method Get -Uri $taskAPI -ContentType "application/json" -Credential $elasticCreds -AllowUnencryptedAuthentication -SkipCertificateCheck
  Write-Debug "Waiting to complete index for 30 seconds. Then checking again."
  Start-Sleep -Seconds 30
} until ("True" -eq $status.completed)

# The final step is to import the Visualizations and Dashboards
Write-Host "Last step! Importing saved visualizations and dashboard objects to visualize the data." -ForegroundColor DarkMagenta
Import-IndexPattern "./setup/dashboard_objects_helium.ndjson"

$configurationSettings.initializedElasticStack = "true"
$configurationSettings | Convertto-JSON | Out-File ./configuration.json -Force

Write-Host "But first, please navigate to your Kibana dashboard to make sure you have some data.`nCopy and Paste the URL below to navigate to the dashboard that was created (ctrl-click might not work):" -ForegroundColor Yellow
Write-Host $kibanaUrl'/app/dashboards#/view/c61c6ad0-13cc-11ec-b374-9dc91dfe0453?_g=(filters:!(),refreshInterval:(pause:!t,value:0),time:(from:now-4y,to:now))' -ForegroundColor DarkCyan
Write-Host "Username : elastic`nPassword : $elasticsearchPassword"
Write-Host "`nNote: Don't be alarmed if some of the visualizations are not populated or have errors, we need hotspot reward data to fix that up.`n"
Write-Host "If you have over 900,000 Total Hotspots, congratulations! It is time to start ingesting rewards data!`nStart by running ./Rewards_Hourly_Ingest.ps1" -ForegroundColor Green

$runHourly = Read-Host "Would you like to start the hourly ingest by ingesting data for $($addresses.count) hotspots?`
1. Yes please! Starting ingesting! `
2. No thank you. I will run that script later. `
Please Choose (1 or 2)"
if ($runHourly -eq 1) {
  <# Start data ingest #>
  Write-Host "Kicking off hourly ingest of hotspot data." -ForegroundColor DarkCyan
  ./Rewards_Hourly_Ingest.ps1
} elseif ($runHourly -eq 2) {
  <# Exit script since data ingest won't occur now. #>
  Write-Host "Exiting script now that the initialization script has run through it's entirety and you do not wish to start hotspot ingest.`nLater on you can start by running ./Rewards_Hourly_Ingest.ps1 in a new PowerShell session." -ForegroundColor Yellow
  Exit
}
