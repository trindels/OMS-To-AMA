param(
    [Parameter(Mandatory=$true, ParameterSetName='SystemAssigned')]
    [switch]
    $SystemAssigned,

    [Parameter(Mandatory=$true, ParameterSetName='UserAssigned')]
    [switch]
    $UserAssigned,

    [Parameter(Mandatory=$true, ParameterSetName='UserAssigned')]
    [string]
    $IdentityId,

    [Parameter(Mandatory=$false)]
    [string[]]
    $SubscriptionId = $null,

    [Parameter(Mandatory=$false)]
    [string[]]
    $IgnoreImageNames = @(),

    [Parameter(Mandatory=$false)]
    [ValidateSet('All', 'VM', 'VMSS')]
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

# Validate Identity Id
if ( $null -ne $UserAssigned -and $UserAssigned -eq $true ) {
    $identityIdSplit = $IdentityId.Split("/")

    # Validate Identity Id
    if ( $identityIdSplit.Length -ne 9 ) {
        Write-Error "Identity Id is not in the correct format (/subscriptions/{subId}/resourceGroups/{rg}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/{name})"
        return
    }
    elseif ( $identityIdSplit[1] -ne "subscriptions" -or
            $identityIdSplit[3] -ne "resourceGroups" -or
            $identityIdSplit[5] -ne "providers" -or
            $identityIdSplit[6] -ne "Microsoft.ManagedIdentity" -or
            $identityIdSplit[7] -ne "userAssignedIdentities" ) {
        Write-Error "Identity Id is not in the correct format (/subscriptions/{subId}/resourceGroups/{rg}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/{name})"
        return
    }
    else {
        # Get UAMI
        $uami = Get-AzUserAssignedIdentity `
            -SubscriptionId $identityIdSplit[2] `
            -ResourceGroupName $identityIdSplit[4] `
            -Name $identityIdSplit[8] `
            -ErrorAction SilentlyContinue

        if ( $null -eq $uami ) {
            Write-Error "User Assigned Identity '$IdentityId' not found"
            return
        }
    }
}

foreach ( $subId in $SubscriptionId ) {
    # Validate Subscription Id
    try {
        $ctx = Set-AzContext -Subscription $subId -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Error "Subscription: '$subId': $($_.Exception.Message)"
        continue
    }
    
    if ( $Target -eq "All" -or $Target -eq "VM" ) {
        # Get all VMs
        $allVm = Get-AzVM

        # Filter Out of Scope VMs
        if ( $null -ne $SystemAssigned -and $SystemAssigned -eq $true ) {
            $allVm = $allVm | Where-Object { $_.Identity.Type -notlike 'SystemAssigned*' }
        }
        elseif ( $null -ne $UserAssigned -and $UserAssigned -eq $true ) {
            $allVm = $allVm | Where-Object { $_.Identity.Type -notlike '*UserAssigned' -or $_.Identity.UserAssignedIdentities.Keys -notcontains $IdentityId }
        }
        $allVm = $allVm | Where-Object { $_.VirtualMachineProfile.StorageProfile.ImageReference.Offer -notin $IgnoreImageNames }
        
        # Update Each In-Scope VM Identity
        foreach ( $vm in $allVm ) {
            # Auditing
            $action = "Add User Assigned Identity"
            if ( $null -ne $SystemAssigned -and $SystemAssigned -eq $true ) { $action = "Add System Assigned Identity" }
            $audit = @{
                Action = $action
                SubscriptionId = $subId
                ResourceGroupName = $vm.ResourceGroupName
                ResourceType = $vm.Type
                ResourceName = $vm.Name
                Status = "Unchanged"
                Message = ""
            }

            # Updating
            try {
                if ( $null -ne $SystemAssigned -and $SystemAssigned -eq $true ) {
                    if ( $null -eq $vm.Identity -or $vm.Identity.Type -eq "None" ) {
                        $vm | Update-AzVM -IdentityType SystemAssigned -ErrorAction Stop | Out-Null
                    }
                    else {
                        $vm | Update-AzVM -IdentityType SystemAssignedUserAssigned -IdentityId @( $vm.Identity.UserAssignedIdentities.Keys ) -ErrorAction Stop | Out-Null
                    }
                }
                elseif ( $null -ne $UserAssigned -and $UserAssigned -eq $true ) {
                    $idType = "UserAssigned"
                    if ( $null -ne $vm.Identity -and $vm.Identity.Type -like "*SystemAssigned*" ) { $idType = "SystemAssignedUserAssigned" }
                    $ids = $vm.Identity.UserAssignedIdentities.Keys + $uami.Id
                    $vm | Update-AzVM -IdentityType $idType -IdentityId @( $ids ) -ErrorAction Stop | Out-Null
                }
                Write-Host "Successfully Updated VM Identity: $($vm.Name)"
                $audit.Status = "Success"
            }
            catch {
                Write-Error "Failed to Update VM Identity: $($vm.Name)"
                $audit.Status = "Failed"
                $audit.Message = $_.Exception.Message
            }

            # Save Audit
            $outputAudit += New-AuditObject @audit
        }
    }

    if ( $Target -eq "All" -or $Target -eq "VMSS" ) {
        # Get all VM Scale Sets
        $allVmss = Get-AzVmss

        # Filter Out of Scope VMSS
        if ( $null -ne $SystemAssigned -and $SystemAssigned -eq $true ) {
            $allVmss = $allVmss | Where-Object { $_.Identity.Type -notlike '*SystemAssigned*' }
        }
        elseif ( $null -ne $UserAssigned -and $UserAssigned -eq $true ) {
            $allVmss = $allVmss | Where-Object { $_.Identity.Type -notlike '*UserAssigned*' -or $_.Identity.UserAssignedIdentities.Keys -notcontains $IdentityId }
        }
        $allVmss = $allVmss | Where-Object { $_.VirtualMachineProfile.StorageProfile.ImageReference.Offer -notin $IgnoreImageNames }
        
        # Update Each In-Scope VMSS Identity
        foreach ( $vm in $allVmss ) {
            # Audit
            $action = "Add User Assigned Identity"
            if ( $null -ne $SystemAssigned -and $SystemAssigned -eq $true ) { $action = "Add System Assigned Identity" }
            $audit = @{
                Action = $action
                SubscriptionId = $subId
                ResourceGroupName = $vm.ResourceGroupName
                ResourceType = $vm.Type
                ResourceName = $vm.Name
                Status = "Unchanged"
                Message = ""
            }

            #Update
            try {
                if ( $null -ne $SystemAssigned -and $SystemAssigned -eq $true ) {
                    if ( $null -eq $vm.Identity -or $vm.Identity.Type -eq "None" ) {
                        $vm | Update-AzVmss -IdentityType SystemAssigned -ErrorAction Stop | Out-Null
                    }
                    else {
                        $vm | Update-AzVmss -IdentityType SystemAssignedUserAssigned -IdentityId @( $vm.Identity.UserAssignedIdentities.Keys ) -ErrorAction Stop | Out-Null
                    }
                }
                elseif ( $null -ne $UserAssigned -and $UserAssigned -eq $true ) {
                    $idType = "UserAssigned"
                    if ( $null -ne $vm.Identity -and $vm.Identity.Type -like "*SystemAssigned*" ) { $idType = "SystemAssignedUserAssigned" }
                    $ids = $vm.Identity.UserAssignedIdentities.Keys + $uami.Id
                    $vm | Update-AzVmss -IdentityType $idType -IdentityId @( $ids ) -ErrorAction Stop | Out-Null
                }
                Write-Host "Successfully Updated VMSS Identity: $($vm.Name)"
                $audit.Status = "Success"
            }
            catch {
                Write-Error "Failed to Update VMSS Identity: $($vm.Name)"
                $audit.Status = "Failed"
                $audit.Message = $_.Exception.Message
            }

            # Save Audit
            $outputAudit += New-AuditObject @audit
        }
    }
}

# Set the Current Powershell Context back to the original
Set-AzContext -Context $oldCtx | Out-Null

# Return Output Audit History
return $outputAudit