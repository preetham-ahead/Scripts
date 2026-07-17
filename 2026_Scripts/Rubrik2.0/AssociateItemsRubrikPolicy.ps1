############################################################
# Step 3: Associate Non-Prod VMs to RubrikCutover Policy
# PowerShell 5.1 compatible (Invoke-RestMethod)
############################################################

$DryRun = $false
 
$VMs = Import-Csv $VMMappingCSV
$Step3Results = @()
 
foreach ($vm in $VMs) {
    try {
        # Resolve Subscription ID
        $sub = Get-AzSubscription -SubscriptionName $vm.SubscriptionName -ErrorAction Stop
        if (-not $sub) { throw "Subscription '$($vm.SubscriptionName)' not found" }
        $subId = $sub.Id
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
 
        # Vault context
        $vaultObj = Get-AzRecoveryServicesVault -Name $vm.VaultName -ErrorAction Stop
        $vaultRG = $vaultObj.ResourceGroupName
        Set-AzRecoveryServicesVaultContext -Vault $vaultObj -ErrorAction Stop
 
        # Skip if already on RubrikCutover
        if ($vm.CurrentPolicy -eq "RubrikCutover") {
            $action = "Already on RubrikCutover"
            $Step3Results += [PSCustomObject]@{
                SubscriptionName = $vm.SubscriptionName
                SubscriptionId   = $subId
                VaultName        = $vm.VaultName
                VaultRG          = $vaultRG
                VMName           = $vm.VMName
                CurrentPolicy    = $vm.CurrentPolicy
                Action           = $action
            }
            continue
        }
 
        # Construct container & item names
        $containerName = "iaasvmcontainer;iaasvmcontainerv2;$($vm.ResourceGroupName);$($vm.VMName)"
        $itemName = "vm;iaasvmcontainerv2;$($vm.ResourceGroupName);$($vm.VMName)"
 
        # Full REST URL with api-version
        $url = "https://management.azure.com/subscriptions/$subId/resourceGroups/$vaultRG/providers/Microsoft.RecoveryServices/vaults/$($vm.VaultName)/backupFabrics/Azure/protectionContainers/$containerName/protectedItems/$itemName?api-version=2023-02-01"
 
        # Payload JSON (policyId only)
        $policyId = "/subscriptions/$subId/resourceGroups/$vaultRG/providers/Microsoft.RecoveryServices/vaults/$($vm.VaultName)/backupPolicies/RubrikCutover"
        $body = @{
            properties = @{
                policyId = $policyId
            }
        } | ConvertTo-Json -Depth 10 -Compress
 
        if ($DryRun) {
            $action = "Dry Run: Would associate $($vm.VMName)"
        }
        else {
            # Get Bearer token for Azure REST
            $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
            $headers = @{
                "Authorization" = "Bearer $token"
                "Content-Type"  = "application/json"
            }
 
            # Invoke REST method
            $response = Invoke-RestMethod -Method Put -Uri $url -Headers $headers -Body $body
 
            $action = "Associated"
        }
    }
    catch {
        # Capture error message
        $rawError = $_.Exception.Message
        if ($_.Exception.InnerException -and $_.Exception.InnerException.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.InnerException.Response.GetResponseStream())
            $rawError = $reader.ReadToEnd()
        }
        $action = "Failed: $rawError"
    }
 
    # Log results
    $Step3Results += [PSCustomObject]@{
        SubscriptionName = $vm.SubscriptionName
        SubscriptionId   = $subId
        VaultName        = $vm.VaultName
        VaultRG          = $vaultRG
        VMName           = $vm.VMName
        CurrentPolicy    = $vm.CurrentPolicy
        Action           = $action
    }
}
 
# Export log
$Step3Results | Export-Csv $Step3Log -NoTypeInformation
Write-Host ""
Write-Host "Step 3 completed. Results logged to $Step3Log" -ForegroundColor Cyan