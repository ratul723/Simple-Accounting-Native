/**
 * G22C: controller for c/sabEquityWorkspace (Capital & equity).
 *
 * Read only. Actions in the workspace call the G17 services directly, unchanged:
 * SABEquityService.saveStakeholder / saveClass / saveTransaction / approveTransaction / cancelTransaction and
 * SABDistributionService.saveDraft / approve / settle / cancel, each lifecycle action with a request key.
 *
 * Holdings follow SABEquityService.holdings: Posted transactions dated today or earlier; Issue adds units,
 * Redemption removes them and Transfer moves them between stakeholders. Share capital is units held x par per
 * class. A distribution line's paid amount is the sum of its Effective settlements.
 */
public with sharing class SABEquityWorkspaceController {

    private static final Integer MAX_ROWS = 200;
    private static final Integer MAX_DISTRIBUTIONS = 50;
    private static final Set<String> DECLARED_STATUSES = new Set<String>{ 'Posted Payable', 'Part Settled', 'Settled' };
    private static final Set<String> OPEN_STATUSES = new Set<String>{ 'Posted Payable', 'Part Settled' };

    public class WorkspaceData {
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public Boolean canManage { get; set; }
        @AuraEnabled public Boolean canApprove { get; set; }
        @AuraEnabled public Boolean canPostJournal { get; set; }
        @AuraEnabled public Boolean distributionsAvailable { get; set; }
        @AuraEnabled public Date fiscalYearStart { get; set; }
        @AuraEnabled public Decimal shareCapital { get; set; }
        @AuraEnabled public Decimal unitsOutstanding { get; set; }
        @AuraEnabled public Integer holderCount { get; set; }
        @AuraEnabled public Decimal declaredThisYear { get; set; }
        @AuraEnabled public Decimal unpaid { get; set; }
        @AuraEnabled public Date nextPaymentDue { get; set; }
        @AuraEnabled public List<ClassRow> classes { get; set; }
        @AuraEnabled public List<StakeholderRow> stakeholders { get; set; }
        @AuraEnabled public List<TransactionRow> transactions { get; set; }
        @AuraEnabled public List<DistributionRow> distributions { get; set; }
    }

    public class ClassRow {
        @AuraEnabled public Id classId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String classCode { get; set; }
        @AuraEnabled public Decimal parValue { get; set; }
        @AuraEnabled public Boolean active { get; set; }
        @AuraEnabled public String capitalAccount { get; set; }
        @AuraEnabled public String premiumAccount { get; set; }
        @AuraEnabled public Decimal unitsOutstanding { get; set; }
        @AuraEnabled public List<HoldingRow> holdings { get; set; }
    }

    public class HoldingRow {
        @AuraEnabled public Id stakeholderId { get; set; }
        @AuraEnabled public String stakeholderName { get; set; }
        @AuraEnabled public Decimal units { get; set; }
        @AuraEnabled public Decimal percent { get; set; }
    }

    public class StakeholderRow {
        @AuraEnabled public Id stakeholderId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String reference { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String accountName { get; set; }
    }

    public class TransactionRow {
        @AuraEnabled public Id transactionId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public Date transactionDate { get; set; }
        @AuraEnabled public String transactionType { get; set; }
        @AuraEnabled public String className { get; set; }
        @AuraEnabled public String stakeholderName { get; set; }
        @AuraEnabled public String toStakeholderName { get; set; }
        @AuraEnabled public Decimal units { get; set; }
        @AuraEnabled public Decimal value { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Boolean createdByMe { get; set; }
    }

    public class DistributionRow {
        @AuraEnabled public Id distributionId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String distributionType { get; set; }
        @AuraEnabled public String className { get; set; }
        @AuraEnabled public Date declarationDate { get; set; }
        @AuraEnabled public Date recordDate { get; set; }
        @AuraEnabled public Date paymentDueDate { get; set; }
        @AuraEnabled public Decimal totalAmount { get; set; }
        @AuraEnabled public Decimal paidAmount { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public Boolean createdByMe { get; set; }
        @AuraEnabled public String sourceAccount { get; set; }
        @AuraEnabled public String payableAccount { get; set; }
        @AuraEnabled public String bankAccount { get; set; }
        @AuraEnabled public List<LineRow> lines { get; set; }
    }

    public class LineRow {
        @AuraEnabled public Id lineId { get; set; }
        @AuraEnabled public String stakeholderName { get; set; }
        @AuraEnabled public Decimal entitledUnits { get; set; }
        @AuraEnabled public Decimal entitledAmount { get; set; }
        @AuraEnabled public Decimal paidAmount { get; set; }
        @AuraEnabled public String state { get; set; }
    }

    public class Option {
        @AuraEnabled public String value { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String kind { get; set; }

        Option(String value, String label, String kind) {
            this.value = value;
            this.label = label;
            this.kind = kind;
        }
    }

    public class FormOptions {
        @AuraEnabled public List<Option> accounts { get; set; }
        @AuraEnabled public List<Option> glAccounts { get; set; }
        @AuraEnabled public List<Option> bankAccounts { get; set; }
    }

    @AuraEnabled
    public static WorkspaceData getWorkspace(Id companyId) {
        assertView(companyId);
        try {
            return build(companyId, Date.today());
        } catch (QueryException ex) {
            throw auraError('Capital & equity could not be loaded: ' + ex.getMessage());
        }
    }

    @AuraEnabled
    public static FormOptions getFormOptions(Id companyId) {
        assertView(companyId);
        FormOptions options = new FormOptions();
        options.accounts = new List<Option>();
        options.glAccounts = new List<Option>();
        options.bankAccounts = new List<Option>();
        try {
            for (Account account : [SELECT Id, Name FROM Account WITH USER_MODE ORDER BY Name LIMIT 500]) {
                options.accounts.add(new Option(account.Id, account.Name, null));
            }
            for (GL_Account__c account : [
                SELECT Id, Name, Account_Code__c, Account_Type__c
                FROM GL_Account__c
                WHERE Company__c = :companyId AND Is_Active__c = true
                WITH USER_MODE
                ORDER BY Account_Code__c
                LIMIT 1000
            ]) {
                options.glAccounts.add(new Option(account.Id, account.Account_Code__c + ' ' + account.Name, account.Account_Type__c));
            }
            for (Bank_Account__c bank : [
                SELECT Id, Name, Currency__c
                FROM Bank_Account__c
                WHERE Company__c = :companyId AND Is_Active__c = true
                WITH USER_MODE
                ORDER BY Name
                LIMIT 200
            ]) {
                options.bankAccounts.add(new Option(bank.Id, bank.Name + ' (' + bank.Currency__c + ')', null));
            }
        } catch (QueryException ex) {
            throw auraError('Form options could not be loaded: ' + ex.getMessage());
        }
        return options;
    }

    @TestVisible
    private static WorkspaceData build(Id companyId, Date today) {
        Accounting_Company__c company = [
            SELECT Functional_Currency__c, Fiscal_Year_Start_Month__c
            FROM Accounting_Company__c
            WHERE Id = :companyId
            WITH USER_MODE
            LIMIT 1
        ];
        WorkspaceData data = new WorkspaceData();
        data.currencyCode = company.Functional_Currency__c;
        data.canManage = SABPermissionService.hasPermission('SAB_Manage_Equity');
        data.canApprove = SABPermissionService.hasPermission('SAB_Approve_Equity');
        data.canPostJournal = SABPermissionService.hasPermission('SAB_Post_Journal');
        data.fiscalYearStart = fiscalYearStart(today, company.Fiscal_Year_Start_Month__c);
        data.stakeholders = stakeholders(companyId);
        data.classes = classes(companyId);
        loadTransactions(data, companyId, today);
        data.distributionsAvailable = SABEquityReadPolicy.canReadDistributions();
        data.distributions = data.distributionsAvailable ? distributions(companyId) : new List<DistributionRow>();
        distributionFigures(data);
        return data;
    }

    @TestVisible
    private static Date fiscalYearStart(Date today, Decimal startMonth) {
        Integer month = startMonth == null || startMonth < 1 || startMonth > 12 ? 1 : startMonth.intValue();
        Integer year = today.month() >= month ? today.year() : today.year() - 1;
        return Date.newInstance(year, month, 1);
    }

    private static List<StakeholderRow> stakeholders(Id companyId) {
        List<StakeholderRow> rows = new List<StakeholderRow>();
        for (Stakeholder__c holder : [
            SELECT Id, Name, Stakeholder_Reference__c, Status__c, Account__r.Name
            FROM Stakeholder__c
            WHERE Company__c = :companyId
            WITH USER_MODE
            ORDER BY Name
            LIMIT :MAX_ROWS
        ]) {
            StakeholderRow row = new StakeholderRow();
            row.stakeholderId = holder.Id;
            row.name = holder.Name;
            row.reference = holder.Stakeholder_Reference__c;
            row.status = holder.Status__c;
            row.accountName = holder.Account__r == null ? null : holder.Account__r.Name;
            rows.add(row);
        }
        return rows;
    }

    private static List<ClassRow> classes(Id companyId) {
        List<ClassRow> rows = new List<ClassRow>();
        for (Equity_Class__c shareClass : [
            SELECT Id, Name, Class_Code__c, Par_Value__c, Is_Active__c, Capital_Account__r.Account_Code__c, Premium_Account__r.Account_Code__c
            FROM Equity_Class__c
            WHERE Company__c = :companyId
            WITH USER_MODE
            ORDER BY Class_Code__c
            LIMIT :MAX_ROWS
        ]) {
            ClassRow row = new ClassRow();
            row.classId = shareClass.Id;
            row.name = shareClass.Name;
            row.classCode = shareClass.Class_Code__c;
            row.parValue = shareClass.Par_Value__c;
            row.active = shareClass.Is_Active__c == true;
            row.capitalAccount = shareClass.Capital_Account__r == null ? null : shareClass.Capital_Account__r.Account_Code__c;
            row.premiumAccount = shareClass.Premium_Account__r == null ? null : shareClass.Premium_Account__r.Account_Code__c;
            row.unitsOutstanding = 0;
            row.holdings = new List<HoldingRow>();
            rows.add(row);
        }
        return rows;
    }

    private static void loadTransactions(WorkspaceData data, Id companyId, Date today) {
        data.transactions = new List<TransactionRow>();
        Map<Id, Map<Id, Decimal>> unitsByClass = new Map<Id, Map<Id, Decimal>>();
        Id userId = UserInfo.getUserId();
        for (Equity_Transaction__c tx : [
            SELECT Id, Name, Transaction_Date__c, Transaction_Type__c, Equity_Class__c, Equity_Class__r.Name, Stakeholder__c,
                   Stakeholder__r.Name, To_Stakeholder__c, To_Stakeholder__r.Name, Units__c, Value__c, Status__c, CreatedById
            FROM Equity_Transaction__c
            WHERE Company__c = :companyId
            WITH USER_MODE
            ORDER BY Transaction_Date__c DESC, Name DESC
            LIMIT 5000
        ]) {
            if (tx.Status__c == 'Posted' && tx.Transaction_Date__c <= today) {
                applyHolding(unitsByClass, tx);
            }
            if (data.transactions.size() < MAX_ROWS) {
                data.transactions.add(transactionRow(tx, userId));
            }
        }
        Map<Id, String> names = new Map<Id, String>();
        for (StakeholderRow holder : data.stakeholders) {
            names.put(holder.stakeholderId, holder.name);
        }
        data.shareCapital = 0;
        data.unitsOutstanding = 0;
        Set<Id> holders = new Set<Id>();
        for (ClassRow row : data.classes) {
            Map<Id, Decimal> units = unitsByClass.containsKey(row.classId) ? unitsByClass.get(row.classId) : new Map<Id, Decimal>();
            for (Decimal value : units.values()) {
                row.unitsOutstanding += value;
            }
            for (Id holder : units.keySet()) {
                if (units.get(holder) == 0) {
                    continue;
                }
                HoldingRow holding = new HoldingRow();
                holding.stakeholderId = holder;
                holding.stakeholderName = names.get(holder);
                holding.units = units.get(holder);
                holding.percent = row.unitsOutstanding == 0 ? 0 : (holding.units * 100 / row.unitsOutstanding).setScale(2);
                row.holdings.add(holding);
                holders.add(holder);
            }
            data.unitsOutstanding += row.unitsOutstanding;
            data.shareCapital += row.unitsOutstanding * (row.parValue == null ? 0 : row.parValue);
        }
        data.holderCount = holders.size();
    }

    @TestVisible
    private static void applyHolding(Map<Id, Map<Id, Decimal>> unitsByClass, Equity_Transaction__c tx) {
        if (!unitsByClass.containsKey(tx.Equity_Class__c)) {
            unitsByClass.put(tx.Equity_Class__c, new Map<Id, Decimal>());
        }
        Map<Id, Decimal> units = unitsByClass.get(tx.Equity_Class__c);
        Decimal value = tx.Units__c == null ? 0 : tx.Units__c;
        if (tx.Transaction_Type__c == 'Issue') {
            add(units, tx.Stakeholder__c, value);
        } else if (tx.Transaction_Type__c == 'Redemption') {
            add(units, tx.Stakeholder__c, -value);
        } else if (tx.Transaction_Type__c == 'Transfer') {
            add(units, tx.Stakeholder__c, -value);
            add(units, tx.To_Stakeholder__c, value);
        }
    }

    private static void add(Map<Id, Decimal> units, Id holder, Decimal value) {
        if (holder == null) {
            return;
        }
        units.put(holder, (units.containsKey(holder) ? units.get(holder) : 0) + value);
    }

    private static TransactionRow transactionRow(Equity_Transaction__c tx, Id userId) {
        TransactionRow row = new TransactionRow();
        row.transactionId = tx.Id;
        row.name = tx.Name;
        row.transactionDate = tx.Transaction_Date__c;
        row.transactionType = tx.Transaction_Type__c;
        row.className = tx.Equity_Class__r == null ? null : tx.Equity_Class__r.Name;
        row.stakeholderName = tx.Stakeholder__r == null ? null : tx.Stakeholder__r.Name;
        row.toStakeholderName = tx.To_Stakeholder__r == null ? null : tx.To_Stakeholder__r.Name;
        row.units = tx.Units__c;
        row.value = tx.Value__c;
        row.status = tx.Status__c;
        row.createdByMe = tx.CreatedById == userId;
        return row;
    }

    private static List<DistributionRow> distributions(Id companyId) {
        Map<Id, DistributionRow> byId = new Map<Id, DistributionRow>();
        List<DistributionRow> rows = new List<DistributionRow>();
        Id userId = UserInfo.getUserId();
        for (Distribution__c d : [
            SELECT Id, Name, Distribution_Type__c, Equity_Class__r.Name, Declaration_Date__c, Record_Date__c, Payment_Due_Date__c,
                   Total_Amount__c, Status__c, CreatedById, Source_Account__r.Account_Code__c, Source_Account__r.Name,
                   Payable_Account__r.Account_Code__c, Payable_Account__r.Name, Bank_Account__r.Name
            FROM Distribution__c
            WHERE Company__c = :companyId
            WITH USER_MODE
            ORDER BY Declaration_Date__c DESC, Name DESC
            LIMIT :MAX_DISTRIBUTIONS
        ]) {
            DistributionRow row = new DistributionRow();
            row.distributionId = d.Id;
            row.name = d.Name;
            row.distributionType = d.Distribution_Type__c;
            row.className = d.Equity_Class__r == null ? null : d.Equity_Class__r.Name;
            row.declarationDate = d.Declaration_Date__c;
            row.recordDate = d.Record_Date__c;
            row.paymentDueDate = d.Payment_Due_Date__c;
            row.totalAmount = d.Total_Amount__c;
            row.paidAmount = 0;
            row.status = d.Status__c;
            row.createdByMe = d.CreatedById == userId;
            row.sourceAccount = d.Source_Account__r == null ? null : d.Source_Account__r.Account_Code__c + ' ' + d.Source_Account__r.Name;
            row.payableAccount = d.Payable_Account__r == null ? null : d.Payable_Account__r.Account_Code__c + ' ' + d.Payable_Account__r.Name;
            row.bankAccount = d.Bank_Account__r == null ? null : d.Bank_Account__r.Name;
            row.lines = new List<LineRow>();
            byId.put(d.Id, row);
            rows.add(row);
        }
        if (byId.isEmpty()) {
            return rows;
        }
        Set<Id> distributionIds = byId.keySet();
        Map<Id, LineRow> lineById = new Map<Id, LineRow>();
        for (Distribution_Line__c line : [
            SELECT Id, Distribution__c, Stakeholder__r.Name, Entitled_Units__c, Entitled_Amount__c, Settlement_State__c
            FROM Distribution_Line__c
            WHERE Distribution__c IN :distributionIds
            WITH USER_MODE
            ORDER BY Distribution__c, Stakeholder__r.Name
            LIMIT 5000
        ]) {
            LineRow row = new LineRow();
            row.lineId = line.Id;
            row.stakeholderName = line.Stakeholder__r == null ? null : line.Stakeholder__r.Name;
            row.entitledUnits = line.Entitled_Units__c;
            row.entitledAmount = line.Entitled_Amount__c == null ? 0 : line.Entitled_Amount__c;
            row.paidAmount = 0;
            row.state = line.Settlement_State__c;
            lineById.put(line.Id, row);
            byId.get(line.Distribution__c).lines.add(row);
        }
        if (lineById.isEmpty()) {
            return rows;
        }
        Set<Id> lineIds = lineById.keySet();
        for (AggregateResult agg : [
            SELECT Distribution_Line__c lineId, SUM(Allocated_Amount__c) paid
            FROM Distribution_Settlement__c
            WHERE Distribution_Line__c IN :lineIds AND Status__c = 'Effective'
            WITH USER_MODE
            GROUP BY Distribution_Line__c
        ]) {
            Decimal paid = (Decimal) agg.get('paid');
            lineById.get((Id) agg.get('lineId')).paidAmount = paid == null ? 0 : paid;
        }
        for (DistributionRow row : rows) {
            for (LineRow line : row.lines) {
                row.paidAmount += line.paidAmount;
            }
        }
        return rows;
    }

    private static void distributionFigures(WorkspaceData data) {
        data.declaredThisYear = 0;
        data.unpaid = 0;
        for (DistributionRow row : data.distributions) {
            if (DECLARED_STATUSES.contains(row.status) && row.declarationDate != null && row.declarationDate >= data.fiscalYearStart) {
                data.declaredThisYear += row.totalAmount == null ? 0 : row.totalAmount;
            }
            if (OPEN_STATUSES.contains(row.status)) {
                data.unpaid += (row.totalAmount == null ? 0 : row.totalAmount) - row.paidAmount;
                if (row.paymentDueDate != null && (data.nextPaymentDue == null || row.paymentDueDate < data.nextPaymentDue)) {
                    data.nextPaymentDue = row.paymentDueDate;
                }
            }
        }
    }

    private static void assertView(Id companyId) {
        try {
            SABEquityReadPolicy.assertCanView(companyId);
        } catch (SABEquityReadPolicy.EquityAccessException ex) {
            throw auraError(ex.getMessage());
        }
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}