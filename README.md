# Helium-PowDerHound
A multipurpose tool to ingest Helium hotspot network data into an Elastic stack using PowerShell.
```
#########################################################################################################################
#  / \__                       _ _                         ___               ___                                     _   #
#  (    r\___        /\  /\___| (_)_   _ _ __ ___         / _ \_____      __/   \___ _ __ /\  /\___  _   _ _ __   __| |  #
#  /         O      / /_/ / _ \ | | | | | '_ ` _ \ _____ / /_)/ _ \ \ /\ / / /\ / _ \ '__/ /_/ / _ \| | | | '_ \ / _` |  #
#  /   (_____/     / __  /  __/ | | |_| | | | | | |_____/ ___/ (_) \ V  V / /_//  __/ | / __  / (_) | |_| | | | | (_| |  #
#  /_____/   U     \/ /_/ \___|_|_|\__,_|_| |_| |_|     \/    \___/ \_/\_/___,' \___|_| \/ /_/ \___/ \__,_|_| |_|\__,_|  #
#                                                                                                                        #
##########################################################################################################################
```

https://user-images.githubusercontent.com/5582679/196057475-9470f86a-17ac-4c2f-955b-aed8a289348b.mov

# Introduction 

     Helium-PowDerHound

     This is a (Helium) (Power)Shell script which is ultimately
     made to create (D)ashboards by fetching (Hound) the necessary
     data via the API of Helium and returning JSON that can be easily
     ingested into Elasticsearch.

     License: MIT

     Created by: Nicholas Penning
     
# Features 🚀
- [x] A wizard to walk you through the deployment of an Elastic Stack using Docker
- [x] Ingest Hotspot data to your own self hosted Elastic Stack
- [x] Build custom visualizations and dashboards on ingested data using Kibana
- [x] Fast access to any data you ingest with this tool
- [x] Tag hotspots that you wish to monitor for easy filtering
- [x] Add wallets or hotspots you wish to monitor reward data for
- [x] Fetches the latest Helium API endpoints for programmatic access via PowerShell (creates bones.ps1)
- [x] Build your own use case for accessing Helium API endpoints using PowerShell (bones.ps1 usage)
- [x] Links within data to go explore with Helium Explorer
- [x] Enrich data with hourly HNT price
- [x] Enrich data with last months HNT close price
- [x] Out of the box Dashboard that includes tables, charts, and even a map of reward data
- [x] And much, much more!

# Getting Started

Requirements:
 - PowerShell 7.0+ (Install found [here](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell?view=powershell-7.3))
 - Elasticsearch v8.4+ (with permissions to index docs and create ingest pipelines)
 - Kibana v8.4+ (with permissions to import saved objects)
 - Access to https://api.helium.io and https://www.binance.us
 - 4 GB+ RAM free* (when using the project's docker implementation)

** Docker and Docker Compose (If you don't have an Elastic stack today, build one via containers! Install found [here](https://docs.docker.com/get-docker/))

1.	Clone this repo.

     `git clone https://github.com/nicpenning/Helium-PowDerHound.git`

     If you don't have git then click Code above in the right hand corner of this page and then click Download zip. 
     Then extract to a directory of your choosing. 


2.	Initialize your Elastic Stack (Docker Files Included if you don't have Elasticsearch setup today).
     In PowerShell 7, navigate to the root directory for Helium-PowDerHound and run:
 
     `Unblock-File *.ps1; .\Initialize-Elastic_Stack.ps1`
  
3.	Execute code to start ingesting Helium Data (This happens automatically after the initialization but can be started again by navigating to the root directory and running): 

     `.\Rewards_Hourly_Ingest.ps1`


5.	After geting the basics down, customize your experience by supplying your own wallets.txt or hotspots.txt file. This can be done by repeating step 2, which is running: 

     `.\Initialize-Elastic_Stack.ps1` 


# What's in the box? (🔋 Batteries Included!)

```
Helium-PowDerHound
│   README.md ( This page. )
|   .gitignore ( Files to ignore when pulling the latest code from this project. )
|   LICENSE ( The license for this project. )
│   Helium-PowDerHound.ps1 ( Contains the use cases for ingesting data from the Helium API, creating bones.ps1, and retrieving HNT exchange rates. )
│   Initialize-Elastic_Stack.ps1 ( Used for getting the Elastic stack up and running, setting up pipelines, templates and all the work needed to make this tool successful. It will be run first and foremost for any use of this project. )
|   Rewards_Hourly_Ingest.ps1 ( Used for the operational ingest of Helium data once everything is setup. As the name suggests, this script will call the Helium-PowDerHound.ps1 file to ingest reward data for the hotspots or wallets you configured every hour. In an event you need to stop ingesting data and start over again, simply just run this script to resume data ingest.)
|   configuration.json ( Used for the configuration of this project. The defaults will work with this project but are configurable for your own Elatic stack if you choose not to have this tool build your stack.)
|   bones.ps1 ( A special file that gets genereated when the Intilize-Elastic_Stack.ps1 script is executed (Althought the code is found in Helium-PowDerHound.ps1). It contains the necessary API calls needed to interact with api.helium.io which can be used for custom use cases. )
└───docker
│   │   .env_template ( A docker template for those that don't have the Elastic stack and want this project to build and maintain it for them. Note that the amount of free RAM for memory must be at least 4GB since that is what the project sets MEM_LIMIT to for default. Increase or decrease this for your needs. )
│   │   docker-compose.yml ( A docker compose file to layout all the necessary parts of the Elastic stack to get it up and running. )
│   
└───setup
    │   api_key_creation.json ( Used during the Initialize-Elastic_Stack.ps1 execution which will genreate a secure API key that will be used and stored in the configuration.json file automatically. )
    │   dashboard_objects_helium.ndjson ( The default Dashboard that the project uses. )
    │   enrich_policy_helium.json ( An enrich policy that will make the data from the Helium API even better! )
    │   index_pattern_for_dynamic_updates.ndjson ( The index pattern that will change often due to the use of runtime fields. In short, this is how the HNT value and the last month HNT value gets changed in Kibana for calculations. )
    │   index_template_helium_enriched.json ( The mappings for all of the data used in this project. )
    │   pipeline_helium_enrichment.json ( The pipeline that all data passes through to get properly ingested into the Elastic stack with enrichments to streamline the use of the Helium data. )
    │   reindex_helium.json ( A reindex process that requires all of the hotspots known to be ingested into a custom index that will later enrich all data coming in. One example is that the rewards data api does not include the hotspot name, so we make sure to include the hotspot name in that data for better visualization later on in the platform. )

# Contribute

- Submit Issues as you find them
- Open for Feature Requests
