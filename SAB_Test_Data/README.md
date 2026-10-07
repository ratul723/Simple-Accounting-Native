# SAB test data for Habib Hasan (com2, USD)

24 CSV files, loaded in number order by `load-sab-test-data.js`.

## Run it
From this folder, in a terminal where `sf` works (needs a recent Salesforce CLI with `sf data import bulk`; run `sf update` if the command is missing):

    node load-sab-test-data.js --dry
    node load-sab-test-data.js

`--dry` only checks the files. The real run uses org alias `devscratchorg`. If a file fails, fix the cause and re-run with `--from NN`; rows that already exist are skipped, so re-running is safe.

## Why a script and not a plain CSV import
Salesforce imports need record Ids for every lookup. The CSVs use readable keys instead (`com2`, `HH-1010`, `HH-SUPP-001`). The script swaps each key for the real Id, then imports.

## What loads
| Files | Data | Rows |
|---|---|---|
| 01-02 | GL accounts (all 5 types), 2026 monthly periods | 46, 12 |
| 03-05 | Departments, cost centers, payment terms | 5 each |
| 06-07 | Customers and suppliers (standard Account), accounting profiles | 10, 10 |
| 08-09 | Tax codes and rates | 5 each |
| 10-11 | Bank accounts, asset categories | 5 each |
| 12-16 | Employees, employment, pay components, Draft compensation, Proposed awards | 5, 5, 5, 15, 5 |
| 17-18 | Report definitions (P&L x2, Balance Sheet x2, Cash Flow draft) and mappings | 5, 92 |
| 19-20 | Draft manual journals and lines | 6, 13 |
| 21-24 | Draft supplier bills, bill lines, invoices, invoice lines | 5, 6, 5, 6 |

## After loading (done in the UI, in this order)
1. **Journal Workspace:** post JE-01 to JE-06. Then the reports show: P&L net profit **9,200** (revenue 9,700, expenses 500); Balance Sheet total assets **59,200** = capital 50,000 + current-year earnings 9,200.
2. **HR Workspace > HR Approvals:** approve compensation and awards with a user who is not the creator and holds the approve permission sets.
3. **AP / AR Workspaces:** approve and post the draft bills and invoices, then record payments and receipts.

## Not loadable by CSV (the app blocks direct inserts or they need the UI)
Fixed assets, payments and receipts, payroll runs and settlements, expense claims, bank statements, tax returns, FX revaluation runs. These go through the workspaces or services.

## Assumptions
- Company key is `com2`. If yours differs, the script says so; change `COMPANY_KEY` in the script and the `Company__c` column.
- GL keys start with `HH-` so they do not clash with accounts you already have.
- Periods that overlap an existing one are skipped. Journals pick the open period containing their date.
- Journals use only manual-posting, non-control accounts, because the Journal Workspace hides control accounts.
- Bills and invoices carry no tax code, so totals equal subtotals.
