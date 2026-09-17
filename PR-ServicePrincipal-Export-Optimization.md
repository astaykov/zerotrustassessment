# Optimize ServicePrincipal and AppRoleAssignment Exports

## Summary

Reduce Microsoft Graph export payloads for `ServicePrincipal` and nested `appRoleAssignments` data while preserving the fields required by permission analysis and assessment checks.

## Changes

### ServicePrincipal export

Reduced the top-level `$select` to the required properties:

`id`, `appId`, `displayName`, `accountEnabled`, `servicePrincipalType`, `signInAudience`, `appOwnerOrganizationId`, `publisherName`, `replyUrls`, `preferredSingleSignOnMode`, `appRoleAssignmentRequired`, `tags`, `passwordCredentials`, `keyCredentials`, `appRoles`, `customSecurityAttributes`, `agentIdentityBlueprintId`, and `createdByAppId`.

### AppRoleAssignments export

Changed the nested Graph expansion from:

```text
$expand=appRoleAssignments
```

to:

```text
$expand=appRoleAssignments($select=id,appRoleId,principalId,resourceId)
```

The nested export now retains only `id`, `appRoleId`, `principalId`, and `resourceId`. These fields are required for application permission joins and permission-name resolution.

`RelatedPropertyNames` changes for `owners` and `oauth2PermissionGrants` are not included in this pull request.

## Results

Compared with the export before these changes:

| Metric | Before | After | Reduction |
|---|---:|---:|---:|
| ServicePrincipal JSON export | 4,004,913 bytes | 1,639,005 bytes | 2,365,908 bytes / 59.07% |
| DuckDB database | 8,663,040 bytes | 7,614,464 bytes | 1,048,576 bytes / 12.10% |
| ServicePrincipal records | 614 | 614 | No change |
| AppRoleAssignment records | 159 | 159 | No change |

## Data Integrity

- ServicePrincipal IDs remained unchanged.
- AppRoleAssignment values for `id`, `appRoleId`, `principalId`, and `resourceId` remained unchanged.
- DuckDB ServicePrincipal row counts remained unchanged.
- DuckDB AppRoleAssignment row counts remained unchanged.
- Dependent assessment outputs remained functionally unchanged.
- No `RelatedPropertyNames` changes are included in this pull request.

## Testing

- Focused Pester tests passed: **6 passed, 0 failed**.
- Verified the reduced top-level ServicePrincipal Graph query.
- Verified the reduced nested AppRoleAssignments Graph query.
- Verified ServicePrincipal and AppRoleAssignment counts in exported JSON.
- Verified ServicePrincipal and AppRoleAssignment counts in DuckDB.
- Verified that dependent assessment results were preserved.

## Files Changed

- `src/powershell/assets/export-tenant.config.psd1`
- `code-tests/commands/Export-ZtGraphEntity.Tests.ps1`
