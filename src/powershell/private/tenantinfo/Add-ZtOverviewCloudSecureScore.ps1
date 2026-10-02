function Add-ZtOverviewCloudSecureScore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $SubscriptionId
    )

    $query = @'
securityresources
| where type =~ "microsoft.security/securescores"
| project percentage=round(todecimal(properties.score.percentage)*100), weight=tolong(properties.weight), scoreType=name, environment=tostring(properties.environment)
| where scoreType == "ascScore"
| where environment in~ ("Azure", "AWS", "GCP", "AzureDevOps", "Github", "GitLab")
| extend subTotal = weight*percentage
| summarize percentage = round(sum(subTotal)/sum(weight)) by environment
| extend percentage = iff(isinf(percentage) or isnan(percentage), 0.00, percentage)
| join kind=inner (
    securityresources
    | where type == "microsoft.security/securescores/securescorecontrols"
    | extend environment = tostring(properties.environment)
    | where environment in~ ("Azure", "AWS", "GCP", "AzureDevOps", "Github", "GitLab")
    | summarize maxControlPoints=max(tolong(properties.score.max)) by name, environment
    | summarize max=sum(maxControlPoints) by environment
) on environment
| project-away environment1
| extend current = round(max*percentage/100)
| union (
    securityresources
    | where type =~ "microsoft.security/securescores"
    | project percentage=round(todecimal(properties.score.percentage)*100), weight=tolong(properties.weight), scoreType=name, environment=tostring(properties.environment)
    | where scoreType == "ascScore"
    | where environment in~ ("Azure", "AWS", "GCP", "AzureDevOps", "Github", "GitLab")
    | extend subTotal = weight*percentage
    | summarize percentage = round(sum(subTotal)/sum(weight)), scoreCount=count()
    | where scoreCount > 0
    | project-away scoreCount
    | extend percentage = iff(isinf(percentage) or isnan(percentage), 0.00, percentage)
    | extend joinColumn = 0
    | join kind=inner (
        securityresources
        | where type == "microsoft.security/securescores/securescorecontrols"
        | extend environment = tostring(properties.environment)
        | where environment in~ ("Azure", "AWS", "GCP", "AzureDevOps", "Github", "GitLab")
        | summarize maxControlPoints=max(tolong(properties.score.max)) by name
        | summarize max=sum(maxControlPoints)
        | extend joinColumn = 0
    ) on joinColumn
    | project-away joinColumn, joinColumn1
    | extend current = round(max*percentage/100), environment = "All"
)
| project secureScore = pack_all()
| summarize secureScore = make_list(secureScore)
'@

    $score = $null
    try {
        $response = @(Invoke-ZtAzureResourceGraphRequest -Query $query -SubscriptionId $SubscriptionId -ErrorAction Stop)
        $scores = @($response | ForEach-Object { $_.secureScore } | Where-Object { $null -ne $_ })
        if ($scores.Count -gt 0) {
            $score = $scores
        }
    }
    catch {
        Write-PSFMessage 'Cloud secure score collection failed; the score will be unavailable.' -Tag Test -Level Warning
    }

    Add-ZtTenantInfo -Name 'OverviewCloudSecureScore' -Value $score
}
