/**
 * G16: guard for loans, loan schedule lines, investments and investment transactions.
 *
 * Outside the G16 services' write scope:
 *  - Loans may be inserted only as Draft (a blank status becomes Draft), edited only while Draft without touching status,
 *    approval stamps or the drawdown journal, and deleted only while Draft.
 *  - Loan schedule lines and investment transactions are system records: no direct insert, update or delete.
 *  - Investments may be inserted directly (a blank status becomes Active), but their status and GL mapping change only
 *    through SABInvestmentService.
 */
public with sharing class SABLoanInvestmentGuard {
    private static Integer scopeDepth = 0;

    /** Opened only by SABLoanService and SABInvestmentService around their own writes. */
    public static void beginWrite() {
        scopeDepth++;
    }

    public static void endWrite() {
        scopeDepth = scopeDepth > 0 ? scopeDepth - 1 : 0;
    }

    public static Boolean inWriteScope() {
        return scopeDepth > 0;
    }

    public static void guardLoans(List<Loan__c> rows, Map<Id, Loan__c> oldMap, Boolean isDelete) {
        if (!isDelete && oldMap == null) {
            for (Loan__c row : rows) {
                row.Status__c = row.Status__c == null ? 'Draft' : row.Status__c;
            }
        }
        if (inWriteScope()) {
            return;
        }
        for (Loan__c row : rows) {
            Loan__c old = oldMap == null ? null : oldMap.get(row.Id);
            String message;
            if (isDelete) {
                message = row.Status__c == 'Draft' ? null : 'Only Draft loans can be deleted.';
            } else if (old == null) {
                message = row.Status__c != 'Draft' || row.Approved_By__c != null || row.Drawdown_Journal__c != null
                    ? 'Loans start as Draft; approve them through the loan service.' : null;
            } else if (old.Status__c != 'Draft') {
                message = 'Only Draft loans can be edited; use the loan service for approval, accruals and repayments.';
            } else if (row.Status__c != old.Status__c || row.Approved_By__c != old.Approved_By__c || row.Approved_At__c != old.Approved_At__c
                    || row.Drawdown_Journal__c != old.Drawdown_Journal__c) {
                message = 'Loan status, approval and drawdown fields change only through the loan service.';
            }
            if (message != null) {
                row.addError(message);
            }
        }
    }

    public static void guardSystemRecords(List<SObject> rows, String label) {
        if (inWriteScope()) {
            return;
        }
        for (SObject row : rows) {
            row.addError(label + ' records are created and maintained only by the G16 services.');
        }
    }

    public static void guardInvestments(List<Investment__c> rows, Map<Id, Investment__c> oldMap) {
        if (oldMap == null) {
            for (Investment__c row : rows) {
                row.Status__c = row.Status__c == null ? 'Active' : row.Status__c;
            }
        }
        if (inWriteScope() || oldMap == null) {
            return;
        }
        for (Investment__c row : rows) {
            Investment__c old = oldMap.get(row.Id);
            if (row.Status__c != old.Status__c || row.Investment_Account__c != old.Investment_Account__c
                    || row.Income_Account__c != old.Income_Account__c || row.Gain_Loss_Account__c != old.Gain_Loss_Account__c
                    || row.Fee_Account__c != old.Fee_Account__c || row.Bank_Account__c != old.Bank_Account__c
                    || row.Valuation_Policy_Key__c != old.Valuation_Policy_Key__c || row.Company__c != old.Company__c) {
                row.addError('Investment status, company, valuation policy and GL mapping change only through the investment service.');
            }
        }
    }
}
