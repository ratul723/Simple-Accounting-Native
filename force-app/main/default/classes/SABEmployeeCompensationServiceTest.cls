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
        insert u;
        return u;
    }

    private static void assignPermissionSet(User user, String permissionSetName) {
        PermissionSet ps = [
            SELECT Id
            FROM PermissionSet
            WHERE Name = :permissionSetName
            LIMIT 1
        ];
        insert new PermissionSetAssignment(
            AssigneeId = user.Id,
            PermissionSetId = ps.Id
        );
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
                 AND RowCause = 'Manual']
            );
            System.assertEquals(
                1,
                [SELECT COUNT() FROM Pay_Component__Share
                 WHERE ParentId = :component.Id
                 AND UserOrGroupId = :target.Id
                 AND RowCause = 'Manual']
            );
            System.assertEquals(
                1,
                [SELECT COUNT() FROM Employee_Pay_Component__Share
                 WHERE ParentId = :assignment.Id
                 AND UserOrGroupId = :target.Id
                 AND RowCause = 'Manual']
            );
            System.assertEquals(
                1,
                [SELECT COUNT() FROM Benefit_Award__Share
                 WHERE ParentId = :award.Id
                 AND UserOrGroupId = :target.Id
                 AND RowCause = 'Manual']
            );
        }
    }

}
