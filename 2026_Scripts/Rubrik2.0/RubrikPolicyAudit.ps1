$NonProdSubscriptions = @(
    "242ea273-f410-4701-9f78-f9d5d1bf4788",
    "15a10332-e234-483c-b5f8-98c893e1bded",
    "4da90f32-8484-4f1f-836b-e1d63cd8585e",
    "bd417f81-9e36-4bfb-8b53-6237674e0529",
    "ccdaa912-583c-4bae-9d31-8dbb7856f763",
    "14043a1a-3c25-4729-a4b6-c58738f2171d",
    "547f24d3-6c9a-4a28-8b57-b15e2984fef9",
    "3791c0a2-b604-4f3e-ad16-e66446cf1a7e",
    "db7c19f5-bea7-44ca-9a52-7c5a3ef73f71",
    "76569fbe-c870-4d4e-9359-6376262f21e1",
    "c5a9f5d6-1aa1-44ad-bcec-36217430cd77",
    "b69aab00-5450-4a61-989e-0af16401e9e9",
    "e759fb00-b4cb-47a9-8f5b-112720a2a8f5",
    "eacb2b72-994c-4e85-a8ae-ba2594545d00",
    "2cf8dbb5-8708-40ee-92a9-089714260fbd",
    "e3f7401b-554b-40d2-9234-1f2c8f6e2439",
    "4def8413-d6b5-445a-9a80-84d122c5464b",
    "b9c9a7fe-21f0-4e36-bbda-fd41076dc69f",
    "ed9eb190-f796-44c2-8390-c57ff345778e",
    "08a7c685-a9b3-4692-89c5-ee656d7924df"
)

$PolicyReport = @()
 
foreach ($sub in $NonProdSubscriptions) {
 
    Set-AzContext -SubscriptionId $sub | Out-Null
    $vaults = Get-AzRecoveryServicesVault
 
    foreach ($vault in $vaults) {
 
        Set-AzRecoveryServicesVaultContext -Vault $vault
 
        $policy = Get-AzRecoveryServicesBackupProtectionPolicy -Name "RubrikCutover" -ErrorAction SilentlyContinue
 
        if ($policy) {
 
            # Extract Monthly Days
            $monthlyDays = $null
            if ($policy.RetentionPolicy.MonthlySchedule.RetentionScheduleDaily.DaysOfTheMonth) {
                $monthlyDays = ($policy.RetentionPolicy.MonthlySchedule.RetentionScheduleDaily.DaysOfTheMonth | ForEach-Object {
                    if ($_.IsLast -eq $true) { "LastDay" }
                    else { $_.Date }
                }) -join ","
            }
 
            # Extract Yearly Days
            $yearlyDays = $null
            if ($policy.RetentionPolicy.YearlySchedule.RetentionScheduleDaily.DaysOfTheMonth) {
                $yearlyDays = ($policy.RetentionPolicy.YearlySchedule.RetentionScheduleDaily.DaysOfTheMonth | ForEach-Object {
                    if ($_.IsLast -eq $true) { "LastDay" }
                    else { $_.Date }
                }) -join ","
            }
            
            # Get policy via REST
            $apiVersion = "2023-02-01"
            $uri = "/subscriptions/$sub/resourceGroups/$($vault.ResourceGroupName)/providers/Microsoft.RecoveryServices/vaults/$($vault.Name)/backupPolicies/RubrikCutover?api-version=$apiVersion"
 
            $policyRest = Invoke-AzRestMethod -Method GET -Path $uri
            $policyJson = ($policyRest.Content | ConvertFrom-Json)
 
            $tieringMode = $policyJson.properties.tieringPolicy.archivedRP.tieringMode
            
            $snapshotsRetained = $policyJson.properties.instantRpRetentionRangeInDays
 
            if (-not $tieringMode) { $tieringMode = "NotConfigured" }
 
            $PolicyReport += [PSCustomObject]@{
                SubscriptionName   = (Get-AzContext).Subscription.Name
                VaultName          = $vault.Name
                ScheduleFrequency  = $policy.SchedulePolicy.ScheduleRunFrequency
                ScheduleTimeUTC    = ($policy.SchedulePolicy.ScheduleRunTimes -join ",")
                InstantSnapshot    = $snapshotsRetained
                DailyRetention     = $policy.RetentionPolicy.DailySchedule.DurationCountInDays
                WeeklyRetention    = $policy.RetentionPolicy.WeeklySchedule.DurationCountInWeeks
                MonthlyRetention   = $policy.RetentionPolicy.MonthlySchedule.DurationCountInMonths
                MonthlyDays        = $monthlyDays
                YearlyRetention    = $policy.RetentionPolicy.YearlySchedule.DurationCountInYears
                YearlyMonths       = ($policy.RetentionPolicy.YearlySchedule.MonthsOfYear -join ",")
                YearlyDays         = $yearlyDays
                ArhiveTieringMode  = $tieringMode
            }
        }
    }
}
 
$PolicyReport | Export-Csv "$OutputFolder\RubrikCutoverPolicyAudit_03_05_2026.csv" -NoTypeInformation