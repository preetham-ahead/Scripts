# ============================================
# CONFIGURATION
# ============================================
$organization = "https://dev.azure.com/cenlarfsb"
$outputFile = "C:\Temp\ADO_ProjectAdmins_Hybrid2.csv"
 
Write-Host "Verifying login..." -ForegroundColor Cyan
az devops configure --defaults organization=$organization
 
$results = @()
 
# ============================================
# GET ALL PROJECTS
# ============================================
$projects = az devops project list --query "value[].{Name:name}" -o json | ConvertFrom-Json
 
foreach ($project in $projects) {
    $pName = $project.Name
    Write-Host "`nProcessing Project: $pName" -ForegroundColor Yellow
 
    # ----------------------------------------
    # Get Project Administrators Group Descriptor
    # ----------------------------------------
    $groupDescriptor = az devops security group list --scope project --project "$pName" --query "graphGroups[?contains(displayName, 'Project Administrators')].descriptor" -o tsv
 
    if (-not $groupDescriptor) {
        Write-Warning "No Project Administrators group found in $pName"
        continue
    }
 
    # ----------------------------------------
    # Get Members of Project Administrators Group
    # ----------------------------------------
    $json = az devops security group membership list --id $groupDescriptor -o json
    $data = $json | ConvertFrom-Json
 
    $memberList = @()
    if ($data.members) {
        $memberList = $data.members.PSObject.Properties.Value
    }
    if ($memberList.Count -eq 0) {
        $memberList = $data.PSObject.Properties.Value | Where-Object { $_.displayName -ne $null }
    }
 
    if ($memberList.Count -eq 0) {
        Write-Warning "   - No members found in $pName"
        continue
    }
 
    # ----------------------------------------
# Process each member
# ----------------------------------------
foreach ($m in $memberList) {
    Write-Host "   -> Found: $($m.displayName)" -ForegroundColor Gray
 
    # 1. If it has mail, treat as Direct User
    if ($m.mailAddress -or $m.principalName) {
        $results += [PSCustomObject]@{
            Project    = $pName
            AdminName  = $m.displayName
            AdminEmail = if ($m.mailAddress) { $m.mailAddress } else { $m.principalName }
            Type       = "User"
        }
        Write-Host "      + Added Direct User" -ForegroundColor Green
    }
    # 2. Try expanding via Azure AD (Entra ID)
    else {
        Write-Host "      + Expanding Group: $($m.displayName)" -ForegroundColor Cyan
        $aadGroupId = az ad group list --filter "displayName eq '$($m.displayName)'" --query "[0].id" -o tsv
        if ($aadGroupId) {
            $groupMembers = az ad group member list --group $aadGroupId --query "[].{Name:displayName,Mail:mail,userPrincipalName:userPrincipalName}" -o json | ConvertFrom-Json
            foreach ($gm in $groupMembers) {
                $results += [PSCustomObject]@{
                    Project    = $pName
                    AdminName  = $gm.Name
                    AdminEmail = if ($gm.Mail) { $gm.Mail } else { $gm.userPrincipalName }
                    Type       = "AAD Group Member"
                }
                Write-Host "         - $($gm.Name)" -ForegroundColor Green
            }
        }
        # 3. If Azure AD yields nothing, try On-Prem AD
        elseif (Get-Module ActiveDirectory -ErrorAction SilentlyContinue) {
            try {
                $adMembers = Get-ADGroupMember -Identity $m.displayName -Recursive | Select-Object Name, SamAccountName
                foreach ($member in $adMembers) {
                    $results += [PSCustomObject]@{
                        Project    = $pName
                        AdminName  = $member.Name
                        AdminEmail = $member.SamAccountName
                        Type       = "OnPrem AD Member"
                    }
                    Write-Host "         - $($member.Name)" -ForegroundColor Green
                }
            }
            catch {
                Write-Warning "      Could not expand group in On-Prem AD: $($m.displayName)"
            }
        }
        # 4. Final Fallback
        else {
            Write-Warning "      Could not expand group: $($m.displayName). Azure AD returned no ID and AD module unavailable."
        }
    }
    Start-Sleep -Milliseconds 150
}
}


 
# ============================================
# EXPORT TO CSV
# ============================================
if ($results.Count -gt 0) {
    $results |
    Sort-Object Project, Type, AdminName |
    Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8
    Write-Host "`nDone! Exported $($results.Count) admins to $outputFile" -ForegroundColor Green
}
else {
    Write-Error "No results found. Ensure you are logged in and have permission to read project admins."
}