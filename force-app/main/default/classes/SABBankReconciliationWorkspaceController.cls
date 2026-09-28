public with sharing class SABBankReconciliationWorkspaceController {
    private static final Decimal ZERO = Decimal.valueOf('0');

    public class BankAccountDTO {
        @AuraEnabled public Id bankAccountId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String bankName { get; set; }
        @AuraEnabled public String maskedAccountNumber { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Boolean active { get; set; }
        @AuraEnabled public Id glAccountId { get; set; }
        @AuraEnabled public String glAccountCode { get; set; }
        @AuraEnabled public String glAccountName { get; set; }
        @AuraEnabled public Decimal currentBookBalance { get; set; }
        @AuraEnabled public Id latestStatementId { get; set; }
        @AuraEnabled public String latestStatementName { get; set; }
        @AuraEnabled public Date latestStatementEndDate { get; set; }
        @AuraEnabled public Decimal latestStatementClosingAmount { get; set; }
        @AuraEnabled public String latestStatementStatus { get; set; }
        @AuraEnabled public Id latestReconciliationId { get; set; }
        @AuraEnabled public String latestReconciliationStatus { get; set; }
        @AuraEnabled public Decimal latestDifference { get; set; }
    }

    public class StatementOptionDTO {
        @AuraEnabled public Id statementId { get; set; }
        @AuraEnabled public Id bankAccountId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public Date startDate { get; set; }
        @AuraEnabled public Date endDate { get; set; }
        @AuraEnabled public Decimal openingAmount { get; set; }
        @AuraEnabled public Decimal closingAmount { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String label { get; set; }
    }

    public class DashboardDTO {
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public String companyName { get; set; }
        @AuraEnabled public String functionalCurrency { get; set; }
        @AuraEnabled public Boolean canImport { get; set; }
        @AuraEnabled public Boolean canReconcile { get; set; }
        @AuraEnabled public Boolean canFinalize { get; set; }
        @AuraEnabled public Integer bankAccountCount { get; set; }
        @AuraEnabled public Integer statementCount { get; set; }
        @AuraEnabled public Integer validatedStatementCount { get; set; }
        @AuraEnabled public Integer reconciledStatementCount { get; set; }
        @AuraEnabled public Integer inReviewReconciliationCount { get; set; }
        @AuraEnabled public Decimal functionalCurrencyBookCash { get; set; }
        @AuraEnabled public Integer excludedForeignCurrencyBankCount { get; set; }
        @AuraEnabled public List<BankAccountDTO> bankAccounts { get; set; }
        @AuraEnabled public List<StatementOptionDTO> statements { get; set; }
    }

    public class StatementLineDTO {
        @AuraEnabled public Id lineId { get; set; }
        @AuraEnabled public Decimal lineNumber { get; set; }
        @AuraEnabled public Date transactionDate { get; set; }
        @AuraEnabled public Date valueDate { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public String providerLineId { get; set; }
        @AuraEnabled public String reference { get; set; }
        @AuraEnabled public Decimal activeMatchedAmount { get; set; }
        @AuraEnabled public Decimal remainingAmount { get; set; }
        @AuraEnabled public Boolean fullyMatched { get; set; }
    }

    public class MatchDTO {
        @AuraEnabled public Id matchId { get; set; }
        @AuraEnabled public Id statementLineId { get; set; }
        @AuraEnabled public Id journalEntryLineId { get; set; }
        @AuraEnabled public Id journalEntryId { get; set; }
        @AuraEnabled public String journalName { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public String matchType { get; set; }
        @AuraEnabled public Decimal matchedAmount { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Id reversalOfId { get; set; }
    }

    public class StatementWorkspaceDTO {
        @AuraEnabled public Id statementId { get; set; }
        @AuraEnabled public String statementName { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public Id bankAccountId { get; set; }
        @AuraEnabled public String bankAccountName { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Date startDate { get; set; }
        @AuraEnabled public Date endDate { get; set; }
        @AuraEnabled public Decimal openingAmount { get; set; }
        @AuraEnabled public Decimal closingAmount { get; set; }
        @AuraEnabled public String statementStatus { get; set; }
        @AuraEnabled public Id reconciliationId { get; set; }
        @AuraEnabled public String reconciliationName { get; set; }
        @AuraEnabled public String reconciliationStatus { get; set; }
        @AuraEnabled public Decimal storedBookClosingAmount { get; set; }
        @AuraEnabled public Decimal storedStatementClosingAmount { get; set; }
        @AuraEnabled public Decimal storedDifference { get; set; }
        @AuraEnabled public Id approvedById { get; set; }
        @AuraEnabled public Datetime approvedAt { get; set; }
        @AuraEnabled public Decimal provisionalBookClosingAmount { get; set; }
        @AuraEnabled public Decimal provisionalDifference { get; set; }
        @AuraEnabled public Integer lineCount { get; set; }
        @AuraEnabled public Integer fullyMatchedLineCount { get; set; }
        @AuraEnabled public Integer proposedMatchCount { get; set; }
        @AuraEnabled public Integer confirmedMatchCount { get; set; }
        @AuraEnabled public Boolean allLinesFullyMatched { get; set; }
        @AuraEnabled public Boolean hasProposedMatches { get; set; }
        @AuraEnabled public Boolean canFinalizeNow { get; set; }
        @AuraEnabled public List<StatementLineDTO> lines { get; set; }
        @AuraEnabled public List<MatchDTO> matches { get; set; }
    }

    public class ImportLineInput {
        @AuraEnabled public Decimal lineNumber { get; set; }
        @AuraEnabled public Date transactionDate { get; set; }
        @AuraEnabled public Date valueDate { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public String providerLineId { get; set; }
        @AuraEnabled public String reference { get; set; }
        @AuraEnabled public String sourceRawText { get; set; }
        @AuraEnabled public String lineFingerprint { get; set; }
    }

    public class ImportStatementInput {
        @AuraEnabled public Id bankAccountId { get; set; }
        @AuraEnabled public Date statementStartDate { get; set; }
        @AuraEnabled public Date statementEndDate { get; set; }
        @AuraEnabled public Decimal openingAmount { get; set; }
        @AuraEnabled public Decimal closingAmount { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public String importFingerprint { get; set; }
        @AuraEnabled public List<ImportLineInput> lines { get; set; }
    }

    public class CandidateDTO {
        @AuraEnabled public Id journalEntryLineId { get; set; }
        @AuraEnabled public Id journalEntryId { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public String journalDescription { get; set; }
        @AuraEnabled public Decimal journalAmount { get; set; }
        @AuraEnabled public Decimal journalRemainingAmount { get; set; }
        @AuraEnabled public Decimal statementRemainingAmount { get; set; }
        @AuraEnabled public Decimal suggestedMatchAmount { get; set; }
        @AuraEnabled public Integer dateDifferenceDays { get; set; }
        @AuraEnabled public Boolean exactAmount { get; set; }
        @AuraEnabled public String transactionCurrency { get; set; }
        @AuraEnabled public String sourceLineKey { get; set; }
    }

    public class ActionResultDTO {
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public Id secondaryRecordId { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String message { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static DashboardDTO getDashboard(Id companyId) {
        try {
            SABPermissionService.assertPermission(
                'SAB_View_Bank_Detail',
                'You do not have permission to view Bank Reconciliation details.'
            );
            if (companyId == null) {
                throw new AuraHandledException('Accounting Company is required.');
            }

            SABCompanyAccessService.assertCompanyAccess(companyId);

            Accounting_Company__c company = [
                SELECT Id, Name__c, Functional_Currency__c
                FROM Accounting_Company__c
                WHERE Id = :companyId
                LIMIT 1
            ];

            List<Bank_Account__c> bankAccounts = [
                SELECT Id, Name, Bank_Name__c, Masked_Account_Number__c,
                       Currency__c, GL_Account__c,
                       GL_Account__r.Account_Code__c, GL_Account__r.Name,
                       Is_Active__c
                FROM Bank_Account__c
                WHERE Company__c = :companyId
                ORDER BY Is_Active__c DESC, Name ASC
                LIMIT 500
            ];

            Set<Id> bankIds = new Set<Id>();
            Set<Id> glIds = new Set<Id>();
            for (Bank_Account__c b : bankAccounts) {
                bankIds.add(b.Id);
                if (b.GL_Account__c != null) glIds.add(b.GL_Account__c);
            }

            Map<Id, Decimal> balances =
                calculateBookBalanceByGL(companyId, glIds, Date.today());

            List<Bank_Statement__c> statements =
                bankIds.isEmpty()
                    ? new List<Bank_Statement__c>()
                    : [
                        SELECT Id, Name, Bank_Account__c,
                               Statement_Start_Date__c, Statement_End_Date__c,
                               Opening_Amount__c, Closing_Amount__c,
                               Currency__c, Status__c
                        FROM Bank_Statement__c
                        WHERE Company__c = :companyId
                          AND Bank_Account__c IN :bankIds
                        ORDER BY Statement_End_Date__c DESC, CreatedDate DESC
                        LIMIT 2000
                    ];

            Map<Id, Bank_Statement__c> latestStatementByBank =
                new Map<Id, Bank_Statement__c>();
            Set<Id> statementIds = new Set<Id>();
            Integer validated = 0;
            Integer reconciled = 0;

            for (Bank_Statement__c s : statements) {
                statementIds.add(s.Id);
                if (!latestStatementByBank.containsKey(s.Bank_Account__c)) {
                    latestStatementByBank.put(s.Bank_Account__c, s);
                }
                if (s.Status__c == 'Validated') validated++;
                if (s.Status__c == 'Reconciled') reconciled++;
            }

            Map<Id, Bank_Reconciliation__c> latestReconByStatement =
                new Map<Id, Bank_Reconciliation__c>();
            Integer inReview = 0;

            if (!statementIds.isEmpty()) {
                for (Bank_Reconciliation__c r : [
                    SELECT Id, Bank_Statement__c, Status__c,
                           Difference__c, CreatedDate
                    FROM Bank_Reconciliation__c
                    WHERE Bank_Statement__c IN :statementIds
                    ORDER BY CreatedDate DESC
                ]) {
                    if (!latestReconByStatement.containsKey(r.Bank_Statement__c)) {
                        latestReconByStatement.put(r.Bank_Statement__c, r);
                    }
                    if (r.Status__c == 'In Review') inReview++;
                }
            }

            DashboardDTO out = new DashboardDTO();
            out.companyId = company.Id;
            out.companyName = company.Name__c;
            out.functionalCurrency = company.Functional_Currency__c;
            out.canImport = SABPermissionService.hasPermission('SAB_Import_Bank_Statement');
            out.canReconcile = SABPermissionService.hasPermission('SAB_Reconcile_Bank');
            out.canFinalize = SABPermissionService.hasPermission('SAB_Finalize_Bank_Reconciliation');
            out.bankAccountCount = bankAccounts.size();
            out.statementCount = statements.size();
            out.validatedStatementCount = validated;
            out.reconciledStatementCount = reconciled;
            out.inReviewReconciliationCount = inReview;
            out.functionalCurrencyBookCash = ZERO;
            out.excludedForeignCurrencyBankCount = 0;
            out.bankAccounts = new List<BankAccountDTO>();
            out.statements = new List<StatementOptionDTO>();

            String functional =
                SABMoneyService.normalizeCurrencyCode(
                    company.Functional_Currency__c
                );

            for (Bank_Account__c b : bankAccounts) {
                BankAccountDTO dto = new BankAccountDTO();
                dto.bankAccountId = b.Id;
                dto.name = b.Name;
                dto.bankName = b.Bank_Name__c;
                dto.maskedAccountNumber = b.Masked_Account_Number__c;
                dto.currencyCode = b.Currency__c;
                dto.active = b.Is_Active__c;
                dto.glAccountId = b.GL_Account__c;
                dto.glAccountCode = b.GL_Account__r == null
                    ? null : b.GL_Account__r.Account_Code__c;
                dto.glAccountName = b.GL_Account__r == null
                    ? null : b.GL_Account__r.Name;
                dto.currentBookBalance =
                    b.GL_Account__c != null && balances.containsKey(b.GL_Account__c)
                        ? balances.get(b.GL_Account__c) : ZERO;

                Bank_Statement__c latest = latestStatementByBank.get(b.Id);
                if (latest != null) {
                    dto.latestStatementId = latest.Id;
                    dto.latestStatementName = latest.Name;
                    dto.latestStatementEndDate = latest.Statement_End_Date__c;
                    dto.latestStatementClosingAmount = latest.Closing_Amount__c;
                    dto.latestStatementStatus = latest.Status__c;

                    Bank_Reconciliation__c lr =
                        latestReconByStatement.get(latest.Id);
                    if (lr != null) {
                        dto.latestReconciliationId = lr.Id;
                        dto.latestReconciliationStatus = lr.Status__c;
                        dto.latestDifference = lr.Difference__c;
                    }
                }

                if (
                    SABMoneyService.normalizeCurrencyCode(b.Currency__c)
                    == functional
                ) {
                    out.functionalCurrencyBookCash += dto.currentBookBalance;
                } else {
                    out.excludedForeignCurrencyBankCount++;
                }

                out.bankAccounts.add(dto);
            }

            for (Bank_Statement__c s : statements) {
                StatementOptionDTO dto = new StatementOptionDTO();
                dto.statementId = s.Id;
                dto.bankAccountId = s.Bank_Account__c;
                dto.name = s.Name;
                dto.startDate = s.Statement_Start_Date__c;
                dto.endDate = s.Statement_End_Date__c;
                dto.openingAmount = s.Opening_Amount__c;
                dto.closingAmount = s.Closing_Amount__c;
                dto.currencyCode = s.Currency__c;
                dto.status = s.Status__c;
                dto.label = s.Name + ' · ' + String.valueOf(s.Statement_End_Date__c)
                    + ' · ' + s.Status__c;
                out.statements.add(dto);
            }

            return out;
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static StatementWorkspaceDTO getStatementWorkspace(
        Id bankStatementId
    ) {
        try {
            SABPermissionService.assertPermission(
                'SAB_View_Bank_Detail',
                'You do not have permission to view Bank Reconciliation details.'
            );
            if (bankStatementId == null) {
                throw new AuraHandledException('Bank Statement is required.');
            }

            Bank_Statement__c s = [
                SELECT Id, Name, Company__c, Bank_Account__c,
                       Bank_Account__r.Name, Bank_Account__r.GL_Account__c,
                       Statement_Start_Date__c, Statement_End_Date__c,
                       Opening_Amount__c, Closing_Amount__c,
                       Currency__c, Status__c
                FROM Bank_Statement__c
                WHERE Id = :bankStatementId
                LIMIT 1
            ];

            SABCompanyAccessService.assertCompanyAccess(s.Company__c);
            SABAccessControlService.assertRecordReadAccess(s.Id);

            List<Bank_Reconciliation__c> recs = [
                SELECT Id, Name, Status__c, Book_Closing_Amount__c,
                       Statement_Closing_Amount__c, Difference__c,
                       Approved_By__c, Approved_At__c
                FROM Bank_Reconciliation__c
                WHERE Bank_Statement__c = :s.Id
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];

            Bank_Reconciliation__c r =
                recs.isEmpty() ? null : recs[0];

            List<Bank_Statement_Line__c> lines = [
                SELECT Id, Line_Number__c, Transaction_Date__c,
                       Value_Date__c, Amount__c,
                       Provider_Line_Id__c, Reference__c
                FROM Bank_Statement_Line__c
                WHERE Bank_Statement__c = :s.Id
                ORDER BY Line_Number__c ASC, CreatedDate ASC
            ];

            List<Reconciliation_Match__c> matches =
                r == null
                    ? new List<Reconciliation_Match__c>()
                    : [
                        SELECT Id, Bank_Statement_Line__c,
                               Journal_Entry_Line__c,
                               Journal_Entry_Line__r.Journal_Entry__c,
                               Journal_Entry_Line__r.Journal_Entry__r.Name,
                               Journal_Entry_Line__r.Journal_Entry__r.Accounting_Date__c,
                               Match_Type__c, Matched_Amount__c,
                               Status__c, Reversal_Of__c
                        FROM Reconciliation_Match__c
                        WHERE Bank_Reconciliation__c = :r.Id
                        ORDER BY CreatedDate ASC
                    ];

            Map<Id, Decimal> activeByLine = new Map<Id, Decimal>();
            Integer proposed = 0;
            Integer confirmed = 0;

            for (Reconciliation_Match__c m : matches) {
                if (m.Status__c == 'Proposed') proposed++;
                if (m.Status__c == 'Confirmed') confirmed++;

                if (m.Status__c == 'Proposed' || m.Status__c == 'Confirmed') {
                    Decimal v = activeByLine.containsKey(m.Bank_Statement_Line__c)
                        ? activeByLine.get(m.Bank_Statement_Line__c) : ZERO;
                    activeByLine.put(
                        m.Bank_Statement_Line__c,
                        v + absoluteAmount(m.Matched_Amount__c)
                    );
                }
            }

            StatementWorkspaceDTO out = new StatementWorkspaceDTO();
            out.statementId = s.Id;
            out.statementName = s.Name;
            out.companyId = s.Company__c;
            out.bankAccountId = s.Bank_Account__c;
            out.bankAccountName = s.Bank_Account__r.Name;
            out.currencyCode = s.Currency__c;
            out.startDate = s.Statement_Start_Date__c;
            out.endDate = s.Statement_End_Date__c;
            out.openingAmount = s.Opening_Amount__c;
            out.closingAmount = s.Closing_Amount__c;
            out.statementStatus = s.Status__c;
            out.lines = new List<StatementLineDTO>();
            out.matches = new List<MatchDTO>();
            out.lineCount = lines.size();
            out.fullyMatchedLineCount = 0;
            out.proposedMatchCount = proposed;
            out.confirmedMatchCount = confirmed;
            out.hasProposedMatches = proposed > 0;

            for (Bank_Statement_Line__c line : lines) {
                StatementLineDTO d = new StatementLineDTO();
                d.lineId = line.Id;
                d.lineNumber = line.Line_Number__c;
                d.transactionDate = line.Transaction_Date__c;
                d.valueDate = line.Value_Date__c;
                d.amount = line.Amount__c;
                d.providerLineId = line.Provider_Line_Id__c;
                d.reference = line.Reference__c;
                d.activeMatchedAmount = activeByLine.containsKey(line.Id)
                    ? activeByLine.get(line.Id) : ZERO;
                Decimal rem = absoluteAmount(line.Amount__c) - d.activeMatchedAmount;
                d.remainingAmount = rem < ZERO ? ZERO : rem;
                d.fullyMatched = d.remainingAmount == ZERO;
                if (d.fullyMatched) out.fullyMatchedLineCount++;
                out.lines.add(d);
            }

            for (Reconciliation_Match__c m : matches) {
                MatchDTO d = new MatchDTO();
                d.matchId = m.Id;
                d.statementLineId = m.Bank_Statement_Line__c;
                d.journalEntryLineId = m.Journal_Entry_Line__c;
                d.journalEntryId = m.Journal_Entry_Line__r == null
                    ? null : m.Journal_Entry_Line__r.Journal_Entry__c;
                d.journalName =
                    m.Journal_Entry_Line__r == null
                    || m.Journal_Entry_Line__r.Journal_Entry__r == null
                        ? null : m.Journal_Entry_Line__r.Journal_Entry__r.Name;
                d.accountingDate =
                    m.Journal_Entry_Line__r == null
                    || m.Journal_Entry_Line__r.Journal_Entry__r == null
                        ? null : m.Journal_Entry_Line__r.Journal_Entry__r.Accounting_Date__c;
                d.matchType = m.Match_Type__c;
                d.matchedAmount = m.Matched_Amount__c;
                d.status = m.Status__c;
                d.reversalOfId = m.Reversal_Of__c;
                out.matches.add(d);
            }

            if (r != null) {
                out.reconciliationId = r.Id;
                out.reconciliationName = r.Name;
                out.reconciliationStatus = r.Status__c;
                out.storedBookClosingAmount = r.Book_Closing_Amount__c;
                out.storedStatementClosingAmount = r.Statement_Closing_Amount__c;
                out.storedDifference = r.Difference__c;
                out.approvedById = r.Approved_By__c;
                out.approvedAt = r.Approved_At__c;
            }

            out.provisionalBookClosingAmount =
                calculateSingleGLBookBalance(
                    s.Company__c,
                    s.Bank_Account__r.GL_Account__c,
                    s.Statement_End_Date__c
                );

            out.provisionalDifference =
                normalizeAmount(
                    s.Closing_Amount__c
                    - out.provisionalBookClosingAmount
                );

            out.allLinesFullyMatched =
                out.lineCount > 0
                && out.fullyMatchedLineCount == out.lineCount;

            out.canFinalizeNow =
                r != null
                && r.Status__c == 'In Review'
                && out.allLinesFullyMatched
                && !out.hasProposedMatches
                && out.provisionalDifference == ZERO;

            return out;
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static ActionResultDTO importStatement(
        ImportStatementInput input
    ) {
        try {
            SABBankStatementImportService.ImportRequest req =
                new SABBankStatementImportService.ImportRequest();

            req.bankAccountId = input.bankAccountId;
            req.statementStartDate = input.statementStartDate;
            req.statementEndDate = input.statementEndDate;
            req.openingAmount = input.openingAmount;
            req.closingAmount = input.closingAmount;
            req.transactionCurrency = input.currencyCode;
            req.importFingerprint = input.importFingerprint;
            req.lines = new List<SABBankStatementImportService.LineRequest>();

            if (input.lines != null) {
                for (ImportLineInput x : input.lines) {
                    SABBankStatementImportService.LineRequest y =
                        new SABBankStatementImportService.LineRequest();
                    y.lineNumber = x.lineNumber;
                    y.transactionDate = x.transactionDate;
                    y.valueDate = x.valueDate;
                    y.amount = x.amount;
                    y.providerLineId = x.providerLineId;
                    y.reference = x.reference;
                    y.sourceRawText = x.sourceRawText;
                    y.lineFingerprint = x.lineFingerprint;
                    req.lines.add(y);
                }
            }

            SABBankStatementImportService.ImportResult r =
                SABBankStatementImportService.importStatement(req);

            return actionResult(
                r.bankStatementId,
                null,
                r.status,
                r.replay
                    ? 'Existing Bank Statement returned; no duplicate import was created.'
                    : 'Bank Statement imported successfully.'
            );
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static ActionResultDTO validateStatement(Id bankStatementId) {
        try {
            SABBankStatementImportService.ImportResult r =
                SABBankStatementImportService.validateStatement(bankStatementId);
            return actionResult(
                r.bankStatementId, null, r.status,
                'Bank Statement validated successfully.'
            );
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static ActionResultDTO startReconciliation(Id bankStatementId) {
        try {
            SABBankReconciliationMatchService.ReconciliationResult r =
                SABBankReconciliationMatchService.startReconciliation(
                    bankStatementId
                );
            return actionResult(
                r.reconciliationId,
                r.bankStatementId,
                r.status,
                r.replay
                    ? 'Existing reconciliation resumed.'
                    : 'Bank Reconciliation started.'
            );
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<CandidateDTO> getMatchCandidates(
        Id reconciliationId,
        Id bankStatementLineId,
        Integer dayWindow
    ) {
        try {
            List<CandidateDTO> out = new List<CandidateDTO>();

            for (
                SABBankReconciliationMatchService.MatchCandidate c :
                SABBankReconciliationMatchService.getMatchCandidates(
                    reconciliationId,
                    bankStatementLineId,
                    dayWindow,
                    100
                )
            ) {
                CandidateDTO d = new CandidateDTO();
                d.journalEntryLineId = c.journalEntryLineId;
                d.journalEntryId = c.journalEntryId;
                d.accountingDate = c.accountingDate;
                d.journalDescription = c.journalDescription;
                d.journalAmount = c.journalAmount;
                d.journalRemainingAmount = c.journalRemainingAmount;
                d.statementRemainingAmount = c.statementRemainingAmount;
                d.suggestedMatchAmount = c.suggestedMatchAmount;
                d.dateDifferenceDays = c.dateDifferenceDays;
                d.exactAmount = c.exactAmount;
                d.transactionCurrency = c.transactionCurrency;
                d.sourceLineKey = c.sourceLineKey;
                out.add(d);
            }

            return out;
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static ActionResultDTO createManualMatch(
        Id reconciliationId,
        Id bankStatementLineId,
        Id journalEntryLineId,
        Decimal matchedAmount
    ) {
        try {
            SABBankReconciliationMatchService.MatchResult r =
                SABBankReconciliationMatchService.createManualMatch(
                    reconciliationId,
                    bankStatementLineId,
                    journalEntryLineId,
                    matchedAmount
                );
            return actionResult(
                r.matchId, reconciliationId, r.status,
                'Manual Bank Reconciliation match confirmed.'
            );
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static ActionResultDTO createSuggestedMatch(
        Id reconciliationId,
        Id bankStatementLineId,
        Id journalEntryLineId,
        Decimal matchedAmount
    ) {
        try {
            SABBankReconciliationMatchService.MatchResult r =
                SABBankReconciliationMatchService.createSuggestedMatch(
                    reconciliationId,
                    bankStatementLineId,
                    journalEntryLineId,
                    matchedAmount
                );
            return actionResult(
                r.matchId, reconciliationId, r.status,
                'Suggested Bank Reconciliation match created.'
            );
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static ActionResultDTO confirmMatch(Id matchId) {
        try {
            SABBankReconciliationMatchService.MatchResult r =
                SABBankReconciliationMatchService.confirmSuggestedMatch(
                    matchId
                );
            return actionResult(
                r.matchId, r.reconciliationId, r.status,
                'Suggested match confirmed.'
            );
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static ActionResultDTO reverseMatch(Id matchId) {
        try {
            SABBankReconciliationMatchService.MatchResult r =
                SABBankReconciliationMatchService.reverseMatch(matchId);
            return actionResult(
                r.matchId, r.reconciliationId, r.status,
                'Reconciliation match reversed.'
            );
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    @AuraEnabled
    public static ActionResultDTO finalizeReconciliation(
        Id reconciliationId
    ) {
        try {
            SABBankReconciliationFinalizationService.FinalizationResult r =
                SABBankReconciliationFinalizationService.finalizeReconciliation(
                    reconciliationId
                );
            return actionResult(
                r.reconciliationId,
                r.bankStatementId,
                r.reconciliationStatus,
                r.replay
                    ? 'Reconciliation was already finalized.'
                    : 'Bank Reconciliation finalized successfully.'
            );
        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    private static Map<Id, Decimal> calculateBookBalanceByGL(
        Id companyId,
        Set<Id> glIds,
        Date asOfDate
    ) {
        Map<Id, Decimal> out = new Map<Id, Decimal>();

        if (glIds == null || glIds.isEmpty()) return out;

        for (AggregateResult a : [
            SELECT GL_Account__c glId,
                   SUM(Debit_Base__c) debitTotal,
                   SUM(Credit_Base__c) creditTotal
            FROM Journal_Entry_Line__c
            WHERE GL_Account__c IN :glIds
              AND Journal_Entry__r.Company__c = :companyId
              AND Journal_Entry__r.Status__c IN ('Posted','Reversed')
              AND Journal_Entry__r.Accounting_Date__c <= :asOfDate
            GROUP BY GL_Account__c
        ]) {
            Decimal d = (Decimal)a.get('debitTotal');
            Decimal c = (Decimal)a.get('creditTotal');
            out.put(
                (Id)a.get('glId'),
                normalizeAmount(
                    (d == null ? ZERO : d)
                    - (c == null ? ZERO : c)
                )
            );
        }

        return out;
    }

    private static Decimal calculateSingleGLBookBalance(
        Id companyId,
        Id glId,
        Date asOfDate
    ) {
        if (glId == null || asOfDate == null) return ZERO;
        Map<Id, Decimal> m =
            calculateBookBalanceByGL(
                companyId,
                new Set<Id>{glId},
                asOfDate
            );
        return m.containsKey(glId) ? m.get(glId) : ZERO;
    }

    private static ActionResultDTO actionResult(
        Id recordId,
        Id secondaryRecordId,
        String status,
        String message
    ) {
        ActionResultDTO r = new ActionResultDTO();
        r.recordId = recordId;
        r.secondaryRecordId = secondaryRecordId;
        r.status = status;
        r.message = message;
        return r;
    }

    private static Decimal absoluteAmount(Decimal value) {
        if (value == null) return ZERO;
        return value < ZERO ? -value : value;
    }

    private static Decimal normalizeAmount(Decimal value) {
        return (value == null ? ZERO : value)
            .setScale(4, RoundingMode.HALF_UP);
    }
}
