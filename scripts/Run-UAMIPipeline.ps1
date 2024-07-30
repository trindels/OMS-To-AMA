$uamiSubId = "00000000-0000-0000-0000-000000000000"
$uamiRgName = "ResourceGroupName"
$uamiName = "UserAssignedIdentityName"

$subs = @(
    "00000000-0000-0000-0000-000000000000"
    "00000000-0000-0000-0000-000000000000"
    "00000000-0000-0000-0000-000000000000"
)

$dcrs = @(
    "/subscriptions/{subId}/resourceGroups/{rg}/providers/Microsoft.Insights/dataCollectionRules/{name1}"
    "/subscriptions/{subId}/resourceGroups/{rg}/providers/Microsoft.Insights/dataCollectionRules/{name2}"
)

# Get the User Assigned Identity
$uami = Get-AzUserAssignedIdentity -SubscriptionId $uamiSubId -ResourceGroupName $uamiRgName -Name $uamiName -ErrorAction Stop

# Add Managed Identity to VMs in Scope
$miAudit = .\Add-ManagedIdentity.ps1 -UserAssigned -IdentityId $uami.Id -SubscriptionId $subs -Target VM
$miAudit | Export-Csv -Path "ManagedIdentityAudit.csv" -NoTypeInformation -NoClobber

# Install Azure Monitor Agent to In Scope VMs
$amaAudit = .\Install-AzureMonitorAgent.ps1 -UserAssigned -IdentityId $uami.Id -SubscriptionId $subs -Target VM
$amaAudit | Export-Csv -Path "AmaAudit.csv" -NoTypeInformation -NoClobber

# Add Data Collection Rule Associations to In Scope VMs
$dcrAudit = .\Add-DcrAssociations.ps1 -DataCollectionRuleId $dcrs -SubscriptionId $subs -Target VM
$dcrAudit | Export-Csv -Path "DcrAudit.csv" -NoTypeInformation -NoClobber
