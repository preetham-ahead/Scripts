$DryRun = $false

$NonProdSubs = @(
    "15a10332-e234-483c-b5f8-98c893e1bded",
    "4da90f32-8484-4f1f-836b-e1d63cd8585e"
)

$NonProdVaults = Import-Csv $VaultInventoryCSV | Where-Object { $NonProdSubs -contains $_.SubscriptionId }
$Step4Results = @()

foreach ($vault in $NonProdVaults) {
    Set-AzContext -SubscriptionId $vault.SubscriptionId
    $vaultObj = Get-AzRecoveryServicesVault -Name $vault.VaultName

    $action = if ($vault.SoftDeleteState -ne "Disabled") { if ($DryRun) {"Would Disable"} else {"Disabled"} } else {"Already Disabled"}

    if (-not $DryRun -and $vault.SoftDeleteState -ne "Disabled") {
        $body = @{
            properties = @{
                securitySettings = @{
                    softDeleteSettings = @{ state = "Disabled" }
                }
            }
        } | ConvertTo-Json -Depth 10

        Invoke-AzRestMethod -Method PATCH -Path "/subscriptions/$($vault.SubscriptionId)/resourceGroups/$($vault.ResourceGroup)/providers/Microsoft.RecoveryServices/vaults/$($vault.VaultName)?api-version=2023-02-01" -Payload $body
    }

    $Step4Results += [PSCustomObject]@{
        SubscriptionId = $vault.SubscriptionId
        VaultName      = $vault.VaultName
        OldSoftDelete  = $vault.SoftDeleteState
        Action         = $action
    }
}

$Step4Results | Export-Csv $Step4Log -NoTypeInformation
Write-Host "Step 4 completed. Results logged to $Step4Log"


<#

##########################################
.SYNOPSIS
    Disables Soft Delete on Recovery Services vaults listed in VaultInventory.csv.

.DESCRIPTION
    Reads CSV with columns:
      SubscriptionName,SubscriptionId,VaultName,ResourceGroup,Location,ImmutabilityState,SoftDeleteState,SoftDeleteRetentionDays
    For each row: sets Az context, resolves the vault, and attempts:
      Set-AzRecoveryServicesVaultProperty -SoftDeleteFeatureState Disable
###########################################

    Outputs a timestamped CSV with per-vault outcome. Supports -DryRun.

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$VaultInventoryCsv,

    [Parameter(Mandatory)]
    [string]$OutputFolder,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}
$OutCsv = Join-Path $OutputFolder ("Step1_DisableSoftDelete_{0}.csv" -f (Get-Date -Format yyyyMMdd_HHmmss))

Write-Host "Connecting to Azure..." -ForegroundColor Cyan
Connect-AzAccount -ErrorAction Stop | Out-Null

$rows = Import-Csv -Path $VaultInventoryCsv
$needCols = 'SubscriptionId','VaultName','ResourceGroup'
$miss = $needCols | Where-Object { $_ -notin $rows[0].PSObject.Properties.Name }
if ($miss) { throw "CSV missing required columns: $($miss -join ', ')" }

$log = New-Object System.Collections.Generic.List[object]

foreach ($r in $rows) {
    $status  = "Skipped"
    $message = ""

    try {
        Set-AzContext -SubscriptionId $r.SubscriptionId -ErrorAction Stop | Out-Null

        $vault = Get-AzRecoveryServicesVault -Name $r.VaultName -ResourceGroupName $r.ResourceGroup -ErrorAction Stop

        if ($DryRun) {
            $status  = "Planned"
            $message = "Would set SoftDeleteFeatureState=Disable"
        } else {
            # Attempt to disable soft delete (may fail if Secure-by-default enforcement / AlwaysON)
            Set-AzRecoveryServicesVaultProperty `
                -VaultId $vault.Id `
                -SoftDeleteFeatureState Disable `
                -ErrorAction Stop | Out-Null

            $status  = "Success"
            $message = "Soft delete disabled"
        }
        Write-Host ("{0}/{1}: {2}" -f $r.ResourceGroup, $r.VaultName, $message) -ForegroundColor Green
    }
    catch {
        $status  = "Failed"
        $message = $_.Exception.Message
        Write-Host ("{0}/{1}: {2}" -f $r.ResourceGroup, $r.VaultName, $message) -ForegroundColor Red
    }

    $log.Add([pscustomobject]@{
        Timestamp        = (Get-Date).ToString("s")
        SubscriptionId   = $r.SubscriptionId
        VaultName        = $r.VaultName
        ResourceGroup    = $r.ResourceGroup
        Action           = "SoftDelete -> Disable"
        Outcome          = $status
        Message          = $message
    })
}

$log | Export-Csv -Path $OutCsv -NoTypeInformation
Write-Host "`nResults saved to: $OutCsv" -ForegroundColor Yellow

#>