$ErrorActionPreference = 'Stop'

$root = (Get-Location).Path
$crossGuard = Join-Path $root 'force-app\main\default\classes\SABCrossCompanyGuardService.cls'
$testClass = Join-Path $root 'force-app\main\default\classes\SABFixedAssetMovementServiceTest.cls'
$permSet = Join-Path $root 'force-app\main\default\permissionsets\SAB_Fixed_Asset_Movement_Manager.permissionset-meta.xml'

foreach ($path in @($crossGuard, $testClass, $permSet)) {
    if (-not (Test-Path $path)) { throw "Required project file not found: $path" }
}

# ---- Cross-company guard governor-limit fix ----
$content = Get-Content -Raw $crossGuard
if ($content.Contains('G9D_FIX04_CACHE')) {
    Write-Host 'SABCrossCompanyGuardService already contains G9D_FIX04 cache changes.'
} else {
    Copy-Item $crossGuard "$crossGuard.g9d-fix04-backup" -Force

    $header = @'
public without sharing class SABCrossCompanyGuardService {

    // G9D_FIX04_CACHE: transaction-scoped relationship caches prevent repeated
    // Journal Line trigger invocations from burning the 100-query governor limit.
    private static final Map<Id, Id> JOURNAL_COMPANY_CACHE = new Map<Id, Id>();
    private static final Map<Id, Id> ACCOUNT_COMPANY_CACHE = new Map<Id, Id>();
    private static final Map<Id, Id> DEPARTMENT_COMPANY_CACHE = new Map<Id, Id>();
    private static final Map<Id, Id> COST_CENTER_COMPANY_CACHE = new Map<Id, Id>();
    private static final Map<Id, Id> PROJECT_COMPANY_CACHE = new Map<Id, Id>();

'@
    if (-not $content.Contains('public without sharing class SABCrossCompanyGuardService {')) {
        throw 'Unexpected SABCrossCompanyGuardService class header.'
    }
    $content = $content.Replace("public without sharing class SABCrossCompanyGuardService {`r`n`r`n", $header)
    $content = $content.Replace("public without sharing class SABCrossCompanyGuardService {`n`n", $header)

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
            if (recordValue.Journal_Entry__c != null) {
                journalIds.add(recordValue.Journal_Entry__c);
            }
            if (recordValue.GL_Account__c != null) {
                accountIds.add(recordValue.GL_Account__c);
            }
            if (recordValue.Department__c != null) {
                departmentIds.add(recordValue.Department__c);
            }
            if (recordValue.Cost_Center__c != null) {
                costCenterIds.add(recordValue.Cost_Center__c);
            }
            if (recordValue.Project__c != null) {
                projectIds.add(recordValue.Project__c);
            }
        }

        cacheJournalCompanies(journalIds);
        cacheAccountCompanies(accountIds);
        cacheDepartmentCompanies(departmentIds);
        cacheCostCenterCompanies(costCenterIds);
        cacheProjectCompanies(projectIds);

        for (Journal_Entry_Line__c recordValue : records) {
            Id companyId =
                JOURNAL_COMPANY_CACHE.get(recordValue.Journal_Entry__c);

            if (companyId == null) {
                continue;
            }

            assertSameCompany(
                recordValue,
                companyId,
                recordValue.GL_Account__c,
                ACCOUNT_COMPANY_CACHE.get(recordValue.GL_Account__c),
                'GL Account'
            );

            assertSameCompany(
                recordValue,
                companyId,
                recordValue.Department__c,
                DEPARTMENT_COMPANY_CACHE.get(recordValue.Department__c),
                'Department'
            );

            assertSameCompany(
                recordValue,
                companyId,
                recordValue.Cost_Center__c,
                COST_CENTER_COMPANY_CACHE.get(recordValue.Cost_Center__c),
                'Cost Center'
            );

            assertSameCompany(
                recordValue,
                companyId,
                recordValue.Project__c,
                PROJECT_COMPANY_CACHE.get(recordValue.Project__c),
                'Project'
            );
        }
    }

    private static void cacheJournalCompanies(Set<Id> ids) {
        Set<Id> missing = new Set<Id>(ids);
        missing.removeAll(JOURNAL_COMPANY_CACHE.keySet());
        if (missing.isEmpty()) {
            return;
        }

        for (Journal_Entry__c row : [
            SELECT Id, Company__c
            FROM Journal_Entry__c
            WHERE Id IN :missing
        ]) {
            JOURNAL_COMPANY_CACHE.put(row.Id, row.Company__c);
        }
    }

    private static void cacheAccountCompanies(Set<Id> ids) {
        Set<Id> missing = new Set<Id>(ids);
        missing.removeAll(ACCOUNT_COMPANY_CACHE.keySet());
        if (missing.isEmpty()) {
            return;
        }

        for (GL_Account__c row : [
            SELECT Id, Company__c
            FROM GL_Account__c
            WHERE Id IN :missing
        ]) {
            ACCOUNT_COMPANY_CACHE.put(row.Id, row.Company__c);
        }
    }

    private static void cacheDepartmentCompanies(Set<Id> ids) {
        Set<Id> missing = new Set<Id>(ids);
        missing.removeAll(DEPARTMENT_COMPANY_CACHE.keySet());
        if (missing.isEmpty()) {
            return;
        }

        for (Department__c row : [
            SELECT Id, Company__c
            FROM Department__c
            WHERE Id IN :missing
        ]) {
            DEPARTMENT_COMPANY_CACHE.put(row.Id, row.Company__c);
        }
    }

    private static void cacheCostCenterCompanies(Set<Id> ids) {
        Set<Id> missing = new Set<Id>(ids);
        missing.removeAll(COST_CENTER_COMPANY_CACHE.keySet());
        if (missing.isEmpty()) {
            return;
        }

        for (Cost_Center__c row : [
            SELECT Id, Company__c
            FROM Cost_Center__c
            WHERE Id IN :missing
        ]) {
            COST_CENTER_COMPANY_CACHE.put(row.Id, row.Company__c);
        }
    }

    private static void cacheProjectCompanies(Set<Id> ids) {
        Set<Id> missing = new Set<Id>(ids);
        missing.removeAll(PROJECT_COMPANY_CACHE.keySet());
        if (missing.isEmpty()) {
            return;
        }

        for (Project__c row : [
            SELECT Id, Company__c
            FROM Project__c
            WHERE Id IN :missing
        ]) {
            PROJECT_COMPANY_CACHE.put(row.Id, row.Company__c);
        }
    }

    public static void validateBankAccounts
'@

    $updated = [regex]::Replace($content, $pattern, $replacement, 1)
    if ($updated -eq $content) { throw 'Could not locate validateJournalLines method. No changes made.' }
    Set-Content -Path $crossGuard -Value $updated -NoNewline
    Write-Host 'Patched SABCrossCompanyGuardService with transaction-scoped relationship caches.'
}

# ---- Test-limit fix ----
$test = Get-Content -Raw $testClass
if (-not $test.Contains("Test.startTest();`r`n            SABFixedAssetDepreciationPostingService.PostingResult result =`r`n                postSeptemberDepreciation(asset.Id, 'F9E-DEP-EVIDENCE');`r`n            Test.stopTest();") -and
    -not $test.Contains("Test.startTest();`n            SABFixedAssetDepreciationPostingService.PostingResult result =`n                postSeptemberDepreciation(asset.Id, 'F9E-DEP-EVIDENCE');`n            Test.stopTest();")) {
    Copy-Item $testClass "$testClass.g9d-fix04-backup" -Force
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
    if (-not $test.Contains($old)) { throw 'Could not locate depreciation evidence setup block.' }
    $test = $test.Replace($old, $new)
    Set-Content -Path $testClass -Value $test -NoNewline
    Write-Host 'Patched depreciation evidence test to use the fresh governor-limit context.'
} else {
    Write-Host 'Depreciation evidence test already contains the G9D_FIX04 start/stop block.'
}

Write-Host ''
Write-Host 'G9D Fix 04 source patch complete.'
Write-Host 'Backups were created beside modified files.'
