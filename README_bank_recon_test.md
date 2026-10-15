# Banking & reconciliation – test pack

Creates a fresh bank account with known transactions so every part of the Banking workspace can be tested:
import, validation errors, exact matches, a choice between two same-amount candidates, an unmatched statement
line fixed by posting a journal, an outstanding cheque, finalisation and a second statement.

## 1. Permissions (the user who runs the test)

```
sf org assign permset --target-org devscratchorg --name SAB_Bank_Reconciliation_Workspace_User --name SAB_Import_Bank_Statement_Action --name SAB_Reconcile_Bank_Action --name SAB_Finalize_Bank_Reconciliation_Action --name SAB_Post_Journal_Action
```

## 2. Load the data

Copy `scripts/apex/seed_bank_recon_test.apex` into your project, check `COMPANY_NAME` at the top
(default `Ratuls Company Ltd`), then run:

```
sf apex run --file scripts/apex/seed_bank_recon_test.apex --target-org devscratchorg
```

Then post RT-01..RT-07, one journal per run (a posting uses many queries, so they cannot all go in one run).
PowerShell:

```
1..7 | ForEach-Object { sf apex run --file scripts/apex/post_next_recon_journal.apex --target-org devscratchorg }
```

Each run prints "Posted [RT-0x] …"; an eighth run prints "Nothing left to post". You can instead post
RT-01..RT-07 by hand in **Journals** (leave RT-08 as Draft).

It creates, in that company:

- GL **1060 Recon Test Bank** and bank account **Recon Test Bank** (company currency, opening 0 on 1 Oct 2026)
- 8 Draft journals on the bank account; you then post RT-01 to RT-07 and keep RT-08 as **Draft**

| Journal | Date | Description | Bank effect | State |
|---|---|---|---|---|
| RT-01 | 1 Oct | Capital deposited | +10,000.00 | Posted |
| RT-02 | 3 Oct | Customer receipt – Acme | +2,500.00 | Posted |
| RT-03 | 5 Oct | Office rent | −1,200.00 | Posted |
| RT-04 | 7 Oct | Supplier payment – Fuel Co | −800.00 | Posted |
| RT-05 | 8 Oct | Office supplies – Paper Ltd | −800.00 | Posted |
| RT-06 | 10 Oct | Electricity | −350.00 | Posted |
| RT-07 | 12 Oct | Cheque 1001 (not cleared yet) | −600.00 | Posted |
| RT-08 | 13 Oct | Bank charges | −25.00 | **Draft** |

Book balance after posting RT-01..RT-07: **8,750.00**. The script is safe to run twice (it skips what exists).

Needs: an **open period covering 1–13 Oct 2026** and at least one active, manual-posting Equity, Revenue and
Expense account in the company.

## 3. Test script

Open **Banking & reconciliation** and click the **Recon Test Bank** card (book balance 8,750.00, "No statement").

**A. Import – error paths**
1. Import statement → choose `rt_statement_no_amount_column.csv` → expect "The file needs date and amount columns."
2. Choose `rt_statement_invalid.csv` → expect "Line 2: use yyyy-mm-dd dates and numeric amounts."
3. Choose `rt_statement_2026-10.csv`, Opening **0**, Closing **9000** (wrong) → Import → validation fails because
   opening + lines ≠ closing (lines net 9,325.00).

**B. Import – correct**
4. Same file, Opening **0**, Closing **9325.00** → Import. The statement is imported, validated and the
   reconciliation starts (status In Review). Card shows "7 to match".
5. Import the same file again with the same values → expect a duplicate/fingerprint refusal.

**C. Matching**
6. Line 10,000.00 (1 Oct) → one candidate RT-01 → match.
7. Line 2,500.00 → RT-02 (value date 4 Oct is inside the date window) → match.
8. Line −1,200.00 → RT-03 → match.
9. Lines −800.00 on 7 and 8 Oct → **two candidates each (RT-04 and RT-05)**. Match 7 Oct to RT-04, 8 Oct to RT-05.
   Try matching the second line to the journal line already used → expect a refusal.
10. Line −350.00 → use the **suggested / proposed** match for RT-06, then **confirm** it. Optionally reverse a
    confirmed match and redo it to test reversal.
11. Line −25.00 ACCOUNT FEE → **no candidate** (RT-08 is still Draft).

**D. Finalise – first attempt blocked**
12. Finalise stays disabled: one line unmatched and the difference is not 0. Hover the button for the reason.

**E. Fix it**
13. Go to **Journals**, open the draft "[RT-08] Bank charges October" and **Post** it (book balance becomes 8,725.00).
14. Back in Banking, select line −25.00 → candidate RT-08 → match.
15. RT-07 (−600.00 cheque) stays as an **outstanding payment** in the ledger list – it is in the books but not on the
    statement. Statement 9,325.00 = book 8,725.00 + outstanding cheque 600.00.
16. **Finalise reconciliation** → status Reconciled, the card shows the statement as finalised and matches are locked.

**F. Next statement (outstanding item clears)**
17. Import `rt_statement_2026-10_part2.csv`, Opening **9325.00**, Closing **10225.00**.
18. Match −600.00 to RT-07 (the cheque clears).
19. Line +1,500.00 UNKNOWN DEPOSIT has no book entry → finalise is blocked. Either post a journal for it
    (Dr 1060 / Cr a revenue or suspense account, 14 Oct) and match it, or leave it to see the unexplained-difference
    message.

## 4. What each step proves

| Area | Steps |
|---|---|
| CSV parsing and file errors | 1–2 |
| Opening + lines = closing validation | 3 |
| Duplicate statement protection | 5 |
| Exact and date-window matching | 6–8 |
| Several candidates, one-to-one matching | 9 |
| Proposed → confirm, reverse | 10 |
| Unmatched line, finalise blocked | 11–12 |
| Only posted lines can be matched | 11, 13–14 |
| Outstanding items, finalise | 15–16 |
| Continuing statements, clearing outstanding items | 17–19 |

To run the whole test again, change `BANK_CODE` to another free code (for example 1061) and the journal keys,
or use a fresh scratch org; finalised reconciliations cannot be undone.
