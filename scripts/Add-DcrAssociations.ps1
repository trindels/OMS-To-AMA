param(
    [Parameter(Mandatory=$true)]
    [string[]]
    $DataCollectionRuleId = @(),

    [Parameter(Mandatory=$false)]
    [string[]]
    $SubscriptionId = $null,

    [Parameter(Mandatory=$false)]
    [ValidateSet('Windows', 'Linux')]
    [string]
    $OSFilter = $null,

    [Parameter(Mandatory=$false)]
    [ValidateSet('All', 'VM', 'VMSS', 'Arc')]
    [string]
    $Target = 'All'
)

# Output Audit History
function New-AuditObject
{
    [OutputType([PSCustomObject])]
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        [Parameter(Mandatory = $false)]
        [string]$ResourceGroupName = "",
        [Parameter(Mandatory = $false)]
        [string]$ResourceName = "",
        [Parameter(Mandatory = $false)]
        [string]$ResourceType = "",
        [Parameter(Mandatory = $true)]
        [string]$DataCollectionRuleId,
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [Parameter(Mandatory = $false)]
        [string]$Message = ""
    )

    $object = New-Object -TypeName PSObject
    $object | Add-Member -MemberType NoteProperty -Name "Action" -Value $Action
    $object | Add-Member -MemberType NoteProperty -Name "SubscriptionId" -Value $SubscriptionId
    $object | Add-Member -MemberType NoteProperty -Name "ResourceGroupName" -Value $ResourceGroupName
    $object | Add-Member -MemberType NoteProperty -Name "ResourceName" -Value $ResourceName
    $object | Add-Member -MemberType NoteProperty -Name "ResourceType" -Value $ResourceType
    $object | Add-Member -MemberType NoteProperty -Name "DataCollectionRuleId" -Value $DataCollectionRuleId
    $object | Add-Member -MemberType NoteProperty -Name "Status" -Value $Status
    $object | Add-Member -MemberType NoteProperty -Name "Message" -Value $Message

    return $object
}
$outputAudit = @()

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
            -Name $dcrIdSplit[8] `
            -ErrorAction SilentlyContinue
        
        if ( $null -eq $dcr ) {
            Write-Error "Data Collection Rule ($dcrId) not found."
            return
        }
    }
}

# Run Your Script
foreach ( $subId in $SubscriptionId ) { # Loop Through Subscriptions
    # Validate Subscription Id
    try {
        $ctx = Set-AzContext -Subscription $subId -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Error "Subscription: '$subId': $($_.Exception.Message)"
        continue
    }
    
    $resIds = @()

    if ( $Target -eq "All" -or $Target -eq "VM" ) {
        # Get Your VMs in the current Subscription
        $vms = Get-AzVM -ErrorAction SilentlyContinue
        if ( $null -ne $OSFilter ) {
            $vms = $vms | Where-Object { $_.StorageProfile.OsDisk.OsType -ieq $OSFilter }
        }
        $resIds += $vms.Id
    }
    if ( $Target -eq "All" -or $Target -eq "VMSS" ) {
        # Get Your VMs in the current Subscription
        $vms = Get-AzVmss -ErrorAction SilentlyContinue.
        if ( $null -ne $OSFilter ) {
            $vms = $vms | Where-Object { $_.VirtualMachineProfile.StorageProfile.OsDisk.OsType -ieq $OSFilter }
        }
        $resIds += $vms.Id
    }
    if ( $Target -eq "All" -or $Target -eq "Arc" ) {
        # Get Your VMs in the current Subscription
        $vms = Get-AzConnectedMachine -ErrorAction SilentlyContinue
        if ( $null -ne $OSFilter ) {
            $vms = $vms | Where-Object { $_.OSType -ieq $OSFilter }
        }
        $resIds += $vms.Id
    }

    foreach ( $res in $resIds ) { # Loop Through VMs
        # Get Current Data Collection Rule Associations
        $currentDcrs = Get-AzDataCollectionRuleAssociation -ResourceUri $res

        foreach ( $dcrId in $DataCollectionRuleId ) { # Loop Through DCRs
            $assocName = "$($dcrId.split("/")[-1])-association"
            if ( $dcrId -notIn $currentDcrs.DataCollectionRuleId ) { # Verify
                # Auditing
                $audit = @{
                    Action = "Add Data Collection Rule Association"
                    SubscriptionId = $res.split("/")[2]
                    ResourceGroupName = $res.split("/")[4]
                    ResourceType = $res.split("/")[6] + "/" + $res.split("/")[7]
                    ResourceName = $res.split("/")[8]
                    DataCollectionRuleId = $dcrId
                    Status = "Unchanged"
                    Message = ""
                }

                # Update
                try {
                    New-AzDataCollectionRuleAssociation -Association $assocName -ResourceUri $res -DataCollectionRuleId $dcrId -ErrorAction Stop | Out-Null
                    Write-Host "Successfully Updated Association: $resId - $dcrId"
                    $audit.Status = "Success"                    
                }
                catch {
                    Write-Error "Failed to Add Data Collection Rule Association: \n  Resource: $($resId) \n  Data Collection Rule: $($dcrId)"
                    $audit.Status = "Failed"
                    $audit.Message = $_.Exception.Message
                }

                # Save Audit Results
                $outputAudit += New-AuditObject @audit
            }
        }
    }
}

# Set the Current Powershell Context back to the original
Set-AzContext -Context $oldCtx | Out-Null

# Return Output Audit History
return $outputAudit