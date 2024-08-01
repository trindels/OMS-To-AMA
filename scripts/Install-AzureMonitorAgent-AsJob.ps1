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

foreach ( $subId in $SubscriptionId ) {
    # Validate Subscription Id
    try {
        Set-AzContext -Subscription $subId -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Error "Subscription: '$subId': $($_.Exception.Message)"
        continue
    }
    
    if ( $Target -eq "All" -or $Target -eq "VM" ) {
        # Get all VMs
        $allVm = Get-AzVM -Status

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
            # Auditing
            $audit = @{
                Action = ( $SystemAssigned ? "Add AMA with System Identity" : "Add AMA with User Assigned Identity" )
                SubscriptionId = $subId
                ResourceGroupName = $vm.ResourceGroupName
                ResourceType = $vm.Type
                ResourceName = $vm.Name
                Status = "Unchanged"
                Message = ""
            }

            # Update
            try {
                if ( $vm.PowerState -eq "VM running" ) {
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
                    $job = Set-AzVMExtension @agentConfig -AsJob -ErrorAction Stop
                    Write-Host "Started Updating VM Extension: $($vm.Name)"
                    $audit.Status = "Pending"
                    $audit.Message = $job.Id
                } else {
                    Write-Host "Skipping VM Extension Update: $($vm.Name) (Offline)"
                    $audit.Status = "Skipped"
                    $audit.Message = "VM is Offline"
                }
            }
            catch {
                Write-Error "Failed to Update VM Extension: $($vm.Name)"
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
            # Auditing
            $audit = @{
                Action = ( $SystemAssigned ? "Add AMA with System Identity" : "Add AMA with User Assigned Identity" )
                SubscriptionId = $subId
                ResourceGroupName = $vm.ResourceGroupName
                ResourceType = $vm.Type
                ResourceName = $vm.Name
                Status = "Unchanged"
                Message = ""
            }

            # Update
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
                $job = Update-AzVmss -VirtualMachineScaleSet $vm -AsJob -ErrorAction Stop
                Write-Host "Started Updating VMSS AMA Extension: $($vm.Name)"
                $audit.Status = "Pending"
                $audit.Message = "$($job.Id)"
            }
            catch {
                Write-Error "Failed to Update VMSS AMA Extension: $($vm.Name)"
                $audit.Status = "Failed"
                $audit.Message = $_.Exception.Message
            }

            # Save Audit
            $outputAudit += New-AuditObject @audit
        }
    }

    if ( $Target -eq "All" -or $Target -eq "Arc" ) {
        # Get all VM Scale Sets
        $allArc = Get-AzConnectedMachine

        # Update Each In-Scope VMSS Identity
        foreach ( $vm in $allArc ) {
            # Auditing
            $audit = @{
                Action = "Add AMA with System Identity"
                SubscriptionId = $subId
                ResourceGroupName = $vm.ResourceGroupName
                ResourceType = $vm.Type
                ResourceName = $vm.Name
                Status = "Unchanged"
                Message = ""
            }

            # Update
            try {
                $osType = $vm.OsType.substring(0,1).ToUpper() + $vm.OsType.substring(1).ToLower()
                $agentConfig = @{
                    MachineName = $vm.Name
                    ResourceGroupName = $vm.ResourceGroupName
                    Location = $vm.Location
                    Name = "AzureMonitor$($osType)Agent"
                    ExtensionType = "AzureMonitor$($osType)Agent"
                    Publisher = "Microsoft.Azure.Monitor"
                    EnableAutomaticUpgrade = $true
                }
                if ( $UserAssigned ) {
                    $agentConfig.Add( "Setting", "{`"authentication`":{`"managedIdentity`":{`"identifier-name`":`"mi_res_id`",`"identifier-value`":`"$($uami.Id)`"}}}" )
                }
                $job = New-AzConnectedMachineExtension @agentConfig -AsJob -ErrorAction Stop
                Write-Host "Started Updating Arc AMA Extension: $($vm.Name)"
                $audit.Status = "Pending"
                $audit.Message = "$($job.Id)"
            }
            catch {
                Write-Error "Failed to Update Arc AMA Extension: $($vm.Name)"
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

# Pending Job Status Check
$jobsRemaining = $outputAudit | Where-Object { $_.Status -eq "Pending" }
Write-Host "Check Pending Jobs." -NoNewline
while( $jobsRemaining.Count -gt 0 ) {
    # Wait for 60 seconds
    Start-Sleep -Seconds 60
    Write-Host "." -NoNewline

    # Loop Through Pending Jobs
    foreach ( $j in ($outputAudit | Where-Object { $_.Status -eq "Pending" }) ) {
        $job = Get-Job -Id $j.Message
        if ( $job.State -eq "Completed" ) {
            $j.Status = "Success"
            $j.Message = ""
        } elseif ( $job.State -notin @("NotStarted", "Running", "Completed") ) {
            $j.Status = "Failed"
            $j.Message = $job.Error[0].Exception.Message
        }
    }
    
    # Are their remaining jobs?
    $jobsRemaining = $outputAudit | Where-Object { $_.Status -eq "Pending" }
}
Write-Host "Complete!"

# Return Output Audit History
return $outputAudit