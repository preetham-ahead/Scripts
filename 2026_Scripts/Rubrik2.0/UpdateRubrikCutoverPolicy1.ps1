$DryRun = $false

$TargetPolicyName = "RubrikCutover"
$ApiVersion = "2023-02-01"

$ProdSubsPhaseA = @(
    "c897867e-5a88-4dda-a0a7-fbab47742925"
)

$ProdVaultsPhaseA = Import-Csv $VaultInventoryCSV |
    Where-Object { $ProdSubsPhaseA -contains $_.SubscriptionId }

foreach ($vault in $ProdVaultsPhaseA) {

    Write-Host "`nProcessing vault: $($vault.VaultName)" -ForegroundColor Yellow

    # -----------------------------
    # SUB + VAULT CONTEXT
    # -----------------------------
    Set-AzContext -SubscriptionId $vault.SubscriptionId | Out-Null

    $vaultObj = Get-AzRecoveryServicesVault -Name $vault.VaultName -ErrorAction Stop
    Set-AzRecoveryServicesVaultContext -Vault $vaultObj

    # -----------------------------
    # CHECK POLICY EXISTENCE
    # -----------------------------
    $policy = Get-AzRecoveryServicesBackupProtectionPolicy `
        -Name $TargetPolicyName `
        -ErrorAction SilentlyContinue

    # ============================================================
    # CREATE POLICY IF MISSING
    # ============================================================
    if (-not $policy) {

        Write-Host "RubrikCutover NOT found → creating policy" -ForegroundColor Cyan

        if ($DryRun) {
            Write-Host "DRY RUN → Would create RubrikCutover in vault $($vault.VaultName)" -ForegroundColor DarkCyan
        }
        else {
            # ---- Base Schedule (Daily)
            $schedule = Get-AzRecoveryServicesBackupSchedulePolicyObject `
                -WorkloadType AzureVM

            $schedule.ScheduleRunFrequency = "Daily"
            $schedule.ScheduleRunTimes.Clear()
            $schedule.ScheduleRunTimes.Add(
                (Get-Date "02:00").ToUniversalTime()
            )

            # ---- Base Retention
            $retention = Get-AzRecoveryServicesBackupRetentionPolicyObject `
                -WorkloadType AzureVM

            # Short retention – you will refine via REST
            $retention.DailySchedule.DurationCountInDays = 7
            $retention.IsWeeklyScheduleEnabled  = $false
            $retention.IsMonthlyScheduleEnabled = $false
            $retention.IsYearlyScheduleEnabled  = $false

            # ---- Create policy
            $policy = New-AzRecoveryServicesBackupProtectionPolicy `
                -Name $TargetPolicyName `
                -WorkloadType AzureVM `
                -SchedulePolicy  $schedule `
                -RetentionPolicy $retention

            Write-Host "Created RubrikCutover in vault $($vault.VaultName)" -ForegroundColor Green
        }
    }
    else {
        Write-Host "RubrikCutover exists → updating" -ForegroundColor Cyan
    }

    # ============================================================
    # REST UPDATE (CREATE OR EXISTING)
    # ============================================================
    if (-not $DryRun -or $policy) {

        $uri = "/subscriptions/$($vault.SubscriptionId)/resourceGroups/$($vault.ResourceGroup)/providers/Microsoft.RecoveryServices/vaults/$($vault.VaultName)/backupPolicies/$TargetPolicyName?api-version=$ApiVersion"

        $policyRest = Invoke-AzRestMethod -Method GET -Path $uri
        $policyJson = $policyRest.Content | ConvertFrom-Json

        # -----------------------------
        # CUSTOM POLICY CHANGES
        # -----------------------------
        $policyJson.properties.instantRpRetentionRangeInDays = 1

        $policyJson.properties.retentionPolicy.monthlySchedule.retentionScheduleDaily.daysOfTheMonth =
            @(@{ date = 1; isLast = $false })

        if (-not $policyJson.properties.tieringPolicy) {
            $policyJson.properties | Add-Member `
                -MemberType NoteProperty `
                -Name tieringPolicy `
                -Value @{ archivedRP = @{ tieringMode = "TierRecommended" } }
        }
        else {
            $policyJson.properties.tieringPolicy.archivedRP.tieringMode = "TierRecommended"
        }

        $body = $policyJson | ConvertTo-Json -Depth 100

        if ($DryRun) {
            Write-Host "DRY RUN → Would PUT RubrikCutover policy to vault $($vault.VaultName)" -ForegroundColor Cyan
        }
        else {
            Invoke-AzRestMethod -Method PUT -Path $uri -Payload $body | Out-Null
            Write-Host "RubrikCutover updated in vault $($vault.VaultName)" -ForegroundColor Green
        }
    }
}
 