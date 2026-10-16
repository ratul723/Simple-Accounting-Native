@IsTest
private class SABImportServiceTest {

    @TestSetup
    static void setupData() {
        SABImportTestFixture.createFixture();
    }

    private static Map<Decimal, Import_Row__c> rows(Id jobId) {
        Map<Decimal, Import_Row__c> result = new Map<Decimal, Import_Row__c>();
        for (Import_Row__c r : [SELECT Row_Number__c, Validation_Status__c, Validation_Message__c, Committed_Record_Id__c FROM Import_Row__c
                WHERE Import_Job__c = :jobId WITH SYSTEM_MODE]) {
            result.put(r.Row_Number__c, r);
        }
        return result;
    }

    @IsTest
    static void chartOfAccountsStagesValidatesAndCommitsValidRows() {
        String csv = 'Account_Code,Name,Account_Type,Normal_Balance\n5000,Rent,Expense,\n4000,Duplicate sales,Revenue,\n6000,Mystery,Income,\n';
        SABImportService.ActionResult staged;
        SABImportService.ActionResult replay;
        SABImportService.ActionResult validated;
        SABImportService.ActionResult committed;
        System.runAs(SABImportTestFixture.user(SABImportTestFixture.IMPORTER)) {
            SABTestGovernor.startTest();
            staged = SABImportService.stage(SABImportTestFixture.companyId(), 'Chart of Accounts', csv);
            replay = SABImportService.stage(SABImportTestFixture.companyId(), 'Chart of Accounts', csv);
            validated = SABImportService.validate(staged.importJobId);
            committed = SABImportService.commitImport(staged.importJobId, 'I20-COA-COMMIT');
            SABTestGovernor.stopTest();
        }
        System.assertEquals('Parsed', staged.status, 'Staged.');
        System.assertEquals(3, staged.rowCount, 'Three data rows.');
        System.assertEquals(true, replay.replay, 'The same file replays the job.');
        System.assertEquals('Validated', validated.status, 'Errors keep the job at Validated.');
        System.assertEquals(1, validated.validCount, 'One valid row.');
        System.assertEquals(2, validated.errorCount, 'Two invalid rows.');
        System.assertEquals('Part Failed', committed.status, 'Only the valid row is committed.');
        Map<Decimal, Import_Row__c> byRow = rows(staged.importJobId);
        System.assert(byRow.get(2).Validation_Message__c.contains('already exists'), byRow.get(2).Validation_Message__c);
        System.assert(byRow.get(3).Validation_Message__c.contains('account_type must be'), byRow.get(3).Validation_Message__c);
        GL_Account__c rent = [SELECT Normal_Balance__c, Account_Type__c FROM GL_Account__c WHERE Id = :byRow.get(1).Committed_Record_Id__c WITH SYSTEM_MODE];
        System.assertEquals('Debit', rent.Normal_Balance__c, 'Expense accounts default to a debit balance.');
        System.assertEquals('Committed', byRow.get(1).Validation_Status__c, 'Row committed.');
    }

    @IsTest
    static void journalImportsCreateBalancedDraftJournals() {
        String csv = 'journal_key,accounting_date,account_code,debit,credit,description,explanation\n'
            + 'J1,2026-01-15,1100,"1,250.00",0,January cash sale,Cash in\n'
            + 'J1,2026-01-15,4000,0,1250,January cash sale,Sale\n'
            + 'J2,2026-01-20,1100,100,0,Unbalanced,\n'
            + 'J2,2026-01-20,4000,0,90,Unbalanced,\n'
            + 'J3,2026-01-21,1200,50,0,Control,\n'
            + 'J3,2026-01-21,4000,0,50,Control,\n'
            + 'J4,2026-02-10,1100,10,0,Closed month,\n'
            + 'J4,2026-02-10,4000,0,10,Closed month,\n';
        SABImportService.ActionResult validated;
        SABImportService.ActionResult committed;
        Id jobId;
        System.runAs(SABImportTestFixture.user(SABImportTestFixture.IMPORTER)) {
            SABTestGovernor.startTest();
            jobId = SABImportService.stage(SABImportTestFixture.companyId(), 'Journal Entries', csv).importJobId;
            validated = SABImportService.validate(jobId);
            committed = SABImportService.commitImport(jobId, 'I20-JNL-COMMIT');
            SABTestGovernor.stopTest();
        }
        System.assertEquals(2, validated.validCount, 'Only J1 is valid.');
        System.assertEquals(6, validated.errorCount, 'J2, J3 and J4 fail.');
        Map<Decimal, Import_Row__c> byRow = rows(jobId);
        System.assert(byRow.get(3).Validation_Message__c.contains('does not balance'), byRow.get(3).Validation_Message__c);
        System.assert(byRow.get(5).Validation_Message__c.contains('control accounts'), byRow.get(5).Validation_Message__c);
        System.assertEquals('Error', byRow.get(6).Validation_Status__c, 'A valid line of a journal with an invalid line is rejected too.');
        System.assert(byRow.get(6).Validation_Message__c.contains('journal J3 has invalid lines (row 5)'), byRow.get(6).Validation_Message__c);
        System.assert(byRow.get(7).Validation_Message__c.contains('no Open accounting period'), byRow.get(7).Validation_Message__c);
        Journal_Entry__c journal = [SELECT Status__c, Entry_Type__c, Accounting_Date__c, Description__c,
            (SELECT Debit_Base__c, Credit_Base__c FROM Journal_Entry_Line_Journal_Entry__r) FROM Journal_Entry__c WHERE Id = :byRow.get(1).Committed_Record_Id__c
            WITH SYSTEM_MODE];
        System.assertEquals('Draft', journal.Status__c, 'Imported journals wait in Draft for normal posting controls.');
        System.assertEquals('Manual', journal.Entry_Type__c, 'Journal Entries import as Manual journals.');
        System.assertEquals('January cash sale', journal.Description__c, 'Description from the file.');
        System.assertEquals(2, journal.Journal_Entry_Line_Journal_Entry__r.size(), 'Two lines.');
        System.assertEquals('Part Failed', committed.status, 'Invalid journals are left out.');
    }

    @IsTest
    static void rejectsUnsupportedOrMalformedFilesAndUsersWithoutAGrant() {
        List<String> messages = new List<String>();
        Boolean outsiderDenied = false;
        Database.SaveResult directRow;
        Id openingJob;
        SABImportService.ActionResult opening;
        SABTestGovernor.startTest();
        System.runAs(SABImportTestFixture.user(SABImportTestFixture.IMPORTER)) {
            Id companyId = SABImportTestFixture.companyId();
            List<List<String>> bad = new List<List<String>>{new List<String>{'Employees', 'name\nAcme\n'},
                new List<String>{'Chart of Accounts', 'account_code,name\n9000,Missing type\n'}, new List<String>{'Chart of Accounts', 'account_code,name,account_type\n'}};
            for (List<String> b : bad) {
                try {
                    SABImportService.stage(companyId, b[0], b[1]);
                } catch (SABImportService.ImportException ex) {
                    messages.add(ex.getMessage());
                }
            }
            openingJob = SABImportService.stage(companyId, 'Opening Balances',
                'journal_key,accounting_date,account_code,debit,credit\nOB,2026-01-01,1100,500,0\nOB,2026-01-01,4000,0,500\n').importJobId;
            try {
                SABImportService.commitImport(openingJob, 'I20-TOO-EARLY');
            } catch (SABImportService.ImportException ex) {
                messages.add(ex.getMessage());
            }
            SABImportService.validate(openingJob);
            opening = SABImportService.commitImport(openingJob, 'I20-OPENING');
            directRow = Database.insert(new Import_Row__c(Import_Job__c = openingJob, Row_Number__c = 99, Validation_Status__c = 'Valid'), false,
                AccessLevel.SYSTEM_MODE);
        }
        System.runAs(SABImportTestFixture.user(SABImportTestFixture.OUTSIDER)) {
            try {
                SABImportService.stage(SABImportTestFixture.companyId(), 'Chart of Accounts', 'account_code,name,account_type\n7000,Other,Expense\n');
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                outsiderDenied = true;
            }
        }
        SABTestGovernor.stopTest();
        List<String> fragments = new List<String>{'Supported import types', 'Missing required column: account_type', 'at least one data row',
            'Validate the import before committing'};
        System.assertEquals(fragments.size(), messages.size(), 'Every invalid request was refused: ' + messages);
        for (Integer i = 0; i < fragments.size(); i++) {
            System.assert(messages[i].contains(fragments[i]), 'Expected "' + fragments[i] + '" but got: ' + messages[i]);
        }
        System.assertEquals('Committed', opening.status, 'Opening balances commit.');
        System.assertEquals('Opening', [SELECT Entry_Type__c FROM Journal_Entry__c WHERE Description__c = 'Imported journal OB' WITH SYSTEM_MODE].Entry_Type__c,
            'Opening Balances import as Opening journals.');
        System.assertEquals(false, directRow.isSuccess(), 'Import rows are system records.');
        System.assertEquals(true, outsiderDenied, 'Users without a company grant cannot import.');
        System.assertEquals(Date.newInstance(2026, 1, 15), SABImportService.parseDate('2026-01-15'), 'ISO dates parse.');
        System.assertEquals(null, SABImportService.parseDate('15/01/2026'), 'Other formats are refused.');
        System.assertEquals(null, SABImportService.parseAmount('ten'), 'Non-numeric amounts are refused.');
    }

    @IsTest
    static void customersAndSuppliersImportAsAccountingProfiles() {
        String customers = 'name,tax_number,credit_limit\nGreenfield Produce,53 004,20000\nGreenfield Produce,,\nCoastal Foods,,-5\nPacific Grocers,,1000\n';
        String suppliers = 'name\nFuel Co\n';
        SABImportService.ActionResult committed;
        SABImportService.ActionResult supplierCheck;
        System.runAs(SABImportTestFixture.user(SABImportTestFixture.IMPORTER)) {
            SABTestGovernor.startTest();
            SABImportService.ActionResult staged = SABImportService.stage(SABImportTestFixture.companyId(), 'Customers', customers);
            SABImportService.validate(staged.importJobId);
            committed = SABImportService.commitImport(staged.importJobId, 'I20-CUST-COMMIT');
            SABImportService.ActionResult sup = SABImportService.stage(SABImportTestFixture.companyId(), 'Suppliers', suppliers);
            supplierCheck = SABImportService.validate(sup.importJobId);
            SABTestGovernor.stopTest();
        }
        System.assertEquals('Part Failed', committed.status, 'Duplicates and bad limits are rejected.');
        System.assertEquals(1, committed.committedCount, 'One customer committed.');
        Map<Decimal, Import_Row__c> byRow = rows(committed.importJobId);
        System.assertEquals('Error', byRow.get(1).Validation_Status__c, 'A name twice in the file is rejected.');
        System.assert(byRow.get(3).Validation_Message__c.contains('credit_limit'), byRow.get(3).Validation_Message__c);
        Party_Accounting_Profile__c profile = [SELECT Is_Customer__c, Credit_Limit__c, AR_Control_Account__r.Account_Code__c, Account__r.Name
            FROM Party_Accounting_Profile__c WHERE Id = :byRow.get(4).Committed_Record_Id__c WITH SYSTEM_MODE];
        System.assert(profile.Is_Customer__c, 'Customer profile.');
        System.assertEquals(1000, profile.Credit_Limit__c, 'Credit limit.');
        System.assertEquals('1200', profile.AR_Control_Account__r.Account_Code__c, 'AR control account.');
        System.assertEquals('Pacific Grocers', profile.Account__r.Name, 'Account name.');
        System.assertEquals(0, supplierCheck.validCount, 'No AP control account, so suppliers cannot be imported.');
    }

    @IsTest
    static void budgetLinesValidateAgainstPeriodsAndAccounts() {
        String csv = 'budget_name,fiscal_year,period_key,account_code,amount,department_code,project_code\n'
            + 'FY26 Plan,2026,I20-2026-01,4000,1500,,\n'
            + 'FY26 Plan,2026,I20-2099-01,4000,10,,\n'
            + 'FY26 Plan,26,I20-2026-01,9999,abc,NOPE,NOPROJ\n';
        SABImportService.ActionResult validated;
        System.runAs(SABImportTestFixture.user(SABImportTestFixture.IMPORTER)) {
            SABTestGovernor.startTest();
            SABImportService.ActionResult staged = SABImportService.stage(SABImportTestFixture.companyId(), 'Budgets', csv);
            validated = SABImportService.validate(staged.importJobId);
            SABTestGovernor.stopTest();
        }
        System.assertEquals(1, validated.validCount, 'One valid budget line.');
        Map<Decimal, Import_Row__c> byRow = rows(validated.importJobId);
        System.assert(byRow.get(2).Validation_Message__c.contains('period_key'), byRow.get(2).Validation_Message__c);
        String third = byRow.get(3).Validation_Message__c;
        System.assert(third.contains('fiscal_year') && third.contains('account_code') && third.contains('amount') && third.contains('department_code')
            && third.contains('project_code'), third);
        System.assertEquals(2026, SABImportService.parseYear('2026'), 'Year parsing.');
        System.assertEquals(null, SABImportService.parseYear('26'), 'Two digits rejected.');
    }
}