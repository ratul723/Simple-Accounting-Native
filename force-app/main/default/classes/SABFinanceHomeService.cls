/**
 * G22A: assembles Finance home for one Accounting Company.
 *
 * Read only. Ledger figures use posted journal lines (Posted and Reversed journals, as
 * SABLedgerReportService does); receivables reuse SABARAgingService and payables reuse the AP
 * workspace controller so every figure matches the workspace it links to. Each section is read in
 * user mode behind its own access check: a section the user cannot read is returned with
 * available = false and the rest of the page still renders.
 *
 * The approvals queue is read only here; approve and reject are wired to SABApprovalService in G22E.
 */
public with sharing class SABFinanceHomeService {

    private static final List<String> LEDGER_STATUSES = new List<String>{ 'Posted', 'Reversed' };
    private static final String STATUS_PENDING = 'Pending';
    private static final Integer TREND_WEEKS = 12;
    private static final Integer PAYABLES_WINDOW_DAYS = 14;

    public class HomeData {
        @AuraEnabled public String companyName { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public String setupStatus { get; set; }
        @AuraEnabled public Boolean companyActive { get; set; }
        @AuraEnabled public Date today { get; set; }
        @AuraEnabled public Boolean hasPeriod { get; set; }
        @AuraEnabled public String periodKey { get; set; }
        @AuraEnabled public Date periodStart { get; set; }
        @AuraEnabled public String periodStatus { get; set; }
        @AuraEnabled public Figure cash { get; set; }
        @AuraEnabled public Figure receivables { get; set; }
        @AuraEnabled public Figure payables { get; set; }
        @AuraEnabled public Figure profit { get; set; }
        @AuraEnabled public List<TrendPoint> cashTrend { get; set; }
        @AuraEnabled public List<MonthBar> monthly { get; set; }
        @AuraEnabled public List<AttentionItem> attention { get; set; }
        @AuraEnabled public RoleCard roleCard { get; set; }
        @AuraEnabled public Boolean recentAvailable { get; set; }
        @AuraEnabled public List<PostingRow> recent { get; set; }
        @AuraEnabled public Boolean approvalsAvailable { get; set; }
        @AuraEnabled public List<ApprovalRow> approvals { get; set; }
        @AuraEnabled public SetupSummary setup { get; set; }
    }

    public class Figure {
        @AuraEnabled public Boolean available { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
        @AuraEnabled public Integer count { get; set; }
        @AuraEnabled public Decimal secondaryAmount { get; set; }
        @AuraEnabled public Date nextDate { get; set; }
        @AuraEnabled public Boolean hasComparison { get; set; }
        @AuraEnabled public Decimal comparison { get; set; }
    }

    public class TrendPoint {
        @AuraEnabled public Date pointDate { get; set; }
        @AuraEnabled public Decimal balance { get; set; }
    }

    public class MonthBar {
        @AuraEnabled public Date monthStart { get; set; }
        @AuraEnabled public Decimal income { get; set; }
        @AuraEnabled public Decimal expense { get; set; }
    }

    public class AttentionItem {
        @AuraEnabled public String key { get; set; }
        @AuraEnabled public String icon { get; set; }
        @AuraEnabled public String tone { get; set; }
        @AuraEnabled public String title { get; set; }
        @AuraEnabled public String detail { get; set; }
        @AuraEnabled public String workspace { get; set; }
    }

    public class RoleCard {
        @AuraEnabled public String kind { get; set; }
        @AuraEnabled public String caption { get; set; }
        @AuraEnabled public String valueText { get; set; }
        @AuraEnabled public Decimal valueAmount { get; set; }
        @AuraEnabled public Boolean isMoney { get; set; }
        @AuraEnabled public String detail { get; set; }
        @AuraEnabled public Boolean showMeter { get; set; }
        @AuraEnabled public Decimal meterPercent { get; set; }
        @AuraEnabled public String actionLabel { get; set; }
        @AuraEnabled public String actionWorkspace { get; set; }
        @AuraEnabled public List<RoleItem> items { get; set; }
    }

    public class RoleItem {
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String detail { get; set; }
    }

    public class PostingRow {
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public Date accountingDate { get; set; }
        @AuraEnabled public String postedBy { get; set; }
        @AuraEnabled public String status { get; set; }
    }

    public class ApprovalRow {
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public String name { get; set; }
        @AuraEnabled public String sourceType { get; set; }
        @AuraEnabled public String sourceKey { get; set; }
        @AuraEnabled public String requestedBy { get; set; }
        @AuraEnabled public Datetime requestedAt { get; set; }
        @AuraEnabled public String needs { get; set; }
        @AuraEnabled public String status { get; set; }
    }

    public class SetupSummary {
        @AuraEnabled public Integer accountCount { get; set; }
        @AuraEnabled public Integer periodCount { get; set; }
        @AuraEnabled public Integer bankAccountCount { get; set; }
    }

    private class CloseProgress {
        Integer done = 0;
        Integer total = 0;
    }

    private class HomeContext {
        Id companyId;
        Date today;
        Accounting_Period__c period;
        List<Accounting_Period__c> yearPeriods = new List<Accounting_Period__c>();
        SABPersonaService.Persona persona;
        List<Approval_Step__c> mySteps;
        CloseProgress close;
        Integer overdueCount = 0;
        Decimal overdueAmount = 0;
        Boolean overdueKnown = false;
    }

    public static HomeData getHome(Id companyId) {
        SABFinanceHomeReadPolicy.assertCanView(companyId);
        HomeContext ctx = new HomeContext();
        ctx.companyId = companyId;
        ctx.today = Date.today();
        ctx.persona = SABPersonaService.current();

        HomeData data = new HomeData();
        data.today = ctx.today;
        loadCompany(data, companyId);
        loadPeriods(ctx, data);
        if (data.companyActive != true) {
            data.setup = setupSummary(companyId);
            return data;
        }
        data.cash = cashFigure(ctx, data);
        data.receivables = receivablesFigure(ctx);
        data.payables = payablesFigure(ctx);
        data.profit = profitFigure(ctx, data);
        data.attention = attention(ctx);
        data.roleCard = roleCard(ctx);
        loadRecent(ctx, data);
        loadApprovals(ctx, data);
        return data;
    }

    private static void loadCompany(HomeData data, Id companyId) {
        Accounting_Company__c company = [
            SELECT Name__c, Functional_Currency__c, Setup_Status__c
            FROM Accounting_Company__c
            WHERE Id = :companyId
            WITH USER_MODE
            LIMIT 1
        ];
        data.companyName = company.Name__c;
        data.currencyCode = company.Functional_Currency__c;
        data.setupStatus = company.Setup_Status__c;
        data.companyActive = company.Setup_Status__c == 'Active';
    }

    private static void loadPeriods(HomeContext ctx, HomeData data) {
        data.hasPeriod = false;
        if (!SABFinanceHomeReadPolicy.canRead(Accounting_Period__c.SObjectType, new List<Schema.SObjectField>{
                Accounting_Period__c.Period_Key__c, Accounting_Period__c.Start_Date__c, Accounting_Period__c.End_Date__c,
                Accounting_Period__c.Status__c, Accounting_Period__c.Fiscal_Year__c })) {
            return;
        }
        Id companyId = ctx.companyId;
        Date today = ctx.today;
        List<Accounting_Period__c> current = [
            SELECT Id, Period_Key__c, Start_Date__c, End_Date__c, Status__c, Fiscal_Year__c
            FROM Accounting_Period__c
            WHERE Company__c = :companyId AND Start_Date__c <= :today AND End_Date__c >= :today
            WITH USER_MODE
            ORDER BY Start_Date__c DESC
            LIMIT 1
        ];
        if (current.isEmpty()) {
            return;
        }
        ctx.period = current[0];
        data.hasPeriod = true;
        data.periodKey = ctx.period.Period_Key__c;
        data.periodStart = ctx.period.Start_Date__c;
        data.periodStatus = ctx.period.Status__c;
        Decimal fiscalYear = ctx.period.Fiscal_Year__c;
        ctx.yearPeriods = [
            SELECT Id, Start_Date__c
            FROM Accounting_Period__c
            WHERE Company__c = :companyId AND Fiscal_Year__c = :fiscalYear AND Start_Date__c <= :today
            WITH USER_MODE
            ORDER BY Start_Date__c ASC
            LIMIT 24
        ];
    }

    private static Boolean canReadLedger() {
        return SABFinanceHomeReadPolicy.canRead(Journal_Entry_Line__c.SObjectType, new List<Schema.SObjectField>{
                Journal_Entry_Line__c.GL_Account__c, Journal_Entry_Line__c.Debit_Base__c, Journal_Entry_Line__c.Credit_Base__c })
            && SABFinanceHomeReadPolicy.canRead(Journal_Entry__c.SObjectType, new List<Schema.SObjectField>{
                Journal_Entry__c.Company__c, Journal_Entry__c.Status__c, Journal_Entry__c.Accounting_Date__c,
                Journal_Entry__c.Accounting_Period__c });
    }

    private static Figure unavailable() {
        Figure figure = new Figure();
        figure.available = false;
        figure.amount = 0;
        figure.count = 0;
        figure.hasComparison = false;
        return figure;
    }

    private static Figure cashFigure(HomeContext ctx, HomeData data) {
        Figure figure = unavailable();
        data.cashTrend = new List<TrendPoint>();
        if (!canReadLedger() || !SABFinanceHomeReadPolicy.canRead(Bank_Account__c.SObjectType, new List<Schema.SObjectField>{
                Bank_Account__c.GL_Account__c, Bank_Account__c.Is_Active__c })) {
            return figure;
        }
        Id companyId = ctx.companyId;
        Set<Id> glIds = new Set<Id>();
        for (Bank_Account__c bank : [
            SELECT GL_Account__c
            FROM Bank_Account__c
            WHERE Company__c = :companyId AND Is_Active__c = true AND GL_Account__c != null
            WITH USER_MODE
            LIMIT 200
        ]) {
            glIds.add(bank.GL_Account__c);
        }
        figure.available = true;
        figure.count = glIds.size();
        Date startDate = ctx.today.addDays(-7 * TREND_WEEKS);
        Date endDate = ctx.today;
        Decimal opening = 0;
        Map<Date, Decimal> movements = new Map<Date, Decimal>();
        if (!glIds.isEmpty()) {
            AggregateResult openingRow = [
                SELECT SUM(Debit_Base__c) debitTotal, SUM(Credit_Base__c) creditTotal
                FROM Journal_Entry_Line__c
                WHERE GL_Account__c IN :glIds AND Journal_Entry__r.Company__c = :companyId
                  AND Journal_Entry__r.Status__c IN :LEDGER_STATUSES AND Journal_Entry__r.Accounting_Date__c <= :startDate
                WITH USER_MODE
            ];
            opening = net(openingRow);
            for (AggregateResult row : [
                SELECT Journal_Entry__r.Accounting_Date__c entryDate, SUM(Debit_Base__c) debitTotal, SUM(Credit_Base__c) creditTotal
                FROM Journal_Entry_Line__c
                WHERE GL_Account__c IN :glIds AND Journal_Entry__r.Company__c = :companyId
                  AND Journal_Entry__r.Status__c IN :LEDGER_STATUSES
                  AND Journal_Entry__r.Accounting_Date__c > :startDate AND Journal_Entry__r.Accounting_Date__c <= :endDate
                WITH USER_MODE
                GROUP BY Journal_Entry__r.Accounting_Date__c
                LIMIT 200
            ]) {
                movements.put((Date) row.get('entryDate'), net(row));
            }
        }
        data.cashTrend = trend(startDate, opening, movements);
        figure.amount = data.cashTrend[data.cashTrend.size() - 1].balance;
        return figure;
    }

    @TestVisible
    private static List<TrendPoint> trend(Date startDate, Decimal opening, Map<Date, Decimal> movements) {
        List<TrendPoint> points = new List<TrendPoint>();
        for (Integer week = 0; week <= TREND_WEEKS; week++) {
            Date pointDate = startDate.addDays(7 * week);
            Decimal balance = opening;
            for (Date movementDate : movements.keySet()) {
                if (movementDate <= pointDate) {
                    balance += movements.get(movementDate);
                }
            }
            TrendPoint point = new TrendPoint();
            point.pointDate = pointDate;
            point.balance = balance.setScale(2);
            points.add(point);
        }
        return points;
    }

    private static Figure receivablesFigure(HomeContext ctx) {
        Figure figure = unavailable();
        try {
            SABARAgingService.ARAgingRequest request = new SABARAgingService.ARAgingRequest();
            request.companyId = ctx.companyId;
            request.asOfDate = ctx.today;
            request.includeSettled = false;
            SABARAgingService.ARAgingResult aging = SABARAgingService.getAging(request);
            figure.available = true;
            figure.amount = zero(aging.totalOutstanding);
            for (SABARAgingService.ARAgingRow row : aging.rows == null ? new List<SABARAgingService.ARAgingRow>() : aging.rows) {
                if (row.daysPastDue != null && row.daysPastDue > 0 && zero(row.outstandingBaseAmount) > 0) {
                    ctx.overdueCount++;
                    ctx.overdueAmount += row.outstandingBaseAmount;
                }
            }
            ctx.overdueKnown = true;
            figure.count = ctx.overdueCount;
            figure.secondaryAmount = ctx.overdueAmount;
        } catch (Exception ex) {
            figure = unavailable();
        }
        return figure;
    }

    private static Figure payablesFigure(HomeContext ctx) {
        Figure figure = unavailable();
        try {
            SABAccountsPayableWorkspaceController.WorkspaceDTO payables =
                SABAccountsPayableWorkspaceController.getWorkspace(ctx.companyId, ctx.today, 'All', null, false);
            Date horizon = ctx.today.addDays(PAYABLES_WINDOW_DAYS);
            figure.available = true;
            for (SABAccountsPayableWorkspaceController.BillRowDTO bill : payables.bills == null
                    ? new List<SABAccountsPayableWorkspaceController.BillRowDTO>() : payables.bills) {
                if (bill.status == 'Posted' && zero(bill.outstandingAmount) > 0 && bill.dueDate != null && bill.dueDate <= horizon) {
                    figure.amount += bill.outstandingAmount;
                    figure.count++;
                    figure.nextDate = figure.nextDate == null || bill.dueDate < figure.nextDate ? bill.dueDate : figure.nextDate;
                }
            }
        } catch (Exception ex) {
            figure = unavailable();
        }
        return figure;
    }

    private static Figure profitFigure(HomeContext ctx, HomeData data) {
        Figure figure = unavailable();
        data.monthly = new List<MonthBar>();
        if (ctx.yearPeriods.isEmpty() || !canReadLedger() || !SABFinanceHomeReadPolicy.canRead(GL_Account__c.SObjectType,
                new List<Schema.SObjectField>{ GL_Account__c.Account_Type__c })) {
            return figure;
        }
        Id companyId = ctx.companyId;
        Map<Id, MonthBar> bars = new Map<Id, MonthBar>();
        for (Accounting_Period__c period : ctx.yearPeriods) {
            MonthBar bar = new MonthBar();
            bar.monthStart = period.Start_Date__c;
            bar.income = 0;
            bar.expense = 0;
            bars.put(period.Id, bar);
        }
        Set<Id> periodIds = bars.keySet();
        for (AggregateResult row : [
            SELECT Journal_Entry__r.Accounting_Period__c periodId, GL_Account__r.Account_Type__c accountType,
                   SUM(Debit_Base__c) debitTotal, SUM(Credit_Base__c) creditTotal
            FROM Journal_Entry_Line__c
            WHERE Journal_Entry__r.Company__c = :companyId AND Journal_Entry__r.Status__c IN :LEDGER_STATUSES
              AND Journal_Entry__r.Accounting_Period__c IN :periodIds AND GL_Account__r.Account_Type__c IN ('Revenue', 'Expense')
            WITH USER_MODE
            GROUP BY Journal_Entry__r.Accounting_Period__c, GL_Account__r.Account_Type__c
            LIMIT 100
        ]) {
            MonthBar bar = bars.get((Id) row.get('periodId'));
            if (bar == null) {
                continue;
            }
            if ((String) row.get('accountType') == 'Revenue') {
                bar.income -= net(row);
            } else {
                bar.expense += net(row);
            }
        }
        Decimal profit = 0;
        for (Accounting_Period__c period : ctx.yearPeriods) {
            MonthBar bar = bars.get(period.Id);
            profit += bar.income - bar.expense;
            data.monthly.add(bar);
        }
        figure.available = true;
        figure.amount = profit;
        applyBudget(ctx, figure, periodIds);
        return figure;
    }

    private static void applyBudget(HomeContext ctx, Figure figure, Set<Id> periodIds) {
        if (!SABFinanceHomeReadPolicy.canRead(Budget__c.SObjectType, new List<Schema.SObjectField>{
                Budget__c.Status__c, Budget__c.Fiscal_Year__c, Budget__c.Version__c })
            || !SABFinanceHomeReadPolicy.canRead(Budget_Line__c.SObjectType, new List<Schema.SObjectField>{
                Budget_Line__c.Amount__c, Budget_Line__c.GL_Account__c, Budget_Line__c.Accounting_Period__c })) {
            return;
        }
        Id companyId = ctx.companyId;
        Decimal fiscalYear = ctx.period.Fiscal_Year__c;
        List<Budget__c> budgets = [
            SELECT Id
            FROM Budget__c
            WHERE Company__c = :companyId AND Status__c = 'Approved' AND Fiscal_Year__c = :fiscalYear
            WITH USER_MODE
            ORDER BY Version__c DESC
            LIMIT 1
        ];
        if (budgets.isEmpty()) {
            return;
        }
        Id budgetId = budgets[0].Id;
        Decimal budgetProfit = 0;
        for (AggregateResult row : [
            SELECT GL_Account__r.Account_Type__c accountType, SUM(Amount__c) total
            FROM Budget_Line__c
            WHERE Budget__c = :budgetId AND Accounting_Period__c IN :periodIds
              AND GL_Account__r.Account_Type__c IN ('Revenue', 'Expense')
            WITH USER_MODE
            GROUP BY GL_Account__r.Account_Type__c
        ]) {
            Decimal total = zero((Decimal) row.get('total'));
            budgetProfit += (String) row.get('accountType') == 'Revenue' ? total : -total;
        }
        figure.hasComparison = true;
        figure.comparison = figure.amount - budgetProfit;
    }

    private static List<AttentionItem> attention(HomeContext ctx) {
        List<AttentionItem> items = new List<AttentionItem>();
        List<Approval_Step__c> steps = mySteps(ctx);
        if (!steps.isEmpty()) {
            List<String> names = new List<String>();
            for (Approval_Step__c step : steps) {
                if (names.size() < 4) {
                    names.add(step.Approval_Request__r.Name);
                }
            }
            items.add(item('approvals', 'check', 'info', plural(steps.size(), 'approval') + ' waiting for you',
                String.join(names, ', '), 'home'));
        }
        AttentionItem bank = unreconciledLines(ctx);
        if (bank != null) {
            items.add(bank);
        }
        if (ctx.overdueKnown && ctx.overdueCount > 0) {
            items.add(item('overdue', 'sales', 'bad', plural(ctx.overdueCount, 'overdue invoice'),
                ctx.overdueAmount.setScale(2).format() + ' outstanding past due date', 'sales'));
        }
        AttentionItem drafts = draftJournals(ctx);
        if (drafts != null) {
            items.add(drafts);
        }
        CloseProgress progress = closeProgress(ctx);
        if (ctx.period != null && progress.total > 0) {
            String month = fullMonth(ctx.period.Start_Date__c);
            items.add(item('close', 'close', 'accent',
                ctx.period.Status__c == 'Closed' ? month + ' is closed'
                    : month + ' close is ' + percent(progress.done, progress.total) + '% complete',
                progress.done + ' of ' + progress.total + ' close tasks done', 'close'));
        }
        return items;
    }

    private static List<Approval_Step__c> mySteps(HomeContext ctx) {
        if (ctx.mySteps != null) {
            return ctx.mySteps;
        }
        ctx.mySteps = new List<Approval_Step__c>();
        if (!SABFinanceHomeReadPolicy.canRead(Approval_Step__c.SObjectType, new List<Schema.SObjectField>{
                Approval_Step__c.Decision__c, Approval_Step__c.Assignee_User__c })
            || !SABFinanceHomeReadPolicy.canRead(Approval_Request__c.SObjectType, new List<Schema.SObjectField>{
                Approval_Request__c.Company__c, Approval_Request__c.Status__c })) {
            return ctx.mySteps;
        }
        Id companyId = ctx.companyId;
        Id userId = UserInfo.getUserId();
        ctx.mySteps = [
            SELECT Id, Approval_Request__c, Approval_Request__r.Name
            FROM Approval_Step__c
            WHERE Decision__c = :STATUS_PENDING AND Assignee_User__c = :userId
              AND Approval_Request__r.Company__c = :companyId AND Approval_Request__r.Status__c = :STATUS_PENDING
            WITH USER_MODE
            ORDER BY Approval_Request__r.Requested_At__c ASC
            LIMIT 50
        ];
        return ctx.mySteps;
    }

    private static AttentionItem unreconciledLines(HomeContext ctx) {
        if (!SABFinanceHomeReadPolicy.canRead(Bank_Statement_Line__c.SObjectType, new List<Schema.SObjectField>{
                Bank_Statement_Line__c.Bank_Statement__c })
            || !SABFinanceHomeReadPolicy.canRead(Bank_Statement__c.SObjectType, new List<Schema.SObjectField>{
                Bank_Statement__c.Company__c, Bank_Statement__c.Statement_End_Date__c })
            || !SABFinanceHomeReadPolicy.canRead(Reconciliation_Match__c.SObjectType, new List<Schema.SObjectField>{
                Reconciliation_Match__c.Bank_Statement_Line__c, Reconciliation_Match__c.Status__c })) {
            return null;
        }
        Id companyId = ctx.companyId;
        Integer open = [
            SELECT COUNT()
            FROM Bank_Statement_Line__c
            WHERE Bank_Statement__r.Company__c = :companyId
              AND Id NOT IN (SELECT Bank_Statement_Line__c FROM Reconciliation_Match__c WHERE Status__c = 'Confirmed')
            WITH USER_MODE
        ];
        if (open == 0) {
            return null;
        }
        AggregateResult latest = [
            SELECT MAX(Statement_End_Date__c) lastDate
            FROM Bank_Statement__c
            WHERE Company__c = :companyId
            WITH USER_MODE
        ];
        Date lastDate = (Date) latest.get('lastDate');
        return item('bank', 'bank', 'warn', plural(open, 'bank line') + ' to reconcile',
            lastDate == null ? 'Imported statements' : 'Statements to ' + shortDate(lastDate), 'bank');
    }

    private static AttentionItem draftJournals(HomeContext ctx) {
        if (ctx.period == null || !SABFinanceHomeReadPolicy.canRead(Journal_Entry__c.SObjectType, new List<Schema.SObjectField>{
                Journal_Entry__c.Status__c, Journal_Entry__c.Accounting_Period__c })) {
            return null;
        }
        Id periodId = ctx.period.Id;
        Id companyId = ctx.companyId;
        Integer drafts = [
            SELECT COUNT()
            FROM Journal_Entry__c
            WHERE Company__c = :companyId AND Accounting_Period__c = :periodId AND Status__c = 'Draft'
            WITH USER_MODE
        ];
        if (drafts == 0) {
            return null;
        }
        return item('drafts', 'journal', 'neutral', plural(drafts, 'draft journal') + ' in ' + fullMonth(ctx.period.Start_Date__c),
            'Post or discard before closing ' + ctx.period.Period_Key__c, 'journal');
    }

    private static CloseProgress closeProgress(HomeContext ctx) {
        if (ctx.close != null) {
            return ctx.close;
        }
        ctx.close = new CloseProgress();
        if (ctx.period == null || !SABFinanceHomeReadPolicy.canRead(Close_Task__c.SObjectType, new List<Schema.SObjectField>{
                Close_Task__c.Status__c, Close_Task__c.Accounting_Period__c })) {
            return ctx.close;
        }
        Id periodId = ctx.period.Id;
        for (AggregateResult row : [
            SELECT Status__c taskStatus, COUNT(Id) taskCount
            FROM Close_Task__c
            WHERE Accounting_Period__c = :periodId
            WITH USER_MODE
            GROUP BY Status__c
        ]) {
            Integer count = (Integer) row.get('taskCount');
            ctx.close.total += count;
            if ((String) row.get('taskStatus') == 'Complete') {
                ctx.close.done += count;
            }
        }
        return ctx.close;
    }

    @TestVisible
    private static RoleCard roleCardFor(Id companyId, String personaKey) {
        HomeContext ctx = new HomeContext();
        ctx.companyId = companyId;
        ctx.today = Date.today();
        ctx.persona = SABPersonaService.current();
        ctx.persona.key = personaKey;
        loadPeriods(ctx, new HomeData());
        return roleCard(ctx);
    }

    private static RoleCard roleCard(HomeContext ctx) {
        String key = ctx.persona.key;
        if (key == SABPersonaService.FINANCE_MANAGER) {
            return financeManagerCard(ctx);
        }
        if (key == SABPersonaService.BOOKKEEPER) {
            return bookkeeperCard(ctx);
        }
        if (key == SABPersonaService.TREASURY) {
            return treasuryCard(ctx);
        }
        if (key == SABPersonaService.HR) {
            return hrCard(ctx);
        }
        if (key == SABPersonaService.DIRECTOR) {
            return directorCard(ctx);
        }
        return auditorCard(ctx);
    }

    private static RoleCard card(String kind, String caption) {
        RoleCard roleCard = new RoleCard();
        roleCard.kind = kind;
        roleCard.caption = caption;
        roleCard.isMoney = false;
        roleCard.showMeter = false;
        roleCard.items = new List<RoleItem>();
        return roleCard;
    }

    private static RoleCard financeManagerCard(HomeContext ctx) {
        CloseProgress progress = closeProgress(ctx);
        RoleCard roleCard = card('close', 'Close progress for ' + (ctx.period == null ? 'the current period' : ctx.period.Period_Key__c));
        roleCard.valueText = progress.total == 0 ? 'No close tasks yet' : progress.done + ' of ' + progress.total + ' tasks';
        roleCard.showMeter = progress.total > 0;
        roleCard.meterPercent = progress.total == 0 ? 0 : percent(progress.done, progress.total);
        roleCard.actionLabel = 'Open period close';
        roleCard.actionWorkspace = 'close';
        return roleCard;
    }

    private static RoleCard bookkeeperCard(HomeContext ctx) {
        RoleCard roleCard = card('drafts', 'Your drafts');
        roleCard.actionWorkspace = 'journal';
        if (!SABFinanceHomeReadPolicy.canRead(Journal_Entry__c.SObjectType, new List<Schema.SObjectField>{
                Journal_Entry__c.Status__c, Journal_Entry__c.Description__c })) {
            return roleCard;
        }
        Id companyId = ctx.companyId;
        Id userId = UserInfo.getUserId();
        for (Journal_Entry__c journal : [
            SELECT Id, Name, Description__c
            FROM Journal_Entry__c
            WHERE Company__c = :companyId AND Status__c = 'Draft' AND CreatedById = :userId
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 5
        ]) {
            RoleItem row = new RoleItem();
            row.recordId = journal.Id;
            row.name = journal.Name;
            row.detail = journal.Description__c;
            roleCard.items.add(row);
        }
        roleCard.detail = roleCard.items.isEmpty() ? 'No draft journals. New drafts you create appear here.' : null;
        return roleCard;
    }

    private static RoleCard treasuryCard(HomeContext ctx) {
        RoleCard roleCard = card('release', 'Payments to release');
        roleCard.isMoney = true;
        roleCard.valueAmount = 0;
        roleCard.actionLabel = 'Open payments';
        roleCard.actionWorkspace = 'payments';
        if (!SABFinanceHomeReadPolicy.canRead(Accounting_Payment__c.SObjectType, new List<Schema.SObjectField>{
                Accounting_Payment__c.Amount__c, Accounting_Payment__c.Direction__c, Accounting_Payment__c.Processing_State__c,
                Accounting_Payment__c.Effective_Date__c })) {
            roleCard.detail = 'Payment detail is not available to you.';
            return roleCard;
        }
        Id companyId = ctx.companyId;
        AggregateResult row = [
            SELECT SUM(Amount__c) total, COUNT(Id) paymentCount, MIN(Effective_Date__c) nextDate
            FROM Accounting_Payment__c
            WHERE Company__c = :companyId AND Direction__c = 'Disbursement' AND Processing_State__c IN ('Draft', 'Authorized')
            WITH USER_MODE
        ];
        Integer count = (Integer) row.get('paymentCount');
        Date nextDate = (Date) row.get('nextDate');
        roleCard.valueAmount = zero((Decimal) row.get('total'));
        roleCard.detail = count == 0 ? 'Nothing waiting for release.'
            : plural(count, 'payment') + (nextDate == null ? '' : ', next value date ' + shortDate(nextDate));
        return roleCard;
    }

    private static RoleCard hrCard(HomeContext ctx) {
        RoleCard roleCard = card('payroll', 'Latest payroll');
        roleCard.actionLabel = 'Open payroll';
        roleCard.actionWorkspace = 'payroll';
        if (!SABFinanceHomeReadPolicy.canRead(Payroll_Run__c.SObjectType, new List<Schema.SObjectField>{
                Payroll_Run__c.Run_Key__c, Payroll_Run__c.Workflow_State__c, Payroll_Run__c.Pay_Period_End__c })) {
            roleCard.valueText = 'Not available';
            return roleCard;
        }
        Id companyId = ctx.companyId;
        List<Payroll_Run__c> runs = [
            SELECT Run_Key__c, Workflow_State__c, Pay_Period_End__c
            FROM Payroll_Run__c
            WHERE Company__c = :companyId
            WITH USER_MODE
            ORDER BY Pay_Period_End__c DESC NULLS LAST
            LIMIT 1
        ];
        if (runs.isEmpty()) {
            roleCard.valueText = 'No payroll runs yet';
            return roleCard;
        }
        roleCard.caption = 'Payroll ' + runs[0].Run_Key__c;
        roleCard.valueText = runs[0].Workflow_State__c;
        roleCard.detail = runs[0].Pay_Period_End__c == null ? null : 'Pay period ends ' + shortDate(runs[0].Pay_Period_End__c) + '.';
        return roleCard;
    }

    private static RoleCard directorCard(HomeContext ctx) {
        Integer waiting = mySteps(ctx).size();
        RoleCard roleCard = card('approve', 'Waiting for your decision');
        roleCard.valueText = plural(waiting, 'approval');
        roleCard.detail = waiting == 0 ? 'Nothing needs your approval right now.'
            : 'Requests assigned to you are listed in the approvals queue.';
        return roleCard;
    }

    private static RoleCard auditorCard(HomeContext ctx) {
        RoleCard roleCard = card('audit', 'Read-only access');
        roleCard.actionLabel = 'Open audit history';
        roleCard.actionWorkspace = 'audit';
        if (!SABFinanceHomeReadPolicy.canRead(Business_Action__c.SObjectType, new List<Schema.SObjectField>{
                Business_Action__c.Company__c, Business_Action__c.Action_At__c })) {
            roleCard.valueText = 'Not available';
            return roleCard;
        }
        Id companyId = ctx.companyId;
        Datetime monthStart = Datetime.newInstance(ctx.today.toStartOfMonth(), Time.newInstance(0, 0, 0, 0));
        Integer events = [
            SELECT COUNT()
            FROM Business_Action__c
            WHERE Company__c = :companyId AND Action_At__c >= :monthStart
            WITH USER_MODE
        ];
        roleCard.valueText = plural(events, 'event');
        roleCard.detail = 'logged this month across postings, approvals and period actions.';
        return roleCard;
    }

    private static void loadRecent(HomeContext ctx, HomeData data) {
        data.recent = new List<PostingRow>();
        data.recentAvailable = SABFinanceHomeReadPolicy.canRead(Journal_Entry__c.SObjectType, new List<Schema.SObjectField>{
            Journal_Entry__c.Status__c, Journal_Entry__c.Description__c, Journal_Entry__c.Accounting_Date__c,
            Journal_Entry__c.Posted_At__c, Journal_Entry__c.Posted_By__c });
        if (!data.recentAvailable) {
            return;
        }
        Id companyId = ctx.companyId;
        for (Journal_Entry__c journal : [
            SELECT Id, Name, Description__c, Accounting_Date__c, Status__c, Posted_By__r.Name
            FROM Journal_Entry__c
            WHERE Company__c = :companyId AND Status__c IN :LEDGER_STATUSES
            WITH USER_MODE
            ORDER BY Posted_At__c DESC NULLS LAST
            LIMIT 5
        ]) {
            PostingRow row = new PostingRow();
            row.recordId = journal.Id;
            row.name = journal.Name;
            row.description = journal.Description__c;
            row.accountingDate = journal.Accounting_Date__c;
            row.postedBy = journal.Posted_By__r == null ? null : journal.Posted_By__r.Name;
            row.status = journal.Status__c;
            data.recent.add(row);
        }
    }

    private static void loadApprovals(HomeContext ctx, HomeData data) {
        data.approvals = new List<ApprovalRow>();
        data.approvalsAvailable = SABFinanceHomeReadPolicy.canRead(Approval_Request__c.SObjectType, new List<Schema.SObjectField>{
                Approval_Request__c.Status__c, Approval_Request__c.Source_Type__c, Approval_Request__c.Source_Business_Key__c,
                Approval_Request__c.Requested_By__c, Approval_Request__c.Requested_At__c })
            && SABFinanceHomeReadPolicy.canRead(Approval_Step__c.SObjectType, new List<Schema.SObjectField>{
                Approval_Step__c.Decision__c, Approval_Step__c.Assignee_User__c, Approval_Step__c.Sequence__c });
        if (!data.approvalsAvailable) {
            return;
        }
        Id companyId = ctx.companyId;
        Map<Id, ApprovalRow> byId = new Map<Id, ApprovalRow>();
        for (Approval_Request__c request : [
            SELECT Id, Name, Source_Type__c, Source_Business_Key__c, Requested_At__c, Status__c, Requested_By__r.Name
            FROM Approval_Request__c
            WHERE Company__c = :companyId AND Status__c = :STATUS_PENDING
            WITH USER_MODE
            ORDER BY Requested_At__c ASC
            LIMIT 10
        ]) {
            ApprovalRow row = new ApprovalRow();
            row.recordId = request.Id;
            row.name = request.Name;
            row.sourceType = request.Source_Type__c;
            row.sourceKey = request.Source_Business_Key__c;
            row.requestedAt = request.Requested_At__c;
            row.requestedBy = request.Requested_By__r == null ? null : request.Requested_By__r.Name;
            row.status = request.Status__c;
            byId.put(request.Id, row);
            data.approvals.add(row);
        }
        if (byId.isEmpty()) {
            return;
        }
        Set<Id> requestIds = byId.keySet();
        for (Approval_Step__c step : [
            SELECT Approval_Request__c, Assignee_User__r.Name
            FROM Approval_Step__c
            WHERE Approval_Request__c IN :requestIds AND Decision__c = :STATUS_PENDING
            WITH USER_MODE
            ORDER BY Sequence__c ASC
        ]) {
            ApprovalRow row = byId.get(step.Approval_Request__c);
            if (row.needs == null && step.Assignee_User__r != null) {
                row.needs = step.Assignee_User__r.Name;
            }
        }
    }

    private static SetupSummary setupSummary(Id companyId) {
        SetupSummary summary = new SetupSummary();
        summary.accountCount = Schema.SObjectType.GL_Account__c.isAccessible()
            ? [SELECT COUNT() FROM GL_Account__c WHERE Company__c = :companyId WITH USER_MODE] : 0;
        summary.periodCount = Schema.SObjectType.Accounting_Period__c.isAccessible()
            ? [SELECT COUNT() FROM Accounting_Period__c WHERE Company__c = :companyId WITH USER_MODE] : 0;
        summary.bankAccountCount = Schema.SObjectType.Bank_Account__c.isAccessible()
            ? [SELECT COUNT() FROM Bank_Account__c WHERE Company__c = :companyId WITH USER_MODE] : 0;
        return summary;
    }

    private static AttentionItem item(String key, String icon, String tone, String title, String detail, String workspace) {
        AttentionItem row = new AttentionItem();
        row.key = key;
        row.icon = icon;
        row.tone = tone;
        row.title = title;
        row.detail = detail;
        row.workspace = workspace;
        return row;
    }

    private static Decimal net(AggregateResult row) {
        return zero((Decimal) row.get('debitTotal')) - zero((Decimal) row.get('creditTotal'));
    }

    private static Decimal zero(Decimal value) {
        return value == null ? 0 : value;
    }

    @TestVisible
    private static Integer percent(Integer done, Integer total) {
        return total == 0 ? 0 : (Integer) Math.round(done * 100.0 / total);
    }

    @TestVisible
    private static String plural(Integer count, String noun) {
        return count + ' ' + (count == 1 ? noun : noun + 's');
    }

    private static final List<String> MONTH_NAMES = new List<String>{
        'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'
    };

    @TestVisible
    private static String fullMonth(Date value) {
        return MONTH_NAMES[value.month() - 1];
    }

    @TestVisible
    private static String shortDate(Date value) {
        return value.day() + ' ' + MONTH_NAMES[value.month() - 1].left(3);
    }
}
