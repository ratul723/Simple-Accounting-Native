/**
 * G9E - Fixed Asset Workspace, Reconciliation & Security Hardening.
 *
 * Read-only operational workspace over the existing G9A-G9D Fixed Asset
 * lifecycle. Mutations remain in the established domain services.
 *
 * Security:
 * - Custom Permission: SAB_View_Fixed_Asset_Workspace
 * - with sharing
 * - Accounting Company access enforced server-side
 * - Fixed Asset / Schedule / Movement read access checked
 * - queried SObjects are passed through stripInaccessible before DTO mapping
 *
 * Reconciliation uses the PRIMARY book currently used by the fixed-asset
 * lifecycle services:
 *   NBV = Cost - Posted Depreciation - Posted Impairment - Disposal Amount
 *
 * A disposed asset should have no future Planned schedule lines.
 * An active/planned/impaired asset may have future Planned depreciation, but
 * the future amount cannot exceed the remaining depreciable carrying base.
 */
public with sharing class SABFixedAssetWorkspaceController {

    public class FixedAssetWorkspaceException extends Exception {}

    private static final String VIEW_PERMISSION =
        'SAB_View_Fixed_Asset_Workspace';

    private static final String PRIMARY_BOOK =
        'PRIMARY';

    private static final Decimal ZERO =
        Decimal.valueOf('0');

    private static final Decimal TOLERANCE =
        Decimal.valueOf('0.01');

    public class CompanyOptionDTO {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
    }

    public class DashboardDTO {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String companyName { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
        @AuraEnabled public String bookKey { get; set; }

        @AuraEnabled public Integer totalAssets { get; set; }
        @AuraEnabled public Integer plannedAssets { get; set; }
        @AuraEnabled public Integer inServiceAssets { get; set; }
        @AuraEnabled public Integer impairedAssets { get; set; }
        @AuraEnabled public Integer disposedAssets { get; set; }

        @AuraEnabled public Decimal grossCost { get; set; }
        @AuraEnabled public Decimal postedDepreciation { get; set; }
        @AuraEnabled public Decimal postedImpairment { get; set; }
        @AuraEnabled public Decimal disposalAmount { get; set; }
        @AuraEnabled public Decimal netBookValue { get; set; }
        @AuraEnabled public Decimal futurePlannedDepreciation { get; set; }

        @AuraEnabled public Integer reconciliationReviewCount { get; set; }
        @AuraEnabled public List<AssetRowDTO> assets { get; set; }
    }

    public class AssetRowDTO {
        @AuraEnabled public Id assetId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String assetTag { get; set; }
        @AuraEnabled public String companyAssetKey { get; set; }
        @AuraEnabled public String categoryName { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Date acquisitionDate { get; set; }
        @AuraEnabled public Date inServiceDate { get; set; }
        @AuraEnabled public Decimal cost { get; set; }
        @AuraEnabled public Decimal residualValue { get; set; }
        @AuraEnabled public Decimal postedDepreciation { get; set; }
        @AuraEnabled public Decimal postedImpairment { get; set; }
        @AuraEnabled public Decimal disposalAmount { get; set; }
        @AuraEnabled public Decimal netBookValue { get; set; }
        @AuraEnabled public Decimal futurePlannedDepreciation { get; set; }
        @AuraEnabled public Integer movementCount { get; set; }
        @AuraEnabled public Integer activeScheduleCount { get; set; }
        @AuraEnabled public String reconciliationStatus { get; set; }
    }

    public class ScheduleLineDTO {
        @AuraEnabled public Id lineId { get; set; }
        @AuraEnabled public String periodName { get; set; }
        @AuraEnabled public Date scheduledDate { get; set; }
        @AuraEnabled public Decimal plannedDepreciation { get; set; }
        @AuraEnabled public String bookKey { get; set; }
        @AuraEnabled public Decimal calculationVersion { get; set; }
        @AuraEnabled public String status { get; set; }
    }

    public class MovementDTO {
        @AuraEnabled public Id movementId { get; set; }
        @AuraEnabled public String movementType { get; set; }
        @AuraEnabled public Date movementDate { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public Decimal proceeds { get; set; }
        @AuraEnabled public String bookKey { get; set; }
        @AuraEnabled public String movementKey { get; set; }
        @AuraEnabled public String reason { get; set; }
        @AuraEnabled public Id journalEntryId { get; set; }
        @AuraEnabled public Id accountingEventId { get; set; }
    }

    public class ReconciliationDTO {
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Integer issueCount { get; set; }
        @AuraEnabled public List<String> issues { get; set; }
        @AuraEnabled public Decimal cost { get; set; }
        @AuraEnabled public Decimal postedDepreciation { get; set; }
        @AuraEnabled public Decimal postedImpairment { get; set; }
        @AuraEnabled public Decimal disposalAmount { get; set; }
        @AuraEnabled public Decimal netBookValue { get; set; }
        @AuraEnabled public Decimal residualValue { get; set; }
        @AuraEnabled public Decimal futurePlannedDepreciation { get; set; }
        @AuraEnabled public Integer overduePlannedCount { get; set; }
        @AuraEnabled public Integer duplicateMovementKeyCount { get; set; }
        @AuraEnabled public Integer duplicateScheduleKeyCount { get; set; }
    }

    public class AssetDetailDTO {
        @AuraEnabled public Id assetId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String assetTag { get; set; }
        @AuraEnabled public String companyAssetKey { get; set; }
        @AuraEnabled public String companyName { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
        @AuraEnabled public String categoryName { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Date acquisitionDate { get; set; }
        @AuraEnabled public Date inServiceDate { get; set; }
        @AuraEnabled public Decimal cost { get; set; }
        @AuraEnabled public Decimal residualValue { get; set; }
        @AuraEnabled public Integer usefulLifeMonths { get; set; }
        @AuraEnabled public String depreciationMethod { get; set; }
        @AuraEnabled public String location { get; set; }
        @AuraEnabled public String departmentName { get; set; }
        @AuraEnabled public String costCenterName { get; set; }
        @AuraEnabled public String custodianName { get; set; }
        @AuraEnabled public List<ScheduleLineDTO> scheduleLines { get; set; }
        @AuraEnabled public List<MovementDTO> movements { get; set; }
        @AuraEnabled public ReconciliationDTO reconciliation { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static List<CompanyOptionDTO> getAccessibleCompanies() {
        assertViewPermission();

        try {
            Set<Id> companyIds =
                SABCompanyAccessService.getAccessibleCompanyIds();

            if (companyIds.isEmpty()) {
                return new List<CompanyOptionDTO>();
            }

            assertCompanyObjectReadable();

            List<Accounting_Company__c> companies = [
                SELECT Id,
                       Name__c,
                       Functional_Currency__c
                FROM Accounting_Company__c
                WHERE Id IN :companyIds
                  AND Is_Active__c = true
                ORDER BY Name__c
            ];

            companies =
                stripCompanies(companies);

            List<CompanyOptionDTO> result =
                new List<CompanyOptionDTO>();

            for (Accounting_Company__c company : companies) {
                CompanyOptionDTO dto =
                    new CompanyOptionDTO();

                dto.companyId = company.Id;
                dto.name = company.Name__c;
                dto.functionalCurrency =
                    company.Functional_Currency__c;

                result.add(dto);
            }

            return result;
        } catch (Exception ex) {
            throw handled(ex);
        }
    }

    @AuraEnabled(cacheable=true)
    public static DashboardDTO getDashboard(
        Id companyId
    ) {
        assertViewPermission();

        if (companyId == null) {
            throw new AuraHandledException(
                'Accounting Company is required.'
            );
        }

        try {
            SABCompanyAccessService.assertCompanyAccess(
                companyId
            );

            assertWorkspaceObjectsReadable();

            Accounting_Company__c company = [
                SELECT Id,
                       Name__c,
                       Functional_Currency__c
                FROM Accounting_Company__c
                WHERE Id = :companyId
                LIMIT 1
            ];

            List<Fixed_Asset__c> rawAssets = [
                SELECT Id,
                       Name,
                       Asset_Tag__c,
                       Company_Asset_Key__c,
                       Company__c,
                       Asset_Category__c,
                       Asset_Category__r.Name,
                       Acquisition_Date__c,
                       In_Service_Date__c,
                       Functional_Currency_Cost__c,
                       Residual_Value__c,
                       Useful_Life_Months__c,
                       Depreciation_Method__c,
                       Status__c,
                       Location__c,
                       Department__c,
                       Department__r.Name,
                       Cost_Center__c,
                       Cost_Center__r.Name,
                       Custodian__c,
                       Custodian__r.Name
                FROM Fixed_Asset__c
                WHERE Company__c = :companyId
                ORDER BY Name
                LIMIT 200
            ];

            List<Fixed_Asset__c> assets =
                stripFixedAssets(rawAssets);

            Set<Id> assetIds =
                new Set<Id>();

            for (Fixed_Asset__c asset : assets) {
                assetIds.add(asset.Id);
            }

            Map<Id, Decimal> postedDep =
                new Map<Id, Decimal>();
            Map<Id, Decimal> futureDep =
                new Map<Id, Decimal>();
            Map<Id, Integer> activeScheduleCounts =
                new Map<Id, Integer>();
            Map<Id, Integer> overduePlannedCounts =
                new Map<Id, Integer>();

            Map<Id, Decimal> impairment =
                new Map<Id, Decimal>();
            Map<Id, Decimal> disposal =
                new Map<Id, Decimal>();
            Map<Id, Integer> movementCounts =
                new Map<Id, Integer>();

            if (!assetIds.isEmpty()) {
                for (AggregateResult row : [
                    SELECT Fixed_Asset__c assetId,
                           Status__c status,
                           SUM(Planned_Depreciation__c) total,
                           COUNT(Id) lineCount
                    FROM Asset_Schedule_Line__c
                    WHERE Fixed_Asset__c IN :assetIds
                      AND Book_Key__c = :PRIMARY_BOOK
                      AND Status__c != 'Superseded'
                    GROUP BY Fixed_Asset__c, Status__c
                ]) {
                    Id assetId =
                        (Id) row.get('assetId');
                    String status =
                        (String) row.get('status');
                    Decimal total =
                        (Decimal) row.get('total');

                    if (total == null) {
                        total = ZERO;
                    }

                    if (status == 'Posted') {
                        postedDep.put(
                            assetId,
                            total
                        );
                    }

                    if (status == 'Planned') {
                        futureDep.put(
                            assetId,
                            total
                        );

                        activeScheduleCounts.put(
                            assetId,
                            Integer.valueOf(
                                String.valueOf(
                                    row.get('lineCount')
                                )
                            )
                        );
                    }
                }

                for (AggregateResult row : [
                    SELECT Fixed_Asset__c assetId,
                           Movement_Type__c movementType,
                           SUM(Amount__c) total,
                           COUNT(Id) movementCount
                    FROM Asset_Movement__c
                    WHERE Fixed_Asset__c IN :assetIds
                      AND Book_Key__c = :PRIMARY_BOOK
                    GROUP BY Fixed_Asset__c, Movement_Type__c
                ]) {
                    Id assetId =
                        (Id) row.get('assetId');
                    String movementType =
                        (String) row.get('movementType');
                    Decimal total =
                        (Decimal) row.get('total');

                    if (total == null) {
                        total = ZERO;
                    }

                    Integer countValue =
                        Integer.valueOf(
                            String.valueOf(
                                row.get('movementCount')
                            )
                        );

                    movementCounts.put(
                        assetId,
                        (movementCounts.containsKey(assetId)
                            ? movementCounts.get(assetId)
                            : 0) + countValue
                    );

                    if (movementType == 'Impairment') {
                        impairment.put(
                            assetId,
                            total
                        );
                    }

                    if (movementType == 'Disposal') {
                        disposal.put(
                            assetId,
                            total
                        );
                    }
                }

                List<Asset_Schedule_Line__c> overdueLines =
                    stripScheduleLines([
                        SELECT Id,
                               Fixed_Asset__c,
                               Scheduled_Date__c,
                               Status__c
                        FROM Asset_Schedule_Line__c
                        WHERE Fixed_Asset__c IN :assetIds
                          AND Book_Key__c = :PRIMARY_BOOK
                          AND Status__c = 'Planned'
                          AND Scheduled_Date__c <= :Date.today()
                        LIMIT 5000
                    ]);

                for (Asset_Schedule_Line__c line : overdueLines) {
                    overduePlannedCounts.put(
                        line.Fixed_Asset__c,
                        (overduePlannedCounts.containsKey(
                            line.Fixed_Asset__c
                        )
                            ? overduePlannedCounts.get(
                                line.Fixed_Asset__c
                            )
                            : 0) + 1
                    );
                }
            }

            DashboardDTO dashboard =
                new DashboardDTO();

            dashboard.companyId = company.Id;
            dashboard.companyName = company.Name__c;
            dashboard.functionalCurrency =
                company.Functional_Currency__c;
            dashboard.bookKey = PRIMARY_BOOK;

            dashboard.totalAssets = assets.size();
            dashboard.plannedAssets = 0;
            dashboard.inServiceAssets = 0;
            dashboard.impairedAssets = 0;
            dashboard.disposedAssets = 0;
            dashboard.grossCost = ZERO;
            dashboard.postedDepreciation = ZERO;
            dashboard.postedImpairment = ZERO;
            dashboard.disposalAmount = ZERO;
            dashboard.netBookValue = ZERO;
            dashboard.futurePlannedDepreciation = ZERO;
            dashboard.reconciliationReviewCount = 0;
            dashboard.assets = new List<AssetRowDTO>();

            for (Fixed_Asset__c asset : assets) {
                Decimal cost =
                    nz(asset.Functional_Currency_Cost__c);
                Decimal residual =
                    nz(asset.Residual_Value__c);
                Decimal dep =
                    valueOrZero(
                        postedDep,
                        asset.Id
                    );
                Decimal imp =
                    valueOrZero(
                        impairment,
                        asset.Id
                    );
                Decimal disp =
                    valueOrZero(
                        disposal,
                        asset.Id
                    );
                Decimal future =
                    valueOrZero(
                        futureDep,
                        asset.Id
                    );

                Decimal nbv =
                    normalize(
                        cost
                        - dep
                        - imp
                        - disp
                    );

                dashboard.grossCost += cost;
                dashboard.postedDepreciation += dep;
                dashboard.postedImpairment += imp;
                dashboard.disposalAmount += disp;
                dashboard.netBookValue += nbv;
                dashboard.futurePlannedDepreciation += future;

                if (asset.Status__c == 'Planned') {
                    dashboard.plannedAssets++;
                } else if (asset.Status__c == 'In Service') {
                    dashboard.inServiceAssets++;
                } else if (asset.Status__c == 'Impaired') {
                    dashboard.impairedAssets++;
                } else if (asset.Status__c == 'Disposed') {
                    dashboard.disposedAssets++;
                }

                String reconciliationStatus =
                    reconciliationStatus(
                        asset.Status__c,
                        cost,
                        residual,
                        dep,
                        imp,
                        disp,
                        nbv,
                        future
                    );

                if (reconciliationStatus != 'OK') {
                    dashboard.reconciliationReviewCount++;
                }

                AssetRowDTO row =
                    new AssetRowDTO();

                row.assetId = asset.Id;
                row.name = asset.Name;
                row.assetTag = asset.Asset_Tag__c;
                row.companyAssetKey =
                    asset.Company_Asset_Key__c;
                row.categoryName =
                    asset.Asset_Category__r == null
                        ? null
                        : asset.Asset_Category__r.Name;
                row.status = asset.Status__c;
                row.acquisitionDate =
                    asset.Acquisition_Date__c;
                row.inServiceDate =
                    asset.In_Service_Date__c;
                row.cost = cost;
                row.residualValue = residual;
                row.postedDepreciation = dep;
                row.postedImpairment = imp;
                row.disposalAmount = disp;
                row.netBookValue = nbv;
                row.futurePlannedDepreciation = future;
                row.movementCount =
                    movementCounts.containsKey(asset.Id)
                        ? movementCounts.get(asset.Id)
                        : 0;
                row.activeScheduleCount =
                    activeScheduleCounts.containsKey(asset.Id)
                        ? activeScheduleCounts.get(asset.Id)
                        : 0;
                row.reconciliationStatus =
                    reconciliationStatus;

                dashboard.assets.add(row);
            }

            dashboard.grossCost =
                normalize(dashboard.grossCost);
            dashboard.postedDepreciation =
                normalize(dashboard.postedDepreciation);
            dashboard.postedImpairment =
                normalize(dashboard.postedImpairment);
            dashboard.disposalAmount =
                normalize(dashboard.disposalAmount);
            dashboard.netBookValue =
                normalize(dashboard.netBookValue);
            dashboard.futurePlannedDepreciation =
                normalize(dashboard.futurePlannedDepreciation);

            return dashboard;
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw handled(ex);
        }
    }

    @AuraEnabled(cacheable=true)
    public static AssetDetailDTO getAssetDetail(
        Id assetId
    ) {
        assertViewPermission();

        if (assetId == null) {
            throw new AuraHandledException(
                'Fixed Asset Id is required.'
            );
        }

        try {
            assertWorkspaceObjectsReadable();

            Fixed_Asset__c asset = [
                SELECT Id,
                       Name,
                       Asset_Tag__c,
                       Company_Asset_Key__c,
                       Company__c,
                       Company__r.Name__c,
                       Company__r.Functional_Currency__c,
                       Asset_Category__c,
                       Asset_Category__r.Name,
                       Status__c,
                       Acquisition_Date__c,
                       In_Service_Date__c,
                       Functional_Currency_Cost__c,
                       Residual_Value__c,
                       Useful_Life_Months__c,
                       Depreciation_Method__c,
                       Location__c,
                       Department__c,
                       Department__r.Name,
                       Cost_Center__c,
                       Cost_Center__r.Name,
                       Custodian__c,
                       Custodian__r.Name
                FROM Fixed_Asset__c
                WHERE Id = :assetId
                LIMIT 1
            ];

            SABCompanyAccessService.assertCompanyAccess(
                asset.Company__c
            );

            List<Asset_Schedule_Line__c> scheduleRows = [
                SELECT Id,
                       Fixed_Asset__c,
                       Period__c,
                       Period__r.Name,
                       Scheduled_Date__c,
                       Planned_Depreciation__c,
                       Book_Key__c,
                       Calculation_Version__c,
                       Status__c
                FROM Asset_Schedule_Line__c
                WHERE Fixed_Asset__c = :asset.Id
                ORDER BY Scheduled_Date__c, Calculation_Version__c
                LIMIT 1000
            ];

            List<Asset_Movement__c> movementRows = [
                SELECT Id,
                       Fixed_Asset__c,
                       Movement_Type__c,
                       Movement_Date__c,
                       Accounting_Date__c,
                       Amount__c,
                       Disposal_Proceeds__c,
                       Book_Key__c,
                       Movement_Key__c,
                       Reason__c,
                       Journal_Entry__c,
                       Accounting_Event__c
                FROM Asset_Movement__c
                WHERE Fixed_Asset__c = :asset.Id
                ORDER BY Accounting_Date__c DESC, CreatedDate DESC
                LIMIT 1000
            ];

            asset =
                stripFixedAssets(
                    new List<Fixed_Asset__c>{ asset }
                )[0];

            scheduleRows =
                stripScheduleLines(scheduleRows);

            movementRows =
                stripMovements(movementRows);

            AssetDetailDTO result =
                new AssetDetailDTO();

            result.assetId = asset.Id;
            result.name = asset.Name;
            result.assetTag = asset.Asset_Tag__c;
            result.companyAssetKey =
                asset.Company_Asset_Key__c;
            result.companyName =
                asset.Company__r == null
                    ? null
                    : asset.Company__r.Name__c;
            result.functionalCurrency =
                asset.Company__r == null
                    ? null
                    : asset.Company__r.Functional_Currency__c;
            result.categoryName =
                asset.Asset_Category__r == null
                    ? null
                    : asset.Asset_Category__r.Name;
            result.status = asset.Status__c;
            result.acquisitionDate =
                asset.Acquisition_Date__c;
            result.inServiceDate =
                asset.In_Service_Date__c;
            result.cost =
                nz(asset.Functional_Currency_Cost__c);
            result.residualValue =
                nz(asset.Residual_Value__c);
            result.usefulLifeMonths =
                asset.Useful_Life_Months__c == null
                    ? null
                    : Integer.valueOf(
                        String.valueOf(
                            asset.Useful_Life_Months__c
                        )
                    );
            result.depreciationMethod =
                asset.Depreciation_Method__c;
            result.location =
                asset.Location__c;
            result.departmentName =
                asset.Department__r == null
                    ? null
                    : asset.Department__r.Name;
            result.costCenterName =
                asset.Cost_Center__r == null
                    ? null
                    : asset.Cost_Center__r.Name;
            result.custodianName =
                asset.Custodian__r == null
                    ? null
                    : asset.Custodian__r.Name;

            result.scheduleLines =
                new List<ScheduleLineDTO>();

            for (Asset_Schedule_Line__c line :
                scheduleRows
            ) {
                ScheduleLineDTO dto =
                    new ScheduleLineDTO();

                dto.lineId = line.Id;
                dto.periodName =
                    line.Period__r == null
                        ? null
                        : line.Period__r.Name;
                dto.scheduledDate =
                    line.Scheduled_Date__c;
                dto.plannedDepreciation =
                    nz(line.Planned_Depreciation__c);
                dto.bookKey = line.Book_Key__c;
                dto.calculationVersion =
                    line.Calculation_Version__c;
                dto.status = line.Status__c;

                result.scheduleLines.add(dto);
            }

            result.movements =
                new List<MovementDTO>();

            for (Asset_Movement__c movement :
                movementRows
            ) {
                MovementDTO dto =
                    new MovementDTO();

                dto.movementId = movement.Id;
                dto.movementType =
                    movement.Movement_Type__c;
                dto.movementDate =
                    movement.Movement_Date__c;
                dto.accountingDate =
                    movement.Accounting_Date__c;
                dto.amount =
                    nz(movement.Amount__c);
                dto.proceeds =
                    nz(movement.Disposal_Proceeds__c);
                dto.bookKey =
                    movement.Book_Key__c;
                dto.movementKey =
                    movement.Movement_Key__c;
                dto.reason =
                    movement.Reason__c;
                dto.journalEntryId =
                    movement.Journal_Entry__c;
                dto.accountingEventId =
                    movement.Accounting_Event__c;

                result.movements.add(dto);
            }

            result.reconciliation =
                buildReconciliation(
                    asset,
                    scheduleRows,
                    movementRows
                );

            return result;
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw handled(ex);
        }
    }

    private static ReconciliationDTO buildReconciliation(
        Fixed_Asset__c asset,
        List<Asset_Schedule_Line__c> scheduleRows,
        List<Asset_Movement__c> movementRows
    ) {
        Decimal cost =
            nz(asset.Functional_Currency_Cost__c);
        Decimal residual =
            nz(asset.Residual_Value__c);

        Decimal postedDep = ZERO;
        Decimal futureDep = ZERO;
        Integer overdue = 0;

        Set<String> scheduleKeys =
            new Set<String>();
        Integer duplicateScheduleKeys = 0;

        for (Asset_Schedule_Line__c line :
            scheduleRows
        ) {
            if (line.Book_Key__c != PRIMARY_BOOK) {
                continue;
            }

            String key =
                String.valueOf(line.Scheduled_Date__c)
                + '|'
                + line.Book_Key__c
                + '|'
                + String.valueOf(
                    line.Calculation_Version__c
                );

            if (scheduleKeys.contains(key)) {
                duplicateScheduleKeys++;
            } else {
                scheduleKeys.add(key);
            }

            Decimal amount =
                nz(line.Planned_Depreciation__c);

            if (line.Status__c == 'Posted') {
                postedDep += amount;
            }

            if (line.Status__c == 'Planned') {
                futureDep += amount;

                if (
                    line.Scheduled_Date__c != null
                    && line.Scheduled_Date__c <= Date.today()
                ) {
                    overdue++;
                }
            }
        }

        Decimal impairment = ZERO;
        Decimal disposal = ZERO;

        Set<String> movementKeys =
            new Set<String>();
        Integer duplicateMovementKeys = 0;

        for (Asset_Movement__c movement :
            movementRows
        ) {
            if (movement.Book_Key__c != PRIMARY_BOOK) {
                continue;
            }

            if (
                !String.isBlank(
                    movement.Movement_Key__c
                )
            ) {
                if (
                    movementKeys.contains(
                        movement.Movement_Key__c
                    )
                ) {
                    duplicateMovementKeys++;
                } else {
                    movementKeys.add(
                        movement.Movement_Key__c
                    );
                }
            }

            Decimal amount =
                nz(movement.Amount__c);

            if (
                movement.Movement_Type__c
                    == 'Impairment'
                && movement.Accounting_Event__c != null
                && movement.Journal_Entry__c != null
            ) {
                impairment += amount;
            }

            if (
                movement.Movement_Type__c
                    == 'Disposal'
                && movement.Accounting_Event__c != null
                && movement.Journal_Entry__c != null
            ) {
                disposal += amount;
            }
        }

        Decimal nbv =
            normalize(
                cost
                - postedDep
                - impairment
                - disposal
            );

        List<String> issues =
            new List<String>();

        if (nbv < -TOLERANCE) {
            issues.add(
                'Net Book Value is negative.'
            );
        }

        if (nbv > cost + TOLERANCE) {
            issues.add(
                'Net Book Value exceeds the recorded asset cost.'
            );
        }

        if (
            postedDep
            + impairment
            + disposal
            > cost + TOLERANCE
        ) {
            issues.add(
                'Posted depreciation, impairment and disposal exceed asset cost.'
            );
        }

        if (
            asset.Status__c == 'Disposed'
            && futureDep > TOLERANCE
        ) {
            issues.add(
                'Disposed asset still has Planned depreciation schedule lines.'
            );
        }

        if (
            asset.Status__c != 'Disposed'
            && futureDep
                > Math.max(
                    ZERO,
                    nbv - residual
                ) + TOLERANCE
        ) {
            issues.add(
                'Future Planned depreciation exceeds the remaining depreciable carrying base.'
            );
        }

        if (duplicateMovementKeys > 0) {
            issues.add(
                'Duplicate Asset Movement keys were detected.'
            );
        }

        if (duplicateScheduleKeys > 0) {
            issues.add(
                'Duplicate schedule date/book/version keys were detected.'
            );
        }

        if (
            asset.Status__c == 'Disposed'
            && Math.abs(nbv) > TOLERANCE
        ) {
            issues.add(
                'Disposed asset does not reconcile to a zero carrying amount.'
            );
        }

        ReconciliationDTO result =
            new ReconciliationDTO();

        result.status =
            issues.isEmpty()
                ? 'OK'
                : 'Review';

        result.issueCount =
            issues.size();

        result.issues = issues;
        result.cost = normalize(cost);
        result.postedDepreciation =
            normalize(postedDep);
        result.postedImpairment =
            normalize(impairment);
        result.disposalAmount =
            normalize(disposal);
        result.netBookValue =
            normalize(nbv);
        result.residualValue =
            normalize(residual);
        result.futurePlannedDepreciation =
            normalize(futureDep);
        result.overduePlannedCount =
            overdue;
        result.duplicateMovementKeyCount =
            duplicateMovementKeys;
        result.duplicateScheduleKeyCount =
            duplicateScheduleKeys;

        return result;
    }

    private static String reconciliationStatus(
        String assetStatus,
        Decimal cost,
        Decimal residual,
        Decimal postedDep,
        Decimal impairment,
        Decimal disposal,
        Decimal nbv,
        Decimal futureDep
    ) {
        if (nbv < -TOLERANCE || nbv > cost + TOLERANCE) {
            return 'Review';
        }

        if (
            postedDep + impairment + disposal
                > cost + TOLERANCE
        ) {
            return 'Review';
        }

        if (
            assetStatus == 'Disposed'
            && (
                futureDep > TOLERANCE
                || Math.abs(nbv) > TOLERANCE
            )
        ) {
            return 'Review';
        }

        if (
            assetStatus != 'Disposed'
            && futureDep
                > Math.max(
                    ZERO,
                    nbv - residual
                ) + TOLERANCE
        ) {
            return 'Review';
        }

        return 'OK';
    }

    private static Decimal valueOrZero(
        Map<Id, Decimal> values,
        Id keyValue
    ) {
        return values.containsKey(keyValue)
            ? nz(values.get(keyValue))
            : ZERO;
    }

    private static Decimal nz(Decimal value) {
        return value == null
            ? ZERO
            : value;
    }

    private static Decimal normalize(Decimal value) {
        return SABMoneyService.normalizeLedgerAmount(
            nz(value),
            RoundingMode.HALF_UP
        );
    }

    private static void assertViewPermission() {
        SABPermissionService.assertPermission(
            VIEW_PERMISSION,
            'You do not have permission to view the Fixed Asset Workspace.'
        );
    }

    private static void assertWorkspaceObjectsReadable() {
        assertCompanyObjectReadable();

        if (
            !Fixed_Asset__c.SObjectType
                .getDescribe()
                .isAccessible()
        ) {
            throw new FixedAssetWorkspaceException(
                'You do not have read access to Fixed Assets.'
            );
        }

        if (
            !Asset_Schedule_Line__c.SObjectType
                .getDescribe()
                .isAccessible()
        ) {
            throw new FixedAssetWorkspaceException(
                'You do not have read access to Asset Schedule Lines.'
            );
        }

        if (
            !Asset_Movement__c.SObjectType
                .getDescribe()
                .isAccessible()
        ) {
            throw new FixedAssetWorkspaceException(
                'You do not have read access to Asset Movements.'
            );
        }
    }

    private static void assertCompanyObjectReadable() {
        if (
            !Accounting_Company__c.SObjectType
                .getDescribe()
                .isAccessible()
        ) {
            throw new FixedAssetWorkspaceException(
                'You do not have read access to Accounting Companies.'
            );
        }
    }

    private static List<Fixed_Asset__c> stripFixedAssets(
        List<Fixed_Asset__c> rows
    ) {
        if (rows == null || rows.isEmpty()) {
            return new List<Fixed_Asset__c>();
        }

        List<SObject> stripped =
            Security.stripInaccessible(
                AccessType.READABLE,
                rows
            ).getRecords();

        List<Fixed_Asset__c> result =
            new List<Fixed_Asset__c>();

        for (SObject row : stripped) {
            result.add((Fixed_Asset__c) row);
        }

        return result;
    }

    private static List<Asset_Schedule_Line__c> stripScheduleLines(
        List<Asset_Schedule_Line__c> rows
    ) {
        if (rows == null || rows.isEmpty()) {
            return new List<Asset_Schedule_Line__c>();
        }

        List<SObject> stripped =
            Security.stripInaccessible(
                AccessType.READABLE,
                rows
            ).getRecords();

        List<Asset_Schedule_Line__c> result =
            new List<Asset_Schedule_Line__c>();

        for (SObject row : stripped) {
            result.add((Asset_Schedule_Line__c) row);
        }

        return result;
    }

    private static List<Asset_Movement__c> stripMovements(
        List<Asset_Movement__c> rows
    ) {
        if (rows == null || rows.isEmpty()) {
            return new List<Asset_Movement__c>();
        }

        List<SObject> stripped =
            Security.stripInaccessible(
                AccessType.READABLE,
                rows
            ).getRecords();

        List<Asset_Movement__c> result =
            new List<Asset_Movement__c>();

        for (SObject row : stripped) {
            result.add((Asset_Movement__c) row);
        }

        return result;
    }

    private static List<Accounting_Company__c> stripCompanies(
        List<Accounting_Company__c> rows
    ) {
        if (rows == null || rows.isEmpty()) {
            return new List<Accounting_Company__c>();
        }

        List<SObject> stripped =
            Security.stripInaccessible(
                AccessType.READABLE,
                rows
            ).getRecords();

        List<Accounting_Company__c> result =
            new List<Accounting_Company__c>();

        for (SObject row : stripped) {
            result.add((Accounting_Company__c) row);
        }

        return result;
    }

    private static AuraHandledException handled(
        Exception ex
    ) {
        AuraHandledException error =
            new AuraHandledException(
                ex.getMessage()
            );
        return error;
    }
}
