$ProdSubsPhaseA = @(
    "325841e1-5f9d-4828-9042-02c0afe1fa43",
    "c897867e-5a88-4dda-a0a7-fbab47742925",
    "dadca81d-8560-4826-acae-3be792ac93e9",
    "354c53a6-45f8-49c8-ad6e-4cbd5fc578f6"
)

$VaultReport = @()
 
foreach ($sub in $ProdSubsPhaseA) {
 
    Set-AzContext -SubscriptionId $sub | Out-Null
    Write-Host "Scanning Subscription: $sub" -ForegroundColor Yellow
 
    $vaults = Get-AzRecoveryServicesVault
 
    foreach ($vault in $vaults) {
 
        $apiVersion = "2023-02-01"
        $uri = "/subscriptions/$sub/resourceGroups/$($vault.ResourceGroupName)/providers/Microsoft.RecoveryServices/vaults/$($vault.Name)?api-version=$apiVersion"
 
        $vaultRest = Invoke-AzRestMethod -Method GET -Path $uri
        $vaultJson = ($vaultRest.Content | ConvertFrom-Json)
 
        # Immutability
        $immutability = $vaultJson.properties.securitySettings.immutabilitySettings.state
        if (-not $immutability) { $immutability = "NotConfigured" }
 
        # Soft Delete
        $softDelete = $vaultJson.properties.securitySettings.softDeleteSettings.softDeleteState
        $retention  = $vaultJson.properties.securitySettings.softDeleteSettings.softDeleteRetentionPeriodInDays
 
        if (-not $softDelete) { $softDelete = "Disabled" }
        if (-not $retention)  { $retention  = "Unknown" }
 
        $VaultReport += [PSCustomObject]@{
            SubscriptionName   = (Get-AzContext).Subscription.Name
            SubscriptionId     = $sub
            VaultName          = $vault.Name
            ResourceGroup      = $vault.ResourceGroupName
            Location           = $vault.Location
            ImmutabilityState  = $immutability
            SoftDeleteState    = $softDelete
            SoftDeleteRetentionDays = $retention
        }
    }
}
 
$VaultReport | Export-Csv "$OutputFolder\VaultInventory.csv" -NoTypeInformation