@IsTest
private class SABPersonaServiceTest {

    @IsTest
    static void bookkeeperFromPostJournalPermission() {
        User user = SABAppShellTestFixture.createUser('sabpbk', 'SAB Persona Bookkeeper',
            new List<String>{ 'SAB_App_User', 'SAB_Post_Journal_Action' });
        SABPersonaService.Persona persona;
        Test.startTest();
        System.runAs(user) {
            persona = SABPersonaService.current();
        }
        Test.stopTest();
        System.assertEquals(SABPersonaService.BOOKKEEPER, persona.key, 'SAB_Post_Journal maps to Bookkeeper.');
        System.assertEquals('Bookkeeper', persona.label, 'Label follows the demo roles.');
        System.assertEquals('AS', persona.initials, 'Initials come from first and last name.');
        System.assertEquals('Alex', persona.firstName, 'First name feeds the home greeting.');
    }

    @IsTest
    static void personaPriorityAcrossPermissionSets() {
        User manager = SABAppShellTestFixture.createUser('sabpfm', 'SAB Persona Manager',
            new List<String>{ 'SAB_Close_Period_Action', 'SAB_Post_Journal_Action' });
        User director = SABAppShellTestFixture.createUser('sabpdr', 'SAB Persona Director',
            new List<String>{ 'SAB_Approve_Financial_Document_Action' });
        User treasury = SABAppShellTestFixture.createUser('sabptr', 'SAB Persona Treasury',
            new List<String>{ 'SAB_Release_Payment_Action' });
        User hr = SABAppShellTestFixture.createUser('sabphr', 'SAB Persona HR',
            new List<String>{ 'SAB_Payroll_Calculation_User' });
        User auditor = SABAppShellTestFixture.createUser('sabpau', 'SAB Persona Auditor', new List<String>{ 'SAB_App_User' });
        Map<String, String> keys = new Map<String, String>();
        Test.startTest();
        System.runAs(manager) {
            keys.put('manager', SABPersonaService.resolveKey());
        }
        System.runAs(director) {
            keys.put('director', SABPersonaService.resolveKey());
            System.assert(SABPersonaService.current().canApprove, 'Director holds the approval permission.');
        }
        System.runAs(treasury) {
            keys.put('treasury', SABPersonaService.resolveKey());
        }
        System.runAs(hr) {
            keys.put('hr', SABPersonaService.resolveKey());
        }
        System.runAs(auditor) {
            keys.put('auditor', SABPersonaService.resolveKey());
        }
        Test.stopTest();
        System.assertEquals(SABPersonaService.FINANCE_MANAGER, keys.get('manager'), 'Close period outranks posting.');
        System.assertEquals(SABPersonaService.DIRECTOR, keys.get('director'), 'Approval permission maps to Director.');
        System.assertEquals(SABPersonaService.TREASURY, keys.get('treasury'), 'Release payment maps to Treasury.');
        System.assertEquals(SABPersonaService.HR, keys.get('hr'), 'Payroll calculation maps to HR.');
        System.assertEquals(SABPersonaService.AUDITOR, keys.get('auditor'), 'No action permission falls back to Auditor.');
    }

    @IsTest
    static void labelsAndInitialsAreSafe() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            System.assertEquals('Treasury', SABPersonaService.labelOf(SABPersonaService.TREASURY), 'Known key label.');
            System.assertEquals('Auditor', SABPersonaService.labelOf('UNKNOWN'), 'Unknown keys fall back to Auditor.');
            System.assertEquals('', SABPersonaService.initialsOf(' '), 'Blank names give no initials.');
            System.assertEquals('MT', SABPersonaService.initialsOf('mei tanaka smith'), 'At most two initials.');
        }
    }
}
