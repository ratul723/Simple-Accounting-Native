/**
 * G16: loan repayment schedules. Pure calculation, no SOQL or DML.
 *
 *   Annuity          level instalment P * r / (1 - (1 + r)^-n); interest on the opening balance; principal = instalment - interest
 *   Equal Principal  principal P / n each period; interest on the opening balance
 * r = annual rate / 100 * months per period / 12. Amounts are rounded to 2 decimals; the final instalment clears the
 * remaining balance exactly. A zero rate gives equal principal with no interest under either method.
 */
public with sharing class SABLoanScheduleCalculator {
    public class LoanScheduleException extends Exception {}

    public class Instalment {
        public Integer sequence;
        public Date dueDate;
        public Decimal principalDue;
        public Decimal interestDue;
        public Decimal closingBalance;
    }

    public static Integer monthsPerPeriod(String frequency) {
        if (frequency == 'Monthly') {
            return 1;
        }
        if (frequency == 'Quarterly') {
            return 3;
        }
        throw new LoanScheduleException('Repayment frequency must be Monthly or Quarterly.');
    }

    /** Number of instalments; the maturity date must fall exactly on an instalment date. */
    public static Integer instalments(Date startDate, Date maturityDate, String frequency) {
        Integer step = monthsPerPeriod(frequency);
        if (startDate == null || maturityDate == null || maturityDate <= startDate) {
            throw new LoanScheduleException('Maturity date must be after the start date.');
        }
        for (Integer n = 1; n <= 360; n++) {
            Date due = startDate.addMonths(n * step);
            if (due == maturityDate) {
                return n;
            }
            if (due > maturityDate) {
                break;
            }
        }
        throw new LoanScheduleException('Maturity date must fall on a ' + frequency.toLowerCase()
            + ' instalment date after the start date, within 360 instalments.');
    }

    public static List<Instalment> build(Decimal principal, Decimal annualRatePercent, Date startDate, Date maturityDate,
            String frequency, String method) {
        if (principal == null || principal <= 0) {
            throw new LoanScheduleException('Principal must be greater than zero.');
        }
        if (annualRatePercent == null || annualRatePercent < 0 || annualRatePercent > 100) {
            throw new LoanScheduleException('Interest rate must be between 0 and 100 percent.');
        }
        if (method != 'Annuity' && method != 'Equal Principal') {
            throw new LoanScheduleException('Schedule method must be Annuity or Equal Principal.');
        }
        Integer step = monthsPerPeriod(frequency);
        Integer n = instalments(startDate, maturityDate, frequency);
        Decimal rate = annualRatePercent / 100 * step / 12;
        Decimal level;
        if (method == 'Annuity' && rate > 0) {
            Decimal growth = 1;
            for (Integer i = 0; i < n; i++) {
                growth = growth * (1 + rate);
            }
            level = (principal * rate * growth / (growth - 1)).setScale(2, RoundingMode.HALF_UP);
        }
        Decimal equalPrincipal = (principal / n).setScale(2, RoundingMode.HALF_UP);
        List<Instalment> rows = new List<Instalment>();
        Decimal balance = principal.setScale(2, RoundingMode.HALF_UP);
        for (Integer i = 1; i <= n; i++) {
            Instalment row = new Instalment();
            row.sequence = i;
            row.dueDate = startDate.addMonths(i * step);
            row.interestDue = (balance * rate).setScale(2, RoundingMode.HALF_UP);
            if (i == n) {
                row.principalDue = balance;
            } else if (level != null) {
                row.principalDue = level - row.interestDue;
            } else {
                row.principalDue = equalPrincipal;
            }
            balance -= row.principalDue;
            row.closingBalance = balance;
            rows.add(row);
        }
        return rows;
    }
}
