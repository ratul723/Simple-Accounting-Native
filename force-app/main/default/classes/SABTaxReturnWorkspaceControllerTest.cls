@IsTest
private class SABTaxReturnWorkspaceControllerTest {
    private static final String TAX_USER = 'SAB G11 Tax User';
    private static final String READER = 'SAB G11 Reader';
    private static final String NO_VIEW = 'SAB G11 No View';
    private static final String NO_GRANT = 'SAB G11 No Grant';
    private static final Set<String> ACTION_SETS = new Set<String>{'SAB_Prepare_Tax_Return_Action', 'SAB_Review_Tax_Return_Action',
        'SAB_Submit_Tax_Return_Action', 'SAB_Record_Tax_Authority_Outcome_Action', 'SAB_Amend_Tax_Return_Action'};

    private static Map<String, User> users = new Map<String, User>();

    // ------------------------------------------------------------- fixtures

    private static User newUser(Id profileId, String lastName, String alias, String unique) {
        return new User(Username = alias + '.' + unique + '@example.invalid', Email = alias + '@example.invalid', LastName = lastName,
            Alias = alias, TimeZoneSidKey = 'Asia/Dhaka', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', ProfileId = profileId);
    }

    @TestSetup
    static void setupData() {
        User taxUserRecord;
        User readerUser;
        User noViewUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Id standardProfile = [SELECT Id FROM Profile WHERE UserType = 'Standard' ORDER BY Name LIMIT 1].Id;
            String unique = UserInfo.getOrganizationId() + '.' + String.valueOf(System.now().getTime());
            taxUserRecord = newUser(standardProfile, TAX_USER, 'g11tax', unique);
            readerUser = newUser(standardProfile, READER, 'g11rdr', unique);
            noViewUser = newUser(standardProfile, NO_VIEW, 'g11nov', unique);
            User noGrantUser = newUser(standardProfile, NO_GRANT, 'g11nog', unique);
            insert as system new List<User>{taxUserRecord, readerUser, noViewUser, noGrantUser};
            Set<String> names = new Set<String>(ACTION_SETS);
            names.addAll(new Set<String>{'SAB_Tax_Return_Workspace_User', 'SAB_View_Audit_Detail_Action'});
            Map<String, Id> sets = new Map<String, Id>();
            for (PermissionSet p : [SELECT Id, Name FROM PermissionSet WHERE Name IN :names WITH SYSTEM_MODE]) {
                sets.put(p.Name, p.Id);
            }
            System.assertEquals(names.size(), sets.size(), 'Deploy G6C/G6D action sets, G8F audit set and the G11 workspace set.');
            // Test-only audit field access, so the history panel's full path (actor and reason) is covered.
            PermissionSet auditFields = new PermissionSet(Name = 'SAB_G11_Test_Audit_Fields', Label = 'SAB G11 Test Audit Fields');
            insert as system auditFields;
            insert as system new ObjectPermissions(ParentId = auditFields.Id, SobjectType = 'Business_Action__c', PermissionsRead = true);
            insert as system new List<FieldPermissions>{
                new FieldPermissions(ParentId = auditFields.Id, SobjectType = 'Business_Action__c', Field = 'Business_Action__c.Actor__c',
                    PermissionsRead = true, PermissionsEdit = false),
                new FieldPermissions(ParentId = auditFields.Id, SobjectType = 'Business_Action__c', Field = 'Business_Action__c.Reason__c',
                    PermissionsRead = true, PermissionsEdit = false)};
            List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
            for (String name : names) {
                rows.add(new PermissionSetAssignment(AssigneeId = taxUserRecord.Id, PermissionSetId = sets.get(name)));
            }
            rows.add(new PermissionSetAssignment(AssigneeId = taxUserRecord.Id, PermissionSetId = auditFields.Id));
            rows.add(new PermissionSetAssignment(AssigneeId = readerUser.Id, PermissionSetId = sets.get('SAB_Tax_Return_Workspace_User')));
            rows.add(new PermissionSetAssignment(AssigneeId = noGrantUser.Id, PermissionSetId = sets.get('SAB_Tax_Return_Workspace_User')));
            for (String name : ACTION_SETS) {
                rows.add(new PermissionSetAssignment(AssigneeId = noViewUser.Id, PermissionSetId = sets.get(name)));
            }
            insert as system rows;
        }
        System.runAs(taxUserRecord) {
            Accounting_Company__c company = new Accounting_Company__c(Name__c = 'G11 Tax Company', Company_Key__c = 'G11',
                Country_Code__c = 'BD', Functional_Currency__c = 'BDT', Fiscal_Calendar_Type__c = 'Calendar',
                Fiscal_Year_Start_Month__c = 1, Setup_Status__c = 'Active', Is_Active__c = true);
            insert as system company;
            List<Company_User_Access__c> grants = new List<Company_User_Access__c>();
            Map<String, Id> grantees = new Map<String, Id>{'G11-TAX' => taxUserRecord.Id, 'G11-READER' => readerUser.Id, 'G11-NOVIEW' => noViewUser.Id};
            for (String key : grantees.keySet()) {
                grants.add(new Company_User_Access__c(Company__c = company.Id, User__c = grantees.get(key), Is_Active__c = true,
                    Effective_From__c = Date.today(), Grant_Key__c = key, Role__c = 'Finance Manager'));
            }
            insert as system grants;
            Tax_Registration__c registration = new Tax_Registration__c(Name = 'G11 BD VAT', Company__c = company.Id,
                Country_Pack_Version__c = 'GENERIC-1', Effective_From__c = Date.newInstance(2026, 1, 1), Filing_Frequency__c = 'Monthly',
                Is_Active__c = true, Jurisdiction__c = 'BD', Registration_Identifier__c = 'G11-BD-VAT');
            insert as system new List<Tax_Registration__c>{registration,
                new Tax_Registration__c(Name = 'G11 Old VAT', Company__c = company.Id, Country_Pack_Version__c = 'GENERIC-1',
                    Effective_From__c = Date.newInstance(2025, 1, 1), Is_Active__c = false, Jurisdiction__c = 'BD',
                    Registration_Identifier__c = 'G11-OLD')};
            preparedReturn(company.Id, registration.Id, Date.newInstance(2026, 9, 1), Date.newInstance(2026, 9, 30));
            preparedReturn(company.Id, registration.Id, Date.newInstance(2026, 8, 1), Date.newInstance(2026, 8, 31));
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    // Same shape as the G6D lifecycle fixture: a Prepared return with the five generic boxes and source hashes.
    private static void preparedReturn(Id companyId, Id registrationId, Date periodStart, Date periodEnd) {
        Tax_Return__c taxReturn = new Tax_Return__c(Company__c = companyId, Tax_Registration__c = registrationId,
            Period_Start__c = periodStart, Period_End__c = periodEnd, Country_Pack_Version__c = 'GENERIC-1', Return_Version__c = 1,
            Status__c = 'Prepared');
        insert as system taxReturn;
        Map<String, Decimal> boxes = new Map<String, Decimal>{'OUTPUT_TAXABLE_BASE' => 100, 'OUTPUT_TAX' => 15,
            'INPUT_TAXABLE_BASE' => 100, 'INPUT_TAX_RECOVERABLE' => 6, 'NET_TAX_DUE' => 9};
        List<Tax_Return_Line__c> lines = new List<Tax_Return_Line__c>();
        Integer i = 0;
        for (String box : boxes.keySet()) {
            lines.add(new Tax_Return_Line__c(Tax_Return__c = taxReturn.Id, Box_Key__c = box, Label__c = box,
                Calculated_Amount__c = boxes.get(box), Adjustment_Amount__c = 0, Final_Amount__c = boxes.get(box),
                Source_Inclusion_Hash__c = 'abcde'.substring(i, i + 1).repeat(64)));
            i++;
        }
        insert as system lines;
    }

    private static User fixtureUser(String lastName) {
        if (!users.containsKey(lastName)) {
            users.put(lastName, [SELECT Id FROM User WHERE LastName = :lastName AND Alias LIKE 'g11%' WITH SYSTEM_MODE LIMIT 1]);
        }
        return users.get(lastName);
    }

    private static Id companyId() {
        return [SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = 'G11' WITH SYSTEM_MODE].Id;
    }

    private static Id returnFor(Integer month) {
        Date periodStart = Date.newInstance(2026, month, 1);
        return [SELECT Id FROM Tax_Return__c WHERE Period_Start__c = :periodStart AND Company__r.Company_Key__c = 'G11'
            WITH SYSTEM_MODE ORDER BY Return_Version__c DESC LIMIT 1].Id;
    }

    // ---------------------------------------------------------------- tests

    @IsTest
    static void workspaceListsRegistrationsReturnsAndCapabilities() {
        Id companyId = companyId();
        SABTaxReturnWorkspaceController.WorkspaceDTO ws;
        SABTaxReturnWorkspaceController.WorkspaceDTO readerWs;
        SABTestGovernor.startTest();
        System.runAs(fixtureUser(TAX_USER)) {
            ws = SABTaxReturnWorkspaceController.getWorkspace(companyId);
        }
        System.runAs(fixtureUser(READER)) {
            readerWs = SABTaxReturnWorkspaceController.getWorkspace(companyId);
        }
        SABTestGovernor.stopTest();
        System.assertEquals('G11 Tax Company', ws.companyName, 'Company name is returned.');
        System.assertEquals(1, ws.registrations.size(), 'Only active registrations are offered.');
        System.assertEquals('Monthly', ws.registrations[0].filingFrequency, 'Filing frequency is returned.');
        System.assertEquals(2, ws.returns.size(), 'Both returns are listed.');
        System.assertEquals(Date.newInstance(2026, 9, 30), ws.returns[0].periodEnd, 'Latest period first.');
        System.assertEquals(9, ws.returns[0].netTaxDue, 'Net tax due comes from the NET_TAX_DUE box.');
        System.assertEquals(false, ws.returns[0].sourceLocked, 'Prepared returns are not locked.');
        Map<String, Integer> counts = new Map<String, Integer>();
        for (SABTaxReturnWorkspaceController.StateCount c : ws.stateCounts) {
            counts.put(c.state, c.count);
        }
        System.assertEquals(2, counts.get('Prepared'), 'Two Prepared returns.');
        System.assertEquals(0, counts.get('Submitted'), 'Every status is reported, including zero.');
        System.assertEquals(0, ws.openNetTaxDue, 'Nothing reviewed or submitted yet.');
        System.assert(ws.filingReferenceMaxLength > 0, 'Field limits come from describe.');
        System.assertEquals(true, ws.capabilities.prepare, 'Tax user can prepare.');
        System.assertEquals(true, ws.capabilities.amend, 'Tax user can amend.');
        System.assertEquals(false, readerWs.capabilities.prepare, 'Reader has no action permissions.');
        System.assertEquals(false, readerWs.capabilities.review, 'Reader cannot review.');
    }

    @IsTest
    static void preparesAndAdjustsThroughTheWorkspace() {
        Id augustId = returnFor(8);
        Id registrationId = [SELECT Id FROM Tax_Registration__c WHERE Registration_Identifier__c = 'G11-BD-VAT' WITH SYSTEM_MODE].Id;
        SABTaxReturnWorkspaceController.PrepareResultDTO prepared;
        SABTaxReturnWorkspaceController.LineDTO adjusted;
        System.runAs(fixtureUser(TAX_USER)) {
            SABTestGovernor.startTest();
            prepared = SABTaxReturnWorkspaceController.prepareReturn(registrationId, Date.newInstance(2026, 10, 1),
                Date.newInstance(2026, 10, 31));
            adjusted = SABTaxReturnWorkspaceController.setAdjustment(augustId, 'OUTPUT_TAX', 2);
            SABTestGovernor.stopTest();
        }
        System.assertNotEquals(null, prepared.taxReturnId, 'October return is prepared.');
        System.assertEquals(false, prepared.rebuiltExistingReturn, 'A new return, not a rebuild.');
        System.assertEquals(0, prepared.outputSourceCount, 'No posted taxed documents in October.');
        System.assertEquals(2, adjusted.adjustmentAmount, 'Adjustment is saved.');
        System.assertEquals(17, adjusted.finalAmount, 'Final amount includes the adjustment.');
        String denied;
        System.runAs(fixtureUser(READER)) {
            try {
                SABTaxReturnWorkspaceController.setAdjustment(augustId, 'OUTPUT_TAX', 5);
            } catch (SABPermissionService.PermissionDeniedException ex) {
                denied = ex.getMessage();
            }
        }
        System.assert(denied != null && denied.contains('permission'), 'Readers cannot adjust: ' + denied);
    }

    @IsTest
    static void lifecycleThroughAmendmentShowsVersionsAndHistory() {
        Id septemberId = returnFor(9);
        SABTaxReturnLifecycleService.LifecycleResult amendment;
        SABTaxReturnWorkspaceController.ReturnDetailDTO original;
        SABTaxReturnWorkspaceController.ReturnDetailDTO amended;
        System.runAs(fixtureUser(TAX_USER)) {
            SABTestGovernor.startTest();
            SABTaxReturnLifecycleService.reviewReturn(septemberId, 'G11-REVIEW', 'Checked against ledger');
            SABTaxReturnLifecycleService.submitReturn(septemberId, 'NBR-2026-09', 'G11-SUBMIT', null);
            SABTaxReturnLifecycleService.recordAuthorityOutcome(septemberId, 'Rejected', 'ACK-2026-09', 'G11-OUTCOME', 'Box mismatch');
            amendment = SABTaxReturnLifecycleService.createAmendment(septemberId, 'G11-AMEND', 'Correct output tax');
            SABTestGovernor.stopTest();
            original = SABTaxReturnWorkspaceController.getReturnDetail(septemberId);
            amended = SABTaxReturnWorkspaceController.getReturnDetail(amendment.amendmentTaxReturnId);
        }
        System.assertEquals('Amended', original.taxReturn.status, 'Original becomes Amended.');
        System.assertEquals('NBR-2026-09', original.taxReturn.filingReference, 'Filing reference is shown.');
        System.assertEquals('ACK-2026-09', original.taxReturn.acknowledgementReference, 'Acknowledgement is shown.');
        System.assertEquals(true, original.taxReturn.sourceLocked, 'Review locked the source hash.');
        System.assertEquals(5, original.lines.size(), 'All five boxes are shown.');
        System.assertEquals(2, amended.versions.size(), 'Both versions for the period are listed.');
        System.assertEquals(2, amended.taxReturn.returnVersion, 'Amendment is version 2.');
        System.assertEquals(septemberId, amended.taxReturn.amendsTaxReturnId, 'Amendment links the original.');
        System.assert(original.history.size() >= 4, 'Review, submit, outcome and amendment are audited: ' + original.history.size());
        Boolean sawReason = false;
        for (SABTaxReturnWorkspaceController.HistoryDTO h : original.history) {
            sawReason = sawReason || h.reason == 'Checked against ledger';
            System.assertNotEquals(null, h.actorName, 'Actor is shown when readable.');
        }
        System.assert(sawReason, 'Reasons are shown when readable.');
    }

    @IsTest
    static void enforcesPermissionCompanyAccessAndAuditVisibility() {
        Id companyId = companyId();
        Id septemberId = returnFor(9);
        List<String> refused = new List<String>();
        SABTaxReturnWorkspaceController.ReturnDetailDTO readerDetail;
        SABTestGovernor.startTest();
        System.runAs(fixtureUser(NO_VIEW)) {
            try {
                SABTaxReturnWorkspaceController.getWorkspace(companyId);
            } catch (SABPermissionService.PermissionDeniedException ex) {
                refused.add('workspace-permission');
            }
            try {
                SABTaxReturnWorkspaceController.getReturnDetail(septemberId);
            } catch (SABPermissionService.PermissionDeniedException ex) {
                refused.add('detail-permission');
            }
        }
        System.runAs(fixtureUser(NO_GRANT)) {
            try {
                SABTaxReturnWorkspaceController.getWorkspace(companyId);
            } catch (SABCompanyAccessService.CompanyAccessDeniedException ex) {
                refused.add('workspace-company');
            }
        }
        System.runAs(fixtureUser(READER)) {
            readerDetail = SABTaxReturnWorkspaceController.getReturnDetail(septemberId);
            for (Integer i = 0; i < 2; i++) {
                try {
                    if (i == 0) {
                        SABTaxReturnWorkspaceController.getWorkspace(null);
                    } else {
                        SABTaxReturnWorkspaceController.getReturnDetail(null);
                    }
                } catch (SABTaxReturnWorkspaceController.TaxReturnWorkspaceException ex) {
                    refused.add('required-' + i);
                }
            }
        }
        SABTestGovernor.stopTest();
        System.assertEquals(new List<String>{'workspace-permission', 'detail-permission', 'workspace-company', 'required-0',
            'required-1'}, refused, 'Unauthorized and incomplete requests are refused.');
        System.assertEquals(5, readerDetail.lines.size(), 'Readers see the return boxes.');
        System.assertEquals(0, readerDetail.history.size(), 'Audit history needs audit detail permission.');
        SABTaxReturnWorkspaceController.Capabilities caps = SABTaxReturnWorkspaceController.capabilities();
        System.assertNotEquals(null, caps.viewAudit, 'Every capability flag is populated.');
    }
}
