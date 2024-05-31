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
if ( $UserAssigned ) {
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

# Get All Available Subscriptions
$allCtx = Get-AzContext -ListAvailable

foreach ( $subId in $SubscriptionId ) {
    # Validate Subscription Id
    $ctx = $allCtx | Where-Object { $_.Subscription.Id -eq $subId }
    if ( $null -ne $ctx ) {
        Set-AzContext -Context $ctx | Out-Null
    }
    else {
        Write-Error "Subscription '$subId' not available"
        break
    }

    
    if ( $Target -eq "All" -or $Target -eq "VM" ) {
        # Get all VMs
        $allVm = Get-AzVM

        # Filter Out of Scope VMs
        if ( $SystemAssigned ) {
            $allVm = $allVm | Where-Object { $_.Identity.Type -notlike 'SystemAssigned*' }
        }
        elseif ( $UserAssigned ) {
            $allVm = $allVm | Where-Object { $_.Identity.Type -notlike '*UserAssigned' -or $_.Identity.UserAssignedIdentities.Keys -notcontains $IdentityId }
        }
        $allVm = $allVm | Where-Object { $_.VirtualMachineProfile.StorageProfile.ImageReference.Offer -notin $IgnoreImageNames }
        
        # Update Each In-Scope VM Identity
        foreach ( $vm in $allVm ) {
            try {
                if ( $SystemAssigned ) {
                    if ( $null -eq $vm.Identity -or $vm.Identity.Type -eq "None" ) {
                        $vm | Update-AzVM -IdentityType SystemAssigned -ErrorAction Stop | Out-Null
                    }
                    else {
                        $vm | Update-AzVM -IdentityType SystemAssignedUserAssigned -IdentityId @( $vm.Identity.UserAssignedIdentities.Keys ) -ErrorAction Stop | Out-Null
                    }
                }
                elseif ( $UserAssigned ) {
                    $idType = $null -ne $vm.Identity -and $vm.Identity.Type -like "*SystemAssigned*" ? "SystemAssignedUserAssigned" : "UserAssigned"
                    $ids = $vm.Identity.UserAssignedIdentities.Keys + $uami.Id
                    $vm | Update-AzVM -IdentityType $idType -IdentityId @( $ids ) -ErrorAction Stop | Out-Null
                }
                Write-Host "Successfully Updated VM Identity: $($vm.Name)"
            }
            catch {
                Write-Error "Failed to Update VM Identity: $($vm.Name)"
            }
        }
    }

    if ( $Target -eq "All" -or $Target -eq "VMSS" ) {
        # Get all VM Scale Sets
        $allVmss = Get-AzVmss

        # Filter Out of Scope VMSS
        if ( $SystemAssigned ) {
            $allVmss = $allVmss | Where-Object { $_.Identity.Type -notlike '*SystemAssigned*' }
        }
        elseif ( $UserAssigned ) {
            $allVmss = $allVmss | Where-Object { $_.Identity.Type -notlike '*UserAssigned*' -or $_.Identity.UserAssignedIdentities.Keys -notcontains $IdentityId }
        }
        $allVmss = $allVmss | Where-Object { $_.VirtualMachineProfile.StorageProfile.ImageReference.Offer -notin $IgnoreImageNames }
        
        # Update Each In-Scope VMSS Identity
        foreach ( $vm in $allVmss ) {
            try {
                if ( $SystemAssigned ) {
                    if ( $null -eq $vm.Identity -or $vm.Identity.Type -eq "None" ) {
                        $vm | Update-AzVmss -IdentityType SystemAssigned -ErrorAction Stop | Out-Null
                    }
                    else {
                        $vm | Update-AzVmss -IdentityType SystemAssignedUserAssigned -IdentityId @( $vm.Identity.UserAssignedIdentities.Keys ) -ErrorAction Stop | Out-Null
                    }
                }
                elseif ( $UserAssigned ) {
                    $idType = $null -ne $vm.Identity -and $vm.Identity.Type -like "*SystemAssigned*" ? "SystemAssignedUserAssigned" : "UserAssigned"
                    $ids = $vm.Identity.UserAssignedIdentities.Keys + $uami.Id
                    $vm | Update-AzVmss -IdentityType $idType -IdentityId @( $ids ) -ErrorAction Stop | Out-Null
                }
                Write-Host "Successfully Updated VMSS Identity: $($vm.Name)"
            }
            catch {
                Write-Error "Failed to Update VMSS Identity: $($vm.Name)"
                Write-Error "$($_.Exception.Message)"
            }
        }
    }
}

# Set the Current Powershell Context back to the original
Set-AzContext -Context $oldCtx | Out-Null