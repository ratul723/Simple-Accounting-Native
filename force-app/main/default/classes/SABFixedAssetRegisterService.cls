/**
 * G9A - Fixed Asset Register Foundation & Acquisition Linkage.
 *
 * Scope:
 * - controlled Fixed Asset registration
 * - Asset Category / GL mapping validation
 * - optional linkage to a Posted Supplier Bill Line
 * - functional-currency acquisition cost derivation when a source bill line is used
 * - company/dimension isolation
 * - no second acquisition journal is created
 */
public with sharing class SABFixedAssetRegisterService {

    public class FixedAssetRegisterException extends Exception {}

    private static final String PERMISSION =
        'SAB_Manage_Fixed_Assets';
    private static final Decimal ZERO =
        Decimal.valueOf('0');

    @TestVisible
    private static Boolean mutationInProgress = false;

    public static Boolean isMutationInProgress() {
        return mutationInProgress;
    }

    public class RegistrationRequest {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String assetName { get; set; }
        @AuraEnabled public String companyAssetKey { get; set; }
        @AuraEnabled public Id assetCategoryId { get; set; }
        @AuraEnabled public Id sourceBillLineId { get; set; }
        @AuraEnabled public Date acquisitionDate { get; set; }
        @AuraEnabled public Date inServiceDate { get; set; }
        @AuraEnabled public Decimal functionalCurrencyCost { get; set; }
        @AuraEnabled public Decimal residualValue { get; set; }
        @AuraEnabled public Integer usefulLifeMonths { get; set; }
        @AuraEnabled public String depreciationMethod { get; set; }
        @AuraEnabled public String assetTag { get; set; }
        @AuraEnabled public Id custodianId { get; set; }
        @AuraEnabled public Id departmentId { get; set; }
        @AuraEnabled public Id costCenterId { get; set; }
        @AuraEnabled public String location { get; set; }
        @AuraEnabled public String initialStatus { get; set; }
    }

    public class RegistrationResult {
        @AuraEnabled public Id fixedAssetId { get; private set; }
        @AuraEnabled public String status { get; private set; }
        @AuraEnabled public Decimal functionalCurrencyCost { get; private set; }
        @AuraEnabled public Boolean sourceBillLinked { get; private set; }

        private RegistrationResult() {}
    }

    @AuraEnabled
    public static RegistrationResult registerAsset(
        RegistrationRequest request
    ) {
        SABPermissionService.assertPermission(
            PERMISSION,
            'You do not have permission to manage Fixed Assets.'
        );

        validateRequiredRequest(request);

        SABCompanyAccessService.assertCompanyAccess(
            request.companyId
        );

        Asset_Category__c category = loadCategory(
            request.assetCategoryId
        );

        validateCategory(
            category,
            request.companyId
        );

        Decimal cost =
            request.functionalCurrencyCost == null
                ? null
                : SABMoneyService.normalizeLedgerAmount(
                    request.functionalCurrencyCost,
                    RoundingMode.HALF_UP
                );

        Id departmentId = request.departmentId;
        Id costCenterId = request.costCenterId;

        if (request.sourceBillLineId != null) {
            Bill_Line__c sourceLine =
                loadSourceBillLine(
                    request.sourceBillLineId
                );

            validateSourceBillLine(
                sourceLine,
                request.companyId,
                category.Asset_Account__c
            );

            Decimal sourceCost =
                deriveFunctionalSourceCost(sourceLine);

            if (
                cost != null
                && cost != sourceCost
            ) {
                throw new FixedAssetRegisterException(
                    'Functional Currency Cost must match the capitalized cost of the Posted Supplier Bill Line.'
                );
            }

            cost = sourceCost;

            if (departmentId == null) {
                departmentId =
                    sourceLine.Department__c;
            }

            if (costCenterId == null) {
                costCenterId =
                    sourceLine.Cost_Center__c;
            }
        }

        if (cost == null || cost <= ZERO) {
            throw new FixedAssetRegisterException(
                'Functional Currency Cost must be greater than zero.'
            );
        }

        Decimal residual =
            request.residualValue == null
                ? ZERO
                : SABMoneyService.normalizeLedgerAmount(
                    request.residualValue,
                    RoundingMode.HALF_UP
                );

        if (residual < ZERO) {
            throw new FixedAssetRegisterException(
                'Residual Value cannot be negative.'
            );
        }

        if (residual > cost) {
            throw new FixedAssetRegisterException(
                'Residual Value cannot exceed Functional Currency Cost.'
            );
        }

        Integer usefulLife =
            request.usefulLifeMonths;

        if (
            usefulLife == null
            && category.Default_Useful_Life_Months__c != null
        ) {
            usefulLife =
                Integer.valueOf(
                    category.Default_Useful_Life_Months__c
                );
        }

        if (usefulLife == null || usefulLife <= 0) {
            throw new FixedAssetRegisterException(
                'Useful Life Months must be greater than zero.'
            );
        }

        String method =
            String.isBlank(request.depreciationMethod)
                ? 'Straight Line'
                : request.depreciationMethod.trim();

        validateDepreciationMethod(
            category,
            method
        );

        if (
            request.inServiceDate
                < request.acquisitionDate
        ) {
            throw new FixedAssetRegisterException(
                'In Service Date cannot be earlier than Acquisition Date.'
            );
        }

        validateOptionalCompanyRelationships(
            request.companyId,
            request.custodianId,
            departmentId,
            costCenterId
        );

        String status =
            resolveInitialStatus(
                request.initialStatus,
                request.inServiceDate
            );

        Fixed_Asset__c asset =
            new Fixed_Asset__c(
                Name = request.assetName.trim(),
                Company__c = request.companyId,
                Company_Asset_Key__c =
                    request.companyAssetKey.trim(),
                Asset_Category__c =
                    request.assetCategoryId,
                Source_Bill_Line__c =
                    request.sourceBillLineId,
                Acquisition_Date__c =
                    request.acquisitionDate,
                In_Service_Date__c =
                    request.inServiceDate,
                Functional_Currency_Cost__c =
                    cost,
                Residual_Value__c =
                    residual,
                Useful_Life_Months__c =
                    usefulLife,
                Depreciation_Method__c =
                    method,
                Status__c =
                    status,
                Asset_Tag__c =
                    normalizeOptionalText(
                        request.assetTag
                    ),
                Custodian__c =
                    request.custodianId,
                Department__c =
                    departmentId,
                Cost_Center__c =
                    costCenterId,
                Location__c =
                    normalizeOptionalText(
                        request.location
                    )
            );

        mutationInProgress = true;
        try {
            insert asset;
        } finally {
            mutationInProgress = false;
        }

        RegistrationResult result =
            new RegistrationResult();
        result.fixedAssetId = asset.Id;
        result.status = asset.Status__c;
        result.functionalCurrencyCost =
            asset.Functional_Currency_Cost__c;
        result.sourceBillLinked =
            asset.Source_Bill_Line__c != null;
        return result;
    }

    private static void validateRequiredRequest(
        RegistrationRequest request
    ) {
        if (request == null) {
            throw new FixedAssetRegisterException(
                'Fixed Asset registration request is required.'
            );
        }

        if (request.companyId == null) {
            throw new FixedAssetRegisterException(
                'Accounting Company is required.'
            );
        }

        if (String.isBlank(request.assetName)) {
            throw new FixedAssetRegisterException(
                'Fixed Asset Name is required.'
            );
        }

        if (String.isBlank(request.companyAssetKey)) {
            throw new FixedAssetRegisterException(
                'Company Asset Key is required.'
            );
        }

        if (request.assetCategoryId == null) {
            throw new FixedAssetRegisterException(
                'Asset Category is required.'
            );
        }

        if (request.acquisitionDate == null) {
            throw new FixedAssetRegisterException(
                'Acquisition Date is required.'
            );
        }

        if (request.inServiceDate == null) {
            throw new FixedAssetRegisterException(
                'In Service Date is required.'
            );
        }
    }

    private static Asset_Category__c loadCategory(
        Id categoryId
    ) {
        List<Asset_Category__c> rows = [
            SELECT Id,
                   Company__c,
                   Is_Active__c,
                   Allowed_Methods__c,
                   Default_Useful_Life_Months__c,
                   Asset_Account__c,
                   Asset_Account__r.Company__c,
                   Asset_Account__r.Is_Active__c,
                   Asset_Account__r.Account_Type__c,
                   Accumulated_Depreciation_Account__c,
                   Accumulated_Depreciation_Account__r.Company__c,
                   Accumulated_Depreciation_Account__r.Is_Active__c,
                   Accumulated_Depreciation_Account__r.Account_Type__c,
                   Depreciation_Expense_Account__c,
                   Depreciation_Expense_Account__r.Company__c,
                   Depreciation_Expense_Account__r.Is_Active__c,
                   Depreciation_Expense_Account__r.Account_Type__c,
                   Disposal_Gain_Loss_Account__c,
                   Disposal_Gain_Loss_Account__r.Company__c,
                   Disposal_Gain_Loss_Account__r.Is_Active__c,
                   Disposal_Gain_Loss_Account__r.Account_Type__c
            FROM Asset_Category__c
            WHERE Id = :categoryId
            LIMIT 1
        ];

        if (rows.isEmpty()) {
            throw new FixedAssetRegisterException(
                'Asset Category was not found.'
            );
        }

        return rows[0];
    }

    private static void validateCategory(
        Asset_Category__c category,
        Id companyId
    ) {
        if (
            category.Company__c == null
            || category.Company__c != companyId
        ) {
            throw new FixedAssetRegisterException(
                'Asset Category must belong to the same Accounting Company.'
            );
        }

        if (category.Is_Active__c != true) {
            throw new FixedAssetRegisterException(
                'Asset Category must be active.'
            );
        }

        validateMappedAccount(
            category.Asset_Account__r,
            companyId,
            'Asset',
            'Asset Account'
        );

        validateMappedAccount(
            category.Accumulated_Depreciation_Account__r,
            companyId,
            'Asset',
            'Accumulated Depreciation Account'
        );

        validateMappedAccount(
            category.Depreciation_Expense_Account__r,
            companyId,
            'Expense',
            'Depreciation Expense Account'
        );

        if (
            category.Disposal_Gain_Loss_Account__r == null
            || category.Disposal_Gain_Loss_Account__r.Company__c
                != companyId
            || category.Disposal_Gain_Loss_Account__r.Is_Active__c
                != true
            || (
                category.Disposal_Gain_Loss_Account__r.Account_Type__c
                    != 'Revenue'
                && category.Disposal_Gain_Loss_Account__r.Account_Type__c
                    != 'Expense'
            )
        ) {
            throw new FixedAssetRegisterException(
                'Disposal Gain/Loss Account must be an active Revenue or Expense account in the same Accounting Company.'
            );
        }
    }

    private static void validateMappedAccount(
        GL_Account__c account,
        Id companyId,
        String expectedType,
        String label
    ) {
        if (
            account == null
            || account.Company__c != companyId
            || account.Is_Active__c != true
            || account.Account_Type__c != expectedType
        ) {
            throw new FixedAssetRegisterException(
                label
                + ' must be an active '
                + expectedType
                + ' account in the same Accounting Company.'
            );
        }
    }

    private static Bill_Line__c loadSourceBillLine(
        Id sourceBillLineId
    ) {
        List<Bill_Line__c> rows = [
            SELECT Id,
                   Supplier_Bill__c,
                   Supplier_Bill__r.Company__c,
                   Supplier_Bill__r.Status__c,
                   Supplier_Bill__r.Transaction_Currency__c,
                   Supplier_Bill__r.Functional_Currency__c,
                   Supplier_Bill__r.Exchange_Rate__c,
                   Expense_or_Asset_Account__c,
                   Expense_or_Asset_Account__r.Company__c,
                   Expense_or_Asset_Account__r.Is_Active__c,
                   Expense_or_Asset_Account__r.Account_Type__c,
                   Net_Amount__c,
                   Nonrecoverable_Tax_Amount__c,
                   Department__c,
                   Cost_Center__c
            FROM Bill_Line__c
            WHERE Id = :sourceBillLineId
            LIMIT 1
        ];

        if (rows.isEmpty()) {
            throw new FixedAssetRegisterException(
                'Source Supplier Bill Line was not found.'
            );
        }

        return rows[0];
    }

    private static void validateSourceBillLine(
        Bill_Line__c line,
        Id companyId,
        Id categoryAssetAccountId
    ) {
        if (
            line.Supplier_Bill__r == null
            || line.Supplier_Bill__r.Company__c
                != companyId
        ) {
            throw new FixedAssetRegisterException(
                'Source Supplier Bill Line must belong to the same Accounting Company.'
            );
        }

        if (
            line.Supplier_Bill__r.Status__c
                != 'Posted'
        ) {
            throw new FixedAssetRegisterException(
                'Source Supplier Bill must be Posted before a Fixed Asset can be registered from its line.'
            );
        }

        if (
            line.Expense_or_Asset_Account__c == null
            || line.Expense_or_Asset_Account__c
                != categoryAssetAccountId
            || line.Expense_or_Asset_Account__r == null
            || line.Expense_or_Asset_Account__r.Company__c
                != companyId
            || line.Expense_or_Asset_Account__r.Is_Active__c
                != true
            || line.Expense_or_Asset_Account__r.Account_Type__c
                != 'Asset'
        ) {
            throw new FixedAssetRegisterException(
                'Source Supplier Bill Line must have posted to the Asset Category Asset Account.'
            );
        }
    }

    private static Decimal deriveFunctionalSourceCost(
        Bill_Line__c line
    ) {
        Decimal transactionAmount =
            SABMoneyService.normalizeTransactionAmount(
                nullToZero(line.Net_Amount__c)
                + nullToZero(
                    line.Nonrecoverable_Tax_Amount__c
                ),
                RoundingMode.HALF_UP
            );

        if (transactionAmount <= ZERO) {
            throw new FixedAssetRegisterException(
                'Source Supplier Bill Line capitalized amount must be greater than zero.'
            );
        }

        String transactionCurrency =
            SABMoneyService.normalizeCurrencyCode(
                line.Supplier_Bill__r.Transaction_Currency__c
            );

        String functionalCurrency =
            SABMoneyService.normalizeCurrencyCode(
                line.Supplier_Bill__r.Functional_Currency__c
            );

        Decimal effectiveRate =
            transactionCurrency == functionalCurrency
                ? Decimal.valueOf('1')
                : line.Supplier_Bill__r.Exchange_Rate__c;

        SABMoneyService.ConversionResult conversion =
            SABMoneyService.convertToFunctional(
                transactionAmount,
                transactionCurrency,
                functionalCurrency,
                effectiveRate,
                RoundingMode.HALF_UP
            );

        return conversion.functionalAmount;
    }

    private static void validateDepreciationMethod(
        Asset_Category__c category,
        String method
    ) {
        if (
            method != 'Straight Line'
            && method != 'Other Supported'
        ) {
            throw new FixedAssetRegisterException(
                'Unsupported Depreciation Method.'
            );
        }

        if (
            !String.isBlank(category.Allowed_Methods__c)
        ) {
            Set<String> allowed = new Set<String>();

            for (
                String raw :
                category.Allowed_Methods__c.split('[,;|]')
            ) {
                if (!String.isBlank(raw)) {
                    allowed.add(raw.trim());
                }
            }

            if (
                !allowed.isEmpty()
                && !allowed.contains(method)
            ) {
                throw new FixedAssetRegisterException(
                    'Depreciation Method is not allowed by the selected Asset Category.'
                );
            }
        }
    }

    private static void validateOptionalCompanyRelationships(
        Id companyId,
        Id custodianId,
        Id departmentId,
        Id costCenterId
    ) {
        if (departmentId != null) {
            Department__c department = [
                SELECT Id, Company__c
                FROM Department__c
                WHERE Id = :departmentId
                LIMIT 1
            ];

            if (department.Company__c != companyId) {
                throw new FixedAssetRegisterException(
                    'Department must belong to the same Accounting Company.'
                );
            }
        }

        if (costCenterId != null) {
            Cost_Center__c costCenter = [
                SELECT Id, Company__c
                FROM Cost_Center__c
                WHERE Id = :costCenterId
                LIMIT 1
            ];

            if (costCenter.Company__c != companyId) {
                throw new FixedAssetRegisterException(
                    'Cost Center must belong to the same Accounting Company.'
                );
            }
        }

        if (custodianId != null) {
            Integer activeEmploymentCount = [
                SELECT COUNT()
                FROM Employment__c
                WHERE Employee__c = :custodianId
                  AND Company__c = :companyId
                  AND Employment_Status__c = 'Active'
            ];

            if (activeEmploymentCount == 0) {
                throw new FixedAssetRegisterException(
                    'Custodian must have an active Employment in the same Accounting Company.'
                );
            }
        }
    }

    private static String resolveInitialStatus(
        String requestedStatus,
        Date inServiceDate
    ) {
        String status =
            String.isBlank(requestedStatus)
                ? (
                    inServiceDate <= Date.today()
                        ? 'In Service'
                        : 'Planned'
                )
                : requestedStatus.trim();

        if (
            status != 'Planned'
            && status != 'In Service'
        ) {
            throw new FixedAssetRegisterException(
                'A new Fixed Asset can start only as Planned or In Service.'
            );
        }

        if (
            status == 'In Service'
            && inServiceDate > Date.today()
        ) {
            throw new FixedAssetRegisterException(
                'An In Service Fixed Asset cannot have a future In Service Date.'
            );
        }

        return status;
    }

    private static Decimal nullToZero(
        Decimal value
    ) {
        return value == null ? ZERO : value;
    }

    private static String normalizeOptionalText(
        String value
    ) {
        return String.isBlank(value)
            ? null
            : value.trim();
    }
}
