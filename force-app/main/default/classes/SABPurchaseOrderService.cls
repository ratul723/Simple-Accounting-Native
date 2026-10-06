/**
 * G12: Purchase orders.
 *
 *   saveDraft      SAB_Manage_Purchase_Order   create or replace a Draft order and its lines
 *   submit         SAB_Manage_Purchase_Order   Draft -> Submitted (re-validates supplier and lines, recomputes total)
 *   approve        SAB_Approve_Purchase_Order  Submitted -> Approved; approver differs from creator and submitter
 *   returnToDraft  SAB_Approve_Purchase_Order  Submitted -> Draft with a reason
 *   cancel         SAB_Manage_Purchase_Order   Draft/Submitted/Approved -> Cancelled when nothing is received or billed
 *   close          SAB_Manage_Purchase_Order   Approved/Part Received/Received -> Closed (no further receipts or bills)
 *
 * Purchase orders are operational documents with no ledger impact. Receipts update quantities through
 * applyReceipt; supplier bills are matched against orders and receipts by SABPurchaseMatchingService.
 * Every lifecycle action is idempotent by request key and audited in Business_Action__c.
 */
public with sharing class SABPurchaseOrderService {
    public class PurchaseOrderException extends Exception {}

    private static final String MANAGE = 'SAB_Manage_Purchase_Order';
    private static final String APPROVE = 'SAB_Approve_Purchase_Order';
    public static final String DRAFT = 'Draft';
    public static final String SUBMITTED = 'Submitted';
    public static final String APPROVED = 'Approved';
    public static final String PART_RECEIVED = 'Part Received';
    public static final String RECEIVED = 'Received';
    public static final String CLOSED = 'Closed';
    public static final String CANCELLED = 'Cancelled';
    public static final Set<String> RECEIVABLE = new Set<String>{APPROVED, PART_RECEIVED};
    public static final Set<String> BILLABLE = new Set<String>{APPROVED, PART_RECEIVED, RECEIVED};
    private static final Integer MAX_LINES = 500;
    private static final Integer MAX_REASON = 255;
    private static final String SOURCE_TYPE = 'Purchase_Order__c';

    // ------------------------------------------------------------------ DTOs

    public class LineRequest {
        @AuraEnabled public Decimal lineNumber { get; set; }
        @AuraEnabled public String description { get; set; }
        @AuraEnabled public Decimal quantity { get; set; }
        @AuraEnabled public Decimal unitPrice { get; set; }
        @AuraEnabled public Id departmentId { get; set; }
        @AuraEnabled public Id costCenterId { get; set; }
    }

    public class PurchaseOrderRequest {
        @AuraEnabled public Id purchaseOrderId { get; set; }
        @AuraEnabled public Id companyId { get; set; }
        @AuraEnabled public Id supplierProfileId { get; set; }
        @AuraEnabled public Date orderDate { get; set; }
        @AuraEnabled public String currencyCode { get; set; }
        @AuraEnabled public List<LineRequest> lines { get; set; }
    }

    public class ActionResult {
        @AuraEnabled public Id purchaseOrderId;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal total;
        @AuraEnabled public Boolean replay;
    }

    // ---------------------------------------------------------------- drafts

    @AuraEnabled
    public static Id saveDraft(PurchaseOrderRequest request) {
        SABPermissionService.assertPermission(MANAGE, 'Purchase order management permission is required.');
        if (request == null || request.companyId == null || request.supplierProfileId == null || request.orderDate == null
            || String.isBlank(request.currencyCode)) {
            throw new PurchaseOrderException('Company, supplier, order date and currency are required.');
        }
        SABCompanyAccessService.assertCompanyAccess(request.companyId);
        String currencyCode = SABMoneyService.normalizeCurrencyCode(request.currencyCode);
        List<Purchase_Order_Line__c> lines = validateLines(request.companyId, toLines(request.lines));
        assertSupplier(request.companyId, request.supplierProfileId);
        Purchase_Order__c order;
        if (request.purchaseOrderId != null) {
            authorize(request.purchaseOrderId);
            order = load(request.purchaseOrderId, true);
            if (order.Company__c != request.companyId) {
                throw new PurchaseOrderException('A purchase order cannot move to another company.');
            }
            if (order.Status__c != DRAFT) {
                throw new PurchaseOrderException('Only Draft purchase orders can be edited.');
            }
        } else {
            order = new Purchase_Order__c(Company__c = request.companyId, Status__c = DRAFT);
        }
        order.Supplier_Profile__c = request.supplierProfileId;
        order.Order_Date__c = request.orderDate;
        order.Currency__c = currencyCode;
        order.Total__c = total(lines);
        Writer writer = new Writer();
        writer.saveDraft(order, lines);
        return order.Id;
    }

    // ------------------------------------------------------------- lifecycle

    @AuraEnabled
    public static ActionResult submit(Id purchaseOrderId, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(MANAGE, 'Purchase order management permission is required.');
        Purchase_Order__c visible = authorize(purchaseOrderId);
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'PURCHASE_ORDER_SUBMITTED');
        }
        Purchase_Order__c order = load(purchaseOrderId, true);
        requireStatus(order, new Set<String>{DRAFT}, 'Only a Draft purchase order can be submitted.');
        assertSupplier(order.Company__c, order.Supplier_Profile__c);
        List<Purchase_Order_Line__c> lines = new Store().lines(order.Id);
        validateLines(order.Company__c, lines);
        order.Total__c = total(lines);
        order.Status__c = SUBMITTED;
        order.Submitted_By__c = UserInfo.getUserId();
        order.Submitted_At__c = System.now();
        return write(order, 'PURCHASE_ORDER_SUBMITTED', key, 'Purchase order submitted for approval.');
    }

    @AuraEnabled
    public static ActionResult approve(Id purchaseOrderId, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(APPROVE, 'Purchase order approval permission is required.');
        Purchase_Order__c visible = authorize(purchaseOrderId);
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'PURCHASE_ORDER_APPROVED');
        }
        Purchase_Order__c order = load(purchaseOrderId, true);
        requireStatus(order, new Set<String>{SUBMITTED}, 'Only a Submitted purchase order can be approved.');
        Id actor = UserInfo.getUserId();
        if (actor == order.CreatedById || actor == order.Submitted_By__c) {
            throw new PurchaseOrderException('The creator or submitter of a purchase order cannot approve it.');
        }
        order.Status__c = APPROVED;
        order.Approved_By__c = actor;
        order.Approved_At__c = System.now();
        return write(order, 'PURCHASE_ORDER_APPROVED', key, 'Purchase order approved.');
    }

    @AuraEnabled
    public static ActionResult returnToDraft(Id purchaseOrderId, String reason, String requestKey) {
        String key = requireKey(requestKey);
        String why = requireReason(reason);
        SABPermissionService.assertPermission(APPROVE, 'Purchase order approval permission is required.');
        Purchase_Order__c visible = authorize(purchaseOrderId);
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'PURCHASE_ORDER_RETURNED');
        }
        Purchase_Order__c order = load(purchaseOrderId, true);
        requireStatus(order, new Set<String>{SUBMITTED}, 'Only a Submitted purchase order can be returned to Draft.');
        order.Status__c = DRAFT;
        order.Submitted_By__c = null;
        order.Submitted_At__c = null;
        return write(order, 'PURCHASE_ORDER_RETURNED', key, why);
    }

    @AuraEnabled
    public static ActionResult cancel(Id purchaseOrderId, String reason, String requestKey) {
        String key = requireKey(requestKey);
        String why = requireReason(reason);
        SABPermissionService.assertPermission(MANAGE, 'Purchase order management permission is required.');
        Purchase_Order__c visible = authorize(purchaseOrderId);
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'PURCHASE_ORDER_CANCELLED');
        }
        Purchase_Order__c order = load(purchaseOrderId, true);
        requireStatus(order, new Set<String>{DRAFT, SUBMITTED, APPROVED}, 'Received, closed or cancelled purchase orders cannot be cancelled.');
        Store store = new Store();
        if (store.hasReceipts(order.Id) || store.hasBillLines(order.Id)) {
            throw new PurchaseOrderException('A purchase order with goods receipts or supplier bill lines cannot be cancelled; close it instead.');
        }
        order.Status__c = CANCELLED;
        return write(order, 'PURCHASE_ORDER_CANCELLED', key, why);
    }

    @AuraEnabled
    public static ActionResult close(Id purchaseOrderId, String reason, String requestKey) {
        String key = requireKey(requestKey);
        String why = requireReason(reason);
        SABPermissionService.assertPermission(MANAGE, 'Purchase order management permission is required.');
        Purchase_Order__c visible = authorize(purchaseOrderId);
        Business_Action__c prior = new Store().action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'PURCHASE_ORDER_CLOSED');
        }
        Purchase_Order__c order = load(purchaseOrderId, true);
        requireStatus(order, new Set<String>{APPROVED, PART_RECEIVED, RECEIVED}, 'Only an approved or received purchase order can be closed.');
        if (new Store().hasDraftReceipts(order.Id)) {
            throw new PurchaseOrderException('Accept or cancel the Draft goods receipts before closing the purchase order.');
        }
        order.Status__c = CLOSED;
        return write(order, 'PURCHASE_ORDER_CLOSED', key, why);
    }

    // ---------------------------------------------------- receipts (trusted)

    /**
     * Applies accepted (positive) or cancelled (negative) receipt quantities to an order the caller has locked,
     * and moves the order between Approved, Part Received and Received. Called only by SABGoodsReceiptService
     * after its permission, company and lock checks.
     */
    public static void applyReceipt(Id purchaseOrderId, Map<Id, Decimal> deltaByLine) {
        Store store = new Store();
        Purchase_Order__c order = store.lockOrder(purchaseOrderId);
        Map<Id, Purchase_Order_Line__c> lines = new Map<Id, Purchase_Order_Line__c>(store.lines(purchaseOrderId));
        Boolean anyReceived = false;
        Boolean allReceived = true;
        for (Purchase_Order_Line__c line : lines.values()) {
            Decimal receivedQuantity = (line.Received_Quantity__c == null ? 0 : line.Received_Quantity__c)
                + (deltaByLine.containsKey(line.Id) ? deltaByLine.get(line.Id) : 0);
            if (receivedQuantity < 0) {
                throw new PurchaseOrderException('Received quantity cannot become negative on line '
                    + line.Line_Number__c.stripTrailingZeros().toPlainString() + '.');
            }
            line.Received_Quantity__c = receivedQuantity;
            line.Remaining_Quantity__c = receivedQuantity >= line.Quantity__c ? 0 : line.Quantity__c - receivedQuantity;
            anyReceived = anyReceived || receivedQuantity > 0;
            allReceived = allReceived && receivedQuantity >= line.Quantity__c;
        }
        for (Id lineId : deltaByLine.keySet()) {
            if (!lines.containsKey(lineId)) {
                throw new PurchaseOrderException('A receipt line does not belong to its purchase order.');
            }
        }
        order.Status__c = allReceived ? RECEIVED : (anyReceived ? PART_RECEIVED : APPROVED);
        new Writer().quantities(order, lines.values());
    }

    // --------------------------------------------------------------- helpers

    private static Purchase_Order__c authorize(Id purchaseOrderId) {
        if (purchaseOrderId == null) {
            throw new PurchaseOrderException('Purchase order is required.');
        }
        List<Purchase_Order__c> visible = [SELECT Id, Company__c FROM Purchase_Order__c WHERE Id = :purchaseOrderId WITH USER_MODE];
        if (visible.isEmpty()) {
            throw new PurchaseOrderException('Purchase order not found or not accessible.');
        }
        SABCompanyAccessService.assertCompanyAccess(visible[0].Company__c);
        return visible[0];
    }

    private static Purchase_Order__c load(Id purchaseOrderId, Boolean lockRow) {
        Purchase_Order__c order = lockRow ? new Store().lockOrder(purchaseOrderId) : null;
        if (order == null) {
            throw new PurchaseOrderException('Purchase order not found.');
        }
        SABCompanyAccessService.assertCompanyAccess(order.Company__c);
        return order;
    }

    private static void requireStatus(Purchase_Order__c order, Set<String> allowed, String message) {
        if (!allowed.contains(order.Status__c)) {
            throw new PurchaseOrderException(message);
        }
    }

    private static void assertSupplier(Id companyId, Id supplierProfileId) {
        List<Party_Accounting_Profile__c> rows = [SELECT Id, Company__c, Is_Active__c, Is_Supplier__c FROM Party_Accounting_Profile__c
            WHERE Id = :supplierProfileId WITH USER_MODE];
        if (rows.isEmpty() || rows[0].Company__c != companyId || rows[0].Is_Active__c != true || rows[0].Is_Supplier__c != true) {
            throw new PurchaseOrderException('Supplier must be an active supplier profile in the purchase order company.');
        }
    }

    private static List<Purchase_Order_Line__c> toLines(List<LineRequest> requests) {
        List<Purchase_Order_Line__c> lines = new List<Purchase_Order_Line__c>();
        for (LineRequest r : requests == null ? new List<LineRequest>() : requests) {
            if (r == null) {
                throw new PurchaseOrderException('Purchase order lines cannot be empty.');
            }
            lines.add(new Purchase_Order_Line__c(Line_Number__c = r.lineNumber,
                Description__c = r.description == null ? null : r.description.trim(), Quantity__c = r.quantity,
                Unit_Price__c = r.unitPrice, Department__c = r.departmentId, Cost_Center__c = r.costCenterId));
        }
        return lines;
    }

    // Line rules shared by saveDraft and submit (direct Draft edits are re-validated at submission).
    private static List<Purchase_Order_Line__c> validateLines(Id companyId, List<Purchase_Order_Line__c> lines) {
        if (lines.isEmpty() || lines.size() > MAX_LINES) {
            throw new PurchaseOrderException('A purchase order needs between 1 and ' + MAX_LINES + ' lines.');
        }
        Set<Decimal> numbers = new Set<Decimal>();
        Set<Id> departments = new Set<Id>();
        Set<Id> costCenters = new Set<Id>();
        for (Purchase_Order_Line__c line : lines) {
            if (line.Line_Number__c == null || line.Line_Number__c <= 0 || !numbers.add(line.Line_Number__c)) {
                throw new PurchaseOrderException('Line numbers must be positive and unique.');
            }
            if (String.isBlank(line.Description__c) || line.Description__c.length() > 255) {
                throw new PurchaseOrderException('Line ' + line.Line_Number__c + ' needs a description of up to 255 characters.');
            }
            if (line.Quantity__c == null || line.Quantity__c <= 0) {
                throw new PurchaseOrderException('Line ' + line.Line_Number__c + ' quantity must be greater than zero.');
            }
            if (line.Unit_Price__c == null || line.Unit_Price__c < 0) {
                throw new PurchaseOrderException('Line ' + line.Line_Number__c + ' unit price cannot be negative.');
            }
            if (line.Department__c != null) {
                departments.add(line.Department__c);
            }
            if (line.Cost_Center__c != null) {
                costCenters.add(line.Cost_Center__c);
            }
        }
        if (!departments.isEmpty()) {
            for (Department__c d : [SELECT Id, Company__c, Is_Active__c FROM Department__c WHERE Id IN :departments WITH USER_MODE]) {
                if (d.Company__c != companyId || d.Is_Active__c != true) {
                    throw new PurchaseOrderException('Departments must be active and belong to the purchase order company.');
                }
                departments.remove(d.Id);
            }
        }
        if (!costCenters.isEmpty()) {
            for (Cost_Center__c c : [SELECT Id, Company__c, Is_Active__c FROM Cost_Center__c WHERE Id IN :costCenters WITH USER_MODE]) {
                if (c.Company__c != companyId || c.Is_Active__c != true) {
                    throw new PurchaseOrderException('Cost centers must be active and belong to the purchase order company.');
                }
                costCenters.remove(c.Id);
            }
        }
        if (!departments.isEmpty() || !costCenters.isEmpty()) {
            throw new PurchaseOrderException('A department or cost center was not found or is not accessible.');
        }
        return lines;
    }

    private static Decimal total(List<Purchase_Order_Line__c> lines) {
        Decimal sum = 0;
        for (Purchase_Order_Line__c line : lines) {
            sum += (line.Quantity__c * line.Unit_Price__c).setScale(4, RoundingMode.HALF_UP);
        }
        return sum;
    }

    private static String requireKey(String requestKey) {
        Integer maxLength = Business_Action__c.Request_Key__c.getDescribe().getLength();
        if (String.isBlank(requestKey) || requestKey.trim().length() > maxLength) {
            throw new PurchaseOrderException('Request key is required and must not exceed ' + maxLength + ' characters.');
        }
        return requestKey.trim();
    }

    private static String requireReason(String reason) {
        if (String.isBlank(reason) || reason.trim().length() > MAX_REASON) {
            throw new PurchaseOrderException('A reason of up to ' + MAX_REASON + ' characters is required.');
        }
        return reason.trim();
    }

    private static ActionResult replay(Business_Action__c prior, Id purchaseOrderId, String expectedAction) {
        if (prior.Action__c != expectedAction || prior.Source_Record_Id__c != String.valueOf(purchaseOrderId)) {
            throw new PurchaseOrderException('Request key has already been used for a different purchasing action.');
        }
        Purchase_Order__c order = new Store().lockOrder(purchaseOrderId);
        return result(order, true);
    }

    private static ActionResult write(Purchase_Order__c order, String actionName, String key, String reason) {
        new Writer().lifecycle(order, new Business_Action__c(Company__c = order.Company__c, Action__c = actionName,
            Actor__c = UserInfo.getUserId(), Action_At__c = System.now(), Reason__c = reason, Request_Key__c = key,
            Source_Type__c = SOURCE_TYPE, Source_Record_Id__c = String.valueOf(order.Id), Source_Version__c = 1));
        return result(order, false);
    }

    private static ActionResult result(Purchase_Order__c order, Boolean isReplay) {
        ActionResult r = new ActionResult();
        r.purchaseOrderId = order.Id;
        r.status = order.Status__c;
        r.total = order.Total__c;
        r.replay = isReplay;
        return r;
    }

    /**
     * Narrow system reads after the permission and company checks. Lifecycle and integrity reads must see the
     * whole order, its lines, receipts and bill lines whatever the running user's sharing.
     */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Record_Id__c FROM Business_Action__c
                WHERE Request_Key__c = :key WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
        Purchase_Order__c lockOrder(Id purchaseOrderId) {
            List<Purchase_Order__c> rows = [SELECT Id, Company__c, Supplier_Profile__c, Order_Date__c, Currency__c, Status__c, Total__c,
                Submitted_By__c, Submitted_At__c, Approved_By__c, Approved_At__c, CreatedById FROM Purchase_Order__c
                WHERE Id = :purchaseOrderId WITH SYSTEM_MODE FOR UPDATE];
            return rows.isEmpty() ? null : rows[0];
        }
        List<Purchase_Order_Line__c> lines(Id purchaseOrderId) {
            return [SELECT Id, Line_Number__c, Description__c, Quantity__c, Unit_Price__c, Received_Quantity__c, Remaining_Quantity__c,
                Department__c, Cost_Center__c FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :purchaseOrderId
                WITH SYSTEM_MODE ORDER BY Line_Number__c LIMIT 501];
        }
        Boolean hasReceipts(Id purchaseOrderId) {
            return [SELECT COUNT() FROM Goods_Receipt__c WHERE Purchase_Order__c = :purchaseOrderId AND Status__c != 'Cancelled'
                WITH SYSTEM_MODE] > 0;
        }
        Boolean hasDraftReceipts(Id purchaseOrderId) {
            return [SELECT COUNT() FROM Goods_Receipt__c WHERE Purchase_Order__c = :purchaseOrderId AND Status__c = 'Draft'
                WITH SYSTEM_MODE] > 0;
        }
        Boolean hasBillLines(Id purchaseOrderId) {
            return [SELECT COUNT() FROM Bill_Line__c WHERE Purchase_Order_Line__r.Purchase_Order__c = :purchaseOrderId
                AND Supplier_Bill__r.Status__c != 'Cancelled' WITH SYSTEM_MODE] > 0;
        }
    }

    /** Narrow system writes inside the purchasing guard scope, after the service's checks. */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void saveDraft(Purchase_Order__c order, List<Purchase_Order_Line__c> lines) {
            SABPurchasingGuard.beginWrite();
            try {
                upsert order;
                delete [SELECT Id FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :order.Id WITH SYSTEM_MODE];
                for (Purchase_Order_Line__c line : lines) {
                    line.Purchase_Order__c = order.Id;
                    line.Received_Quantity__c = 0;
                    line.Remaining_Quantity__c = line.Quantity__c;
                }
                insert lines;
            } finally {
                SABPurchasingGuard.endWrite();
            }
        }
        void lifecycle(Purchase_Order__c order, Business_Action__c audit) {
            SABPurchasingGuard.beginWrite();
            try {
                update new Purchase_Order__c(Id = order.Id, Status__c = order.Status__c, Total__c = order.Total__c,
                    Submitted_By__c = order.Submitted_By__c, Submitted_At__c = order.Submitted_At__c,
                    Approved_By__c = order.Approved_By__c, Approved_At__c = order.Approved_At__c);
                insert audit;
            } finally {
                SABPurchasingGuard.endWrite();
            }
        }
        void quantities(Purchase_Order__c order, List<Purchase_Order_Line__c> lines) {
            SABPurchasingGuard.beginWrite();
            try {
                update lines;
                update new Purchase_Order__c(Id = order.Id, Status__c = order.Status__c);
            } finally {
                SABPurchasingGuard.endWrite();
            }
        }
    }
}
