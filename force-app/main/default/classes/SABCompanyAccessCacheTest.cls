@IsTest
private class SABCompanyAccessCacheTest {
    @TestSetup
    static void setupData() {
        String token=UserInfo.getOrganizationId()+'.'+System.now().getTime();
        User other=new User(Alias='sabcach',LastName='SAB Cache User',Username='sabcache.'+token+'@example.invalid',
            Email='cache@example.invalid',ProfileId=UserInfo.getProfileId(),TimeZoneSidKey='Asia/Dhaka',
            LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');
        insert other;
        System.runAs(new User(Id=UserInfo.getUserId())) {
            Accounting_Company__c company=new Accounting_Company__c(Name__c='Cache Test',Company_Key__c='AC1',Country_Code__c='BD',
                Functional_Currency__c='BDT',Fiscal_Calendar_Type__c='Calendar',Fiscal_Year_Start_Month__c=1,Setup_Status__c='Active',Is_Active__c=true);
            insert company;
            insert new Company_User_Access__c(Company__c=company.Id,User__c=UserInfo.getUserId(),Role__c='Bookkeeper',
                Is_Active__c=true,Effective_From__c=Date.today().addDays(-2),Grant_Key__c='CACHE-GRANT');
        }
    }
    private static Company_User_Access__c grantRow() {
        return [SELECT Id,Company__c,User__c,Is_Active__c,Effective_From__c,Effective_To__c FROM Company_User_Access__c WHERE Grant_Key__c='CACHE-GRANT' LIMIT 1];
    }
    @IsTest static void deleteAndUndeleteRefreshAuthorization() {
        System.runAs(new User(Id=UserInfo.getUserId())) {
        Company_User_Access__c grant=grantRow();
        System.assertEquals(true,SABCompanyAccessService.hasCompanyAccess(grant.Company__c),'Warm positive cache.');
        Test.startTest();
        delete grant;
        System.assertEquals(false,SABCompanyAccessService.hasCompanyAccess(grant.Company__c),'Delete removes access immediately.');
        Boolean denied=false;
        try { SABCompanyAccessService.assertCompanyAccess(grant.Company__c); }
        catch(SABCompanyAccessService.CompanyAccessDeniedException ex) { denied=true; }
        System.assert(denied,'Assertion must reject revoked company.');
        undelete grant;
        System.assertEquals(true,SABCompanyAccessService.hasCompanyAccess(grant.Company__c),'Undelete refreshes negative cache.');
        Test.stopTest();
            }
    }
    @IsTest static void inactiveGrantInvalidatesPositiveCache() {
        System.runAs(new User(Id=UserInfo.getUserId())) {
        Company_User_Access__c grant=grantRow();
        SABCompanyAccessService.assertCompanyAccess(grant.Company__c);
        Test.startTest();
        grant.Is_Active__c=false;update grant;
        System.assertEquals(false,SABCompanyAccessService.hasCompanyAccess(grant.Company__c),'Inactive grant denies access.');
        System.assertEquals(null,SABCompanyAccessService.getCompanyRole(grant.Company__c),'Inactive grant supplies no role.');
        Test.stopTest();
            }
    }
    @IsTest static void expiredGrantInvalidatesPositiveCache() {
        System.runAs(new User(Id=UserInfo.getUserId())) {
        Company_User_Access__c grant=grantRow();
        SABCompanyAccessService.assertCompanyAccess(grant.Company__c);
        Test.startTest();grant.Effective_To__c=Date.today().addDays(-1);update grant;
        System.assertEquals(false,SABCompanyAccessService.hasCompanyAccess(grant.Company__c),'New expiry applies immediately.');
        Test.stopTest();
            }
    }
    @IsTest static void reassignmentInvalidatesBothUsers() {
        Company_User_Access__c grant=grantRow();
        User other=[SELECT Id FROM User WHERE LastName='SAB Cache User' LIMIT 1];
        System.assertEquals(true,SABCompanyAccessService.hasCompanyAccess(grant.Company__c),'Original owner starts authorized.');
        System.runAs(other) { System.assertEquals(false,SABCompanyAccessService.hasCompanyAccess(grant.Company__c),'Warm new user negative cache.'); }
        Test.startTest();grant.User__c=other.Id;update grant;
        System.assertEquals(false,SABCompanyAccessService.hasCompanyAccess(grant.Company__c),'Previous user loses access.');
        System.runAs(other) { System.assertEquals(true,SABCompanyAccessService.hasCompanyAccess(grant.Company__c),'New user gains access.'); System.assertEquals('Bookkeeper',SABCompanyAccessService.getCompanyRole(grant.Company__c),'Role lookup works for grant holder.'); }
        Test.stopTest();
    }
    @IsTest static void insertionRefreshesNegativeCache() {
        Company_User_Access__c grant=grantRow();
        User other=[SELECT Id FROM User WHERE LastName='SAB Cache User' LIMIT 1];
        System.runAs(other) { System.assertEquals(false,SABCompanyAccessService.hasCompanyAccess(grant.Company__c),'User initially denied.'); }
        Test.startTest();
        insert new Company_User_Access__c(Company__c=grant.Company__c,User__c=other.Id,Role__c='Bookkeeper',
            Is_Active__c=true,Effective_From__c=Date.today(),Grant_Key__c='CACHE-NEW');
        System.runAs(other) { System.assertEquals(true,SABCompanyAccessService.hasCompanyAccess(grant.Company__c),'Inserted grant clears negative cache.'); System.assert(SABCompanyAccessService.getAccessibleCompanyIds().contains(grant.Company__c),'Company list reflects the new grant.'); System.assertEquals('Bookkeeper',SABCompanyAccessService.getCompanyRole(grant.Company__c),'Role lookup uses the same authorization mode.'); }
        Test.stopTest();
    }
    @IsTest static void repeatedChecksReuseCacheAndReturnedSetIsDefensive() {
        System.runAs(new User(Id=UserInfo.getUserId())) {
        Company_User_Access__c grant=grantRow();
        Test.startTest();
        SABCompanyAccessService.assertCompanyAccess(grant.Company__c);
        Integer beforeQueries=Limits.getQueries();
        for(Integer i=0;i<20;i++) { System.assertEquals(true,SABCompanyAccessService.hasCompanyAccess(grant.Company__c),'Unchanged grants stay cached.'); }
        System.assertEquals(beforeQueries,Limits.getQueries(),'Repeated authorization must not add queries.');
        Set<Id> copy=SABCompanyAccessService.getAccessibleCompanyIds();copy.clear();
        System.assertEquals(true,SABCompanyAccessService.hasCompanyAccess(grant.Company__c),'Caller cannot mutate cache.');
        System.assertEquals('Bookkeeper',SABCompanyAccessService.getCompanyRole(grant.Company__c),'Active role returned.');
        System.assertEquals(false,SABCompanyAccessService.hasCompanyAccess(null),'Null company denied.');
        System.assertEquals(null,SABCompanyAccessService.getCompanyRole(null),'Null company has no role.');
        SABCompanyAccessService.invalidateUsers(null);
        Test.stopTest();
            }
    }
}
