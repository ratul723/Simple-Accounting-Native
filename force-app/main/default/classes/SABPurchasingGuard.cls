/**
 * G12: guard for purchase orders, purchase order lines, goods receipts and goods receipt lines.
 *
 * Outside the purchasing services' write scope:
 *  - Purchase orders and receipts may be inserted only as Draft, edited only while Draft (status, approval and
 *    acceptance fields never), and deleted only while Draft.
 *  - Lines may change only while their parent is Draft; received and remaining quantities never change directly.
 * The services re-validate everything on submit/accept, so direct Draft edits cannot bypass business rules.
 */
public with sharing class SABPurchasingGuard {
    private static final String DRAFT = 'Draft';
    private static Integer scopeDepth = 0;

    /** Opened only by SABPurchaseOrderService and SABGoodsReceiptService around their own writes. */
    public static void beginWrite() {
        scopeDepth++;
    }

    public static void endWrite() {
        scopeDepth = scopeDepth > 0 ? scopeDepth - 1 : 0;
    }

    public static Boolean inWriteScope() {
        return scopeDepth > 0;
    }

    public static void guardPurchaseOrders(List<Purchase_Order__c> rows, Map<Id, Purchase_Order__c> oldMap, Boolean isDelete) {
        // Status is not required and has no picklist default: a new order without one starts as Draft.
        if (!isDelete && oldMap == null) {
            for (Purchase_Order__c row : rows) {
                row.Status__c = row.Status__c == null ? DRAFT : row.Status__c;
            }
        }
        if (inWriteScope()) {
            return;
        }
        for (Purchase_Order__c row : rows) {
            Purchase_Order__c old = oldMap == null ? null : oldMap.get(row.Id);
            String message;
            if (isDelete) {
                message = row.Status__c == DRAFT ? null : 'Only Draft purchase orders can be deleted.';
            } else if (old == null) {
                message = row.Status__c != DRAFT || row.Submitted_By__c != null || row.Approved_By__c != null
                    ? 'Purchase orders start as Draft; submit and approve them through the purchasing service.' : null;
            } else if (old.Status__c != DRAFT) {
                message = 'Only Draft purchase orders can be edited; use the purchasing service for lifecycle changes.';
            } else if (row.Status__c != old.Status__c || row.Submitted_By__c != old.Submitted_By__c || row.Approved_By__c != old.Approved_By__c
                    || row.Submitted_At__c != old.Submitted_At__c || row.Approved_At__c != old.Approved_At__c) {
                message = 'Purchase order status and approval fields change only through the purchasing service.';
            }
            if (message != null) {
                row.addError(message);
            }
        }
    }

    public static void guardPurchaseOrderLines(List<Purchase_Order_Line__c> rows, Map<Id, Purchase_Order_Line__c> oldMap) {
        if (inWriteScope()) {
            return;
        }
        Set<Id> parentIds = new Set<Id>();
        for (Purchase_Order_Line__c row : rows) {
            parentIds.add(row.Purchase_Order__c);
        }
        Map<Id, String> statuses = new Store().purchaseOrderStatuses(parentIds);
        for (Purchase_Order_Line__c row : rows) {
            Purchase_Order_Line__c old = oldMap == null ? null : oldMap.get(row.Id);
            Boolean quantitiesTouched = old == null
                ? (nz(row.Received_Quantity__c) != 0)
                : (row.Received_Quantity__c != old.Received_Quantity__c || row.Remaining_Quantity__c != old.Remaining_Quantity__c);
            if (statuses.get(row.Purchase_Order__c) != DRAFT) {
                row.addError('Purchase order lines can change only while the purchase order is Draft.');
            } else if (quantitiesTouched) {
                row.addError('Received and remaining quantities are maintained by goods receipts.');
            }
        }
    }

    public static void guardGoodsReceipts(List<Goods_Receipt__c> rows, Map<Id, Goods_Receipt__c> oldMap, Boolean isDelete) {
        // Status is not required and has no picklist default: a new receipt without one starts as Draft.
        if (!isDelete && oldMap == null) {
            for (Goods_Receipt__c row : rows) {
                row.Status__c = row.Status__c == null ? DRAFT : row.Status__c;
            }
        }
        if (inWriteScope()) {
            return;
        }
        for (Goods_Receipt__c row : rows) {
            Goods_Receipt__c old = oldMap == null ? null : oldMap.get(row.Id);
            String message;
            if (isDelete) {
                message = row.Status__c == DRAFT ? null : 'Only Draft goods receipts can be deleted.';
            } else if (old == null) {
                message = row.Status__c != DRAFT || row.Accepted_By__c != null || row.Accepted_At__c != null
                    ? 'Goods receipts start as Draft; accept them through the receiving service.' : null;
            } else if (old.Status__c != DRAFT) {
                message = 'Only Draft goods receipts can be edited; use the receiving service to accept or cancel.';
            } else if (row.Status__c != old.Status__c || row.Accepted_By__c != old.Accepted_By__c || row.Accepted_At__c != old.Accepted_At__c
                    || row.Purchase_Order__c != old.Purchase_Order__c) {
                message = 'Goods receipt status, acceptance and purchase order change only through the receiving service.';
            }
            if (message != null) {
                row.addError(message);
            }
        }
    }

    public static void guardGoodsReceiptLines(List<Goods_Receipt_Line__c> rows) {
        if (inWriteScope()) {
            return;
        }
        Set<Id> parentIds = new Set<Id>();
        for (Goods_Receipt_Line__c row : rows) {
            parentIds.add(row.Goods_Receipt__c);
        }
        Map<Id, String> statuses = new Store().receiptStatuses(parentIds);
        for (Goods_Receipt_Line__c row : rows) {
            if (statuses.get(row.Goods_Receipt__c) != DRAFT) {
                row.addError('Goods receipt lines can change only while the goods receipt is Draft.');
            }
        }
    }

    private static Decimal nz(Decimal value) {
        return value == null ? 0 : value;
    }

    // Parent statuses must be read completely, whatever the running user's sharing, so a guard cannot be bypassed.
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        Map<Id, String> purchaseOrderStatuses(Set<Id> ids) {
            Map<Id, String> result = new Map<Id, String>();
            for (Purchase_Order__c row : [SELECT Id, Status__c FROM Purchase_Order__c WHERE Id IN :ids WITH SYSTEM_MODE]) {
                result.put(row.Id, row.Status__c);
            }
            return result;
        }
        Map<Id, String> receiptStatuses(Set<Id> ids) {
            Map<Id, String> result = new Map<Id, String>();
            for (Goods_Receipt__c row : [SELECT Id, Status__c FROM Goods_Receipt__c WHERE Id IN :ids WITH SYSTEM_MODE]) {
                result.put(row.Id, row.Status__c);
            }
            return result;
        }
    }
}
