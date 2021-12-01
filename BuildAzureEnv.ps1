﻿param (
    [ValidateSet("Prod", "Dev")]
    [string]
    $environment                      = "Prod",                               # Set the environment for the deployment

    [ValidateSet("pod")]
    [string]
    $project                          = "pod",                                # Project name

    [string]
    $referenceEnvironment             = 'Dev',                                # Name of the reference environment used as a the basis for building the rest

    [ValidateSet("True", "False")]
    [string]
    $debugMode                        = "False",                              # Run in debug mode (what-if) or actually create the objects

    #[Parameter(Mandatory=$true)]
    [string]
    $owner                            = "andy.melichar@ascentgl.com",         # For tags, can't be derived, must be entered by user

    #[Parameter(Mandatory=$true)]                                   
    [string]
    $contact                          = "andy.melichar@ascentgl.com",         # For tags, can't be derived, must be entered by user
                                
    [string]
    $department                       = "SRE",                                # For tags, can't be derived, must be entered by user

    [string]
    $costcenter                       = "",                                   # For tags, can't be derived, must be entered by user

    [string]
    $createdBy                        = "SRE",                                # For tags, can't be derived, must be entered by user

    [string]
    $subscriptionName                 = "Pod-Prod",                                              

    [string]
    $servicePrincipal                 = "AzureAutomationPS",

    [string]
    $logFilePath                      = ($env:USERPROFILE,"Projects\PowerShell\CreateAzureEnv\CreateAzureEnvironment.log" -join "\"),

    [string]
    $keyVaultName                     = 'sre-dev-keyvault',

    [string]
    $scriptPath                       = ($env:USERPROFILE,"Projects\PowerShell\CreateAzureEnv" -join "\")
)

# This script is designed to roll out an environment
# It accepts the environment name as a parameter to generate the appropriate resources
# The resources are hard coded into the script as well as the specific configuration values
# 
# Need to write to a log if this fails, whole script should. Perform clean up by deleting the resource group
# Need to add validation steps into the process to interrogate the new object and verify the configuration is correct or at least compare the values from dev since it's the template

# To get the application owner, the Microsoft graph module is required - Install-Module -Name Microsoft.Graph -RequiredVersion 0.1.1
# The Az Module also needs to be present

$resourceTypes = @{
    "Resource Group"           = "rg"                                         # This is the list of abbreviations used to identify the resource type in Azure
    "App Config"               = "ac"
    "Log analytics workspace"  = "law"
    "Application Insights"     = "ai"
    "Azure Kubernetes Service" = "aks"
    "App Service Plan"         = "asp"
    "Key Vault"                = "kv"
    "Container Registry"       = "acr"
    "Storage Account"          = "sa"
    "Service Bus Namespace"    = "sb"
    "Cosmos DB"                = "cos"
    "Logic App"                = "lapp"
}

$separators = @{                                                               # These are separator characters used for the naming convention
    "Resource Group"           = "-"
    "App Config"               = "-"
    "Log analytics workspace"  = "-"
    "Application Insights"     = "-"
    "Azure Kubernetes Service" = "-"
    "App Service Plan"         = "-"
    "Logic App"                = "-"
    "Key Vault"                = "-"
    "Container Registry"       = ""
    "Storage Account"          = ""
    "Service Bus Namespace"    = ""
    "Cosmo DB"                 = "-"
    "Azure Subscription"       = '-'
}

$resourceCommand = @{
    "Resource Group"           = "New-AzResourceGroup"
    "App Config"               = "New-AzAppConfigurationStore"
    "Log analytics workspace"  = "New-AzOperationalInsightsWorkspace"
    "Application Insights"     = "New-AzApplicationInsights"
    "Azure Kubernetes Service" = "az aks create"                               # This requires the Azure CLI b/c the app gateway ingress controller is not supported
    "App Service Plan"         = "New-AzAppServicePlan"
    "Logic App"                = "New-AzLogicApp"
    "Key Vault"                = "New-AzKeyVault"
    "Container Registry"       = "New-AzContainerRegistry"
    "Storage Account"          = "New-AzStorageAccount"
    "Service Bus Namespace"    = "New-AzServiceBusNamespace"
    "Cosmos DB"                = "New-AzCosmosDBAccount"
    "Azure Deployment"         = "New-AzResourceGroupDeployment"
}


$envMap = @{                                                                   # This translates the environment name to the appropriate prefix
        "Prod" = "p"
        "Dev"  = "d"
        "QA"   = "q"
        "UAT"  = "u"
}

$resource = New-Object System.Collections.Generic.Dictionary"[String,String]"
$resourceList = [System.Collections.ArrayList]@()

$templateFilePath          = $scriptPath,"ApplicationInsightsTemplate.json" -join "\"                  
$templateParameterFilePath = $scriptPath, "ApplicationInsightsParameters.json" -join "\"

$parameterFile = (get-Content -Path $templateParameterFilePath | ConvertFrom-Json)

$azureNameSpaces = [System.Collections.ArrayList]@()

### Function Definitions ###

function getNameSpaces($baseEnv)
{
    # Get the list of resources in the primary Development environment resource group since it is the reference environment
    # This depends on the service principal being granted contributor rights to the accompanying DEV subscription
    # The function accepts an environment parameter to identify the reference subscription/resource group.

    $rgName  = $envMap[$baseEnv],$project,$resourceTypes["Resource Group"] -join $separators["Resource Group"]
    $subName = $project,$baseEnv -join $separators["Azure Subscription"]

    Set-AzContext -Subscription $subName
    (Get-AzResource -ResourceGroupName $rgName).ResourceType | ForEach-Object {
        $null=$azureNameSpaces.Add($_.Split("/")[0])
    } 
}

function connectToAzure([string]$subName, [string] $keyVaultName, [string]$sp, [string[]]$keys, [string]$tenantId, [string]$applicationId)
{
    $secrets = @{}
    $key = [System.Collections.ArrayList]@()
    $keys | ForEach-Object {
        $secretText = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $_ -AsPlainText                            # Put this in a hash with the secret name and the value and pass it to the function
        $secrets.Add($_,$secretText)
    }

    [byte[]] $AESKey = $secrets["AES-Key"].Split([Environment]::NewLine, [StringSplitOptions]::RemoveEmptyEntries)   # Cast this as a byte array so it can be used to decrypt the password - the key must be in the form a byte array

    $passwordFile = $secrets["AzureAutomationPowerShellEncryptedPassword"]

    $pscredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $applicationId, ($passwordFile | ConvertTo-SecureString -Key $AESKey)
    $azc = Connect-AzAccount -ServicePrincipal -Credential $pscredential -Tenant $tenantId

    $subId = (Get-AzSubscription -SubscriptionName $subName).Id                         # Get the Subscription Id from the name
    $null = Set-AzContext -Subscription $subId                                         # Set the subscription context to create the resources

    if ($resourceList -contains 'CLI') { az account set --subscription $subId}

    Write-Host "Setting subscription to: $subName"

}

function registerProvider()
{
    # This function must be called after the connectToAzure function because it relies on the proper subscription context to be set.
    # I should add error handling to this to manage that exception case.

    $r = $azureNameSpaces | Sort-Object | Get-Unique
    $r | ForEach-Object { 
        Register-AzResourceProvider -ProviderNamespace $_ | Out-Null
    }
}

function createLogEntry([string] $logEntry, [string]$logFilePath, [string]$entryType)
{
    (Get-Date -Format "MM/dd/yyyy HH:mm K"),$entryType,$logEntry -join "**" | Out-File $logFilePath -Append
}

function getResourceMap([string] $filePath)
{
    # Read the list of required objects
    if (Test-Path $filePath) {
        $global:resourceList = Get-Content $filePath

    }
    else
    {
        Write-Host "File does not exist, check file location."
        createLogEntry ($filePath,"file does not exit, check file location" -join " ") $logFilePath "Error"
        exit 1
    }
}

function provisionResource($config)
{
    $commandString = ''

    if ($config["language"] -eq 'CLI'){                            # If there is a language key = CLI, use the CLI separators and then remove the key
        $separator = '--'
        $config.Remove("language")
    }
    else { $separator =  '-'}

    # identify the Id field, it can change with object type

    [string]$type = $config["Type"]
    if ($config.Values -contains "CLI") { [string]$name = $config["name"] }          # Have to account for CLI using the name instead for a parameter
    else { [string]$name = $config["Name"] }

    $config.Remove("Type")

    $config.Keys | ForEach-Object {
        $key = $_
        $value = $config[$key]
        
        if ($key.ToLower() -eq 'command') { $segment = $value + " " }
        elseif ($value -ne "") { $segment = $separator + $key + " " + $value + " " }
        elseif ($value -eq "") { $segment = $separator + $key + " " }

        $commandString = $commandString + $segment
    }

    $commandString

    try {           
            Write-Host "Attempting to create resource: $($config["Name"])"
            $r = Invoke-Expression $commandString
            $r
            if ($type -eq 'Resource Group') { $status = [string]$r.ProvisioningState; $status }
            else { $status=(Get-AzResource -ResourceName $name -ExpandProperties -ErrorAction Stop).Properties.ProvisioningState; $status }
        }
    catch
        {
            Write-Host "An error occurred during resource creation."                      
            createLogEntry $Error $logFilePath "Error"
            Stop-Transcript
            exit 1
        }

    # Go into a while loop while resource is created. This is necessary because of dependencies on certain resources. Skip this if debug is enabled
    
    if ($debugMode -eq 'False') {
        Write-Host "Verifying resource creation is complete."
        do {
            Start-Sleep -Seconds 5
        } while ($status -ne 'Succeeded')
    }
    
    if ($debugMode -eq 'True') {
        $resource.Add("Id","Bogus")
    }
    else {                                                                 # Add the resource Id which could be Id or ResourceId
        if ($r.ResourceId) { $resource.Add("Id",$r.ResourceId) }
        else { $resource.Add("Id",$r.Id) }
    }
    Write-Host "Creation of resource $name completed successfully."
}

function createAzureDeployment($config)
{

    [string]$deploymentName = ("Deploy",$config["ResourceType"], (Get-Date -Format "MM/dd/yyyy_HH_mm_ss") -join "-").Replace("/","_").Replace(" ","-")
    
    $name = $env, $project, $resourceTypes[$config["ResourceType"]] -join $separators[$config["ResourceType"]]
    $workspaceResourceId = (Get-AzResource -ResourceGroupName $config["ResourceGroupName"] -Name ($env,$project,$resourceTypes["Log analytics workspace"] -join "-")).ResourceId

    $parameterFile.parameters | get-member -type properties | ForEach-Object {
        $prop  = $_.Name
        $value = $parameterFile.parameters.$($_.Name).value
        $tempHash = @{}

        if ($value -eq 'empty') {    
            $newValue = (Get-Variable -Name $prop).Value
            $tempHash.Add("Value",$newValue)
            $newValue
            $tempHash
            $parameterFile.parameters.$prop = $tempHash
        }
    }

    $parameterFile | ConvertTo-Json | Out-file $templateParameterFilePath -Force

    $config["Name"] = $deploymentName                                                      # change the calculated name value to the deployment name value. It is incorrect since this is a deployment.
    $resourceType   = $config["ResourceType"]                                                # capture the resource type so we can retrieve the resourceId once the resource has been created
    $name           = $config["Name"]

    $commandString  = ''

    $config.Remove("Type")
    $config.Remove("ResourceType")

    # identify the Id field, it can change with object type

    $config.Keys | ForEach-Object {
        $key = $_
        $value = $config[$key]
        
        if ($key.ToLower() -eq 'command') { $segment = $value + " " }
        elseif ($value -ne "") { $segment = "-" + $key + " " + $value + " " }
        elseif ($value -eq "") { $segment = "-" + $key + " " }

        $commandString = $commandString + $segment
    }

    $commandString

    try {           
            Write-Host "Running the deployment: $($config["Name"])"
            $r = Invoke-Expression $commandString
            $r
        }
    catch
        {
            Write-Host "An error occurred during resource creation."                      
            $Error[0].CategoryInfo
            $Error[0].ErrorDetails
            Stop-Transcript
            exit 1
        }

    if ($debugMode -eq 'True') {
        $resource.Add("Id","Bogus")
    }
    else { 
        $resource.Add("Id",(Get-AzResource -Name $parameterFile.parameters.name.Value -ResourceGroupName $r.ResourceGroupName).ResourceId)
        $resource.Add("Location",(Get-AzResource -Name $parameterFile.parameters.name.Value -ResourceGroupName $r.ResourceGroupName).Location)    # This is required b/c we don't get this from the resource list file for a deployment
    }
    Write-Host "Creation of resource $name completed successfully."

}


function assignTags([string]$resourceId, [string]$type, [string]$location)
{
    
    Write-Host "Getting ready to tag Resource with Id $resourceId"
    #$type
    #$location

    if ($resourceId.Length -le 1) { 
        Write-Host "Resource ID is null, exiting script."
        Stop-Transcript; Exit 0
    }

    # get resource type from calling get-AzResource
    $tags   = @{
    "Project"     = $project
    "Environment" = $environment
    "Object Type" = $type      
    "Owner"       = $owner
    "Contact"     = $contact
    "Region"      = $location
    "Department"  = $department
    "Created By"  = $createdBy
    }

    if ($debugMode -eq "True") {
        try {
            Write-Host "Adding tags"
            $tags.Keys | ForEach-Object {
                
                New-AzTag -Name $_ -Value $tags[$_] -WhatIf
            }
        }
        catch {
            Write-Host "Failed to created tags. $tags"
            $Error
        }
    }
    else
    {
        # Make sure the resource exists
        try {
            if ($type -eq 'Resource Group') { $resource = Get-AzResourceGroup -Id $resourceId -ErrorAction Stop }
            else { $resource = Get-AzResource -ResourceId $resourceId -ErrorAction Stop }
        }
        catch
        {
            Write-Host "Failed to look up resource."
            $Error
            exit 1
        }

        # Try to add tags to it
        try {
            Write-Host "Adding tags"
            New-AzTag -ResourceId $resourceId -Tag $tags
        }
        catch {
            Write-Host "Failed to add tags to resource."
            $Error
            exit 1
        }
    }

}

function cleanUpEnvironment ($resoureGroupName)
{
    # delete the resource group if the creation of the resources fails somewhere and log this also
    # also needs to delete the tags associated with the resources if required
    # Also need to remove the Network Watcher resource group if AKS resource is created

    try {
        $rg = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
        $aksClusterName = $envMap[$environment],$project,$resourceTypes["Azure Kubernetes Service"] -join "-"
        $aksGroupName = "MC", $resoureGroupName,$aksClusterName, $rg.Location -join "_"

        $aksClusterName
        $aksGroupName

        exit 0

        Remove-AzResourceGroup -Name $resoureGroupName -Force -ErrorAction SilentlyContinue
        Remove-AzResourceGroup -Name $aksGroupName -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Host "Failed to remove resource group $resoureGroupName."
        $Error
    }

}

function lockResourceGroup([string] $resourceGroupName)
{
    try {
        New-AzResourceLock -LockName Lock-RG -LockLevel CanNotDelete -ResourceGroupName RG-CLI -Force -ErrorAction Stop
    }
    catch
    {
        Write-Host "Failed to lock resource"
    }

}


#### Testing Section ####

#### Main Program ####

getNameSpaces $referenceEnvironment       # Register any required namespaces to provision resources for this subscription.

Connect-AzAccount                         # this is login with my account first before switching to the service prinicipal

az login                                  # required to use the CLI
az account set --subscription $subscriptionName  # This is going to require some additional code in the connect function to support - this is a SHORTCUT - REPLACE!

Start-Transcript -Path "c:\users\jgange\Projects\PowerShell\CreateAzureEnv\CreateAzureEnv_RunLog.txt"                 # Keep a log of the output

$env       = $envMap[$environment]                                                       # Environment
$filePath  = $env:USERPROFILE + "\Projects\PowerShell\CreateAzureEnv\resourceList.txt"   # Location of the manifest file

# Process the input file with the resource definitions

getResourceMap $filePath

# Connect to the appropriate subscription
$tenantId = '7797ca53-b03e-4a03-baf0-13628aa79c92'
$applicationId = "0702023c-176d-46e8-81bc-5e79e7de57cd"

connectToAzure "Pod-Prod" $keyVaultName $servicePrincipal ("AES-Key","AzureAutomationPowerShellEncryptedPassword") $tenantId $applicationId

registerProvider                          # This registers the list of resources from the Dev subscription project resource group in the target subscription.

# Populate the hash table which contains the components of the command to execute

$resourceList | ForEach-Object {

    Write-Host "Record read: $($_)"
    
    # The first object is always the resource group. For every subsequent resource, resource group must be added to the hash table
    # Create a temporary hashtable to capture the settings from the file - need to account for the case when the value is null
    
    $tempHash = @{}

    $_.split(",") | ForEach-Object {
        $kv =$_.split("=")
        $tempHash.Add($kv[0],$kv[1])
    }
    # Get the name and creation command

    $resource.Add("Command",$resourceCommand[$tempHash["Type"]])

    if ($tempHash["language"] -eq "CLI") {
        $resource.Add("name",($env, $project, $resourceTypes[$tempHash["Type"]] -join $separators[$tempHash["Type"]]))
    }
    else { $resource.Add("Name",($env, $project, $resourceTypes[$tempHash["Type"]] -join $separators[$tempHash["Type"]])) }

    # Add resource group name if the resource is not a resource group
    if ($tempHash["Type"] -ne "Resource Group")
    {
        if ($tempHash["language"] -eq "CLI") {
             $resource.Add("resource-group",$resourceGroupName)
        }
        else { $resource.Add("ResourceGroupName",$resourceGroupName) }                                                  # Pass the resource group name parameter if the resource type is not a resource group
        
    }
    else
    {
        $resourceGroupName = $resource["Name"]   
    }

    $resourceType = $tempHash["Type"]                                                                                  # Save this value because it will be removed so we can iterate easily

    # Add remaining properties
    $tempHash.Keys | ForEach-Object {
        $resource.Add($_,$tempHash[$_])
    }

    # Handle any dependent resources (e.g., App Service Plan for Logic App)

    if ($resource.Values -contains 'Dependent Resource')
    {
        # Iterate through the resource object and save the key which is paired with the Value = Dependent Resource
        # Then compose the resource name and verify it exists before updating the value
        Write-Host 'Handle dependent resources.'

        $resource.Keys | ForEach-Object {
            if ($resource[$_] -eq 'Dependent Resource') { $k = $_ }
        }

        $k
        $resourceReference = $envMap[$environment],$project,$resourceTypes[$k] -join $separators[$k]
        $resource[$k] = $resourceReference

        $resource
    }

    # Enable test mode if the debug flag is set

    if ($debugMode -eq "True")
    {
        if ($resource["language"] -eq 'CLI') {}  #do nothing b/c there is no equivalent statement in Azure CLI
        else { $resource.Add("WhatIf","") }
    }

    # Add error handling behavior
    if ($resource.Keys -notcontains 'language') {$resource.Add("ErrorAction","Stop")}                                                                             # Add error trapping
    
    # Handle deployments - required if the PowerShell commands do not fully implement the resource options

    if ($resource.Type -eq "Azure Deployment")
    {
        createAzureDeployment $resource
    }
    else 
    {
        provisionResource $resource
    }

    # After resource creation, assign the appropriate tags

    assignTags $resource["Id"] $resourceType $resource["Location"]
   
    $tempHash.Clear()                                                                  # Clear the table to be ready for the next resource
    $resource.Clear()                                                                  # Clear the table to be ready for the next resource

}

Write-Host "Completed run."

Stop-Transcript