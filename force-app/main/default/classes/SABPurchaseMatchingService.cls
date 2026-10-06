/**
 * G12: matching of supplier bill lines to purchase orders and goods receipts (two- and three-way match).
 *
 * Called from SABSupplierBillService validation on Submit and Approve, so a mismatched bill cannot be approved
 * or posted. For each bill line that references a purchase order line:
 *   - the order belongs to the bill's company and supplier, uses the bill currency and is open for billing;
 *   - quantity is positive and the unit price is within the price tolerance of the order price;
 *   - quantity billed on live bills (Submitted, Approved, Posted) stays within ordered quantity + tolerance;
 *   - with a receipt requirement (default), billed quantity stays within received quantity + tolerance;
 *   - a referenced goods receipt line is Accepted, belongs to the same order line, and is not over-billed.
 * Supplier credits are checked for consistency only and reduce the billed quantity.
 *
 * Tolerances come from SAB_Purchase_Match_Policy__mdt (company key or blank default). With no record the
 * policy is strict: 0% price and quantity tolerance, goods receipt required.
 */
public with sharing class SABPurchaseMatchingService {
    public class MatchingException extends Exception {}

    private static final String CREDIT = 'Supplier Credit';
    private static final Set<String> LIVE_BILLS = new Set<String>{'Submitted', 'Approved', 'Posted'};

    // Test seam: custom metadata cannot be inserted in tests.
    @TestVisible private static List<SAB_Purchase_Match_Policy__mdt> policyOverride;

    public class MatchPolicy {
        public Decimal priceTolerancePercent = 0;
        public Decimal quantityTolerancePercent = 0;
        public Boolean requireGoodsReceipt = true;
    }

    /** Company-specific active policy, else the blank-key default, else the strict built-in policy. */
    public static MatchPolicy policyFor(String companyKey) {
        SAB_Purchase_Match_Policy__mdt companyRow;
        SAB_Purchase_Match_Policy__mdt defaultRow;
        for (SAB_Purchase_Match_Policy__mdt row : policyOverride != null ? policyOverride : SAB_Purchase_Match_Policy__mdt.getAll().values()) {
            if (row.Is_Active__c != true) {
                continue;
            }
            if (String.isBlank(row.Company_Key__c)) {
                defaultRow = pick(defaultRow, row);
            } else if (row.Company_Key__c == companyKey) {
                companyRow = pick(companyRow, row);
            }
        }
        SAB_Purchase_Match_Policy__mdt chosen = companyRow != null ? companyRow : defaultRow;
        MatchPolicy policy = new MatchPolicy();
        if (chosen != null) {
            policy.priceTolerancePercent = percent(chosen.Price_Tolerance_Percent__c, 'price');
            policy.quantityTolerancePercent = percent(chosen.Quantity_Tolerance_Percent__c, 'quantity');
            policy.requireGoodsReceipt = chosen.Require_Goods_Receipt__c != false;
        }
        return policy;
    }

    private static SAB_Purchase_Match_Policy__mdt pick(SAB_Purchase_Match_Policy__mdt existing, SAB_Purchase_Match_Policy__mdt row) {
        if (existing != null) {
            throw new MatchingException('More than one active purchase match policy applies to the same company.');
        }
        return row;
    }

    private static Decimal percent(Decimal value, String label) {
        if (value == null) {
            return 0;
        }
        if (value < 0 || value > 100) {
            throw new MatchingException('Purchase match ' + label + ' tolerance must be between 0 and 100 percent.');
        }
        return value;
    }

    /**
     * Returns matching errors for a bill's lines (empty when nothing references purchasing). Lines and the bill
     * are already loaded by SABSupplierBillService; this runs after its permission and company checks.
     */
    public static List<String> validateBillLines(Supplier_Bill__c bill, List<Bill_Line__c> lines) {
        List<String> errors = new List<String>();
        Set<Id> orderLineIds = new Set<Id>();
        Set<Id> receiptLineIds = new Set<Id>();
        for (Bill_Line__c line : lines == null ? new List<Bill_Line__c>() : lines) {
            if (line.Purchase_Order_Line__c != null) {
                orderLineIds.add(line.Purchase_Order_Line__c);
            }
            if (line.Goods_Receipt_Line__c != null) {
                receiptLineIds.add(line.Goods_Receipt_Line__c);
                if (line.Purchase_Order_Line__c == null) {
                    errors.add(label(line) + 'a goods receipt line requires the matching purchase order line.');
                }
            }
        }
        if (orderLineIds.isEmpty()) {
            return errors;
        }
        Store store = new Store();
        Map<Id, Purchase_Order_Line__c> orderLines = new Map<Id, Purchase_Order_Line__c>(store.orderLines(orderLineIds));
        Map<Id, Goods_Receipt_Line__c> receiptLines = new Map<Id, Goods_Receipt_Line__c>(store.receiptLines(receiptLineIds));
        MatchPolicy policy = policyFor(store.companyKey(bill.Company__c));
        Map<Id, Decimal> billedByOrderLine = new Map<Id, Decimal>();
        Map<Id, Decimal> billedByReceiptLine = new Map<Id, Decimal>();
        for (Bill_Line__c other : store.otherBillLines(bill.Id, orderLineIds, receiptLineIds)) {
            Decimal signed = signedQuantity(other.Supplier_Bill__r.Document_Type__c, other.Quantity__c);
            add(billedByOrderLine, other.Purchase_Order_Line__c, signed);
            add(billedByReceiptLine, other.Goods_Receipt_Line__c, signed);
        }
        Boolean isCredit = bill.Document_Type__c == CREDIT;
        for (Bill_Line__c line : lines) {
            if (line.Purchase_Order_Line__c == null) {
                continue;
            }
            Purchase_Order_Line__c orderLine = orderLines.get(line.Purchase_Order_Line__c);
            if (orderLine == null) {
                errors.add(label(line) + 'purchase order line was not found.');
                continue;
            }
            Purchase_Order__c order = orderLine.Purchase_Order__r;
            if (order.Company__c != bill.Company__c || order.Supplier_Profile__c != bill.Supplier_Profile__c) {
                errors.add(label(line) + 'purchase order belongs to a different company or supplier.');
                continue;
            }
            if (SABMoneyService.normalizeCurrencyCode(order.Currency__c) != SABMoneyService.normalizeCurrencyCode(bill.Transaction_Currency__c)) {
                errors.add(label(line) + 'bill currency must match the purchase order currency.');
                continue;
            }
            if (!SABPurchaseOrderService.BILLABLE.contains(order.Status__c)) {
                errors.add(label(line) + 'purchase order is ' + order.Status__c + ' and cannot be billed.');
                continue;
            }
            if (line.Quantity__c == null || line.Quantity__c <= 0) {
                errors.add(label(line) + 'a purchase order matched line needs a positive quantity.');
                continue;
            }
            Goods_Receipt_Line__c receiptLine = line.Goods_Receipt_Line__c == null ? null : receiptLines.get(line.Goods_Receipt_Line__c);
            if (line.Goods_Receipt_Line__c != null && (receiptLine == null || receiptLine.Purchase_Order_Line__c != orderLine.Id
                    || receiptLine.Goods_Receipt__r.Status__c != 'Accepted')) {
                errors.add(label(line) + 'goods receipt line must be Accepted and belong to the same purchase order line.');
                continue;
            }
            Decimal signed = signedQuantity(bill.Document_Type__c, line.Quantity__c);
            add(billedByOrderLine, orderLine.Id, signed);
            add(billedByReceiptLine, line.Goods_Receipt_Line__c, signed);
            if (isCredit) {
                continue;
            }
            Decimal priceGap = (line.Unit_Price__c - orderLine.Unit_Price__c).abs();
            if (priceGap > orderLine.Unit_Price__c * policy.priceTolerancePercent / 100) {
                errors.add(label(line) + 'unit price ' + fmt(line.Unit_Price__c) + ' differs from the purchase order price '
                    + fmt(orderLine.Unit_Price__c) + ' beyond the price tolerance.');
            }
            Decimal factor = 1 + policy.quantityTolerancePercent / 100;
            Decimal billed = billedByOrderLine.get(orderLine.Id);
            if (billed > orderLine.Quantity__c * factor) {
                errors.add(label(line) + 'billed quantity ' + fmt(billed) + ' exceeds the ordered quantity ' + fmt(orderLine.Quantity__c) + '.');
            }
            Decimal received = orderLine.Received_Quantity__c == null ? 0 : orderLine.Received_Quantity__c;
            if (policy.requireGoodsReceipt && billed > received * factor) {
                errors.add(label(line) + 'billed quantity ' + fmt(billed) + ' exceeds the received quantity ' + fmt(received) + '.');
            }
            if (receiptLine != null && billedByReceiptLine.get(receiptLine.Id) > receiptLine.Accepted_Quantity__c * factor) {
                errors.add(label(line) + 'billed quantity exceeds the quantity accepted on the referenced goods receipt line.');
            }
        }
        return errors;
    }

    private static Decimal signedQuantity(String documentType, Decimal quantity) {
        Decimal q = quantity == null ? 0 : quantity;
        return documentType == CREDIT ? -q : q;
    }

    private static void add(Map<Id, Decimal> totals, Id key, Decimal value) {
        if (key != null) {
            totals.put(key, (totals.containsKey(key) ? totals.get(key) : 0) + value);
        }
    }

    private static String label(Bill_Line__c line) {
        return 'Bill Line ' + fmt(line.Line_Number__c) + ': ';
    }

    // Quantities and prices are stored with 4 decimals; show them without trailing zeros (4, not 4.0000).
    @TestVisible
    private static String fmt(Decimal value) {
        return value == null ? '' : value.stripTrailingZeros().toPlainString();
    }

    /**
     * Narrow system reads after the supplier bill service's permission and company checks. Order lines are locked
     * so two bills cannot be approved against the same quantity at once; billed totals must see every live bill.
     */
    @SuppressWarnings('PMD.ApexCRUDViolation')
    private without sharing class Store {
        List<Purchase_Order_Line__c> orderLines(Set<Id> ids) {
            return [SELECT Id, Quantity__c, Unit_Price__c, Received_Quantity__c, Purchase_Order__r.Company__c,
                Purchase_Order__r.Supplier_Profile__c, Purchase_Order__r.Currency__c, Purchase_Order__r.Status__c
                FROM Purchase_Order_Line__c WHERE Id IN :ids WITH SYSTEM_MODE FOR UPDATE];
        }
        List<Goods_Receipt_Line__c> receiptLines(Set<Id> ids) {
            if (ids.isEmpty()) {
                return new List<Goods_Receipt_Line__c>();
            }
            return [SELECT Id, Purchase_Order_Line__c, Accepted_Quantity__c, Goods_Receipt__r.Status__c FROM Goods_Receipt_Line__c
                WHERE Id IN :ids WITH SYSTEM_MODE];
        }
        List<Bill_Line__c> otherBillLines(Id billId, Set<Id> orderLineIds, Set<Id> receiptLineIds) {
            return [SELECT Purchase_Order_Line__c, Goods_Receipt_Line__c, Quantity__c, Supplier_Bill__r.Document_Type__c
                FROM Bill_Line__c WHERE Supplier_Bill__c != :billId AND Supplier_Bill__r.Status__c IN :LIVE_BILLS
                AND (Purchase_Order_Line__c IN :orderLineIds OR Goods_Receipt_Line__c IN :receiptLineIds) WITH SYSTEM_MODE LIMIT 5000];
        }
        String companyKey(Id companyId) {
            List<Accounting_Company__c> rows = [SELECT Company_Key__c FROM Accounting_Company__c WHERE Id = :companyId WITH SYSTEM_MODE];
            return rows.isEmpty() ? null : rows[0].Company_Key__c;
        }
    }
}
