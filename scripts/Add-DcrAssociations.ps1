param(
    [Parameter(Mandatory=$true)]
    [string[]]
    $DataCollectionRuleId = @(),

    [Parameter(Mandatory=$false)]
    [string[]]
    $SubscriptionId = $null,

    [Parameter(Mandatory=$false)]
    [ValidateSet('All', 'VM', 'VMSS', 'Arc')]
    [string]
    $Target = 'All'
)

# Get the Current Powershell Context (for restoring later)
$oldCtx = Get-AzContext -ErrorAction Stop

# Determine Azure Powershell Log In Status
if ( $null -eq $oldCtx ) {
    Write-Error "Please Log In to Azure Powershell using Connect-AzAccount."
    return
}

# Set Subscription Id if Not Set
if ( $null -eq $SubscriptionId -or $SubscriptionId -eq "" ) {
    $SubscriptionId = $oldCtx.Subscription.Id
}

# Validate Data Collection Rule IDs
foreach ( $dcrId in $DataCollectionRuleId ) {
    $dcrIdSplit = $dcrId.Split("/")

    # Validate Data Collection Rule ID
    if ( $dcrIdSplit.Length -ne 9 ) {
        Write-Error "Data Collection Rule ID is not in the correct format (/subscriptions/{subId}/resourceGroups/{rg}/providers/Microsoft.Insights/dataCollectionRules/{name})"
        return
    }
    elseif ( $dcrIdSplit[1] -ne "subscriptions" -or
            $dcrIdSplit[3] -ne "resourceGroups" -or
            $dcrIdSplit[5] -ne "providers" -or
            $dcrIdSplit[6] -ne "Microsoft.Insights" -or
            $dcrIdSplit[7] -ne "dataCollectionRules" ) {
        Write-Error "Data Collection Rule ID is not in the correct format (/subscriptions/{subId}/resourceGroups/{rg}/providers/Microsoft.Insights/dataCollectionRules/{name})"
        return
    }
    else {
        # Get DCR
        $dcr = Get-AzDataCollectionRule `
            -SubscriptionId $dcrIdSplit[2] `
            -ResourceGroupName $dcrIdSplit[4] `
            -Name $dcrIdSplit[8]
            -ErrorAction SilentlyContinue
        
        if ( $null -eq $dcr ) {
            Write-Error "Data Collection Rule ($dcrId) not found."
            return
        }
    }
}

# Get All Available Subscriptions
$allCtx = Get-AzContext -ListAvailable

# Run Your Script
foreach ( $subId in $SubscriptionId ) { # Loop Through Subscriptions
    # Validate Subscription Id
    $ctx = $allCtx | Where-Object { $_.Subscription.Id -eq $subId }
    if ( $null -ne $ctx ) {
        Set-AzContext -Context $ctx | Out-Null
    }
    else {
        Write-Error "Subscription '$subId' not available"
        break
    }

    $resIds = @()

    if ( $Target -eq "All" -or $Target -eq "VM" ) {
        # Get Your VMs in the current Subscription
        $vms = Get-AzVM -ErrorAction SilentlyContinue
        $resIds += $vms.Id
    }
    if ( $Target -eq "All" -or $Target -eq "VMSS" ) {
        # Get Your VMs in the current Subscription
        $vms = Get-AzVmss -ErrorAction SilentlyContinue
        $resIds += $vms.Id
    }
    if ( $Target -eq "All" -or $Target -eq "Arc" ) {
        # Get Your VMs in the current Subscription
        $vms = Get-AzConnectedMachine -ErrorAction SilentlyContinue
        $resIds += $vms.Id
    }

    foreach ( $res in $resIds ) { # Loop Through VMs
        # Get Current Data Collection Rule Associations
        $currentDcrs = Get-AzDataCollectionRuleAssociation -ResourceUri $res

        foreach ( $dcrId in $DataCollectionRuleId ) { # Loop Through DCRs
            $assocName = "$($dcr.split("/")[-1])-association"
            if ( $dcrId -notIn $currentDcrs.DataCollectionRuleId ) { # Verify
                New-AzDataCollectionRuleAssociation -Association $assocName -ResourceUri $res -DataCollectionRuleId $dcrId
            }
        }
    }
}

# Set the Current Powershell Context back to the original
Set-AzContext -Context $oldCtx | Out-Null