@IsTest
private class SABEmployeeCompensationServiceTest {
    private static Accounting_Company__c makeCompany(String keyValue) {
        Accounting_Company__c company = new Accounting_Company__c(
            Name__c = 'G10A Company ' + keyValue,
            Company_Key__c = keyValue,
            Country_Code__c = 'BD',
            Functional_Currency__c = 'BDT',
            Fiscal_Calendar_Type__c = 'Calendar',
            Fiscal_Year_Start_Month__c = 1,
            Setup_Status__c = 'Active',
            Is_Active__c = true
        );
        insert company;
        return company;
    }

    private static User makeUser(String token, String lastName) {
        Profile p = [
            SELECT Id
            FROM Profile
            WHERE UserType = 'Standard'
            ORDER BY Name
            LIMIT 1
        ];

        User u = new User(
            Alias = token.substring(0, 8),
            Email = token + '@example.test',
            EmailEncodingKey = 'UTF-8',
            LastName = lastName,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'Asia/Dhaka',
            Username = token + '@example.test'
        );
        // Setup-object DML needs a runAs boundary in standalone Apex tests.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }
        return u;
    }

    private static void assignPermissionSet(User user, String permissionSetName) {
        PermissionSet ps = [
            SELECT Id
            FROM PermissionSet
            WHERE Name = :permissionSetName
            LIMIT 1
        ];
        // Keep permission assignment separate from Accounting Company fixtures.
        // All test scenarios use this helper, including coverageActor.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new PermissionSetAssignment(
                AssigneeId = user.Id,
                PermissionSetId = ps.Id
            );
        }
    }

    private static void grantCompany(
        Id companyId,
        Id userId,
        String keyValue
    ) {
        insert new Company_User_Access__c(
            Company__c = companyId,
            User__c = userId,
            Effective_From__c = Date.today().addDays(-1),
            Effective_To__c = null,
            Grant_Key__c = keyValue,
            Is_Active__c = true,
            Role__c = 'HR'
        );
    }

    private static Employee__c employeeRecord(
        String reference,
        String status
    ) {
        return new Employee__c(
            Employee_Reference__c = reference,
            Status__c = status
        );
    }

    @IsTest
    static void createsEmployeeAndEmploymentAndRejectsOverlap() {
        Accounting_Company__c company = makeCompany('G10A-01');
        User actor = makeUser(
            'g10aactor' + DateTime.now().getTime(),
            'G10A Actor'
        );
        assignPermissionSet(actor, 'SAB_Employee_Compensation_User');
        assignPermissionSet(actor, 'SAB_Manage_Employee_Compensation_Action');
        grantCompany(company.Id, actor.Id, 'G10A-GRANT-01');

        System.runAs(actor) {
            SABEmployeeCompensationService.EmployeeRequest employeeRequest =
                new SABEmployeeCompensationService.EmployeeRequest();
            employeeRequest.employeeReference = 'EMP-G10A-001';
            employeeRequest.status = 'Active';

            Test.startTest();
            Id employeeId = SABEmployeeCompensationService.createEmployee(employeeRequest);
            Test.stopTest();

            System.assertNotEquals(null, employeeId);

            SABEmployeeCompensationService.EmploymentRequest employmentRequest =
                new SABEmployeeCompensationService.EmploymentRequest();
            employmentRequest.employeeId = employeeId;
            employmentRequest.companyId = company.Id;
            employmentRequest.startDate = Date.newInstance(2026, 1, 1);
            employmentRequest.endDate = Date.newInstance(2026, 6, 30);
            employmentRequest.employmentStatus = 'Ended';

            Id employmentId = SABEmployeeCompensationService.createOrUpdateEmployment(
                employmentRequest
            );
            System.assertNotEquals(null, employmentId);

            SABEmployeeCompensationService.EmploymentRequest overlap =
                new SABEmployeeCompensationService.EmploymentRequest();
            overlap.employeeId = employeeId;
            overlap.companyId = company.Id;
            overlap.startDate = Date.newInstance(2026, 6, 1);
            overlap.endDate = Date.newInstance(2026, 12, 31);
            overlap.employmentStatus = 'Active';

            Boolean thrown = false;
            try {
                SABEmployeeCompensationService.createOrUpdateEmployment(overlap);
            } catch (SABEmployeeCompensationService.EmployeeCompensationException ex) {
                thrown = true;
            }
            System.assertEquals(true, thrown);
        }
    }

    @IsTest
    static void createsApprovesAndExpiresCompensationSnapshot() {
        Accounting_Company__c company = makeCompany('G10A-02');
        User actor = makeUser(
            'g10aapprove' + DateTime.now().getTime(),
            'G10A Approver'
        );
        assignPermissionSet(actor, 'SAB_Employee_Compensation_User');
        assignPermissionSet(actor, 'SAB_Manage_Employee_Compensation_Action');
        assignPermissionSet(actor, 'SAB_Approve_Employee_Compensation_Action');
        grantCompany(company.Id, actor.Id, 'G10A-GRANT-02');

        System.runAs(actor) {
            Employee__c employee = employeeRecord('EMP-G10A-002', 'Active');
            insert employee;

            Employment__c employment = new Employment__c(
                Employee__c = employee.Id,
                Company__c = company.Id,
                Employment_Status__c = 'Active',
                Start_Date__c = Date.newInstance(2026, 1, 1)
            );
            insert employment;

            Pay_Component__c salary = new Pay_Component__c(
                Name = 'Basic Salary',
                Company__c = company.Id,
                Component_Key__c = 'BASIC-SALARY-G10A-02',
                Category__c = 'Basic Salary',
                Is_Active__c = true
            );
            insert salary;

            SABEmployeeCompensationService.AssignmentRequest request =
                new SABEmployeeCompensationService.AssignmentRequest();
            request.employmentId = employment.Id;
            request.payComponentId = salary.Id;
            request.amount = 50000;
            request.currencyCode = 'BDT';
            request.effectiveFrom = Date.newInstance(2026, 1, 1);

            Id assignmentId = SABEmployeeCompensationService.createOrUpdateAssignment(request);
            System.assertEquals(
                'Draft',
                [SELECT Status__c FROM Employee_Pay_Component__c WHERE Id = :assignmentId].Status__c
            );

            SABEmployeeCompensationService.approveAssignment(assignmentId);
            Employee_Pay_Component__c approved = [
                SELECT Status__c, Amount__c, Effective_From__c
                FROM Employee_Pay_Component__c
                WHERE Id = :assignmentId
            ];
            System.assertEquals('Approved', approved.Status__c);
            System.assertEquals(50000, approved.Amount__c);

            SABEmployeeCompensationService.expireAssignment(
                assignmentId,
                Date.newInstance(2026, 12, 31)
            );

            approved = [
                SELECT Status__c, Effective_To__c
                FROM Employee_Pay_Component__c
                WHERE Id = :assignmentId
            ];
            System.assertEquals('Expired', approved.Status__c);
            System.assertEquals(Date.newInstance(2026, 12, 31), approved.Effective_To__c);
        }
    }

    @IsTest
    static void blocksCrossCompanyCompensationAndSupportsCurrentSnapshotQuery() {
        Accounting_Company__c companyA = makeCompany('G10A-03A');
        Accounting_Company__c companyB = makeCompany('G10A-03B');
        User actor = makeUser(
            'g10acompany' + DateTime.now().getTime(),
            'G10A Company Boundary'
        );
        assignPermissionSet(actor, 'SAB_Employee_Compensation_User');
        assignPermissionSet(actor, 'SAB_Manage_Employee_Compensation_Action');
        assignPermissionSet(actor, 'SAB_Approve_Employee_Compensation_Action');
        grantCompany(companyA.Id, actor.Id, 'G10A-GRANT-03');

        System.runAs(actor) {
            Employee__c employee = employeeRecord('EMP-G10A-003', 'Active');
            insert employee;

            Employment__c employment = new Employment__c(
                Employee__c = employee.Id,
                Company__c = companyA.Id,
                Employment_Status__c = 'Active',
                Start_Date__c = Date.newInstance(2026, 1, 1)
            );
            insert employment;

            Pay_Component__c foreignComponent = new Pay_Component__c(
                Name = 'Foreign Salary',
                Company__c = companyB.Id,
                Component_Key__c = 'FOREIGN-G10A-03',
                Category__c = 'Basic Salary',
                Is_Active__c = true
            );
            insert foreignComponent;

            SABEmployeeCompensationService.AssignmentRequest request =
                new SABEmployeeCompensationService.AssignmentRequest();
            request.employmentId = employment.Id;
            request.payComponentId = foreignComponent.Id;
            request.amount = 1000;
            request.currencyCode = 'BDT';
            request.effectiveFrom = Date.today();

            Boolean thrown = false;
            try {
                SABEmployeeCompensationService.createOrUpdateAssignment(request);
            } catch (SABEmployeeCompensationService.EmployeeCompensationException ex) {
                thrown = true;
            }
            System.assertEquals(true, thrown);

            Pay_Component__c localComponent = new Pay_Component__c(
                Name = 'Local Salary',
                Company__c = companyA.Id,
                Component_Key__c = 'LOCAL-G10A-03',
                Category__c = 'Basic Salary',
                Is_Active__c = true
            );
            insert localComponent;

            request.payComponentId = localComponent.Id;
            Id assignmentId = SABEmployeeCompensationService.createOrUpdateAssignment(request);
            SABEmployeeCompensationService.approveAssignment(assignmentId);

            List<SABEmployeeCompensationService.CompensationDTO> rows =
                SABEmployeeCompensationService.getCurrentCompensation(
                    companyA.Id,
                    Date.today()
                );
            System.assertEquals(1, rows.size());
            System.assertEquals(1000, rows[0].amount);
        }
    }

    @IsTest
    static void benefitAwardLifecycleRequiresApprovalAndAllowsCancellationBeforeConsumption() {
        Accounting_Company__c company = makeCompany('G10A-04');
        User actor = makeUser(
            'g10aaward' + DateTime.now().getTime(),
            'G10A Award'
        );
        assignPermissionSet(actor, 'SAB_Employee_Compensation_User');
        assignPermissionSet(actor, 'SAB_Manage_Employee_Compensation_Action');
        assignPermissionSet(actor, 'SAB_Approve_Employee_Compensation_Action');
        grantCompany(company.Id, actor.Id, 'G10A-GRANT-04');

        System.runAs(actor) {
            Employee__c employee = employeeRecord('EMP-G10A-004', 'Active');
            insert employee;
            Employment__c employment = new Employment__c(
                Employee__c = employee.Id,
                Company__c = company.Id,
                Employment_Status__c = 'Active',
                Start_Date__c = Date.newInstance(2026, 1, 1)
            );
            insert employment;
            Pay_Component__c incentive = new Pay_Component__c(
                Name = 'Incentive',
                Company__c = company.Id,
                Component_Key__c = 'INCENTIVE-G10A-04',
                Category__c = 'Incentive',
                Is_Active__c = true
            );
            insert incentive;

            SABEmployeeCompensationService.BenefitAwardRequest request =
                new SABEmployeeCompensationService.BenefitAwardRequest();
            request.employmentId = employment.Id;
            request.payComponentId = incentive.Id;
            request.awardKey = 'AWARD-G10A-04';
            request.amount = 10000;
            request.currencyCode = 'BDT';
            request.servicePeriodStart = Date.newInstance(2026, 9, 1);
            request.servicePeriodEnd = Date.newInstance(2026, 9, 30);
            request.reason = 'Approved performance incentive';

            Id awardId = SABEmployeeCompensationService.createBenefitAward(request);
            System.assertEquals(
                'Proposed',
                [SELECT Status__c FROM Benefit_Award__c WHERE Id = :awardId].Status__c
            );

            SABEmployeeCompensationService.approveBenefitAward(awardId);
            Benefit_Award__c approved = [
                SELECT Status__c, Approved_By__c, Approved_At__c
                FROM Benefit_Award__c
                WHERE Id = :awardId
            ];
            System.assertEquals('Approved', approved.Status__c);
            System.assertEquals(actor.Id, approved.Approved_By__c);
            System.assertNotEquals(null, approved.Approved_At__c);

            // Consumption is deliberately reserved for the later payroll stage.
            // Until a Payroll_Run__c claims it, cancellation remains permitted.
            SABEmployeeCompensationService.cancelBenefitAward(awardId);
            System.assertEquals(
                'Cancelled',
                [SELECT Status__c FROM Benefit_Award__c WHERE Id = :awardId].Status__c
            );
        }
    }
    @IsTest
    static void companyUsersReceiveManualSharesForFoundationRecords() {
        Accounting_Company__c company = makeCompany('G10A-05');
        User actor = makeUser(
            'g10ashareactor' + DateTime.now().getTime(),
            'G10A Share Actor'
        );
        User target = makeUser(
            'g10asharetgt' + DateTime.now().getTime(),
            'G10A Share Target'
        );

        assignPermissionSet(actor, 'SAB_Employee_Compensation_User');
        assignPermissionSet(actor, 'SAB_Manage_Employee_Compensation_Action');
        grantCompany(company.Id, actor.Id, 'G10A-GRANT-05-A');
        grantCompany(company.Id, target.Id, 'G10A-GRANT-05-B');

        System.runAs(actor) {
            Employee__c employee = employeeRecord('EMP-G10A-005', 'Active');
            insert employee;

            Employment__c employment = new Employment__c(
                Employee__c = employee.Id,
                Company__c = company.Id,
                Employment_Status__c = 'Active',
                Start_Date__c = Date.newInstance(2026, 1, 1)
            );
            insert employment;

            Pay_Component__c component = new Pay_Component__c(
                Name = 'Food Allowance',
                Company__c = company.Id,
                Component_Key__c = 'FOOD-G10A-05',
                Category__c = 'Food Allowance',
                Is_Active__c = true
            );
            insert component;

            Employee_Pay_Component__c assignment = new Employee_Pay_Component__c(
                Employment__c = employment.Id,
                Pay_Component__c = component.Id,
                Amount__c = 3000,
                Currency__c = 'BDT',
                Effective_From__c = Date.newInstance(2026, 1, 1),
                Status__c = 'Draft'
            );
            insert assignment;

            Benefit_Award__c award = new Benefit_Award__c(
                Employment__c = employment.Id,
                Pay_Component__c = component.Id,
                Award_Key__c = 'AWARD-G10A-05',
                Amount__c = 3000,
                Currency__c = 'BDT',
                Service_Period_Start__c = Date.newInstance(2026, 1, 1),
                Status__c = 'Proposed'
            );
            insert award;

            System.assertEquals(
                1,
                [SELECT COUNT() FROM Employment__Share
                 WHERE ParentId = :employment.Id
                 AND UserOrGroupId = :target.Id
                 AND RowCause = 'Manual'],
                'Employment must have a Manual share for the authorized company user.'
            );
            System.assertEquals(
                1,
                [SELECT COUNT() FROM Pay_Component__Share
                 WHERE ParentId = :component.Id
                 AND UserOrGroupId = :target.Id
                 AND RowCause = 'Manual'],
                'Pay Component must have a Manual share for the authorized company user.'
            );
            System.assertEquals(
                1,
                [SELECT COUNT() FROM Employee_Pay_Component__Share
                 WHERE ParentId = :assignment.Id
                 AND UserOrGroupId = :target.Id
                 AND RowCause = 'Manual'],
                'Compensation assignment must have a Manual share for the authorized company user.'
            );
            System.assertEquals(
                1,
                [SELECT COUNT() FROM Benefit_Award__Share
                 WHERE ParentId = :award.Id
                 AND UserOrGroupId = :target.Id
                 AND RowCause = 'Manual'],
                'Benefit Award must have a Manual share for the authorized company user.'
            );
            System.assertEquals(
                1,
                [SELECT COUNT() FROM Employee__Share
                 WHERE ParentId = :employee.Id
                 AND UserOrGroupId = :target.Id
                 AND RowCause = 'Manual'],
                'Employee sharing must continue to work alongside Employment sharing.'
            );
        }
    }


    @IsTest
    static void employmentSharesSurviveUpdateAndEnding() {
        Accounting_Company__c company = makeCompany('G10A-06');
        User actor = makeUser('g10alifeactor' + DateTime.now().getTime(), 'G10A Lifecycle Actor');
        User target = makeUser('g10alifetgt' + DateTime.now().getTime(), 'G10A Lifecycle Target');
        assignPermissionSet(actor, 'SAB_Employee_Compensation_User');
        assignPermissionSet(actor, 'SAB_Manage_Employee_Compensation_Action');
        grantCompany(company.Id, actor.Id, 'G10A-GRANT-06-A');
        grantCompany(company.Id, target.Id, 'G10A-GRANT-06-B');

        System.runAs(actor) {
            Employee__c employee = employeeRecord('EMP-G10A-006', 'Active');
            insert employee;
            Employment__c employment = new Employment__c(
                Employee__c = employee.Id,
                Company__c = company.Id,
                Employment_Status__c = 'Active',
                Start_Date__c = Date.newInstance(2026, 1, 1)
            );
            Test.startTest();
            insert employment;
            employment.Start_Date__c = Date.newInstance(2026, 1, 2);
            update employment;
            System.assertEquals(1, [SELECT COUNT() FROM Employment__Share
                WHERE ParentId = :employment.Id AND UserOrGroupId = :target.Id
                AND RowCause = 'Manual'], 'An unrelated edit must preserve the Employment share.');
            employment.Employment_Status__c = 'Ended';
            employment.End_Date__c = Date.newInstance(2026, 12, 31);
            update employment;
            Test.stopTest();
            System.assertEquals(1, [SELECT COUNT() FROM Employment__Share
                WHERE ParentId = :employment.Id AND UserOrGroupId = :target.Id
                AND RowCause = 'Manual'], 'Ending employment must preserve exactly one historical Employment share.');
        }
    }


    private static User coverageActor(String token) {
        User actor = makeUser(token + DateTime.now().getTime(), 'G10A Coverage');
        assignPermissionSet(actor, 'SAB_Employee_Compensation_User');
        assignPermissionSet(actor, 'SAB_Manage_Employee_Compensation_Action');
        assignPermissionSet(actor, 'SAB_Approve_Employee_Compensation_Action');
        return actor;
    }

    private static void rejectsRequest(String kind, String payload, String expected) {
        Boolean rejected = false;
        try {
            if (kind == 'Employee') {
                SABEmployeeCompensationService.createEmployee((SABEmployeeCompensationService.EmployeeRequest)
                    JSON.deserialize(payload, SABEmployeeCompensationService.EmployeeRequest.class));
            } else if (kind == 'Employment') {
                SABEmployeeCompensationService.createOrUpdateEmployment((SABEmployeeCompensationService.EmploymentRequest)
                    JSON.deserialize(payload, SABEmployeeCompensationService.EmploymentRequest.class));
            } else if (kind == 'Component') {
                SABEmployeeCompensationService.createOrUpdatePayComponent((SABEmployeeCompensationService.PayComponentRequest)
                    JSON.deserialize(payload, SABEmployeeCompensationService.PayComponentRequest.class));
            } else if (kind == 'Assignment') {
                SABEmployeeCompensationService.createOrUpdateAssignment((SABEmployeeCompensationService.AssignmentRequest)
                    JSON.deserialize(payload, SABEmployeeCompensationService.AssignmentRequest.class));
            } else if (kind == 'Award') {
                SABEmployeeCompensationService.createBenefitAward((SABEmployeeCompensationService.BenefitAwardRequest)
                    JSON.deserialize(payload, SABEmployeeCompensationService.BenefitAwardRequest.class));
            } else {
                System.assert(false, 'Unknown validation case: ' + kind);
            }
        } catch (SABEmployeeCompensationService.EmployeeCompensationException ex) {
            rejected = true;
            System.assertEquals(expected, ex.getMessage(), kind + ' must report the intended validation error.');
        }
        System.assert(rejected, kind + ' request should have failed: ' + payload);
    }

    @IsTest
    static void serviceUpdatesEmploymentAndFiltersEndedRecords() {
        Accounting_Company__c company = makeCompany('C07');
        User actor = coverageActor('g10aempupdate');
        grantCompany(company.Id, actor.Id, 'G10A-C07');
        System.runAs(actor) {
            Employee__c employee = employeeRecord('EMP-C07', 'Active');
            insert employee;
            Employment__c employment = new Employment__c(Employee__c=employee.Id,
                Company__c=company.Id, Employment_Status__c='Active', Start_Date__c=Date.today().addDays(-30));
            insert employment;
            SABEmployeeCompensationService.EmploymentRequest r = new SABEmployeeCompensationService.EmploymentRequest();
            r.employmentId=employment.Id; r.employeeId=employee.Id; r.companyId=company.Id;
            r.startDate=employment.Start_Date__c; r.endDate=Date.today(); r.employmentStatus='Ended';
            Test.startTest();
            System.assertEquals(1, SABEmployeeCompensationService.getEmployments(company.Id, false).size());
            System.assertEquals(employment.Id, SABEmployeeCompensationService.createOrUpdateEmployment(r));
            List<SABEmployeeCompensationService.EmploymentDTO> allRows = SABEmployeeCompensationService.getEmployments(company.Id, true);
            System.assertEquals(1, allRows.size());
            System.assertEquals('Ended', allRows[0].employmentStatus);
            System.assertEquals(employee.Id, allRows[0].employeeId);
            System.assertEquals('EMP-C07', allRows[0].employeeReference);
            System.assertEquals(0, SABEmployeeCompensationService.getEmployments(company.Id, false).size());
            Test.stopTest();
        }
    }

    @IsTest
    static void serviceCreatesAndUpdatesPayComponents() {
        Accounting_Company__c company = makeCompany('C08');
        User actor = coverageActor('g10acomponent');
        User target = makeUser('g10acomptgt'+DateTime.now().getTime(), 'Component reader');
        grantCompany(company.Id, actor.Id, 'G10A-C08-A');
        grantCompany(company.Id, target.Id, 'G10A-C08-B');
        System.runAs(actor) {
            SABEmployeeCompensationService.PayComponentRequest r = new SABEmployeeCompensationService.PayComponentRequest();
            r.name='  Base Pay  '; r.componentKey='G10A-C08'; r.companyId=company.Id; r.category='Basic Salary';
            Test.startTest();
            Id componentId=SABEmployeeCompensationService.createOrUpdatePayComponent(r);
            r.payComponentId=componentId; r.name='Updated Base Pay'; r.countryRuleKey=' BD '; r.isActive=false;
            System.assertEquals(componentId, SABEmployeeCompensationService.createOrUpdatePayComponent(r));
            Test.stopTest();
            Pay_Component__c row=[SELECT Name, Country_Rule_Key__c, Is_Active__c FROM Pay_Component__c WHERE Id=:componentId];
            System.assertEquals('Updated Base Pay',row.Name);
            System.assertEquals('BD',row.Country_Rule_Key__c);
            System.assertEquals(false,row.Is_Active__c);
            System.assertEquals(1,[SELECT COUNT() FROM Pay_Component__Share WHERE ParentId=:componentId
                AND UserOrGroupId=:target.Id AND RowCause='Manual'], 'Component update must preserve company sharing.');
        }
    }

    @IsTest
    static void serviceEditsDraftAssignmentAndReturnsFormulaSnapshot() {
        Accounting_Company__c company=makeCompany('C09');
        User actor=coverageActor('g10adraftedit');
        grantCompany(company.Id,actor.Id,'G10A-C09');
        System.runAs(actor) {
            Employee__c employee=employeeRecord('EMP-C09','Active'); insert employee;
            Employment__c employment=new Employment__c(Employee__c=employee.Id,Company__c=company.Id,
                Employment_Status__c='Active',Start_Date__c=Date.today().addDays(-30)); insert employment;
            Pay_Component__c component=new Pay_Component__c(Name='Base',Company__c=company.Id,
                Component_Key__c='G10A-C09',Category__c='Basic Salary',Is_Active__c=true); insert component;
            Employee_Pay_Component__c assignment=new Employee_Pay_Component__c(Employment__c=employment.Id,
                Pay_Component__c=component.Id,Amount__c=100,Currency__c='BDT',Effective_From__c=Date.today().addDays(-1),Status__c='Draft');
            insert assignment;
            SABEmployeeCompensationService.AssignmentRequest r=new SABEmployeeCompensationService.AssignmentRequest();
            r.assignmentId=assignment.Id; r.employmentId=employment.Id; r.payComponentId=component.Id;
            r.amount=200; r.currencyCode=' bdt '; r.effectiveFrom=assignment.Effective_From__c;
            r.formulaParameterJson='{"rate":200}';
            Test.startTest();
            System.assertEquals(assignment.Id,SABEmployeeCompensationService.createOrUpdateAssignment(r));
            SABEmployeeCompensationService.approveAssignment(assignment.Id);
            List<SABEmployeeCompensationService.CompensationDTO> rows=SABEmployeeCompensationService.getCurrentCompensation(company.Id,null);
            System.assertEquals(1,rows.size()); System.assertEquals(200,rows[0].amount);
            System.assertEquals('BDT',rows[0].currencyCode); System.assertEquals(true,rows[0].formulaBased);
            Boolean blocked=false;
            try { SABEmployeeCompensationService.createOrUpdateAssignment(r); }
            catch(SABEmployeeCompensationService.EmployeeCompensationException ex) {
                blocked=true; System.assert(ex.getMessage().contains('Only Draft'));
            }
            System.assert(blocked,'Approved snapshots must reject edits.');
            Test.stopTest();
        }
    }

    @IsTest
    static void validatesEmployeeRequests() {
        User actor=coverageActor('g10avemployee');
        System.runAs(actor) {
            Test.startTest();
            rejectsRequest('Employee', 'null', 'Employee Reference is required.');
            rejectsRequest('Employee', '{}', 'Employee Reference is required.');
            rejectsRequest('Employee', '{"employeeReference":"E","status":"Wrong"}', 'Employee Status must be Active or Inactive.');
            Test.stopTest();
        }
    }

    @IsTest
    static void validatesEmploymentRequests() {
        User actor=coverageActor('g10avemployment');
        System.runAs(actor) {
            Test.startTest();
            rejectsRequest('Employment', 'null', 'Employment request is required.');
            rejectsRequest('Employment', '{}', 'Employee is required.');
            rejectsRequest('Employment', '{"employeeId":"005000000000001"}', 'Accounting Company is required.');
            rejectsRequest('Employment', '{"employeeId":"005000000000001","companyId":"005000000000001"}', 'Employment Start Date is required.');
            rejectsRequest('Employment', '{"employeeId":"005000000000001","companyId":"005000000000001","startDate":"2026-01-01","employmentStatus":"Wrong"}', 'Employment Status must be Active, Leave, or Ended.');
            Test.stopTest();
        }
    }

    @IsTest
    static void validatesComponentRequests() {
        User actor=coverageActor('g10avcomponent');
        System.runAs(actor) {
            Test.startTest();
            rejectsRequest('Component', 'null', 'Pay Component request is required.');
            rejectsRequest('Component', '{}', 'Pay Component Name is required.');
            rejectsRequest('Component', '{"name":"P"}', 'Component Key is required.');
            rejectsRequest('Component', '{"name":"P","componentKey":"K"}', 'Pay Component Category is required.');
            rejectsRequest('Component', '{"name":"P","componentKey":"K","category":"Wrong"}', 'Unsupported Pay Component Category.');
            Test.stopTest();
        }
    }

    @IsTest
    static void validatesAssignmentRequests() {
        User actor=coverageActor('g10avassignment');
        System.runAs(actor) {
            Test.startTest();
            rejectsRequest('Assignment', 'null', 'Compensation assignment request is required.');
            rejectsRequest('Assignment', '{}', 'Employment is required.');
            rejectsRequest('Assignment', '{"employmentId":"005000000000001"}', 'Pay Component is required.');
            rejectsRequest('Assignment', '{"employmentId":"005000000000001","payComponentId":"005000000000001"}', 'Effective From is required.');
            rejectsRequest('Assignment', '{"employmentId":"005000000000001","payComponentId":"005000000000001","effectiveFrom":"2026-01-01","effectiveTo":"2025-12-31"}', 'Effective To cannot be before Effective From.');
            rejectsRequest('Assignment', '{"employmentId":"005000000000001","payComponentId":"005000000000001","effectiveFrom":"2026-01-01","amount":-1}', 'Compensation amount cannot be negative.');
            rejectsRequest('Assignment', '{"employmentId":"005000000000001","payComponentId":"005000000000001","effectiveFrom":"2026-01-01"}', 'Provide an amount or supported formula parameters.');
            rejectsRequest('Assignment', '{"employmentId":"005000000000001","payComponentId":"005000000000001","effectiveFrom":"2026-01-01","amount":1}', 'Currency is required.');
            Test.stopTest();
        }
    }

    @IsTest
    static void validatesAwardRequests() {
        User actor=coverageActor('g10avaward');
        System.runAs(actor) {
            Test.startTest();
            rejectsRequest('Award', 'null', 'Benefit Award request is required.');
            rejectsRequest('Award', '{}', 'Employment is required.');
            rejectsRequest('Award', '{"employmentId":"005000000000001"}', 'Pay Component is required.');
            rejectsRequest('Award', '{"employmentId":"005000000000001","payComponentId":"005000000000001"}', 'Award Key is required.');
            rejectsRequest('Award', '{"employmentId":"005000000000001","payComponentId":"005000000000001","awardKey":"A"}', 'Benefit Award amount must be greater than zero.');
            rejectsRequest('Award', '{"employmentId":"005000000000001","payComponentId":"005000000000001","awardKey":"A","amount":0}', 'Benefit Award amount must be greater than zero.');
            rejectsRequest('Award', '{"employmentId":"005000000000001","payComponentId":"005000000000001","awardKey":"A","amount":1}', 'Currency is required.');
            rejectsRequest('Award', '{"employmentId":"005000000000001","payComponentId":"005000000000001","awardKey":"A","amount":1,"currencyCode":"BDT"}', 'Service Period Start is required.');
            rejectsRequest('Award', '{"employmentId":"005000000000001","payComponentId":"005000000000001","awardKey":"A","amount":1,"currencyCode":"BDT","servicePeriodStart":"2026-01-02","servicePeriodEnd":"2026-01-01"}', 'Service Period End cannot be before Service Period Start.');
            Test.stopTest();
        }
    }


    @IsTest
    static void rejectsInactiveEmployeeAndReversedEmploymentDates() {
        Accounting_Company__c company=makeCompany('C10');
        User actor=coverageActor('g10aempguards');
        grantCompany(company.Id,actor.Id,'G10A-C10');
        System.runAs(actor) {
            SABEmployeeCompensationService.EmployeeRequest er=new SABEmployeeCompensationService.EmployeeRequest();
            er.employeeReference=' EMP-C10 '; er.status='Inactive';
            Id employeeId=SABEmployeeCompensationService.createEmployee(er);
            System.assertEquals('EMP-C10',[SELECT Employee_Reference__c FROM Employee__c WHERE Id=:employeeId].Employee_Reference__c);
            SABEmployeeCompensationService.EmploymentRequest r=new SABEmployeeCompensationService.EmploymentRequest();
            r.employeeId=employeeId; r.companyId=company.Id; r.startDate=Date.today();
            Test.startTest();
            rejectsRequest('Employment',JSON.serialize(r),'An Inactive Employee cannot receive a new Employment record.');
            update new Employee__c(Id=employeeId,Status__c='Active');
            r.endDate=Date.today().addDays(-1);
            rejectsRequest('Employment',JSON.serialize(r),'Employment End Date cannot be before Start Date.');
            Test.stopTest();
        }
    }

    @IsTest
    static void rejectsMissingCompanyAndMissingLifecycleRecords() {
        User actor=coverageActor('g10amissing');
        System.runAs(actor) {
            Test.startTest();
            Boolean blocked=false;
            try { SABEmployeeCompensationService.getEmployments(null,true); }
            catch(SABEmployeeCompensationService.EmployeeCompensationException ex) {
                blocked=true; System.assertEquals('Accounting Company is required.',ex.getMessage());
            }
            System.assert(blocked,'Company context is mandatory.');
            blocked=false;
            try { SABEmployeeCompensationService.approveAssignment(null); }
            catch(SABEmployeeCompensationService.EmployeeCompensationException ex) {
                blocked=true; System.assertEquals('Employee Pay Component assignment not found.',ex.getMessage());
            }
            System.assert(blocked,'A missing assignment cannot be approved.');
            blocked=false;
            try { SABEmployeeCompensationService.approveBenefitAward(null); }
            catch(SABEmployeeCompensationService.EmployeeCompensationException ex) {
                blocked=true; System.assertEquals('Benefit Award not found.',ex.getMessage());
            }
            System.assert(blocked,'A missing award cannot be approved.');
            Test.stopTest();
        }
    }

}
