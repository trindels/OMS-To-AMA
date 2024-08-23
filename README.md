# OMS-To-AMA - Basic Process
1. Determine Workspaces where Logs are currently collected
2. Create Data Collection Rules
3. Establish Identity to Leverage
    - User Assigned Managed Identity - Microsoft Recommended for At-Scale Deployments
    - System Assigned Managed Identity
4. Deploy Managed Identity Configuration to All Azure VMs
    - User Assigned Managed Identity
    - System Assigned Managed Identity
5. (Non-Azure Servers Only) Deploy Azure Arc for Servers
6. Deploy Azure Monitor Agent Extension to Servers
    - User Assigned Managed Idenity for Azure Virtual Machines
    - System Assigned Managed Identity for Azure Virtual Machines
    - System Assigned Managed Identity for Non-Azure Virtual Machines
7. Associate Data Collection Rules to Resources
    - Azure Virtual Machines
    - Non-Azure Servers

# Defender for SQL - Basic Process
1. Enable Auto Detection for SQL IaaS Extension Installation
2. Determine Workspace(s) where Logs will be collected
3. Determine List of SQL Servers in Scope
4. (If Not Completed) Deploy Azure Monitor Agent to Servers
5. Deploy Defender for SQL Extension
6. Create Defender for SQL Data Collection Rule
7. Associate SQL Servers with the Defender for SQL DCR
