$policyDefinitions = @(
    "/providers/Microsoft.Authorization/policyDefinitions/d367bd60-64ca-4364-98ea-276775bddd94",
    "/providers/Microsoft.Authorization/policyDefinitions/516187d4-ef64-4a1b-ad6b-a7348502976c",
    "/providers/Microsoft.Authorization/policyDefinitions/ae8a10e6-19d6-44a3-a02d-a2bdfc707742",
    "/providers/Microsoft.Authorization/policyDefinitions/637125fd-7c39-4b94-bb0a-d331faf333a9",
    "/providers/Microsoft.Authorization/policyDefinitions/59c3d93f-900b-4827-a8bd-562e7b956e7c",
    "/providers/Microsoft.Authorization/policyDefinitions/98569e20-8f32-4f31-bf34-0e91590ae9d3",
    "/providers/Microsoft.Authorization/policyDefinitions/845857af-0333-4c5d-bbbc-6076697da122",
    "/providers/Microsoft.Authorization/policyDefinitions/94f686d6-9a24-4e19-91f1-de937dc171a4",
    "/providers/Microsoft.Authorization/policyDefinitions/2ea82cdd-f2e8-4500-af75-67a2e084ca74",
    "/providers/Microsoft.Authorization/policyDefinitions/eab1f514-22e3-42e3-9a1f-e1dc9199355c",
    "/providers/Microsoft.Authorization/policyDefinitions/d55b81e1-984f-4a96-acab-fae204e3ca7f",
    "/providers/Microsoft.Authorization/policyDefinitions/89ca9cc7-25cd-4d53-97ba-445ca7a1f222",
    "/providers/Microsoft.Authorization/policyDefinitions/2fea0c12-e7d4-4e03-b7bf-c34b2b8d787d",
    "/providers/Microsoft.Authorization/policyDefinitions/af0082fd-fa58-4349-b916-b0e47abb0935",
    "/providers/Microsoft.Authorization/policyDefinitions/08a4470f-b26d-428d-97f4-7e3e9c92b366",
    "/providers/Microsoft.Authorization/policyDefinitions/84cfed75-dfd4-421b-93df-725b479d356a",
    "/providers/Microsoft.Authorization/policyDefinitions/09963c90-6ee7-4215-8d26-1cc660a1682f",
    "/providers/Microsoft.Authorization/policyDefinitions/f91991d1-5383-4c95-8ee5-5ac423dd8bb1",
    "/providers/Microsoft.Authorization/policyDefinitions/ddca0ddc-4e9d-4bbb-92a1-f7c4dd7ef7ce",
    "/providers/Microsoft.Authorization/policyDefinitions/04754ef9-9ae3-4477-bf17-86ef50026304",
    "/providers/Microsoft.Authorization/policyDefinitions/2227e1f1-23dd-4c3a-85a9-7024a401d8b2",
    "/providers/Microsoft.Authorization/policyDefinitions/63d03cbd-47fd-4ee1-8a1c-9ddf07303de0",
    "/providers/Microsoft.Authorization/policyDefinitions/65503269-6a54-4553-8a28-0065a8e6d929",
    "/providers/Microsoft.Authorization/policyDefinitions/3592ff98-9787-443a-af59-4505d0fe0786",
    "/providers/Microsoft.Authorization/policyDefinitions/2ada9901-073c-444a-9a9a-91865174f0aa"
)
$count = 0
foreach ( $id in $policyDefinitions ) {
    $def = Get-AzPolicyDefinition -Id $id
    $cleanDisplayName = $def.DisplayName -replace '[^a-zA-Z0-9-\s]', ''
    $count++
    New-Item -ItemType Directory -Path "$count - $cleanDisplayName"
    ConvertTo-Json $def.Parameter -Depth 50 | Out-File "$count - $cleanDisplayName\parameter.json" -Force
    ConvertTo-Json $def.PolicyRule -Depth 50 | Out-File "$count - $cleanDisplayName\policyRule.json" -Force
}
