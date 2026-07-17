$DryRun = $false
 
$ProdSubsPhaseA = @(
    "354c53a6-45f8-49c8-ad6e-4cbd5fc578f6"
)
 
$PolicyName = "RubrikCutover"
$apiVersion = "2023-02-01"
 
# Required retention timestamp (must match existing schedule)
$BackupTimeUtc = "2023-01-01T01:00:00Z"
 
# Vault inventory CSV must contain:
# SubscriptionId,VaultName,ResourceGroup
$Vaults = Import-Csv $VaultInventoryCSV |
    Where-Object { $ProdSubsPhaseA -contains $_.SubscriptionId }
 
# ============================================================
# AUTH TOKEN (USED FOR ALL REST CALLS)
# ============================================================

 
# ============================================================
# PROCESS VAULTS
# ============================================================
 
foreach ($vault in $Vaults) {
 
    Write-Host "`nChecking vault: $($vault.VaultName)" -ForegroundColor Yellow
 
    Set-AzContext -SubscriptionId $vault.SubscriptionId | Out-Null
 
    # ✅ ARM TOKEN – MUST BE HERE
    $context  = Get-AzContext
    $tenantId = $context.Tenant.Id
 
    $token = Get-AzAccessToken `
        -TenantId $tenantId `
        -ResourceTypeName Arm
 
    $Headers = @{
        "Authorization" = "Bearer $($token.Token)"
        "Content-Type"  = "application/json"
        "If-Match"      = "*"
    }
 
    $vaultObj = Get-AzRecoveryServicesVault `
        -Name $vault.VaultName `
        -ResourceGroupName $vault.ResourceGroup `
        -ErrorAction Stop
 
    Set-AzRecoveryServicesVaultContext -Vault $vaultObj
 
    $policy = Get-AzRecoveryServicesBackupProtectionPolicy `
        -Name $PolicyName `
        -ErrorAction SilentlyContinue
 
    if (-not $policy) {
        Write-Host "Vault does NOT have $PolicyName → skip" -ForegroundColor DarkGray
        continue
    }
 
    Write-Host "Vault has $PolicyName → enforcing policy" -ForegroundColor Cyan
 
    $fullUri = "https://management.azure.com/subscriptions/$($vault.SubscriptionId)/resourceGroups/$($vault.ResourceGroup)/providers/Microsoft.RecoveryServices/vaults/$($vault.VaultName)/backupPolicies/RubrikCutover?api-version=$apiVersion"
 
    # ========================================================
    # GET EXISTING POLICY
    # ========================================================
 
    $policyJson = Invoke-RestMethod `
        -Method GET `
        -Uri $fullUri `
        -Headers $Headers
 
    # Ensure retentionPolicy exists
    if (-not $policyJson.properties.retentionPolicy) {
        $policyJson.properties | Add-Member -MemberType NoteProperty -Name retentionPolicy -Value @{}
    }
 
    # ========================================================
    # INSTANT RESTORE
    # ========================================================
    $policyJson.properties.instantRpRetentionRangeInDays = 1
 
    # ========================================================
    # DAILY RETENTION (7 DAYS)
    # ========================================================
    $policyJson.properties.retentionPolicy.dailySchedule = @{
        retentionTimes    = @($BackupTimeUtc)
        retentionDuration = @{
            count        = 7
            durationType = "Days"
        }
    }
 
    # ========================================================
    # WEEKLY RETENTION (REMOVE IF PRESENT)
    # ========================================================
    if ($policyJson.properties.retentionPolicy.PSObject.Properties.Name -contains "weeklySchedule") {
        $policyJson.properties.retentionPolicy.PSObject.Properties.Remove("weeklySchedule")
    }
 
    # ========================================================
    # MONTHLY RETENTION (DAY 1, 1 MONTH)
    # ========================================================
    $policyJson.properties.retentionPolicy.monthlySchedule = @{
        retentionScheduleFormatType = "Daily"
        retentionScheduleDaily      = @{
            daysOfTheMonth = @(
                @{ date = 1; isLast = $false }
            )
        }
        retentionTimes              = @($BackupTimeUtc)
        retentionDuration           = @{
            count        = 1
            durationType = "Months"
        }
    }
 
    # ========================================================
    # YEARLY RETENTION
    # JAN 1 + LAST DAY OF DECEMBER, 10 YEARS
    # ========================================================
    $policyJson.properties.retentionPolicy.yearlySchedule = @{
        retentionScheduleFormatType = "Daily"
        monthsOfYear                = @("January", "December")
        retentionScheduleDaily      = @{
            daysOfTheMonth = @(
                @{ date = 1; isLast = $false },   # Jan 1
                @{ date = 0; isLast = $true }     # Dec last day
            )
        }
        retentionTimes              = @($BackupTimeUtc)
        retentionDuration           = @{
            count        = 10
            durationType = "Years"
        }
    }
 
    # ========================================================
    # ARCHIVE TIERING (RECOMMENDED)
    # ========================================================
    $policyJson.properties.tieringPolicy = @{
        archivedRP = @{
            tieringMode = "TierRecommended"
        }
    }
 
    $Body = $policyJson | ConvertTo-Json -Depth 100
 
    # ========================================================
    # UPDATE (PUT WITH IF-MATCH)
    # ========================================================
    try {
    $policyJson = Invoke-RestMethod `
        -Method GET `
        -Uri $fullUri `
        -Headers $Headers
    }
    catch {
        Write-Host "FAILED to GET policy from vault $($vault.VaultName)" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor DarkRed
        continue
    }
}
 
Write-Host "`nAll vaults processed." -ForegroundColor Cyan