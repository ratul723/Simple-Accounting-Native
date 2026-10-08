/**
 * G12B: Purchasing Workspace controller.
 *
 * Read layer for the sabPurchasingWorkspace LWC. Every read runs in user mode after SAB_View_Purchasing, the company grant
 * and the CRUD/FLS policy. All changes go through SABPurchaseOrderService and SABGoodsReceiptService.
 *
 * Match status per order line compares ordered, received and billed quantities. Billed = quantities on lines of live
 * supplier bills (Submitted, Approved, Posted), with supplier credits subtracted, the same rule SABPurchaseMatchingService
 * applies at bill submission and approval.
 */
public with sharing class SABPurchasingWorkspaceController {
    public class PurchasingWorkspaceException extends Exception {}

    private static final String VIEW = 'SAB_View_Purchasing';
    private static final Integer ROW_LIMIT = 200;
    private static final List<String> STATES = new List<String>{'Draft', 'Submitted', 'Approved', 'Part Received', 'Received', 'Closed',
        'Cancelled'};
    private static final Set<String> LIVE_BILL_STATES = new Set<String>{'Submitted', 'Approved', 'Posted'};

    // ------------------------------------------------------------------ DTOs

    public class Capabilities {
        @AuraEnabled public Boolean manage;
        @AuraEnabled public Boolean approve;
        @AuraEnabled public Boolean receive;
    }

    public class OptionDTO {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
    }

    public class StateCount {
        @AuraEnabled public String state;
        @AuraEnabled public Integer count;
    }

    public class OrderDTO {
        @AuraEnabled public Id purchaseOrderId;
        @AuraEnabled public String name;
        @AuraEnabled public Id supplierProfileId;
        @AuraEnabled public String supplierName;
        @AuraEnabled public Date orderDate;
        @AuraEnabled public String currencyCode;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal total;
    }

    public class WorkspaceDTO {
        @AuraEnabled public Id companyId;
        @AuraEnabled public String companyName;
        @AuraEnabled public String functionalCurrency;
        @AuraEnabled public Capabilities capabilities;
        @AuraEnabled public List<OrderDTO> orders;
        @AuraEnabled public List<StateCount> stateCounts;
        @AuraEnabled public Decimal openCommitment;
        @AuraEnabled public List<OptionDTO> suppliers;
        @AuraEnabled public List<OptionDTO> departments;
        @AuraEnabled public List<OptionDTO> costCenters;
    }

    public class OrderLineDTO {
        @AuraEnabled public Id lineId;
        @AuraEnabled public Decimal lineNumber;
        @AuraEnabled public String description;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Decimal lineAmount;
        @AuraEnabled public Id departmentId;
        @AuraEnabled public String departmentName;
        @AuraEnabled public Id costCenterId;
        @AuraEnabled public String costCenterName;
        @AuraEnabled public Decimal receivedQuantity;
        @AuraEnabled public Decimal remainingQuantity;
        @AuraEnabled public Decimal billedQuantity;
        @AuraEnabled public String matchStatus;
    }

    public class ReceiptDTO {
        @AuraEnabled public Id goodsReceiptId;
        @AuraEnabled public String name;
        @AuraEnabled public Date receiptDate;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal totalQuantity;
    }

    public class BillDTO {
        @AuraEnabled public Id supplierBillId;
        @AuraEnabled public String name;
        @AuraEnabled public String documentType;
        @AuraEnabled public String status;
    }

    public class OrderDetailDTO {
        @AuraEnabled public OrderDTO purchaseOrder;
        @AuraEnabled public List<OrderLineDTO> lines;
        @AuraEnabled public List<ReceiptDTO> receipts;
        @AuraEnabled public List<BillDTO> bills;
    }

    // --------------------------------------------------------------- queries

    @AuraEnabled
    public static WorkspaceDTO getWorkspace(Id companyId) {
        if (companyId == null) {
            throw new PurchasingWorkspaceException('Select an Accounting Company first.');
        }
        authorize();
        SABCompanyAccessService.assertCompanyAccess(companyId);
        List<Accounting_Company__c> companies = [SELECT Id, Name__c, Functional_Currency__c FROM Accounting_Company__c
            WHERE Id = :companyId WITH USER_MODE];
        if (companies.isEmpty()) {
            throw new PurchasingWorkspaceException('Accounting Company not found or not accessible.');
        }
        WorkspaceDTO result = new WorkspaceDTO();
        result.companyId = companyId;
        result.companyName = companies[0].Name__c;
        result.functionalCurrency = companies[0].Functional_Currency__c;
        result.capabilities = capabilities();
        Map<String, Integer> counts = new Map<String, Integer>();
        for (String s : STATES) {
            counts.put(s, 0);
        }
        result.orders = new List<OrderDTO>();
        result.openCommitment = 0;
        for (Purchase_Order__c po : [SELECT Id, Name, Supplier_Profile__c, Supplier_Profile__r.Name, Order_Date__c, Currency__c, Status__c,
                Total__c FROM Purchase_Order__c WHERE Company__c = :companyId WITH USER_MODE ORDER BY Order_Date__c DESC, Name DESC
                LIMIT :ROW_LIMIT]) {
            OrderDTO dto = toOrder(po);
            result.orders.add(dto);
            if (counts.containsKey(dto.status)) {
                counts.put(dto.status, counts.get(dto.status) + 1);
            }
            if ((dto.status == 'Approved' || dto.status == 'Part Received') && dto.currencyCode == result.functionalCurrency
                    && dto.total != null) {
                result.openCommitment += dto.total;
            }
        }
        result.stateCounts = new List<StateCount>();
        for (String s : STATES) {
            StateCount c = new StateCount();
            c.state = s;
            c.count = counts.get(s);
            result.stateCounts.add(c);
        }
        result.suppliers = new List<OptionDTO>();
        for (Party_Accounting_Profile__c p : [SELECT Id, Name FROM Party_Accounting_Profile__c WHERE Company__c = :companyId
                AND Is_Supplier__c = true AND Is_Active__c = true WITH USER_MODE ORDER BY Name LIMIT :ROW_LIMIT]) {
            result.suppliers.add(option(p.Name, p.Id));
        }
        result.departments = new List<OptionDTO>();
        for (Department__c d : [SELECT Id, Name FROM Department__c WHERE Company__c = :companyId AND Is_Active__c = true WITH USER_MODE
                ORDER BY Name LIMIT :ROW_LIMIT]) {
            result.departments.add(option(d.Name, d.Id));
        }
        result.costCenters = new List<OptionDTO>();
        for (Cost_Center__c c : [SELECT Id, Name FROM Cost_Center__c WHERE Company__c = :companyId AND Is_Active__c = true WITH USER_MODE
                ORDER BY Name LIMIT :ROW_LIMIT]) {
            result.costCenters.add(option(c.Name, c.Id));
        }
        return result;
    }

    @AuraEnabled
    public static OrderDetailDTO getPurchaseOrderDetail(Id purchaseOrderId) {
        if (purchaseOrderId == null) {
            throw new PurchasingWorkspaceException('Select a purchase order first.');
        }
        authorize();
        List<Purchase_Order__c> rows = [SELECT Id, Name, Company__c, Supplier_Profile__c, Supplier_Profile__r.Name, Order_Date__c, Currency__c,
            Status__c, Total__c FROM Purchase_Order__c WHERE Id = :purchaseOrderId WITH USER_MODE];
        if (rows.isEmpty()) {
            throw new PurchasingWorkspaceException('Purchase order not found or not accessible.');
        }
        SABCompanyAccessService.assertCompanyAccess(rows[0].Company__c);
        OrderDetailDTO detail = new OrderDetailDTO();
        detail.purchaseOrder = toOrder(rows[0]);

        Map<Id, Decimal> billed = new Map<Id, Decimal>();
        Map<Id, BillDTO> bills = new Map<Id, BillDTO>();
        for (Bill_Line__c b : [SELECT Purchase_Order_Line__c, Quantity__c, Supplier_Bill__c, Supplier_Bill__r.Name, Supplier_Bill__r.Status__c,
                Supplier_Bill__r.Document_Type__c FROM Bill_Line__c WHERE Purchase_Order_Line__r.Purchase_Order__c = :purchaseOrderId
                WITH USER_MODE LIMIT 2000]) {
            if (!bills.containsKey(b.Supplier_Bill__c)) {
                BillDTO bill = new BillDTO();
                bill.supplierBillId = b.Supplier_Bill__c;
                bill.name = b.Supplier_Bill__r.Name;
                bill.status = b.Supplier_Bill__r.Status__c;
                bill.documentType = b.Supplier_Bill__r.Document_Type__c;
                bills.put(b.Supplier_Bill__c, bill);
            }
            if (!LIVE_BILL_STATES.contains(b.Supplier_Bill__r.Status__c) || b.Quantity__c == null) {
                continue;
            }
            Decimal signed = b.Supplier_Bill__r.Document_Type__c == 'Supplier Credit' ? -b.Quantity__c : b.Quantity__c;
            billed.put(b.Purchase_Order_Line__c, (billed.containsKey(b.Purchase_Order_Line__c) ? billed.get(b.Purchase_Order_Line__c) : 0) + signed);
        }
        detail.bills = bills.values();

        detail.lines = new List<OrderLineDTO>();
        for (Purchase_Order_Line__c l : [SELECT Id, Line_Number__c, Description__c, Quantity__c, Unit_Price__c, Department__c, Department__r.Name,
                Cost_Center__c, Cost_Center__r.Name, Received_Quantity__c, Remaining_Quantity__c FROM Purchase_Order_Line__c
                WHERE Purchase_Order__c = :purchaseOrderId WITH USER_MODE ORDER BY Line_Number__c LIMIT 501]) {
            OrderLineDTO dto = new OrderLineDTO();
            dto.lineId = l.Id;
            dto.lineNumber = l.Line_Number__c;
            dto.description = l.Description__c;
            dto.quantity = l.Quantity__c;
            dto.unitPrice = l.Unit_Price__c;
            dto.lineAmount = l.Quantity__c == null || l.Unit_Price__c == null ? null : (l.Quantity__c * l.Unit_Price__c).setScale(2, RoundingMode.HALF_UP);
            dto.departmentId = l.Department__c;
            dto.departmentName = l.Department__r == null ? null : l.Department__r.Name;
            dto.costCenterId = l.Cost_Center__c;
            dto.costCenterName = l.Cost_Center__r == null ? null : l.Cost_Center__r.Name;
            dto.receivedQuantity = l.Received_Quantity__c == null ? 0 : l.Received_Quantity__c;
            dto.remainingQuantity = l.Remaining_Quantity__c;
            dto.billedQuantity = billed.containsKey(l.Id) ? billed.get(l.Id) : 0;
            dto.matchStatus = matchStatus(dto.quantity, dto.receivedQuantity, dto.billedQuantity);
            detail.lines.add(dto);
        }

        detail.receipts = new List<ReceiptDTO>();
        for (Goods_Receipt__c r : [SELECT Id, Name, Receipt_Date__c, Status__c, (SELECT Accepted_Quantity__c FROM Goods_Receipt_Line_Goods_Receipt__r)
                FROM Goods_Receipt__c WHERE Purchase_Order__c = :purchaseOrderId WITH USER_MODE ORDER BY Receipt_Date__c DESC, Name DESC
                LIMIT :ROW_LIMIT]) {
            ReceiptDTO dto = new ReceiptDTO();
            dto.goodsReceiptId = r.Id;
            dto.name = r.Name;
            dto.receiptDate = r.Receipt_Date__c;
            dto.status = r.Status__c;
            dto.totalQuantity = 0;
            for (Goods_Receipt_Line__c line : r.Goods_Receipt_Line_Goods_Receipt__r) {
                dto.totalQuantity += line.Accepted_Quantity__c == null ? 0 : line.Accepted_Quantity__c;
            }
            detail.receipts.add(dto);
        }
        return detail;
    }

    // --------------------------------------------------------------- helpers

    /**
     * Not received / Awaiting bill / Part billed / Fully billed / Billed beyond receipt. Quantities, not values: price
     * tolerance is enforced on the bill by SABPurchaseMatchingService.
     */
    @TestVisible
    private static String matchStatus(Decimal ordered, Decimal received, Decimal billedQuantity) {
        if (billedQuantity > received) {
            return 'Billed beyond receipt';
        }
        if (received == 0) {
            return billedQuantity == 0 ? 'Not received' : 'Billed beyond receipt';
        }
        if (billedQuantity == 0) {
            return 'Awaiting bill';
        }
        if (billedQuantity < received) {
            return 'Part billed';
        }
        return received >= ordered ? 'Fully billed' : 'Billed to receipt';
    }

    private static void authorize() {
        SABPermissionService.assertPermission(VIEW, 'Purchasing workspace permission is required.');
        SABAccessControlService.assertReadable(Purchase_Order__c.SObjectType, new List<Schema.SObjectField>{Purchase_Order__c.Company__c,
            Purchase_Order__c.Supplier_Profile__c, Purchase_Order__c.Order_Date__c, Purchase_Order__c.Currency__c, Purchase_Order__c.Status__c,
            Purchase_Order__c.Total__c});
        SABAccessControlService.assertReadable(Purchase_Order_Line__c.SObjectType, new List<Schema.SObjectField>{
            Purchase_Order_Line__c.Description__c, Purchase_Order_Line__c.Quantity__c, Purchase_Order_Line__c.Unit_Price__c,
            Purchase_Order_Line__c.Received_Quantity__c, Purchase_Order_Line__c.Remaining_Quantity__c});
        SABAccessControlService.assertReadable(Goods_Receipt__c.SObjectType, new List<Schema.SObjectField>{Goods_Receipt__c.Status__c,
            Goods_Receipt__c.Receipt_Date__c});
        SABAccessControlService.assertReadable(Bill_Line__c.SObjectType, new List<Schema.SObjectField>{Bill_Line__c.Purchase_Order_Line__c,
            Bill_Line__c.Quantity__c});
    }

    @TestVisible
    private static Capabilities capabilities() {
        Capabilities c = new Capabilities();
        c.manage = SABPermissionService.hasPermission('SAB_Manage_Purchase_Order');
        c.approve = SABPermissionService.hasPermission('SAB_Approve_Purchase_Order');
        c.receive = SABPermissionService.hasPermission('SAB_Receive_Goods');
        return c;
    }

    private static OrderDTO toOrder(Purchase_Order__c po) {
        OrderDTO dto = new OrderDTO();
        dto.purchaseOrderId = po.Id;
        dto.name = po.Name;
        dto.supplierProfileId = po.Supplier_Profile__c;
        dto.supplierName = po.Supplier_Profile__r == null ? null : po.Supplier_Profile__r.Name;
        dto.orderDate = po.Order_Date__c;
        dto.currencyCode = po.Currency__c;
        dto.status = po.Status__c;
        dto.total = po.Total__c;
        return dto;
    }

    private static OptionDTO option(String label, Id value) {
        OptionDTO o = new OptionDTO();
        o.label = label;
        o.value = value;
        return o;
    }
}
