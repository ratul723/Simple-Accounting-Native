/**
 * G12: Goods receipts (and service acceptance) against approved purchase orders.
 *
 *   createReceipt  SAB_Receive_Goods  Draft receipt for an Approved / Part Received purchase order
 *   acceptReceipt  SAB_Receive_Goods  Draft -> Accepted; adds received quantities to the order lines
 *   cancelReceipt  SAB_Receive_Goods  Draft or Accepted -> Cancelled; an Accepted receipt is reversed only when
 *                                     no live supplier bill line uses it
 *
 * Over-receipt beyond the purchase match policy's quantity tolerance is blocked. Receipts have no ledger
 * impact in G12; supplier bills are matched against them (three-way match) by SABPurchaseMatchingService.
 */
public with sharing class SABGoodsReceiptService {
    public class GoodsReceiptException extends Exception {}

    private static final String RECEIVE = 'SAB_Receive_Goods';
    private static final String DRAFT = 'Draft';
    private static final String ACCEPTED = 'Accepted';
    private static final String CANCELLED = 'Cancelled';
    private static final Integer MAX_LINES = 500;
    private static final String SOURCE_TYPE = 'Goods_Receipt__c';

    public class ReceiptLineRequest {
        @AuraEnabled public Id purchaseOrderLineId { get; set; }
        @AuraEnabled public Decimal acceptedQuantity { get; set; }
        @AuraEnabled public Boolean serviceAccepted { get; set; }
        @AuraEnabled public String comment { get; set; }
    }

    public class ReceiptRequest {
        @AuraEnabled public Id purchaseOrderId { get; set; }
        @AuraEnabled public Date receiptDate { get; set; }
        @AuraEnabled public List<ReceiptLineRequest> lines { get; set; }
    }

    public class ActionResult {
        @AuraEnabled public Id goodsReceiptId;
        @AuraEnabled public String status;
        @AuraEnabled public String purchaseOrderStatus;
        @AuraEnabled public Boolean replay;
    }

    @AuraEnabled
    public static Id createReceipt(ReceiptRequest request) {
        SABPermissionService.assertPermission(RECEIVE, 'Goods receiving permission is required.');
        if (request == null || request.purchaseOrderId == null || request.receiptDate == null || request.lines == null
            || request.lines.isEmpty() || request.lines.size() > MAX_LINES) {
            throw new GoodsReceiptException('Purchase order, receipt date and between 1 and ' + MAX_LINES + ' lines are required.');
        }
        Purchase_Order__c visible = visibleOrder(request.purchaseOrderId);
        Store store = new Store();
        Purchase_Order__c order = store.order(visible.Id);
        if (!SABPurchaseOrderService.RECEIVABLE.contains(order.Status__c)) {
            throw new GoodsReceiptException('Goods can be received only against an Approved or Part Received purchase order.');
        }
        if (request.receiptDate < order.Order_Date__c) {
            throw new GoodsReceiptException('Receipt date cannot be before the purchase order date.');
        }
        Set<Id> orderLines = store.lineIds(order.Id);
        Set<Id> seen = new Set<Id>();
        List<Goods_Receipt_Line__c> lines = new List<Goods_Receipt_Line__c>();
        for (ReceiptLineRequest r : request.lines) {
            if (r == null || r.purchaseOrderLineId == null || !orderLines.contains(r.purchaseOrderLineId)) {
                throw new GoodsReceiptException('Every receipt line must reference a line of the purchase order.');
            }
            if (!seen.add(r.purchaseOrderLineId)) {
                throw new GoodsReceiptException('A purchase order line can appear only once per receipt.');
            }
            if (r.acceptedQuantity == null || r.acceptedQuantity <= 0) {
                throw new GoodsReceiptException('Accepted quantity must be greater than zero.');
            }
            if (r.comment != null && r.comment.trim().length() > 255) {
                throw new GoodsReceiptException('Receipt line comments cannot exceed 255 characters.');
            }
            lines.add(new Goods_Receipt_Line__c(Purchase_Order_Line__c = r.purchaseOrderLineId, Accepted_Quantity__c = r.acceptedQuantity,
                Service_Accepted__c = r.serviceAccepted == true, Comment__c = r.comment == null ? null : r.comment.trim()));
        }
        Goods_Receipt__c receipt = new Goods_Receipt__c(Company__c = order.Company__c, Purchase_Order__c = order.Id,
            Receipt_Date__c = request.receiptDate, Status__c = DRAFT);
        new Writer().create(receipt, lines);
        return receipt.Id;
    }

    @AuraEnabled
    public static ActionResult acceptReceipt(Id goodsReceiptId, String requestKey) {
        String key = requireKey(requestKey);
        SABPermissionService.assertPermission(RECEIVE, 'Goods receiving permission is required.');
        Goods_Receipt__c visible = visibleReceipt(goodsReceiptId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'GOODS_RECEIPT_ACCEPTED');
        }
        Purchase_Order__c order = store.lockOrder(visible.Purchase_Order__c);
        Goods_Receipt__c receipt = store.lockReceipt(visible.Id);
        if (receipt.Status__c != DRAFT) {
            throw new GoodsReceiptException('Only a Draft goods receipt can be accepted.');
        }
        if (!SABPurchaseOrderService.RECEIVABLE.contains(order.Status__c)) {
            throw new GoodsReceiptException('The purchase order is no longer open for receiving.');
        }
        List<Goods_Receipt_Line__c> lines = store.receiptLines(receipt.Id);
        if (lines.isEmpty()) {
            throw new GoodsReceiptException('A goods receipt needs at least one line.');
        }
        SABPurchaseMatchingService.MatchPolicy policy = SABPurchaseMatchingService.policyFor(store.companyKey(order.Company__c));
        Map<Id, Purchase_Order_Line__c> orderLines = new Map<Id, Purchase_Order_Line__c>(store.orderLines(order.Id));
        Map<Id, Decimal> deltas = new Map<Id, Decimal>();
        for (Goods_Receipt_Line__c line : lines) {
            Purchase_Order_Line__c orderLine = orderLines.get(line.Purchase_Order_Line__c);
            if (orderLine == null || line.Accepted_Quantity__c == null || line.Accepted_Quantity__c <= 0) {
                throw new GoodsReceiptException('Receipt lines must reference the purchase order and accept a positive quantity.');
            }
            Decimal received = (orderLine.Received_Quantity__c == null ? 0 : orderLine.Received_Quantity__c) + line.Accepted_Quantity__c;
            Decimal limitQuantity = orderLine.Quantity__c * (1 + policy.quantityTolerancePercent / 100);
            if (received > limitQuantity) {
                throw new GoodsReceiptException('Line ' + orderLine.Line_Number__c.stripTrailingZeros().toPlainString() + ' would receive '
                    + received.stripTrailingZeros().toPlainString() + ' against ' + orderLine.Quantity__c.stripTrailingZeros().toPlainString()
                    + ' ordered, beyond the quantity tolerance.');
            }
            deltas.put(orderLine.Id, (deltas.containsKey(orderLine.Id) ? deltas.get(orderLine.Id) : 0) + line.Accepted_Quantity__c);
        }
        return lifecycle(order, receipt, deltas, ACCEPTED, 'GOODS_RECEIPT_ACCEPTED', key, 'Goods receipt accepted.');
    }

    @AuraEnabled
    public static ActionResult cancelReceipt(Id goodsReceiptId, String reason, String requestKey) {
        String key = requireKey(requestKey);
        if (String.isBlank(reason) || reason.trim().length() > 255) {
            throw new GoodsReceiptException('A reason of up to 255 characters is required.');
        }
        SABPermissionService.assertPermission(RECEIVE, 'Goods receiving permission is required.');
        Goods_Receipt__c visible = visibleReceipt(goodsReceiptId);
        Store store = new Store();
        Business_Action__c prior = store.action(key);
        if (prior != null) {
            return replay(prior, visible.Id, 'GOODS_RECEIPT_CANCELLED');
        }
        Purchase_Order__c order = store.lockOrder(visible.Purchase_Order__c);
        Goods_Receipt__c receipt = store.lockReceipt(visible.Id);
        Map<Id, Decimal> deltas = new Map<Id, Decimal>();
        if (receipt.Status__c == ACCEPTED) {
            if (store.billedReceiptLines(receipt.Id)) {
                throw new GoodsReceiptException('This goods receipt is matched to a supplier bill and cannot be cancelled.');
            }
            if (order.Status__c == SABPurchaseOrderService.CLOSED) {
                throw new GoodsReceiptException('Receipts of a closed purchase order cannot be cancelled.');
            }
            for (Goods_Receipt_Line__c line : store.receiptLines(receipt.Id)) {
                deltas.put(line.Purchase_Order_Line__c, (deltas.containsKey(line.Purchase_Order_Line__c)
                    ? deltas.get(line.Purchase_Order_Line__c) : 0) - line.Accepted_Quantity__c);
            }
        } else if (receipt.Status__c != DRAFT) {
            throw new GoodsReceiptException('Only a Draft or Accepted goods receipt can be cancelled.');
        }
        return lifecycle(order, receipt, deltas, CANCELLED, 'GOODS_RECEIPT_CANCELLED', key, reason.trim());
    }

    // --------------------------------------------------------------- helpers

    private static Purchase_Order__c visibleOrder(Id purchaseOrderId) {
        List<Purchase_Order__c> rows = [SELECT Id, Company__c FROM Purchase_Order__c WHERE Id = :purchaseOrderId WITH USER_MODE];
        if (rows.isEmpty()) {
            throw new GoodsReceiptException('Purchase order not found or not accessible.');
        }
        SABCompanyAccessService.assertCompanyAccess(rows[0].Company__c);
        return rows[0];
    }

    private static Goods_Receipt__c visibleReceipt(Id goodsReceiptId) {
        if (goodsReceiptId == null) {
            throw new GoodsReceiptException('Goods receipt is required.');
        }
        List<Goods_Receipt__c> rows = [SELECT Id, Company__c, Purchase_Order__c FROM Goods_Receipt__c WHERE Id = :goodsReceiptId
            WITH USER_MODE];
        if (rows.isEmpty()) {
            throw new GoodsReceiptException('Goods receipt not found or not accessible.');
        }
        SABCompanyAccessService.assertCompanyAccess(rows[0].Company__c);
        return rows[0];
    }

    private static ActionResult lifecycle(Purchase_Order__c order, Goods_Receipt__c receipt, Map<Id, Decimal> deltas, String newStatus,
            String actionName, String key, String reason) {
        Savepoint sp = Database.setSavepoint();
        try {
            if (!deltas.isEmpty()) {
                SABPurchaseOrderService.applyReceipt(order.Id, deltas);
            }
            receipt.Status__c = newStatus;
            if (newStatus == ACCEPTED) {
                receipt.Accepted_By__c = UserInfo.getUserId();
                receipt.Accepted_At__c = System.now();
            }
            new Writer().lifecycle(receipt, new Business_Action__c(Company__c = receipt.Company__c, Action__c = actionName,
                Actor__c = UserInfo.getUserId(), Action_At__c = System.now(), Reason__c = reason, Request_Key__c = key,
                Source_Type__c = SOURCE_TYPE, Source_Record_Id__c = String.valueOf(receipt.Id), Source_Version__c = 1));
        } catch (Exception ex) {
            Database.rollback(sp);
            throw ex;
        }
        return result(receipt.Id, newStatus, new Store().order(order.Id).Status__c, false);
    }

    private static ActionResult replay(Business_Action__c prior, Id receiptId, String expectedAction) {
        if (prior.Action__c != expectedAction || prior.Source_Record_Id__c != String.valueOf(receiptId)) {
            throw new GoodsReceiptException('Request key has already been used for a different receiving action.');
        }
        Store store = new Store();
        Goods_Receipt__c receipt = store.lockReceipt(receiptId);
        return result(receipt.Id, receipt.Status__c, store.order(receipt.Purchase_Order__c).Status__c, true);
    }

    private static ActionResult result(Id receiptId, String status, String orderStatus, Boolean isReplay) {
        ActionResult r = new ActionResult();
        r.goodsReceiptId = receiptId;
        r.status = status;
        r.purchaseOrderStatus = orderStatus;
        r.replay = isReplay;
        return r;
    }

    private static String requireKey(String requestKey) {
        Integer maxLength = Business_Action__c.Request_Key__c.getDescribe().getLength();
        if (String.isBlank(requestKey) || requestKey.trim().length() > maxLength) {
            throw new GoodsReceiptException('Request key is required and must not exceed ' + maxLength + ' characters.');
        }
        return requestKey.trim();
    }

    /** Narrow system reads after the permission and company checks; receipts, lines and bills are read completely. */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Business_Action__c action(String key) {
            List<Business_Action__c> rows = [SELECT Id, Action__c, Source_Record_Id__c FROM Business_Action__c
                WHERE Request_Key__c = :key WITH SYSTEM_MODE LIMIT 1];
            return rows.isEmpty() ? null : rows[0];
        }
        Purchase_Order__c order(Id purchaseOrderId) {
            return [SELECT Id, Company__c, Status__c, Order_Date__c FROM Purchase_Order__c WHERE Id = :purchaseOrderId WITH SYSTEM_MODE];
        }
        Purchase_Order__c lockOrder(Id purchaseOrderId) {
            return [SELECT Id, Company__c, Status__c, Order_Date__c FROM Purchase_Order__c WHERE Id = :purchaseOrderId
                WITH SYSTEM_MODE FOR UPDATE];
        }
        Goods_Receipt__c lockReceipt(Id receiptId) {
            return [SELECT Id, Company__c, Purchase_Order__c, Status__c, Accepted_By__c, Accepted_At__c FROM Goods_Receipt__c
                WHERE Id = :receiptId WITH SYSTEM_MODE FOR UPDATE];
        }
        Set<Id> lineIds(Id purchaseOrderId) {
            return new Map<Id, Purchase_Order_Line__c>([SELECT Id FROM Purchase_Order_Line__c WHERE Purchase_Order__c = :purchaseOrderId
                WITH SYSTEM_MODE LIMIT 501]).keySet();
        }
        List<Purchase_Order_Line__c> orderLines(Id purchaseOrderId) {
            return [SELECT Id, Line_Number__c, Quantity__c, Received_Quantity__c FROM Purchase_Order_Line__c
                WHERE Purchase_Order__c = :purchaseOrderId WITH SYSTEM_MODE LIMIT 501];
        }
        List<Goods_Receipt_Line__c> receiptLines(Id receiptId) {
            return [SELECT Id, Purchase_Order_Line__c, Accepted_Quantity__c FROM Goods_Receipt_Line__c WHERE Goods_Receipt__c = :receiptId
                WITH SYSTEM_MODE LIMIT 501];
        }
        Boolean billedReceiptLines(Id receiptId) {
            return [SELECT COUNT() FROM Bill_Line__c WHERE Goods_Receipt_Line__r.Goods_Receipt__c = :receiptId
                AND Supplier_Bill__r.Status__c != 'Cancelled' WITH SYSTEM_MODE] > 0;
        }
        String companyKey(Id companyId) {
            return [SELECT Company_Key__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE].Company_Key__c;
        }
    }

    /** Narrow system writes inside the purchasing guard scope. */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Writer {
        void create(Goods_Receipt__c receipt, List<Goods_Receipt_Line__c> lines) {
            SABPurchasingGuard.beginWrite();
            try {
                insert receipt;
                for (Goods_Receipt_Line__c line : lines) {
                    line.Goods_Receipt__c = receipt.Id;
                }
                insert lines;
            } finally {
                SABPurchasingGuard.endWrite();
            }
        }
        void lifecycle(Goods_Receipt__c receipt, Business_Action__c audit) {
            SABPurchasingGuard.beginWrite();
            try {
                update new Goods_Receipt__c(Id = receipt.Id, Status__c = receipt.Status__c, Accepted_By__c = receipt.Accepted_By__c,
                    Accepted_At__c = receipt.Accepted_At__c);
                insert audit;
            } finally {
                SABPurchasingGuard.endWrite();
            }
        }
    }
}
