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
.\Add-ManagedIdentity.ps1 -UserAssigned -IdentityId $uami.Id -SubscriptionId $subs -Target VM -OutVariable $miAudit
Export-Csv -Path "ManagedIdentityAudit.csv" -InputObject $miAudit -NoTypeInformation -NoClobber

# Install Azure Monitor Agent to In Scope VMs
.\Install-AzureMonitorAgent.ps1 -UserAssigned -IdentityId $uami.Id -SubscriptionId $subs -Target VM -OutVariable $amaAudit
Export-Csv -Path "AmaAudit.csv" -InputObject $amaAudit -NoTypeInformation -NoClobber

# Add Data Collection Rule Associations to In Scope VMs
.\Add-DcrAssociations.ps1 -DataCollectionRuleId $dcrs -SubscriptionId $subs -Target VM -OutVariable $dcrAudit
Export-Csv -Path "DcrAudit.csv" -InputObject $dcrAudit -NoTypeInformation -NoClobber
