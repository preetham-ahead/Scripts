<#
.SYNOPSIS
    Sets Recovery Services vault ImmutabilityState to "Unlocked" (enabled but not locked)
    for each vault listed in VaultInventory.csv. Does NOT modify Soft-Delete settings.

.DESCRIPTION
    CSV schema expected:
      SubscriptionName, SubscriptionId, VaultName, ResourceGroup, Location, ImmutabilityState, SoftDeleteState, SoftDeleteRetentionDays

    For each row:
      - Switches to the subscription.
      - Gets the vault.
      - If ImmutabilityState != 'Unlocked', runs:
          Update-AzRecoveryServicesVault -ImmutabilityState Unlocked
        Otherwise, records NoChange.
    Outputs a timestamped CSV with per-vault outcome.

.NOTES
    Cmdlet reference:
      Update-AzRecoveryServicesVault -ImmutabilityState {Disabled|Unlocked|Locked}
      (Unlocked means immutability is enabled but not locked.)
#>

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
$OutCsv = Join-Path $OutputFolder ("Set_Immutability_Unlocked_{0}.csv" -f (Get-Date -Format yyyyMMdd_HHmmss))

Write-Host "Connecting to Azure..." -ForegroundColor Cyan
Connect-AzAccount -ErrorAction Stop | Out-Null

# Import CSV & validate required columns
$rows = Import-Csv -Path $VaultInventoryCsv
$required = 'SubscriptionId','VaultName','ResourceGroup'
$missing = $required | Where-Object { $_ -notin $rows[0].PSObject.Properties.Name }
if ($missing) { throw "CSV missing required columns: $($missing -join ', ')" }

$results = New-Object System.Collections.Generic.List[object]

foreach ($r in $rows) {
    $currImmut = $null
    $outcome   = "Skipped"
    $note      = ""

    try {
        # Scope to the subscription
        Set-AzContext -SubscriptionId $r.SubscriptionId -ErrorAction Stop | Out-Null

        # Get the vault and its current immutability state
        $vault = Get-AzRecoveryServicesVault -Name $r.VaultName -ResourceGroupName $r.ResourceGroup -ErrorAction Stop
        $currImmut = $vault.Properties.ImmutabilitySettings.ImmutabilityState  # Disabled | Unlocked | Locked

        if ($currImmut -ne 'Unlocked') {
            if ($DryRun) {
                $outcome = "Planned"
                $note    = "Would set ImmutabilityState=Unlocked (was '$currImmut')"
            } else {
                Update-AzRecoveryServicesVault `
                    -ResourceGroupName $r.ResourceGroup `
                    -Name $r.VaultName `
                    -ImmutabilityState Unlocked `
                    -ErrorAction Stop | Out-Null

                $outcome = "Success"
                $note    = "Immutability set to Unlocked (was '$currImmut')"
            }
        } else {
            $outcome = "NoChange"
            $note    = "Already Unlocked"
        }

        Write-Host ("{0}/{1}: {2}" -f $r.ResourceGroup, $r.VaultName, $note) -ForegroundColor Green
    }
    catch {
        $outcome = "Failed"
        $note    = $_.Exception.Message
        Write-Host ("{0}/{1}: ERROR - {2}" -f $r.ResourceGroup, $r.VaultName, $note) -ForegroundColor Red
    }

    $results.Add([pscustomobject]@{
        Timestamp        = (Get-Date).ToString("s")
        SubscriptionId   = $r.SubscriptionId
        ResourceGroup    = $r.ResourceGroup
        VaultName        = $r.VaultName
        PreviousImmut    = $currImmut
        TargetImmut      = "Unlocked"
        Outcome          = $outcome
        Message          = $note
    })
}

$results | Export-Csv -Path $OutCsv -NoTypeInformation
Write-Host "`nResults saved to: $OutCsv" -ForegroundColor Yellow