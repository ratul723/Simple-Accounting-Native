/**
 * Workspace registry for the Simple Accounting Books shell: groups, order, labels and icons follow
 * the Harbourline demo. "loader" is a static dynamic import so the platform can analyse it;
 * workspaces without a loader stay hidden until their G22 sub-stage registers them.
 * shellAware workspaces receive company, persona and capabilities as @api properties; legacy
 * workspaces read the company from SABCompanyContext__c and session storage as before.
 */
export const GROUPS = [
    'Overview',
    'Ledger',
    'Money in & out',
    'People & assets',
    'Planning',
    'Compliance & reporting',
    'Optional modules',
    'Administration'
];

export const SETUP_ALLOWED = ['home', 'setup', 'import', 'config'];

export const WORKSPACES = [
    { id: 'home', group: 'Overview', label: 'Finance home', icon: 'home', shellAware: true,
        loader: () => import('c/sabFinanceHome') },
    { id: 'journal', group: 'Ledger', label: 'Journals', icon: 'journal', title: 'Journals',
        description: 'Create and edit draft journals, check they balance, preview the posting and post. Posted journals are locked.',
        loader: () => import('c/sabJournalWorkspace') },
    { id: 'reversal', group: 'Ledger', label: 'Journal reversals', icon: 'reverse', title: 'Journal reversals',
        description: 'Reverse posted journals with a required reason and a linked, auditable history.' },
    { id: 'close', group: 'Ledger', label: 'Period close', icon: 'close', title: 'Period close & reopen',
        description: 'Accounting periods, close checklist, blocking exceptions and a permanent record of every close and reopen.',
        loader: () => import('c/sabAccountingPeriodWorkspace') },
    { id: 'audit', group: 'Ledger', label: 'Audit history', icon: 'audit', title: 'Audit & action history',
        description: 'Every posting, reversal, approval, settlement and period action, with who did it, when and why.',
        loader: () => import('c/sabAuditTimeline') },
    { id: 'sales', group: 'Money in & out', label: 'Sales & receivables', icon: 'sales', title: 'Sales & receivables',
        description: 'Invoices, credit notes, customers, receipts and what is still owed.',
        loader: () => import('c/sabAccountsReceivableWorkspace') },
    { id: 'purchases', group: 'Money in & out', label: 'Purchases & payables', icon: 'purch', title: 'Purchases & payables',
        description: 'Supplier bills and credits, purchase orders and receipts, approvals and payment scheduling.',
        loader: () => import('c/sabAccountsPayableWorkspace') },
    { id: 'payments', group: 'Money in & out', label: 'Payments', icon: 'pay', title: 'Payments',
        description: 'Receipts and disbursements, allocations to invoices and bills, FX and settlement status.' },
    { id: 'bank', group: 'Money in & out', label: 'Banking & reconciliation', icon: 'bank', title: 'Banking & reconciliation',
        description: 'Import bank statements, match them to posted ledger lines, explain differences and finalise.',
        loader: () => import('c/sabBankReconciliationWorkspace') },
    { id: 'payroll', group: 'People & assets', label: 'People & payroll', icon: 'people', title: 'People & payroll',
        description: 'Employees, pay components, incentives and allowances, payroll runs, posting and settlement.',
        loader: () => import('c/sabPayrollWorkspace') },
    { id: 'assets', group: 'People & assets', label: 'Fixed assets', icon: 'assets', title: 'Fixed assets',
        description: 'Asset register, acquisition from bills, depreciation, transfers and disposal.',
        loader: () => import('c/sabFixedAssetWorkspace') },
    { id: 'budgets', group: 'Planning', label: 'Budgets', icon: 'budget', title: 'Budgets',
        description: 'Budget versions, budget lines by account and department, and actual against budget on the same basis.',
        loader: () => import('c/sabBudgetWorkspace') },
    { id: 'projects', group: 'Planning', label: 'Projects', icon: 'proj', optional: true, title: 'Projects',
        description: 'Track costs and revenue by project using the project dimension on journal, invoice and bill lines.' },
    { id: 'tax', group: 'Compliance & reporting', label: 'Tax', icon: 'tax', title: 'Tax',
        description: 'Tax codes and rates, calculated source tax lines, and return preparation.',
        loader: () => import('c/sabTaxReturnWorkspace') },
    { id: 'reports', group: 'Compliance & reporting', label: 'Report center', icon: 'report', title: 'Report center',
        description: 'Financial statements from the posted ledger, with drill-down to journal lines and source documents.' },
    { id: 'equity', group: 'Optional modules', label: 'Capital & equity', icon: 'equity', optional: true, title: 'Capital & equity',
        description: 'Share register, capital transactions, dividends and owner distributions.' },
    { id: 'loans', group: 'Optional modules', label: 'Investments & loans', icon: 'loan', optional: true, title: 'Investments & loans',
        description: 'Borrowings, shareholder loans, lending, investments and their accounting.' },
    { id: 'setup', group: 'Administration', label: 'Company setup', icon: 'setup', title: 'Company setup',
        description: 'Company profile, functional currency, fiscal calendar, periods, defaults and document numbering.',
        loader: () => import('c/sabCompanySetupWizard') },
    { id: 'coa', group: 'Administration', label: 'Chart of accounts', icon: 'coa', title: 'Chart of accounts & dimensions',
        description: 'GL accounts, departments, cost centers, projects and report mappings for this company.' },
    { id: 'import', group: 'Administration', label: 'Import & integration', icon: 'import', title: 'Import & integration center',
        description: 'Stage files, validate, preview, commit and retry, and follow every outbound integration request.' },
    { id: 'config', group: 'Administration', label: 'Configuration & diagnostics', icon: 'config', title: 'Configuration & diagnostics',
        description: 'Company features, access grants, approval rules, configuration checks and processing health.' }
];

export const WORKSPACE_BY_ID = Object.fromEntries(WORKSPACES.map((w) => [w.id, w]));
