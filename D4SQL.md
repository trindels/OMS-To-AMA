# Defender for SQL Implementation (At Scale)

## 0. Prerequisite Information
```powershell
# Required Modules
Import-Module @(
    "Az.Accounts"
    "Az.Resources"
    "Az.ResourceGraph"
    "Az.Compute"
    "Az.ConnectedMachine"
    "Az.OperationalInsights"
    "Az.Monitor"
)

# List of Subscription IDs In Scope
$subscriptionIds = @( "00000000-0000-0000-0000-000000000000" )
```

## 1. Enable Auto Detection for SQL IaaS Extension Installation
The SQL IaaS Extension for SQL Server Virtual Machines is a required component for Defender for SQL to function.
(Source: https://learn.microsoft.com/en-us/azure/defender-for-cloud/defender-for-sql-usage?WT.mc_id=Portal-Microsoft_Azure_Security#prerequisites-for-enabling-defender-for-sql-on-non-azure-machines).
The Auto Detection is enabled through the BulkRegistration Feature of the Microsoft.SqlVirtualMachine Resource Provider.

This script can be used to enable this feature on 1 to many subscriptions:
```powershell
# Register Auto Detection Feature
foreach ( $subId in $SubscriptionIds ) {
    try {
        Set-AzContext -Subscription $subId -ErrorAction Stop
        Register-AzResourceProvider -ProviderNamespace Microsoft.SqlVirtualMachine -ErrorAction Stop
        Register-AzProviderFeature -FeatureName BulkRegistration -ProviderNamespace Microsoft.SqlVirtualMachine -ErrorAction Stop
    } catch {
        Write-Host "$($subId) - SQL IaaS Agent Extension - Auto Registration Not Enabled!" -ForegroundColor Red
    }
}
```

Source: https://learn.microsoft.com/en-us/azure/azure-sql/virtual-machines/windows/sql-agent-extension-automatic-registration-all-vms?view=azuresql&tabs=azure-cli

## 2. Determine List of SQL Servers in Scope
Since SQL IaaS Agent Extension is required for Defender for SQL to function, we can query the list of servers
with this agent.  An Azure Resource Graph query would be the easiest method to do this across a large environment.

Select the appropriate ARG Query based on your scope of servers:
```powershell
# Azure Resource Graph Query - Azure VMs Only
$argQuery = @"
    resources
    | where type == "microsoft.compute/virtualmachines/extensions"
    | extend extensionType = properties.type
    | where extensionType == "SqlIaaSAgent"
    | extend vmResourceId = strcat_array(array_split(split(id,"/"),9)[0],"/")
    | project vmResourceId, subscriptionId, resourceGroup, vmName = tostring(split(id,"/")[8]), location
"@
```

```powershell
# Azure Resource Graph Query - Arc for Servers Only
$argQuery = @"
    resources
    | where type == "microsoft.hybridcompute/machines/extensions"
    | extend extensionType = properties.type
    | where extensionType == "WindowsAgent.SqlServer"
    | extend vmResourceId = strcat_array(array_split(split(id,"/"),9)[0],"/")
    | project vmResourceId, subscriptionId, resourceGroup, vmName = tostring(split(id,"/")[8]), location
"@
```

```powershell
# Azure Resource Graph Query - Azure + Arc SQL Servers with SQL IaaS Agent Extension
$argQuery = @"
    resources
    | where type == "microsoft.compute/virtualmachines/extensions" or type == "microsoft.hybridcompute/machines/extensions"
    | extend extensionType = properties.type
    | where extensionType == "SqlIaaSAgent" or extensionType == "WindowsAgent.SqlServer"
    | extend vmResourceId = strcat_array(array_split(split(id,"/"),9)[0],"/")
    | project vmResourceId, subscriptionId, resourceGroup, vmName = tostring(split(id,"/")[8]), location
"@
```

Once you have determined your ARG Query scope, run this command to execute your query:
```powershell
# Execute Azure Resource Graph Query
$argResults = Search-AzGraph -UseTenantScope -Query $argQuery
```

## 3. (If Not Completed) Deploy Azure Monitor Agent to Servers
Instructions coming soon!

## 4. Deploy Defender for SQL Extension
The Defender for SQL Agent Extension is required to collect logs from SQL transport those logs to the
Azure Monitor Agent service.

```powershell
# Get VMs from ARG Query - (Optional) Filter Your List of VMs
$vmsWithSql = $argResults # | Where-Object { $_.subscriptionId -notIn $subscriptionIds }

# Create a Subscription Scope (for efficient loop control)
$agentSubScope = $vmsWithSql | Select-Object subscriptionId -Unique

foreach( $subId in $agentSubScope.subscriptionId ) {
    try {
        # Switch Subscription
        Set-AzContext -Subscription $subId -ErrorAction Stop

        # Install the Defender for Sql Agent Extension on VM
        foreach ( $vm in $vmsWithSql ) {
            try {
                if ( $vm.vmResourceId -like "*microsoft.compute*" ) {
                    Set-AzVmExtension -VMName $vm.vmName `
                        -ResourceGroupName $vm.resourceGroup `
                        -Name "MicrosoftDefenderForSQL" `
                        -Publisher "Microsoft.Azure.AzureDefenderForSQL" `
                        -ExtensionType "AdvancedThreatProtection.Windows" `
                        -TypeHandlerVersion "2.0" `
                        -EnableAutomaticUpgrade $true `
                        -AsJob `
                        -ErrorAction Stop
                } elseif ( $vm.vmResourceId -like "*microsoft.hybridcompute*" ) {
                    New-AzConnectedMachineExtension -MachineName $vm.vmName `
                        -ResourceGroupName $vm.resourceGroup `
                        -Location $vm.location `
                        -Name "MicrosoftDefenderForSQL" `
                        -Publisher "Microsoft.Azure.AzureDefenderForSQL" `
                        -ExtensionType "AdvancedThreatProtection.Windows" `
                        -TypeHandlerVersion "2.0" `
                        -EnableAutomaticUpgrade `
                        -AutoUpgradeMinorVersion `
                        -AsJob `
                        -ErrorAction Stop
                }
            } catch {
                Write-Host "$($subId) - $($vm.resourceGroup) - $($vm.vmName) - Cannot Deploy Extension!" -ForegroundColor Red
            }
        }
    } catch {
        Write-Host "$($subId) - Cannot Switch to Context." -ForegroundColor Red
    }
}
```

## 5. Create Defender for SQL Data Collection Rule
A Data Collection Rule is a set of instructions that inform the Azure Monitor Agent the data to collect from
an Azure Virtual Machine or Azure Arc for Servers resource and identifies which Log Analytics Workspace to deliver
the information.

Determine Workspace referenced in the Data Collection Rule:

```powershell
# Log Analytics Workspace - Resource Information 
$lawSubId = "00000000-0000-0000-0000-000000000000"
$lawRgName = "resourceGroupName"
$lawName = "lawName"

# Get Log Analytics Workspace
try {
    Set-AzContext -Subscription $lawSubId -ErrorAction Stop
    $law = Get-AzOperationalInsightsWorkspace -ResourceGroupName $lawRgName -Name $lawName
} catch {
    Write-Host "$($lawName) - Not Found in Resource Group $($lawRgName) in Subscription $($lawSubId)" -ForegroundColor Red
}
```

Create the Defender for SQL Data Collection Rule:
```powershell
# D4SQL Data Collection Rule - Resource Information
$dcrSubId = "00000000-0000-0000-0000-000000000000"
$dcrRgName = "resourceGroupName"
$dcrName = "D4SQL-$($law.CustomerId.Guid -Replace '-', '')-DCR"
$dcrLocation = "eastus2"

$d4sqlDcrSecurityResearch = $false

# D4SQL Data Collection Rule Configuration
$dcrDataSource = New-AzExtensionDataSourceObject `
    -Name "MicrosoftDefenderForSQL" `
    -ExtensionName "MicrosoftDefenderForSQL" `
    -ExtensionSetting @{ "enableCollectionOfSqlQueriesForSecurityResearch" = $d4sqlDcrSecurityResearch } `
    -Stream @(
        "Microsoft-DefenderForSqlAlerts"
        "Microsoft-DefenderForSqlLogins"
        "Microsoft-DefenderForSqlTelemetry"
        "Microsoft-DefenderForSqlScanEvents"
        "Microsoft-DefenderForSqlScanResults"
    )
$dcrDestination = New-AzLogAnalyticsDestinationObject `
    -Name "LogAnalyticsDest" `
    -WorkspaceResourceId $law.ResourceId
$dcrDataFlow = New-AzDataFlowObject `
    -Destination @( $dcrDestination.Name ) `
    -Stream $dcrDataSource.Stream

# Create D4SQL Data Collection Rule
try {
    $d4sqlDcr = New-AzDataCollectionRule `
        -SubscriptionId = $dcrSubId `
        -ResourceGroupName = $dcrRgName `
        -Name = $dcrName `
        -Location = $dcrLocation `
        -DataSourceExtension = @( $dcrDataSource ) `
        -DestinationLogAnalytic = @( $dcrDestination ) `
        -DataFlow = @( $dcrDataFlow ) `
        -Tag = @{ "createdBy" = "MicrosoftDefenderForSQL" } `
        -ErrorAction Stop
} catch {
    Write-Host "$($dcrName) - Not Created in Resource Group $($dcrRgName) in Subscription $($dcrSubId)" -ForegroundColor Red
}
```

## 6. Associate SQL Servers with the Defender for SQL DCR
To send Defender for SQL information to Defender for Cloud, the D4SQL Data Collection Rule must be associated
with the Azure Virtual Machines and/or Azure Arc for Server resources.

```powershell
# Get the D4SQL Data Collection Rule Object
$d4sqlDcr = Get-AzDataCollectionRule -Name $dcrName -ResourceGroupName $dcrRgName -SubscriptionId $dcrSubId

# Get VMs from ARG Query - (Optional) Filter Your List of VMs
$vmsWithSql = $argResults # | Where-Object { $_.subscriptionId -notIn $subscriptionIds }

# Associate Virtual Machines
foreach ( $vmResId in $vmsWithSql.vmResourceId ) {
    try {
        New-AzDataCollectionRuleAssociation `
            -AssociationName  "D4SQL-Association" `
            -ResourceUri $vmResId `
            -DataCollectionRuleId $d4sqlDcr.Id
    } catch {
        Write-Host "$($vmResId) - Cannot Associate D4SQL DCR" -ForegroundColor Red
    }
}
```