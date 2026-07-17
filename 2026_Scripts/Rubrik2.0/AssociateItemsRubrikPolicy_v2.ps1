<#
.SYNOPSIS
    Bulk-moves Azure IaaS VM backup items to a new policy across vaults/subscriptions.

.DESCRIPTION
    Reads a CSV with columns:
      SubscriptionName,VaultName,VMName,ResourceGroupName,CurrentPolicy,ProtectionStatus,LastBackupStatus
    For each row, sets the subscription & vault context, resolves the VM’s backup item,
    and re-associates it with the target policy (default: RubrikCutover).
    Outputs a timestamped CSV log with the outcome per VM.

.NOTES
    Requires Az.Accounts and Az.RecoveryServices modules.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$VMMappingCSV,

    [Parameter(Mandatory)]
    [string]$OutputFolder,

    [string]$TargetPolicyName = "RubrikCutover",

    [switch]$DryRun  # Use -DryRun to preview without changing anything
)

# ---------- Setup ----------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}
$OutputCsvPath = Join-Path $OutputFolder "Step3_VMAssociation_$(Get-Date -Format yyyyMMdd_HHmmss).csv"

Write-Host "Authenticating to Azure..." -ForegroundColor Cyan
Connect-AzAccount -ErrorAction Stop | Out-Null

try {
    $rows = Import-Csv -Path $VMMappingCSV
} catch {
    throw "Failed to read CSV '$VMMappingCSV'. $_"
}

$requiredCols = 'SubscriptionName','VaultName','VMName','ResourceGroupName','CurrentPolicy'
$missing = $requiredCols | Where-Object { $_ -notin $rows[0].PsObject.Properties.Name }
if ($missing) { throw "CSV is missing required columns: $($missing -join ', ')" }

$results = New-Object System.Collections.Generic.List[object]

# ---------- Main ----------
foreach ($row in $rows) {
    Write-Host "`n=== Processing: $($row.VMName) | Vault: $($row.VaultName) | Sub: $($row.SubscriptionName) ===" -ForegroundColor Yellow

    $status   = "Skipped"
    $message  = ""
    $oldPol   = $row.CurrentPolicy
    $newPol   = $TargetPolicyName

    try {
        # Switch subscription (resolve by name -> ID for reliability)
        $sub = Get-AzSubscription -SubscriptionName $row.SubscriptionName -ErrorAction Stop
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null

        # Resolve vault and set context
        $vault = Get-AzRecoveryServicesVault -Name $row.VaultName -ErrorAction Stop
        Set-AzRecoveryServicesVaultContext -Vault $vault

        # Find the target policy in this vault
        $policy = Get-AzRecoveryServicesBackupProtectionPolicy -Name $TargetPolicyName -ErrorAction Stop

        # Optional fast-path: skip if CSV already shows the target
        if ($oldPol -and ($oldPol -eq $TargetPolicyName)) {
            $status  = "NoChange"
            $message = "Already on target policy"
        } else {
            # Resolve the VM’s backup container and item (IaaS VM)
            $container = Get-AzRecoveryServicesBackupContainer `
                -ContainerType AzureVM `
                -FriendlyName $row.VMName `
                -VaultId $vault.Id

            if (-not $container) { throw "Backup container not found for VM '$($row.VMName)'." }

            $item = Get-AzRecoveryServicesBackupItem `
                -Container $container `
                -WorkloadType AzureVM `
                -VaultId $vault.Id

            if (-not $item) { throw "Backup item not found for VM '$($row.VMName)'." }

            if ($DryRun) {
                $status  = "Planned"
                $message = "Would move from '$oldPol' to '$newPol'"
            } else {
                # Re-associate the item with the new policy (Modify Protection)
                Enable-AzRecoveryServicesBackupProtection `
                    -Item $item `
                    -Policy $policy `
                    -VaultId $vault.Id `
                    -ErrorAction Stop | Out-Null

                $status  = "Success"
                $message = "Policy updated"
            }
        }
    }
    catch {
        $status  = "Failed"
        $message = $_.Exception.Message
        Write-Host "  ✖ $message" -ForegroundColor Red
    }

    $results.Add([pscustomobject]@{
        Timestamp        = (Get-Date).ToString("s")
        SubscriptionName = $row.SubscriptionName
        VaultName        = $row.VaultName
        VMName           = $row.VMName
        ResourceGroup    = $row.ResourceGroupName
        OldPolicy        = $oldPol
        NewPolicy        = $newPol
        Outcome          = $status
        Message          = $message
    })
}

$results | Export-Csv -Path $OutputCsvPath -NoTypeInformation
Write-Host "`nCompleted. Results -> $OutputCsvPath" -ForegroundColor Green