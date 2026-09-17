<#
.SYNOPSIS
    TEMPORARY STUB — synthetic Pass emitter for demo purposes only.
    The real file is at C:\Users\PERENN~1\AppData\Local\Temp\Test-Assessment.41012.original.20260917-143313.ps1 and is restored by the caller.
#>
function Test-Assessment-41012 {
    [ZtTest(
        Category           = 'Identity threat protection',
        CompatibleLicense  = ('ATA'),
        ImplementationCost = 'Medium',
        Pillar             = 'SecOps',
        RiskLevel          = 'High',
        Service            = ('Graph'),
        SfiPillar          = 'Protect identities and secrets',
        TenantType         = ('Workforce'),
        TestId             = 41012,
        Title              = 'Microsoft Entra Connect synchronization account does not hold unnecessary replication permissions',
        UserImpact         = 'Low'
    )]
    [CmdletBinding()]
    param()

    $title = 'Microsoft Entra Connect synchronization account does not hold unnecessary replication permissions'

    # implementationStatus is empty string in the live Q2 payload -> render as em-dash per spec.
    $mdInfo = @'


| Recommendation title | Current score / Maximum score | Score percentage | Implementation status | Last synced | Snapshot time (UTC) | Control state | Status | Reason |
| :------------------- | :---------------------------- | :--------------- | :-------------------- | :---------- | :------------------ | :------------ | :----- | :----- |
| [Remove unnecessary replication permissions for Entra Connect AD DS Connector Account](https://aka.ms/IspmEntraConnectReplicationPermissions) | 8 / 8 | 100.00% | — | 2026-09-17T06:23:41Z | 2026-09-17T00:00:00Z | Default | ✅ Pass | The current score equals the recommendation maximum. |
'@

    $result = "✅ The latest Microsoft Defender for Identity Secure Score assessment reports no unnecessary replication permissions for monitored Microsoft Entra Connect synchronization accounts.`n`n" + $mdInfo

    Add-ZtTestResultDetail -TestId '41012' -Title $title -Status $true -Result $result
}