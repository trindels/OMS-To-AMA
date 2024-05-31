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
        # Identity Configuration Not Prepared
        if ( $SystemAssigned ) {
            $allVm = $allVm | Where-Object { $_.Identity.Type -like '*SystemAssigned*' }
        }
        elseif ( $UserAssigned ) {
            $allVm = $allVm | Where-Object { $_.Identity.Type -like '*UserAssigned*' -or $_.Identity.UserAssignedIdentities.Keys -contains $IdentityId } 
        }
        # Unsupported Images
        $allVm = $allVm | Where-Object { $_.StorageProfile.ImageReference.Offer -notin $IgnoreImageNames } 
        # Agent Already Installed
        $allVm = $allVm | Where-Object { "$($_.Id)/extensions/AzureMonitor$($_.StorageProfile.OsDisk.OsType)Agent" -notin $_.Extensions.Id } 
        
        # Update Each In-Scope VM Identity
        foreach ( $vm in $allVm ) {
            try {
                $agentConfig = @{
                    VMName = $vm.Name
                    ResourceGroupName = $vm.ResourceGroupName
                    Location = $vm.Location
                    Name = "AzureMonitor$($vm.StorageProfile.OsDisk.OsType)Agent"
                    ExtensionType = "AzureMonitor$($vm.StorageProfile.OsDisk.OsType)Agent"
                    Publisher = "Microsoft.Azure.Monitor"
                    TypeHandlerVersion = "1.2"
                    EnableAutomaticUpgrade = $true
                }
                if ( $UserAssigned ) {
                    $agentConfig.Add( "SettingString", "{`"authentication`":{`"managedIdentity`":{`"identifier-name`":`"mi_res_id`",`"identifier-value`":`"$($uami.Id)`"}}}" )
                }
                Set-AzVMExtension @agentConfig -ErrorAction Stop | Out-Null
                Write-Host "Successfully Updated VM: $($vm.Name)"
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
        # Identity Configuration Not Prepared
        if ( $SystemAssigned ) {
            $allVmss = $allVmss | Where-Object { $_.Identity.Type -like '*SystemAssigned*' }
        }
        elseif ( $UserAssigned ) {
            $allVmss = $allVmss | Where-Object { $_.Identity.Type -like '*UserAssigned*' -and $_.Identity.UserAssignedIdentities.Keys -contains $IdentityId }
        }
        # Unsupported Images
        $allVmss = $allVmss | Where-Object { $_.VirtualMachineProfile.StorageProfile.ImageReference.Offer -notin $IgnoreImageNames } 
        # Agent Already Installed
        $allVmss = $allVmss | Where-Object { "AzureMonitor$($_.VirtualMachineProfile.StorageProfile.OsDisk.OsType)Agent" -notin $_.VirtualMachineProfile.ExtensionProfile.Extensions.Name } 

        # Update Each In-Scope VMSS Identity
        foreach ( $vm in $allVmss ) {
            try {
                $agentConfig = @{
                    #VMName = $vm.Name
                    #ResourceGroupName = $vm.ResourceGroupName
                    #Location = $vm.Location
                    Name = "AzureMonitor$($vm.VirtualMachineProfile.StorageProfile.OsDisk.OsType)Agent"
                    Type = "AzureMonitor$($vm.VirtualMachineProfile.StorageProfile.OsDisk.OsType)Agent"
                    Publisher = "Microsoft.Azure.Monitor"
                    TypeHandlerVersion = "1.2"
                    EnableAutomaticUpgrade = $true
                }
                if ( $UserAssigned ) {
                    $agentConfig.Add( "Setting", "{`"authentication`":{`"managedIdentity`":{`"identifier-name`":`"mi_res_id`",`"identifier-value`":`"$($uami.Id)`"}}}" )
                }
                $vm = $vm | Add-AzVmssExtension @agentConfig
                $vm | Update-AzVmss -ErrorAction Stop | Out-Null
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