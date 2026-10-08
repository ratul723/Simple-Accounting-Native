# Bank reconciliation demo (Demo Operating Bank, USD, company com2)

## 1. Load the demo data
    node load-sab-test-data.js
Files 25-28 add: GL 1015 "Demo Operating Bank - USD" (a normal Asset account, so manual journals may use it), the bank account "Demo Operating Bank" mapped to it, and 6 Draft journals DB-01..DB-06.

## 2. Permission sets for the demo user (assign, then reload the page)
    sf org assign permset --name SAB_Bank_Reconciliation_Workspace_User --name SAB_Import_Bank_Statement_Action --name SAB_Reconcile_Bank_Action --name SAB_Finalize_Bank_Reconciliation_Action --name SAB_Post_Journal_Action --target-org devscratchorg
The Import Statement tab stays empty without SAB_Import_Bank_Statement_Action. Match & Review needs SAB_Reconcile_Bank_Action. Finalize needs SAB_Finalize_Bank_Reconciliation_Action.

## 3. Post the bank journals (Journal Workspace) - before the demo
Post DB-01 to DB-05 only. Keep DB-06 as a Draft for the demo story.

| Journal | Date | What it is | Bank effect |
|---|---|---|---|
| DB-01 | Oct 1 | Capital deposited | +25,000.00 |
| DB-02 | Oct 2 | Rent paid | -1,500.00 |
| DB-03 | Oct 3 | Card sales deposit | +6,200.00 |
| DB-04 | Oct 4 | Electricity paid | -380.00 |
| DB-05 | Oct 5 | Stationery | -120.00 |
| DB-06 | Oct 6 | Bank charges (keep Draft) | -15.00 |

Book balance after DB-01..05 = 29,200.00. After DB-06 = 29,185.00.

## 4. The three tabs, in plain words
- **Import Statement:** you type in what the bank says happened. It is a form, not a file upload.
- **Match & Review:** you tell the system which bank line = which journal line already in your books.
- **Finalize:** the system checks the books and the bank agree, then locks the result.

## 5. Demo script
**Import Statement tab** (Bank Account = Demo Operating Bank)
- Statement Start 2026-10-01, End 2026-10-31, Opening 0.00, Closing 29185.00, Currency USD, Import Fingerprint HH-STMT-2026-10-DEMO.
- Add the 6 lines from DEMO_bank_statement_lines_for_the_form.csv (Transaction Date, Value Date, Amount, Provider Line Id, Reference). Deposits are positive, payments negative.
- Click Import Statement, then Validate Selected Statement. Validation checks: opening + lines = closing, dates inside the statement range, line numbers and fingerprints unique, currency matches the bank account.

**Match & Review tab**
- Pick the statement, click Start / Resume Reconciliation (status becomes In Review).
- Select a statement line, click Find Matches, then Match (or Propose, then confirm later). The candidates are posted journal lines on the bank's GL account with the same amount and direction inside the date window.
- Match lines 1-5. Line 6 (-15.00 ACCOUNT FEE) has no candidate yet.

**Finalize tab - first attempt fails on purpose**
- Finalize is blocked because line 6 is not matched and the statement closing (29,185) differs from the book balance (29,200).

**Fix it live**
- Post DB-06 in the Journal Workspace, return to Match & Review, Refresh, Find Matches on line 6, Match it.
- Finalize now passes: every line is matched and 29,185.00 = 29,185.00. The statement becomes Reconciled.

## 6. Rules the demo shows (from the code)
- Only Posted journal lines on the bank's GL account can be matched; a positive statement line must match a debit, a negative one a credit.
- All Proposed matches must be confirmed or reversed before finalizing; every statement line must be fully matched.
- A finalized reconciliation cannot be changed. To rerun the demo, import a new statement with a different Import Fingerprint (and a new bank account or fresh journals).
