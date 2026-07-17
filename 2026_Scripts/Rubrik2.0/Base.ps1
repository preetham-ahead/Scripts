# =========================
# Setup
# =========================
$OutputFolder = "C:\Temp\RSV_Audit_202600407"
$VaultInventoryCSV = "$OutputFolder\VaultInventory.csv"
$VMMappingCSV     = "$OutputFolder\CurrentMapping.csv"

# Dry-run mode: $true = audit/log only, $false = actually apply
$DryRun = $true

# Non-prod subscription IDs
$ProdSubsPhaseA = @(
    "325841e1-5f9d-4828-9042-02c0afe1fa43",
    "c897867e-5a88-4dda-a0a7-fbab47742925",
    "dadca81d-8560-4826-acae-3be792ac93e9",
    "354c53a6-45f8-49c8-ad6e-4cbd5fc578f6"
)

# CSV outputs
$Step1Log = "$OutputFolder\Step1_Immutability.csv"
$Step2Log = "$OutputFolder\Step2_PolicyUpdate.csv"
$Step3Log = "$OutputFolder\Step3_VMAssociation.csv"