# Helium-PoweDerHound
A mulitpurpose tool to ingest Helium hotspot network data into an Elastic stack using PowerShell.

# Introduction 

     Helium-PowDerHound

     This is a (Helium) (Power)Shell script which is ultimately
     made to create (D)ashboards by fetching (Hound) the necessary
     data via the API of Helium and returning JSON that can be easily
     ingested into Elasticsearch.

     License: MIT

     Created by: Nicholas Penning

# Getting Started

Requirements:
 - PowerShell 7.0+
 - Elasticsearch v8.4+ (with permissions to index docs and create ingest pipelines)
 - Kibana v8.4+ (with permissions to import saved objects)
 - Access to https://api.helium.io and https://www.binance.us

** Docker and Docker Compose (If you don't have an Elastic stack today, build one via containers!)

1.	Clone this repo.
2.	Initialize your Elastic Stack (Docker Files Included if you don't have Elasticsearch setup today).
3.	Execute code to start ingesting Helium Data
4.	After geting the basics down, customize your experience by supplying your own wallets.txt or hotspots.txt file.

** If using docker: Navigate to \PowDerHound\docker and run: 
```docker-compose up```

** If running on Linux/Unix, you may need to increase the vm.max_map_count setting from the default (65530) which is too low:
```sudo sysctl -w vm.max_map_count=262144```

# Contribute

- Submit Issues as you find them
- Open for Feature Requests
