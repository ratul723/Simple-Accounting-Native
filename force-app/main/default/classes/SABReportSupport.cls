/**
 * G21: shared helpers for the management reports: authorization, cash account resolution and report-run logging.
 * Reads run in system mode only after SAB_View_Management_Reports and the company grant have been checked.
 */
public with sharing class SABReportSupport {
    public class ReportException extends Exception {}

    private static final String VIEW = 'SAB_View_Management_Reports';

    public static void authorize(Id companyId) {
        SABPermissionService.assertPermission(VIEW, 'Management report permission is required.');
        if (companyId == null) {
            throw new ReportException('Select an Accounting Company first.');
        }
        SABCompanyAccessService.assertCompanyAccess(companyId);
    }

    /** GL accounts behind the company's bank accounts plus accounts whose cash flow category is Cash. */
    public static Set<Id> cashAccounts(Id companyId) {
        return new Store().cashAccounts(companyId);
    }

    /** Logs a completed report run with its parameters and a SHA-256 hash of the output. */
    public static void logRun(Id companyId, String reportType, Map<String, Object> parameters, Object output) {
        new Writer().log(new Report_Run__c(Company__c = companyId, Report_Type__c = reportType, Status__c = 'Complete',
            Currency_Basis__c = 'Functional', Generated_By__c = UserInfo.getUserId(), Generated_At__c = System.now(), Freshness_At__c = System.now(),
            Parameter_JSON__c = JSON.serialize(parameters),
            Output_Hash__c = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(JSON.serialize(output))))));
    }

    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Set<Id> cashAccounts(Id companyId) {
            Set<Id> ids = new Set<Id>();
            for (Bank_Account__c b : [SELECT GL_Account__c FROM Bank_Account__c WHERE Company__c = :companyId WITH SYSTEM_MODE LIMIT 500]) {
                ids.add(b.GL_Account__c);
            }
            for (GL_Account__c a : [SELECT Id FROM GL_Account__c WHERE Company__c = :companyId AND Cash_Flow_Category__c = 'Cash'
                    WITH SYSTEM_MODE LIMIT 500]) {
                ids.add(a.Id);
            }
            return ids;
        }
    }

    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void log(Report_Run__c run) {
            insert as system run;
        }
    }
}
