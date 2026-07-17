$SummaryReport = $VMPolicyReport | Group-Object SubscriptionName | ForEach-Object {
    [PSCustomObject]@{
        SubscriptionName = $_.Name
        TotalProtectedVMs = $_.Count
    }
}

$SummaryReport | Export-Csv "$OutputFolder\SummaryReport.csv" -NoTypeInformation