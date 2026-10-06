/**
 * G10I: payroll rules for proration, formula pay and statutory deductions.
 *
 * Pure calculation with no DML. SABPayrollCalculationService decides eligibility and ordering:
 *   fixed (prorated) -> formula -> benefit awards (G10F) -> statutory.
 *
 * Proration: calendar days. factor = covered days / period days.
 *
 * Formula parameters (Employee_Pay_Component__c.Formula_Parameter_JSON__c), strict JSON:
 *   {"type":"PERCENT_OF","percent":40,"basis":["Basic Salary"],"cap":5000,"floor":0}
 *   {"type":"DAILY_RATE","rate":450,"cap":12000}
 *   {"type":"FIXED","prorate":false}          uses the assignment Amount without proration
 * PERCENT_OF uses the employee's fixed (non-formula) component totals for this run, after proration.
 *
 * Statutory rules (SAB_Statutory_Rule__mdt, keyed by Pay_Component__c.Country_Rule_Key__c):
 *   Rate         basis x Rate_Percent / 100
 *   Capped_Rate  min(basis, Basis_Ceiling) x Rate_Percent / 100, then Amount_Cap
 *   Slab         progressive bands [[upTo, ratePercent], ..., [null, ratePercent]], then Amount_Cap
 * Basis: the listed Basis_Categories (default: all gross categories) after formulas and awards.
 */
public with sharing class SABPayrollRuleEngine {
    public class RuleException extends Exception {}

    public static final String RULE_FIXED = 'G10B_FIXED_V1';
    public static final String RULE_PRORATED = 'G10I_PRORATED_V1';
    public static final String RULE_FORMULA = 'G10I_FORMULA_V1';
    public static final String RULE_STATUTORY = 'G10I_STATUTORY_V1';

    public static final Set<String> GROSS_CATEGORIES = new Set<String>{'Basic Salary', 'Incentive', 'Food Allowance', 'Other'};
    public static final Set<String> ALL_CATEGORIES = new Set<String>{'Basic Salary', 'Incentive', 'Food Allowance', 'Other',
        'Deduction', 'Employer Contribution'};

    private static final Set<String> FORMULA_TYPES = new Set<String>{'PERCENT_OF', 'DAILY_RATE', 'FIXED'};
    private static final Map<String, Set<String>> FORMULA_KEYS = new Map<String, Set<String>>{
        'PERCENT_OF' => new Set<String>{'type', 'percent', 'basis', 'cap', 'floor'},
        'DAILY_RATE' => new Set<String>{'type', 'rate', 'cap', 'floor'},
        'FIXED' => new Set<String>{'type', 'prorate', 'cap', 'floor'}};
    private static final Integer CALC_SCALE = 10;

    // Test seam: statutory rules supplied in memory (custom metadata cannot be inserted in tests).
    @TestVisible private static List<SAB_Statutory_Rule__mdt> ruleOverride;

    // ------------------------------------------------------------- proration

    public class Window {
        public Date startDate;
        public Date endDate;
        public Integer days;
    }

    /** Inclusive overlap of two date ranges; a null end means open-ended. Returns null when they do not overlap. */
    public static Window overlap(Date startA, Date endA, Date startB, Date endB) {
        if (startA == null || startB == null) {
            throw new RuleException('Proration requires start dates.');
        }
        Date s = startA > startB ? startA : startB;
        Date e = endA == null ? endB : (endB == null ? endA : (endA < endB ? endA : endB));
        if (e == null || s > e) {
            return null;
        }
        Window w = new Window();
        w.startDate = s;
        w.endDate = e;
        w.days = s.daysBetween(e) + 1;
        return w;
    }

    public static Integer periodDays(Date starts, Date ends) {
        return starts.daysBetween(ends) + 1;
    }

    public static Decimal prorate(Decimal amount, Integer coveredDays, Integer totalDays) {
        if (amount == null || coveredDays == null || totalDays == null || totalDays <= 0 || coveredDays < 0 || coveredDays > totalDays) {
            throw new RuleException('Proration inputs are invalid.');
        }
        if (coveredDays == totalDays) {
            return amount;
        }
        return (amount * coveredDays / totalDays).setScale(CALC_SCALE, RoundingMode.HALF_UP);
    }

    // --------------------------------------------------------------- formula

    public class Formula {
        public String type;
        public Decimal percent;
        public List<String> basis;
        public Decimal rate;
        public Boolean prorate;
        public Decimal cap;
        public Decimal floor;
    }

    /** Strict parse: unknown types, unknown keys, missing or negative values are rejected. */
    public static Formula parseFormula(String formulaJson) {
        Map<String, Object> raw;
        try {
            Object parsed = System.JSON.deserializeUntyped(formulaJson);
            raw = (Map<String, Object>) parsed;
        } catch (Exception ex) {
            throw new RuleException('Compensation formula must be a JSON object.');
        }
        if (raw == null || !(raw.get('type') instanceof String) || !FORMULA_TYPES.contains((String) raw.get('type'))) {
            throw new RuleException('Compensation formula type must be PERCENT_OF, DAILY_RATE or FIXED.');
        }
        Formula f = new Formula();
        f.type = (String) raw.get('type');
        for (String key : raw.keySet()) {
            if (!FORMULA_KEYS.get(f.type).contains(key)) {
                throw new RuleException('Compensation formula ' + f.type + ' does not support "' + key + '".');
            }
        }
        f.cap = optionalNumber(raw, 'cap');
        f.floor = optionalNumber(raw, 'floor');
        if (f.cap != null && f.floor != null && f.floor > f.cap) {
            throw new RuleException('Compensation formula floor cannot exceed its cap.');
        }
        if (f.type == 'PERCENT_OF') {
            f.percent = requiredNumber(raw, 'percent');
            if (f.percent > 1000) {
                throw new RuleException('Compensation formula percent must not exceed 1000.');
            }
            if (!(raw.get('basis') instanceof List<Object>) || ((List<Object>) raw.get('basis')).isEmpty()) {
                throw new RuleException('Compensation formula PERCENT_OF needs a non-empty basis category list.');
            }
            f.basis = new List<String>();
            for (Object item : (List<Object>) raw.get('basis')) {
                if (!(item instanceof String) || !ALL_CATEGORIES.contains((String) item)) {
                    throw new RuleException('Compensation formula basis must list valid pay component categories.');
                }
                f.basis.add((String) item);
            }
        } else if (f.type == 'DAILY_RATE') {
            f.rate = requiredNumber(raw, 'rate');
        } else {
            Object prorateValue = raw.get('prorate');
            if (!(prorateValue instanceof Boolean)) {
                throw new RuleException('Compensation formula FIXED needs "prorate": true or false.');
            }
            f.prorate = (Boolean) prorateValue;
        }
        return f;
    }

    /**
     * Evaluates a formula. fixedTotals are the employee's fixed component amounts by category for this run
     * (already prorated); assignmentAmount is the compensation Amount__c (used by FIXED).
     */
    public static Decimal evaluateFormula(Formula f, Decimal assignmentAmount, Map<String, Decimal> fixedTotals,
            Integer coveredDays, Integer totalDays) {
        Decimal result;
        if (f.type == 'PERCENT_OF') {
            Decimal basis = 0;
            for (String category : f.basis) {
                basis += fixedTotals.containsKey(category) ? fixedTotals.get(category) : 0;
            }
            result = basis * f.percent / 100;
        } else if (f.type == 'DAILY_RATE') {
            result = f.rate * coveredDays;
        } else {
            if (assignmentAmount == null || assignmentAmount < 0) {
                throw new RuleException('Compensation formula FIXED needs a non-negative amount.');
            }
            result = f.prorate ? prorate(assignmentAmount, coveredDays, totalDays) : assignmentAmount;
        }
        return bound(result, f.floor, f.cap);
    }

    // ------------------------------------------------------------- statutory

    public class StatutoryRule {
        public String ruleKey;
        public String ruleVersion;
        public String method;
        public Decimal ratePercent;
        public Decimal basisCeiling;
        public Decimal amountCap;
        public Set<String> basisCategories;
        public List<List<Decimal>> bands;
    }

    /** The single active rule for the key, country and date. Reads custom metadata without SOQL. */
    public static StatutoryRule ruleFor(String ruleKey, String countryCode, Date asOf) {
        List<SAB_Statutory_Rule__mdt> candidates = new List<SAB_Statutory_Rule__mdt>();
        for (SAB_Statutory_Rule__mdt row : ruleOverride != null ? ruleOverride : SAB_Statutory_Rule__mdt.getAll().values()) {
            if (row.Is_Active__c == true && row.Rule_Key__c == ruleKey
                && (String.isBlank(row.Country_Code__c) || row.Country_Code__c == countryCode)
                && row.Effective_From__c != null && row.Effective_From__c <= asOf
                && (row.Effective_To__c == null || row.Effective_To__c >= asOf)) {
                candidates.add(row);
            }
        }
        if (candidates.isEmpty()) {
            throw new RuleException('No active statutory rule "' + ruleKey + '" is effective on ' + String.valueOf(asOf)
                + (String.isBlank(countryCode) ? '.' : ' for country ' + countryCode + '.'));
        }
        if (candidates.size() > 1) {
            throw new RuleException('More than one active statutory rule "' + ruleKey + '" is effective on ' + String.valueOf(asOf) + '.');
        }
        return toRule(candidates[0]);
    }

    @TestVisible
    private static StatutoryRule toRule(SAB_Statutory_Rule__mdt row) {
        StatutoryRule r = new StatutoryRule();
        r.ruleKey = row.Rule_Key__c;
        r.ruleVersion = row.Rule_Version__c;
        r.method = row.Method__c;
        r.ratePercent = row.Rate_Percent__c;
        r.basisCeiling = row.Basis_Ceiling__c;
        r.amountCap = row.Amount_Cap__c;
        r.basisCategories = new Set<String>();
        if (String.isBlank(row.Basis_Categories__c)) {
            r.basisCategories.addAll(GROSS_CATEGORIES);
        } else {
            for (String category : row.Basis_Categories__c.split(';')) {
                String trimmed = category.trim();
                if (!ALL_CATEGORIES.contains(trimmed)) {
                    throw new RuleException('Statutory rule ' + r.ruleKey + ' lists an unknown basis category "' + trimmed + '".');
                }
                r.basisCategories.add(trimmed);
            }
        }
        if (String.isBlank(r.ruleVersion)) {
            throw new RuleException('Statutory rule ' + r.ruleKey + ' needs a rule version.');
        }
        if (r.method == 'Rate' || r.method == 'Capped_Rate') {
            if (r.ratePercent == null || r.ratePercent < 0 || r.ratePercent > 100) {
                throw new RuleException('Statutory rule ' + r.ruleKey + ' needs a rate between 0 and 100.');
            }
        } else if (r.method == 'Slab') {
            r.bands = parseBands(row.Bands__c, r.ruleKey);
        } else {
            throw new RuleException('Statutory rule ' + r.ruleKey + ' has an unsupported method.');
        }
        return r;
    }

    private static List<List<Decimal>> parseBands(String bandsJson, String ruleKey) {
        List<List<Decimal>> bands = new List<List<Decimal>>();
        try {
            for (Object item : (List<Object>) System.JSON.deserializeUntyped(bandsJson)) {
                List<Object> pair = (List<Object>) item;
                bands.add(new List<Decimal>{pair[0] == null ? null : toDecimal(pair[0]), toDecimal(pair[1])});
            }
        } catch (Exception ex) {
            throw new RuleException('Statutory rule ' + ruleKey + ' bands must be [[upTo, ratePercent], ..., [null, ratePercent]].');
        }
        Decimal previous = 0;
        for (Integer i = 0; i < bands.size(); i++) {
            Decimal upTo = bands[i][0];
            Decimal rate = bands[i][1];
            Boolean last = i == bands.size() - 1;
            if (rate == null || rate < 0 || rate > 100 || (last != (upTo == null)) || (upTo != null && upTo <= previous)) {
                throw new RuleException('Statutory rule ' + ruleKey + ' bands must ascend, use rates 0-100 and end with an open band.');
            }
            previous = upTo == null ? previous : upTo;
        }
        if (bands.isEmpty()) {
            throw new RuleException('Statutory rule ' + ruleKey + ' needs at least one band.');
        }
        return bands;
    }

    /** Basis from the employee's category totals (after formulas and awards), then the rule's method. */
    public static Decimal evaluateStatutory(StatutoryRule r, Map<String, Decimal> categoryTotals) {
        Decimal basis = statutoryBasis(r, categoryTotals);
        Decimal result;
        if (r.method == 'Rate') {
            result = basis * r.ratePercent / 100;
        } else if (r.method == 'Capped_Rate') {
            Decimal capped = r.basisCeiling == null ? basis : (basis < r.basisCeiling ? basis : r.basisCeiling);
            result = capped * r.ratePercent / 100;
        } else {
            result = 0;
            Decimal lower = 0;
            for (List<Decimal> band : r.bands) {
                Decimal upper = band[0];
                if (basis <= lower) {
                    break;
                }
                Decimal top = upper == null || basis < upper ? basis : upper;
                result += (top - lower) * band[1] / 100;
                lower = upper == null ? lower : upper;
            }
        }
        return bound(result, null, r.amountCap);
    }

    public static Decimal statutoryBasis(StatutoryRule r, Map<String, Decimal> categoryTotals) {
        Decimal basis = 0;
        for (String category : r.basisCategories) {
            basis += categoryTotals.containsKey(category) ? categoryTotals.get(category) : 0;
        }
        return basis;
    }

    // --------------------------------------------------------------- helpers

    private static Decimal bound(Decimal value, Decimal floor, Decimal cap) {
        Decimal result = value;
        if (floor != null && result < floor) {
            result = floor;
        }
        if (cap != null && result > cap) {
            result = cap;
        }
        return result.setScale(CALC_SCALE, RoundingMode.HALF_UP);
    }

    private static Decimal requiredNumber(Map<String, Object> raw, String key) {
        Decimal value = optionalNumber(raw, key);
        if (value == null) {
            throw new RuleException('Compensation formula needs a numeric "' + key + '".');
        }
        return value;
    }

    private static Decimal optionalNumber(Map<String, Object> raw, String key) {
        if (!raw.containsKey(key) || raw.get(key) == null) {
            return null;
        }
        Decimal value;
        try {
            value = toDecimal(raw.get(key));
        } catch (Exception ex) {
            throw new RuleException('Compensation formula "' + key + '" must be a number.');
        }
        if (value < 0) {
            throw new RuleException('Compensation formula "' + key + '" cannot be negative.');
        }
        return value;
    }

    private static Decimal toDecimal(Object value) {
        if (value instanceof Decimal) {
            return (Decimal) value;
        }
        if (value instanceof Integer) {
            return Decimal.valueOf((Integer) value);
        }
        if (value instanceof Long) {
            return Decimal.valueOf((Long) value);
        }
        if (value instanceof Double) {
            return Decimal.valueOf((Double) value);
        }
        throw new RuleException('Expected a number.');
    }
}
