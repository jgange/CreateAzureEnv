# Pull current configuration of Dev to use to validate against other environments
# Dev is the reference environment

$outputFile = ($ENV:USERPROFILE, "Projects\PowerShell\CreateAzureEnv" ,"resourceProperties.txt" -join "\")

$primaryProjectResources = [System.Collections.ArrayList]@()

# Connect-AzAccount

$envMap = @{
        "Prod" = "p"
        "Dev"  = "d"
        "QA"   = "q"
        "UAT"  = "u"
}

$subName  = 'Pod-Dev'                                                                 # Target subscription name
$subId = (Get-AzSubscription -SubscriptionName $subName).Id                            # Get the Subscription Id from the name
$null = Set-AzContext -Subscription $subId

$env      = $envMap["Dev"]                                                            # Environment
$s        = '-'                                   
$project  = 'pod'                                                                      # This is the separator character for naming resources

$resources = Get-AzResource -ResourceGroupName d-pod-rg

$resources | ForEach-Object {
    $_ | Format-List -Property * | Out-File $outputFile -Append
    (Get-AzResource -ResourceId $_.ResourceId -ExpandProperties).Properties | Out-File $outputFile -Append
}