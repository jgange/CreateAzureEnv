param (
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
    $servicePrincipal                 = "PODProductionDeployAutomation",

    [string]
    $logFilePath                      = ($env:USERPROFILE,"Projects\PowerShell\CreateAzureEnv\CreateAzureEnvironment.log" -join "\"),

    [string]
    $keyVaultName                     = 'sre-dev-keyvault',

    [string]
    $secretName                       = 'PODProductionDeployAutomationSecret',

    [string]
    $scriptPath                       = ($env:USERPROFILE,"Projects\PowerShell\CreateAzureEnv" -join "\"),

    [string]
    $paramSeparator                  = '|'
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
    "Resource Group"                = "rg"                                         # This is the list of abbreviations used to identify the resource type in Azure
    "App Config"                    = "ac"
    "Log analytics workspace"       = "law"
    "Application Insights"          = "ai"
    "Azure Kubernetes Service"      = "aks"
    "App Service Plan"              = "asp"
    "Key Vault"                     = "kv"
    "Container Registry"            = "acr"
    "Storage Account"               = "sa"
    "Service Bus Namespace"         = "sb"
    "Cosmos DB"                     = "cos"
    "Logic App"                     = "lapp"
    "Application gateway"           = "ag"
    "Service principal"             = "sp"
    "Network security group rule"   = 'nsgr'
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
    "Application gateway"      = "-"
    "Service principal"        = "-"
    "Network security group rule" = "-"
}

$resourceCommand = @{
    "Resource Group"              = "New-AzResourceGroup"
    "App Config"                  = "New-AzAppConfigurationStore"
    "Log analytics workspace"     = "New-AzOperationalInsightsWorkspace"
    "Application Insights"        = "New-AzApplicationInsights"
    "Azure Kubernetes Service"    = "az aks create"                               # This requires the Azure CLI b/c the app gateway ingress controller is not supported
    "App Service Plan"            = "New-AzAppServicePlan"
    "Logic App"                   = "New-AzLogicApp"
    "Key Vault"                   = "New-AzKeyVault"
    "Container Registry"          = "New-AzContainerRegistry"
    "Storage Account"             = "New-AzStorageAccount"
    "Service Bus Namespace"       = "New-AzServiceBusNamespace"
    "Cosmos DB"                   = "New-AzCosmosDBAccount"
    "Azure Deployment"            = "New-AzResourceGroupDeployment"
    "Application gateway"         = ""
    "Service principal"           = "New-AzADServicePrincipal"
    "Network Security Group Rule" = "Add-AzNetworkSecurityRuleConfig"
}

$envMap = @{                                                                   # This translates the environment name to the appropriate prefix
        "Prod" = "p"
        "Dev"  = "d"
        "QA"   = "q"
        "UAT"  = "u"
}

$resource = New-Object System.Collections.Generic.Dictionary"[String,String]"
$resourceList = [System.Collections.ArrayList]@()

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

function connectToAzure([string]$subName, [string]$keyVaultName, [string]$sp, [string]$secretName, [string]$tenantId, [string]$applicationId)
{
    $secret = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName -AsPlainText                            # Put this in a hash with the secret name and the value and pass it to the function

    [securestring]$secStringPassword = ConvertTo-SecureString $secret -AsPlainText -Force
    # $pscredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $applicationId, (ConvertTo-SecureString $secret -AsPlainText -Force)
    [pscredential]$credObject = New-Object System.Management.Automation.PSCredential ($applicationId, $secStringPassword)

    $null = Connect-AzAccount -ServicePrincipal -Credential $credObject -Tenant $tenantId                          # Use $null to suppress output

    $subId = (Get-AzSubscription -SubscriptionName $subName).Id                                                    # Get the Subscription Id from the name
    $null = Set-AzContext -Subscription $subId                                                                     # Set the subscription context to create the resources

	if ($resourceList -match 'CLI') {                                                                           # Set the subscription context for the CLI if there are commands using it
        az login --service-principal -u $applicationId -p $secret --tenant $tenantId
        az account set --subscription $subId
    }                                     

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

function processError()
{
    $errorEntry = ("Exception: " + $Error[0].Exception), ("Category Info: " + $Error[0].CategoryInfo), ("Location: " + $Error[0].InvocationInfo.PositionMessage), ("Fully Qualified Error ID: " + $Error[0].FullyQualifiedErrorId) -join "\`n`n"
    createLogEntry $errorEntry $logFilePath "Error"
    Stop-Transcript
    Exit 1
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

    $config

    if ($config["language"] -eq 'CLI'){                            # If there is a language key = CLI, use the CLI separators for parameters
        $separator = '--'
        [string]$name = $config["name"]
        $language = $config["language"]                            # Need to do a get resource if the lang type was CLI, which means saving the lang type before removing it
        $config.Remove("language") 
    }
    else { 
        $separator =  '-'
        [string]$name = $config["Name"]
    }

    [string]$type = $config["Type"]

    # Handle case where resource already exists by skipping the provisioning step
    if ($type -eq 'Resource Group') {
        $Id = (Get-AzResourceGroup -Name $name -ErrorAction Ignore).ResourceId
        If ($Id) { 
            Write-Host "Resource group $name already exists, skipping provisioning step."
            createLogEntry "Resource group $($name) already exists, skipping provisioning step." $logFilePath "Warning"
            if ($debugMode -eq 'True') { $resource.Add("Id","Bogus") }
            else { $resource.Add("Id",$Id) }                                                            # Add the resource Id which could be Id or ResourceId
            Return
        }
    }
    else {
        if ($language) {                                                             # If using the CLI, pass the proper parameter name
            $Id = (Get-AzResource -Name $name -ResourceGroupName $config["resource-group"] -ErrorAction Ignore).ResourceId
        }
        else { $Id = (Get-AzResource -Name $name -ResourceGroupName $config["ResourceGroupName"] -ErrorAction Ignore).ResourceId }
        
        if ($Id) {
        Write-Host "Resource $name already exists, skipping provisioning step."
        createLogEntry "Resource $($name) already exists, skipping provisioning step." $logFilePath "Warning"
        if ($debugMode -eq 'True') { $resource.Add("Id","Bogus") }
        else { $resource.Add("Id",$Id) }                                                            # Add the resource Id which could be Id or ResourceId
        Return
        }
    }

    $config.Remove("Type")

    # Now identify any values with underscores in them. For those, it means we have to fill in the references from other resources.

    $config.Keys | ForEach-Object {
        $key = $_
        $value = $config[$key]
        
        if ($value.contains("&"))                                                       # This is the separator for derived values                                                
        {
            $resourceRef   = $value.Split("&")
            if ($resourceRef[1] -eq "New") {                                            # Deal with the use case where the object doesn't exist and just needs a name
                $resourceName  = ($envmap[$environment],$project,$resourceTypes[$resourceRef[0]] -join $separators[$resourceRef[0]])
                $value = $resourceName
            }
            elseif ($resourceRef[1] -eq 'ApplicationId') { $value = (Get-AzADServicePrincipal -DisplayName $servicePrincipal).ApplicationId } 
            elseif ($resourceRef[1] -eq 'Password') { $value = '"{0}"' -f (Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName -AsPlainText) }
            else {
			    $resourceCmd   = $resourceCommand[$resourceRef[0]].Replace("New-","Get-")
			    $resourceName  = ($envmap[$environment],$project,$resourceTypes[$resourceRef[0]] -join $separators[$resourceRef[0]])
			    $derivedValue  = "(" + ($resourceCmd,"-name",$resourceName -join " ") + " -ResourceGroupName " + (($envmap[$environment],$project,$resourceTypes["Resource Group"] -join "-")) + ")." + $resourceRef[1]
			    $value         = '"{0}"' -f (Invoke-Expression $derivedValue)
            }
        }

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
            processError
        }

    # Go into a while loop while resource is created. This is necessary because of dependencies on certain resources. Skip this if debug is enabled
    
    if ($debugMode -eq 'False') {
        Write-Host "Verifying resource creation is complete."
        do {
            Start-Sleep -Seconds 5
        } while ($status -ne 'Succeeded')
    }
    
    if ($language) { 
        $r = Get-AzResource -Name $name
        $r
    }  # This is necessary b/c the output from the az cli is in json and hard to decode

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
    # Need to check if the resource already exists

    $templateFilePath          = $scriptPath,$config["TemplateFile"] -join "\"                  
    $templateParameterFilePath = $scriptPath, $config["TemplateParameterFile"] -join "\"

    $parameterFile = (get-Content -Path $templateParameterFilePath | ConvertFrom-Json)

    [string]$deploymentName = ("Deploy",$config["ResourceType"], (Get-Date -Format "MM/dd/yyyy_HH_mm_ss") -join "-").Replace("/","_").Replace(" ","-")
    
    $name = $env, $project, $resourceTypes[$config["ResourceType"]] -join $separators[$config["ResourceType"]]
    # The workspaceResourceId should be a Try/Catch since it might not exist or be accessible
    $workspaceResourceId = (Get-AzResource -ResourceGroupName $config["ResourceGroupName"] -Name ($env,$project,$resourceTypes["Log analytics workspace"] -join "-")).ResourceId
    
    $matchValue = "*" + (($envMap[$environment],$project,$resourceTypes["Resource Group"] -join "-"), ($envMap[$environment],$project,$resourceTypes["Azure Kubernetes Service"] -join "-") -join "_") + "*"
    $aksResourceGroupName = (Get-AzResourceGroup).ResourceGroupName | Where-Object { $_ -like $matchValue }

    $networkSecurityGroups_aks_agentpool_nsg_name = (Get-AzResource -ResourceType "Microsoft.Network/networkSecurityGroups" -ResourceGroupName $aksResourceGroupName).ResourceName

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
    $resourceType   = $config["ResourceType"]                                              # capture the resource type so we can retrieve the resourceId once the resource has been created
    $name           = $parameterFile.parameters.name.Value

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
            processError
        }

    if ($debugMode -eq 'True') {
        $resource.Add("Id","Bogus")
    }
    else { 
        $resource.Add("Id",(Get-AzResource -Name $parameterFile.parameters.name.Value -ResourceGroupName $r.ResourceGroupName).ResourceId)
        $resource.Add("Location",(Get-AzResource -Name $parameterFile.parameters.name.Value -ResourceGroupName $r.ResourceGroupName).Location)    # This is required b/c we don't get this from the resource list file for a deployment
        $Resource.Name = $name
        $resource.Add("ResourceType",$resourceType)
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
        # create a log entry
        Stop-Transcript; Exit 1

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
            processError
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
            processError
        }

        # Try to add tags to it
        try {
            Write-Host "Adding tags"
            New-AzTag -ResourceId $resourceId -Tag $tags
        }
        catch {
            Write-Host "Failed to add tags to resource."
            processError
        }
    }

}
function lockResource($resource)
{
     
    $resourceLock = [ordered]@{
        LockName          = "Lock",$resource["Name"] -join "-"
        LockLevel         = 'CanNotDelete'
        ResourceName      = $resource["Name"]
        Force             = $true
        ErrorAction       = 'Stop'
    }

    if ($resource["Command"] -match "az ") {                                                                                    # Handle the case where the resource was created using the CLI
        if (!($resource["resource-group"])) {
            $resourceLock.Add("ResourceGroupName",$resource["name"])
            $resourceLock.Remove("ResourceName")
        }
        else {
            $resourceLock.Add("ResourceGroupName",$resource["resource-group"])
            $resourceLock.Add("ResourceType",(Get-AzResource -Name $resource["name"] -ResourceGroupName $resource["resource-group"]).ResourceType)          # Get the resource type
            $resourceLock["LockName"] = "Lock",$resource["name"] -join "-"
            $resourceLock["ResourceName"] = $resource["name"]
        }   
    }
   else {                                                                                                                       # If powershell was used, handle that case
       if (!($resource["ResourceGroupName"])) {
            $resourceLock.Add("ResourceGroupName",$resource["Name"])
            $resourceLock.Remove("ResourceName")
        }
        else {
            $resourceLock.Add("ResourceGroupName",$resource["ResourceGroupName"])
            $resourceLock.Add("ResourceType",(Get-AzResource -Name $resource["Name"] -ResourceGroupName $resource["ResourceGroupName"]).ResourceType)          # Get the resource type
        }
    }

    $resourceLock

    try {
        New-AzResourceLock @resourceLock
    }
    catch
    {
        Write-Host "Failed to lock resource"
        processError
    }

    $resourceLock.Clear()

}

function postConfig([boolean]$configComplete)
{
    # stub - call this when the resource manifest has been successfully processed and all the created resources are tagged and locked


}


#### Testing Section ####

#### Main Program ####

Connect-AzAccount -WarningAction Ignore   # this is login with my account first before switching to the service prinicipal

az login                                  # required to use the CLI, also with my account

Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"  # This suppresses the breaking change warnings

getNameSpaces $referenceEnvironment       # Register any required namespaces to provision resources for this subscription.

Start-Transcript -Path "c:\users\jgange\Projects\PowerShell\CreateAzureEnv\CreateAzureEnv_RunLog.txt"                 # Keep a log of the output

$env       = $envMap[$environment]                                                       # Environment
$filePath  = $env:USERPROFILE + "\Projects\PowerShell\CreateAzureEnv\resourceList.txt"   # Location of the resource manifest file - github repo?

getResourceMap $filePath                                                                 # Process the input file with the resource definitions

# Connect to the appropriate subscription
$tenantId = '7797ca53-b03e-4a03-baf0-13628aa79c92'
$applicationId = (Get-AzADServicePrincipal -DisplayName $servicePrincipal).ApplicationId      # Get the App Id based on the Service Principal display name

connectToAzure $subscriptionName $keyVaultName $servicePrincipal $secretName $tenantId $applicationId

registerProvider                          # This registers the list of resources from the Dev subscription project resource group in the target subscription.

# Populate the hash table which contains the components of the command to execute

$resourceList | ForEach-Object {

    Write-Host "Record read: $($_)"
    
    # The first object is always the resource group. For every subsequent resource, resource group must be added to the hash table
    # Create a temporary hashtable to capture the settings from the file - need to account for the case when the value is null
    
    $tempHash = @{}

    $_.split($paramSeparator) | ForEach-Object {
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
        $resourceGroupName = ($env, $project, $resourceTypes["Resource Group"] -join $separators["Resource Group"])
        if ($tempHash["language"] -eq "CLI") {
             $resource.Add("resource-group",$resourceGroupName)
        }
        else { $resource.Add("ResourceGroupName",$resourceGroupName) }                                                  # Pass the resource group name parameter if the resource type is not a resource group
        
    }
    else
    { $resourceGroupName = $resource["Name"] }

    $resourceType = $tempHash["Type"]                                                                                  # Save this value because it will be removed so we can iterate easily

    # Add remaining properties
    $tempHash.Keys | ForEach-Object {
        $resource.Add($_,$tempHash[$_])
    }

    if ($debugMode -eq "True")                                                                                         # Enable test mode if the debug flag is set
    {
        if ($resource["language"] -eq 'CLI') {}                                                                        # Do nothing b/c there is no equivalent statement in Azure CLI
        else { $resource.Add("WhatIf","") }
    }

    # Add error handling behavior for powershell commands. The Azure CLI does not have an equivalent.
    if ($resource.Keys -notcontains 'language') {
        $resource.Add("ErrorAction","Stop")                                                                            # Stop the script on any terminal error
    }                                                                          
    
    # Handle deployments - required if the PowerShell commands do not fully implement the resource options

    if ($resource.Type -eq "Azure Deployment")
        { createAzureDeployment $resource }
    else 
        { provisionResource $resource }

    # After resource creation, assign the appropriate tags

    if ($resource["Command"] -match "az ") {                                             # Adjust for the Azure CLI location switch (uses lowercase)
        assignTags $resource["Id"] $resourceType $resource["location"]
    }
    else { assignTags $resource["Id"] $resourceType $resource["Location"] }
   
    lockResource $resource

    if ($resourceList -contains 'Azure Kubernetes Service')
    {
        # stub to add tags and locks to Network Watcher RG
    }
    

    $tempHash.Clear()                                                                  # Clear the table to be ready for the next resource
    $resource.Clear()                                                                  # Clear the table to be ready for the next resource

}

# Finally, apply non-deletion locks to the resource objects inside the designated resource group

Write-Host "Completed run."

Stop-Transcript