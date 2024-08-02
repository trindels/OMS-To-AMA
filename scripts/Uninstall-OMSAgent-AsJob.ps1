param(
    [Parameter(Mandatory=$false)]
    [string[]]
    $SubscriptionId = $null,

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

        # $allVm = $allVm | Where-Object { `
        #     "$($_.Id)/extensions/MicrosoftMonitoringAgent" -in $_.Extensions.Id `
        #     -or "$($_.Id)/extensions/OmsAgentForLinux" -in $_.Extensions.Id `
        # }
        
        # Update Each In-Scope VM Identity
        foreach ( $vm in $allVm ) {
            # Auditing
            $audit = @{
                Action = "Uninstall OMS/MMA Agent"
                SubscriptionId = $subId
                ResourceGroupName = $vm.ResourceGroupName
                ResourceType = $vm.Type
                ResourceName = $vm.Name
                Status = "Unchanged"
                Message = ""
            }


            # Update
            try {
                $vmExt = Get-AzVmExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name `
                    | Where-Object { $_.ExtensionType -in @("MicrosoftMonitoringAgent", "OmsAgentForLinux") }
                if ( $vmExt.Count -eq 0 ) {
                    $audit.Message = "No Extensions to Remove."
                }  
                elseif ( $vm.PowerState -eq "VM running" ) {
                    $job = $vmExt | Remove-AzVMExtension -Force -AsJob -ErrorAction Stop
                    Write-Host "Removing OMS/MMA VM Extension: $($vm.Name)"
                    $audit.Status = "Pending"
                    $audit.Message = "$($job.Id)"
                } else {
                    Write-Host "Skipping OMS/MMA VM Extension Removal: $($vm.Name) (Offline)"
                    $audit.Status = "Skipped"
                    $audit.Message = "VM is Offline"
                }
            }
            catch {
                Write-Error "Failed to Remove OMS/MMA VM Extension: $($vm.Name)"
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
        $allVmss = $allVmss | Where-Object { `
            "$($_.Id)/extensions/MicrosoftMonitoringAgent" -in $_.Extensions.Id `
            -or "$($_.Id)/extensions/OmsAgentForLinux" -in $_.Extensions.Id `
        }

        # Update Each In-Scope VMSS Identity
        foreach ( $vm in $allVmss ) {
            # Auditing
            $audit = @{
                Action = "Uninstall OMS/MMA Agent"
                SubscriptionId = $subId
                ResourceGroupName = $vm.ResourceGroupName
                ResourceType = $vm.Type
                ResourceName = $vm.Name
                Status = "Unchanged"
                Message = ""
            }

            # Update
            try {
                if ( $vm.VirtualMachineProfile.StorageProfile.OsDisk.OsType -eq "Linux" ) {
                    $agentName = "OmsAgentForLinux"
                } elseif ( $vm.VirtualMachineProfile.StorageProfile.OsDisk.OsType -eq "Windows" ) {
                    $agentName = "MicrosoftMonitoringAgent"
                } else {
                    $agentName = ""
                }

                $vm = $vm | Remove-AzVmssExtension -Name $agentName -ErrorAction Stop
                $job = Update-AzVmss -VirtualMachineScaleSet $vm -AsJob -ErrorAction Stop
                Write-Host "Removing OMS/MMA VMSS Extension: $($vm.Name)"
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
            $j.Message = "$($job.StatusMessage)\n$($job.Debug)"
        }
    }
    
    # Are their remaining jobs?
    $jobsRemaining = $outputAudit | Where-Object { $_.Status -eq "Pending" }
}
Write-Host "Complete!"

# Return Output Audit History
return $outputAudit