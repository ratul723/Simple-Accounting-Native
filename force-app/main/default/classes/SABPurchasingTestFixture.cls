/**
 * G12: shared test data for purchasing tests. Lean by design (SABTestGovernor rules): an Approved purchase
 * order is seeded through the purchasing guard scope rather than replaying save, submit and approve.
 *
 * Users (System Administrator profile so record access is not the subject; field access comes from sets):
 *   buyer     SAB Purchasing User + Manage Purchase Order + Receive Goods
 *   approver  SAB Purchasing User + Approve Purchase Order
 *   ap        broad SAB field access + Approve Financial Document (G3A supplier bill flow)
 * Approved purchase order 'P12-PO': line 1 = 10 x 100, line 2 = 5 x 40, supplier 'P12-SUPPLIER', BDT.
 */
@IsTest
public class SABPurchasingTestFixture {
    public static final String BUYER = 'SAB P12 Buyer';
    public static final String APPROVER = 'SAB P12 Approver';
    public static final String AP = 'SAB P12 AP';
    public static final Date ORDER_DATE = Date.newInstance(2026, 9, 1);

    private static Map<String, User> users = new Map<String, User>();

    public static void createFixture() {
        User buyerUser;
        User approverUser;
        User apUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            String unique = UserInfo.getOrganizationId() + '.' + String.valueOf(System.now().getTime());
            buyerUser = newUser(BUYER, 'p12buy', unique);
            approverUser = newUser(APPROVER, 'p12apr', unique);
            apUser = newUser(AP, 'p12ap', unique);
            insert as system new List<User>{buyerUser, approverUser, apUser};
            Map<Id, Set<String>> setsByUser = new Map<Id, Set<String>>{
                buyerUser.Id => new Set<String>{'SAB_Purchasing_User', 'SAB_Manage_Purchase_Order_Action', 'SAB_Receive_Goods_Action'},
                approverUser.Id => new Set<String>{'SAB_Purchasing_User', 'SAB_Approve_Purchase_Order_Action'},
                apUser.Id => new Set<String>{'SAB_Remaining_Fields_Admin', 'SAB_Approve_Financial_Document_Action'}};
            Set<String> names = new Set<String>();
            for (Set<String> s : setsByUser.values()) {
                names.addAll(s);
            }
            Map<String, Id> setIds = new Map<String, Id>();
            for (PermissionSet p : [SELECT Id, Name FROM PermissionSet WHERE Name IN :names WITH SYSTEM_MODE]) {
                setIds.put(p.Name, p.Id);
            }
            System.assertEquals(names.size(), setIds.size(), 'Deploy the G12 purchasing and G3 permission sets first.');
            List<PermissionSetAssignment> rows = new List<PermissionSetAssignment>();
            for (Id userId : setsByUser.keySet()) {
                for (String name : setsByUser.get(userId)) {
                    rows.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = setIds.get(name)));
                }
            }
            insert as system rows;
        }
        System.runAs(buyerUser) {
            Accounting_Company__c company = new Accounting_Company__c(Name__c = 'P12 Company', Company_Key__c = 'P12', Country_Code__c = 'BD',
                Functional_Currency__c = 'BDT', Fiscal_Calendar_Type__c = 'Calendar', Fiscal_Year_Start_Month__c = 1,
                Setup_Status__c = 'Active', Is_Active__c = true);
            insert as system company;
            List<Company_User_Access__c> grants = new List<Company_User_Access__c>();
            for (User u : new List<User>{buyerUser, approverUser, apUser}) {
                grants.add(new Company_User_Access__c(Company__c = company.Id, User__c = u.Id, Is_Active__c = true,
                    Effective_From__c = Date.today().addDays(-1), Grant_Key__c = 'P12-' + u.Id, Role__c = 'Finance Manager'));
            }
            insert as system grants;
            insert as system new Accounting_Period__c(Name = 'September 2026', Company__c = company.Id, Company_Period_Key__c = 'P12-2026-09',
                Period_Key__c = '2026-09', Start_Date__c = Date.newInstance(2026, 9, 1), End_Date__c = Date.newInstance(2026, 9, 30),
                Fiscal_Year__c = 2026, Fiscal_Quarter__c = 3, Period_Number__c = 9, Status__c = 'Open');
            GL_Account__c apControl = new GL_Account__c(Name = 'Accounts Payable', Company__c = company.Id, Company_Account_Key__c = 'P12-2000',
                Account_Code__c = '2000', Account_Type__c = 'Liability', Normal_Balance__c = 'Credit', Is_Active__c = true,
                Is_Control_Account__c = true, Control_Type__c = 'AP', Manual_Posting_Allowed__c = false);
            GL_Account__c expense = new GL_Account__c(Name = 'Purchases', Company__c = company.Id, Company_Account_Key__c = 'P12-6000',
                Account_Code__c = '6000', Account_Type__c = 'Expense', Normal_Balance__c = 'Debit', Is_Active__c = true,
                Is_Control_Account__c = false, Control_Type__c = 'None', Manual_Posting_Allowed__c = true);
            insert as system new List<GL_Account__c>{apControl, expense};
            Account supplier = new Account(Name = 'P12 Supplier');
            insert as system supplier;
            Party_Accounting_Profile__c profile = new Party_Accounting_Profile__c(Company__c = company.Id, Account__c = supplier.Id,
                Profile_Key__c = 'P12-SUPPLIER', Is_Supplier__c = true, Is_Customer__c = false, Is_Active__c = true,
                AP_Control_Account__c = apControl.Id);
            insert as system profile;
            Purchase_Order__c order = new Purchase_Order__c(Company__c = company.Id, Supplier_Profile__c = profile.Id, Order_Date__c = ORDER_DATE,
                Currency__c = 'BDT', Status__c = 'Approved', Total__c = 1200, Submitted_By__c = buyerUser.Id, Submitted_At__c = System.now(),
                Approved_By__c = approverUser.Id, Approved_At__c = System.now());
            SABPurchasingGuard.beginWrite();
            try {
                insert as system order;
                insert as system new List<Purchase_Order_Line__c>{
                    new Purchase_Order_Line__c(Purchase_Order__c = order.Id, Line_Number__c = 1, Description__c = 'Laptops', Quantity__c = 10,
                        Unit_Price__c = 100, Received_Quantity__c = 0, Remaining_Quantity__c = 10),
                    new Purchase_Order_Line__c(Purchase_Order__c = order.Id, Line_Number__c = 2, Description__c = 'Installation',
                        Quantity__c = 5, Unit_Price__c = 40, Received_Quantity__c = 0, Remaining_Quantity__c = 5)};
            } finally {
                SABPurchasingGuard.endWrite();
            }
        }
        SABTestGovernor.assertSetupWithin(50);
    }

    private static User newUser(String lastName, String alias, String unique) {
        return new User(Username = alias + '.' + unique + '@example.invalid', Email = alias + '@example.invalid', LastName = lastName,
            Alias = alias, TimeZoneSidKey = 'Asia/Dhaka', LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US', ProfileId = UserInfo.getProfileId());
    }

    public static User user(String lastName) {
        if (!users.containsKey(lastName)) {
            users.put(lastName, [SELECT Id FROM User WHERE LastName = :lastName AND Alias LIKE 'p12%' WITH SYSTEM_MODE LIMIT 1]);
        }
        return users.get(lastName);
    }

    public static Id companyId() {
        return [SELECT Id FROM Accounting_Company__c WHERE Company_Key__c = 'P12' WITH SYSTEM_MODE].Id;
    }

    public static Id supplierId() {
        return [SELECT Id FROM Party_Accounting_Profile__c WHERE Profile_Key__c = 'P12-SUPPLIER' WITH SYSTEM_MODE].Id;
    }

    public static Id expenseAccountId() {
        return [SELECT Id FROM GL_Account__c WHERE Company_Account_Key__c = 'P12-6000' WITH SYSTEM_MODE].Id;
    }

    public static Purchase_Order__c approvedOrder() {
        return [SELECT Id, Status__c, Total__c FROM Purchase_Order__c WHERE Company__r.Company_Key__c = 'P12' WITH SYSTEM_MODE
            ORDER BY CreatedDate LIMIT 1];
    }

    public static Map<Integer, Purchase_Order_Line__c> lines(Id purchaseOrderId) {
        Map<Integer, Purchase_Order_Line__c> result = new Map<Integer, Purchase_Order_Line__c>();
        for (Purchase_Order_Line__c line : [SELECT Id, Line_Number__c, Quantity__c, Received_Quantity__c, Remaining_Quantity__c
                FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :purchaseOrderId WITH SYSTEM_MODE]) {
            result.put(line.Line_Number__c.intValue(), line);
        }
        return result;
    }

    /** Accepted receipt seeded through the guard scope; quantities by line number. Returns receipt line ids by line number. */
    public static Map<Integer, Id> seedAcceptedReceipt(Id purchaseOrderId, Map<Integer, Decimal> quantities) {
        Map<Integer, Purchase_Order_Line__c> orderLines = lines(purchaseOrderId);
        Map<Integer, Id> receiptLineIds = new Map<Integer, Id>();
        SABPurchasingGuard.beginWrite();
        try {
            Goods_Receipt__c receipt = new Goods_Receipt__c(Company__c = companyId(), Purchase_Order__c = purchaseOrderId,
                Receipt_Date__c = ORDER_DATE.addDays(5), Status__c = 'Accepted', Accepted_By__c = UserInfo.getUserId(),
                Accepted_At__c = System.now());
            insert as system receipt;
            Map<Integer, Goods_Receipt_Line__c> receiptLines = new Map<Integer, Goods_Receipt_Line__c>();
            for (Integer lineNumber : quantities.keySet()) {
                Purchase_Order_Line__c orderLine = orderLines.get(lineNumber);
                receiptLines.put(lineNumber, new Goods_Receipt_Line__c(Goods_Receipt__c = receipt.Id, Purchase_Order_Line__c = orderLine.Id,
                    Accepted_Quantity__c = quantities.get(lineNumber)));
                orderLine.Received_Quantity__c = (orderLine.Received_Quantity__c == null ? 0 : orderLine.Received_Quantity__c)
                    + quantities.get(lineNumber);
                orderLine.Remaining_Quantity__c = Math.max(0, orderLine.Quantity__c - orderLine.Received_Quantity__c);
            }
            insert as system receiptLines.values();
            update as system orderLines.values();
            update as system new Purchase_Order__c(Id = purchaseOrderId, Status__c = 'Part Received');
            for (Integer lineNumber : receiptLines.keySet()) {
                receiptLineIds.put(lineNumber, receiptLines.get(lineNumber).Id);
            }
        } finally {
            SABPurchasingGuard.endWrite();
        }
        return receiptLineIds;
    }

    /** Draft supplier bill with one line per spec: {orderLineId, receiptLineId, quantity, unitPrice}. */
    public static Id draftBill(String documentType, String vendorReference, List<List<Object>> specs) {
        Supplier_Bill__c bill = new Supplier_Bill__c(Company__c = companyId(), Supplier_Profile__c = supplierId(), Document_Type__c = documentType,
            Document_Date__c = Date.newInstance(2026, 9, 20), Accounting_Date__c = Date.newInstance(2026, 9, 20),
            Due_Date__c = Date.newInstance(2026, 10, 20), Transaction_Currency__c = 'BDT', Vendor_Reference__c = vendorReference,
            Status__c = 'Draft');
        insert as system bill;
        List<Bill_Line__c> lines = new List<Bill_Line__c>();
        Integer lineNumber = 1;
        Id expense = expenseAccountId();
        for (List<Object> spec : specs) {
            Decimal quantity = (Decimal) spec[2];
            Decimal price = (Decimal) spec[3];
            lines.add(new Bill_Line__c(Supplier_Bill__c = bill.Id, Line_Number__c = lineNumber++, Description__c = 'Matched line',
                Purchase_Order_Line__c = (Id) spec[0], Goods_Receipt_Line__c = (Id) spec[1], Quantity__c = quantity, Unit_Price__c = price,
                Net_Amount__c = quantity * price, Recoverable_Tax_Amount__c = 0, Nonrecoverable_Tax_Amount__c = 0,
                Expense_or_Asset_Account__c = expense));
        }
        insert as system lines;
        return bill.Id;
    }

    public static SAB_Purchase_Match_Policy__mdt policy(String body) {
        return (SAB_Purchase_Match_Policy__mdt) JSON.deserialize(body, SAB_Purchase_Match_Policy__mdt.class);
    }
}
