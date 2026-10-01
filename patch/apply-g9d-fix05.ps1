$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$crossGuard = Join-Path $root 'force-app\main\default\classes\SABCrossCompanyGuardService.cls'
$testClass = Join-Path $root 'force-app\main\default\classes\SABFixedAssetMovementServiceTest.cls'
$permSet = Join-Path $root 'force-app\main\default\permissionsets\SAB_Fixed_Asset_Movement_Manager.permissionset-meta.xml'

foreach ($path in @($crossGuard, $testClass, $permSet)) {
    if (-not (Test-Path $path)) { throw "Required project file not found: $path" }
}

# 1) Correct field API names used by the G9D test fixture/query.
$test = Get-Content -Raw $testClass
Copy-Item $testClass "$testClass.g9d-fix05-backup" -Force
$test = $test.Replace('Department_Key__c', 'Company_Department_Key__c')
$test = $test.Replace('Cost_Center_Key__c', 'Company_Cost_Center_Key__c')

# 2) The depreciation evidence test needs its own fresh governor-limit context.
if (-not $test.Contains("Test.startTest();`r`n            SABFixedAssetDepreciationPostingService.PostingResult result =`r`n                postSeptemberDepreciation(asset.Id, 'F9E-DEP-EVIDENCE');`r`n            Test.stopTest();") -and
    -not $test.Contains("Test.startTest();`n            SABFixedAssetDepreciationPostingService.PostingResult result =`n                postSeptemberDepreciation(asset.Id, 'F9E-DEP-EVIDENCE');`n            Test.stopTest();")) {
    $old = @'
            Fixed_Asset__c asset = getAsset('F9E-ASSET-IMPAIR');
            SABFixedAssetDepreciationPostingService.PostingResult result =
                postSeptemberDepreciation(asset.Id, 'F9E-DEP-EVIDENCE');

            Asset_Movement__c movement = [
'@
    $new = @'
            Fixed_Asset__c asset = getAsset('F9E-ASSET-IMPAIR');

            Test.startTest();
            SABFixedAssetDepreciationPostingService.PostingResult result =
                postSeptemberDepreciation(asset.Id, 'F9E-DEP-EVIDENCE');
            Test.stopTest();

            Asset_Movement__c movement = [
'@
    if (-not $test.Contains($old)) { throw 'Could not locate depreciation evidence block.' }
    $test = $test.Replace($old, $new)
}
Set-Content -Path $testClass -Value $test -NoNewline

# 3) Transaction-scoped relationship caches for the Journal Line company guard.
$guard = Get-Content -Raw $crossGuard
if (-not $guard.Contains('G9D_FIX05_CACHE')) {
    Copy-Item $crossGuard "$crossGuard.g9d-fix05-backup" -Force
    # Remove a previously-applied G9D Fix 04/05 cache declaration block, if present.
    $guard = [regex]::Replace(
        $guard,
        '(?s)\s*// G9D_FIX0[45]_CACHE:.*?private static final Map<Id, Id> PROJECT_COMPANY_CACHE = new Map<Id, Id>\(\);',
        ''
    )

    $header = @'
public without sharing class SABCrossCompanyGuardService {

    // G9D_FIX05_CACHE: transaction-scoped caches avoid repeating the same
    // relationship SOQL across multiple Journal Line trigger invocations.
    private static final Map<Id, Id> JOURNAL_COMPANY_CACHE = new Map<Id, Id>();
    private static final Map<Id, Id> ACCOUNT_COMPANY_CACHE = new Map<Id, Id>();
    private static final Map<Id, Id> DEPARTMENT_COMPANY_CACHE = new Map<Id, Id>();
    private static final Map<Id, Id> COST_CENTER_COMPANY_CACHE = new Map<Id, Id>();
    private static final Map<Id, Id> PROJECT_COMPANY_CACHE = new Map<Id, Id>();

'@
    $guard = [regex]::Replace(
        $guard,
        '^public without sharing class SABCrossCompanyGuardService \{\s*',
        [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $header }
    )
    $pattern = '(?s)    public static void validateJournalLines\(\s*List<Journal_Entry_Line__c> records\s*\)\s*\{.*?\n    \}\r?\n\r?\n    public static void validateBankAccounts'
    $replacement = @'
    public static void validateJournalLines(
        List<Journal_Entry_Line__c> records
    ) {
        Set<Id> journalIds = new Set<Id>();
        Set<Id> accountIds = new Set<Id>();
        Set<Id> departmentIds = new Set<Id>();
        Set<Id> costCenterIds = new Set<Id>();
        Set<Id> projectIds = new Set<Id>();

        for (Journal_Entry_Line__c recordValue : records) {
            if (recordValue.Journal_Entry__c != null) journalIds.add(recordValue.Journal_Entry__c);
            if (recordValue.GL_Account__c != null) accountIds.add(recordValue.GL_Account__c);
            if (recordValue.Department__c != null) departmentIds.add(recordValue.Department__c);
            if (recordValue.Cost_Center__c != null) costCenterIds.add(recordValue.Cost_Center__c);
            if (recordValue.Project__c != null) projectIds.add(recordValue.Project__c);
        }

        cacheJournalCompanies(journalIds);
        cacheAccountCompanies(accountIds);
        cacheDepartmentCompanies(departmentIds);
        cacheCostCenterCompanies(costCenterIds);
        cacheProjectCompanies(projectIds);

        for (Journal_Entry_Line__c recordValue : records) {
            Id companyId = JOURNAL_COMPANY_CACHE.get(recordValue.Journal_Entry__c);
            if (companyId == null) continue;

            assertSameCompany(recordValue, companyId, recordValue.GL_Account__c,
                ACCOUNT_COMPANY_CACHE.get(recordValue.GL_Account__c), 'GL Account');
            assertSameCompany(recordValue, companyId, recordValue.Department__c,
                DEPARTMENT_COMPANY_CACHE.get(recordValue.Department__c), 'Department');
            assertSameCompany(recordValue, companyId, recordValue.Cost_Center__c,
                COST_CENTER_COMPANY_CACHE.get(recordValue.Cost_Center__c), 'Cost Center');
            assertSameCompany(recordValue, companyId, recordValue.Project__c,
                PROJECT_COMPANY_CACHE.get(recordValue.Project__c), 'Project');
        }
    }

    private static void cacheJournalCompanies(Set<Id> ids) {
        Set<Id> missing = new Set<Id>(ids);
        missing.removeAll(JOURNAL_COMPANY_CACHE.keySet());
        if (missing.isEmpty()) return;
        for (Journal_Entry__c row : [SELECT Id, Company__c FROM Journal_Entry__c WHERE Id IN :missing]) {
            JOURNAL_COMPANY_CACHE.put(row.Id, row.Company__c);
        }
    }

    private static void cacheAccountCompanies(Set<Id> ids) {
        Set<Id> missing = new Set<Id>(ids);
        missing.removeAll(ACCOUNT_COMPANY_CACHE.keySet());
        if (missing.isEmpty()) return;
        for (GL_Account__c row : [SELECT Id, Company__c FROM GL_Account__c WHERE Id IN :missing]) {
            ACCOUNT_COMPANY_CACHE.put(row.Id, row.Company__c);
        }
    }

    private static void cacheDepartmentCompanies(Set<Id> ids) {
        Set<Id> missing = new Set<Id>(ids);
        missing.removeAll(DEPARTMENT_COMPANY_CACHE.keySet());
        if (missing.isEmpty()) return;
        for (Department__c row : [SELECT Id, Company__c FROM Department__c WHERE Id IN :missing]) {
            DEPARTMENT_COMPANY_CACHE.put(row.Id, row.Company__c);
        }
    }

    private static void cacheCostCenterCompanies(Set<Id> ids) {
        Set<Id> missing = new Set<Id>(ids);
        missing.removeAll(COST_CENTER_COMPANY_CACHE.keySet());
        if (missing.isEmpty()) return;
        for (Cost_Center__c row : [SELECT Id, Company__c FROM Cost_Center__c WHERE Id IN :missing]) {
            COST_CENTER_COMPANY_CACHE.put(row.Id, row.Company__c);
        }
    }

    private static void cacheProjectCompanies(Set<Id> ids) {
        Set<Id> missing = new Set<Id>(ids);
        missing.removeAll(PROJECT_COMPANY_CACHE.keySet());
        if (missing.isEmpty()) return;
        for (Project__c row : [SELECT Id, Company__c FROM Project__c WHERE Id IN :missing]) {
            PROJECT_COMPANY_CACHE.put(row.Id, row.Company__c);
        }
    }

    public static void validateBankAccounts
'@
    $updated = [regex]::Replace($guard, $pattern, $replacement, 1)
    if ($updated -eq $guard) { throw 'Could not locate validateJournalLines method.' }
    Set-Content -Path $crossGuard -Value $updated -NoNewline
}

# 4) Permission set: object access + only NON-required Asset Movement fields.
# Required fields cannot be included in PermissionSet fieldPermissions in API 67+.
$perm = @'
<?xml version="1.0" encoding="UTF-8"?>
<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">
    <description>Allows controlled Fixed Asset transfer, impairment and disposal operations. Financial movements also require SAB_Post_Journal_Action.</description>
    <hasActivationRequired>false</hasActivationRequired>
    <label>SAB Fixed Asset Movement Manager</label>
    <classAccesses>
        <apexClass>SABFixedAssetMovementService</apexClass>
        <enabled>true</enabled>
    </classAccesses>
    <objectPermissions>
        <allowCreate>true</allowCreate>
        <allowDelete>false</allowDelete>
        <allowEdit>true</allowEdit>
        <allowRead>true</allowRead>
        <modifyAllRecords>false</modifyAllRecords>
        <object>Asset_Movement__c</object>
        <viewAllRecords>false</viewAllRecords>
    </objectPermissions>
    <fieldPermissions><editable>true</editable><field>Asset_Movement__c.Disposal_Proceeds__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Asset_Movement__c.Disposal_Bank_Account__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Asset_Movement__c.From_Department__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Asset_Movement__c.To_Department__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Asset_Movement__c.From_Cost_Center__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Asset_Movement__c.To_Cost_Center__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Asset_Movement__c.From_Custodian__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Asset_Movement__c.To_Custodian__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Asset_Movement__c.From_Location__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Asset_Movement__c.To_Location__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Asset_Movement__c.Reason__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Asset_Movement__c.Journal_Entry__c</field><readable>true</readable></fieldPermissions>
    <fieldPermissions><editable>true</editable><field>Asset_Movement__c.Accounting_Event__c</field><readable>true</readable></fieldPermissions>
    <customPermissions>
        <enabled>true</enabled>
        <name>SAB_Manage_Asset_Movements</name>
    </customPermissions>
</PermissionSet>
'@
Copy-Item $permSet "$permSet.g9d-fix05-backup" -Force
Set-Content -Path $permSet -Value $perm -NoNewline

Write-Host 'G9D Fix 05 applied.'
Write-Host 'Corrected: Company_Department_Key__c / Company_Cost_Center_Key__c.'
Write-Host 'Removed required Asset Movement fields from permission-set FLS.'
Write-Host 'Added non-required Asset Movement FLS and object CRUD needed by API 67+ user-mode DML.'
Write-Host 'Added transaction-scoped Journal Line relationship caches.'
