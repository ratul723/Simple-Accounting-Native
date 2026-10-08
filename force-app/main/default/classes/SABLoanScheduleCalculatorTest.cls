@IsTest
private class SABLoanScheduleCalculatorTest {
    private static final Date JAN = Date.newInstance(2026, 1, 1);

    private static String failure(Decimal principal, Decimal rate, Date maturity, String frequency, String method) {
        try {
            SABLoanScheduleCalculator.build(principal, rate, JAN, maturity, frequency, method);
        } catch (SABLoanScheduleCalculator.LoanScheduleException ex) {
            return ex.getMessage();
        }
        return null;
    }

    @IsTest
    static void annuityHasLevelInstalmentsAndClearsTheBalance() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            List<SABLoanScheduleCalculator.Instalment> rows = SABLoanScheduleCalculator.build(12000, 12, JAN, Date.newInstance(2026, 4, 1),
                'Monthly', 'Annuity');
            System.assertEquals(3, rows.size(), 'Three monthly instalments.');
            System.assertEquals(Date.newInstance(2026, 2, 1), rows[0].dueDate, 'First instalment one month after the start.');
            System.assertEquals(120.00, rows[0].interestDue, 'Interest on 12,000 at 1% a month.');
            System.assertEquals(3960.27, rows[0].principalDue, 'Level instalment 4,080.27 less interest.');
            System.assertEquals(80.40, rows[1].interestDue, 'Interest on the reduced balance.');
            System.assertEquals(3999.87, rows[1].principalDue, 'Second principal.');
            System.assertEquals(4039.86, rows[2].principalDue, 'The last instalment clears the balance.');
            System.assertEquals(0, rows[2].closingBalance, 'Fully repaid.');
        }
    }

    @IsTest
    static void equalPrincipalQuarterlyAndZeroRate() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            List<SABLoanScheduleCalculator.Instalment> equal = SABLoanScheduleCalculator.build(12000, 12, JAN, Date.newInstance(2026, 4, 1),
                'Monthly', 'Equal Principal');
            System.assertEquals(4000, equal[0].principalDue, 'Equal principal.');
            System.assertEquals(40.00, equal[2].interestDue, 'Interest on the last 4,000.');
            List<SABLoanScheduleCalculator.Instalment> quarterly = SABLoanScheduleCalculator.build(10000, 0, JAN, Date.newInstance(2027, 1, 1),
                'Quarterly', 'Annuity');
            System.assertEquals(4, quarterly.size(), 'Four quarterly instalments in a year.');
            System.assertEquals(Date.newInstance(2026, 4, 1), quarterly[0].dueDate, 'Quarterly due dates.');
            System.assertEquals(0, quarterly[0].interestDue, 'A zero rate charges no interest.');
            System.assertEquals(2500, quarterly[0].principalDue, 'A zero-rate annuity repays equal principal.');
        }
    }

    @IsTest
    static void rejectsInvalidTerms() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Date april = Date.newInstance(2026, 4, 1);
            Map<String, String> cases = new Map<String, String>{
                failure(0, 12, april, 'Monthly', 'Annuity') => 'greater than zero',
                failure(1000, 101, april, 'Monthly', 'Annuity') => 'between 0 and 100',
                failure(1000, 12, april, 'Monthly', 'Bullet') => 'Annuity or Equal Principal',
                failure(1000, 12, april, 'Weekly', 'Annuity') => 'Monthly or Quarterly',
                failure(1000, 12, Date.newInstance(2026, 4, 15), 'Monthly', 'Annuity') => 'instalment date',
                failure(1000, 12, JAN, 'Monthly', 'Annuity') => 'after the start date'};
            for (String message : cases.keySet()) {
                System.assert(message != null && message.contains(cases.get(message)), 'Expected "' + cases.get(message) + '" but got: ' + message);
            }
            System.assertEquals(6, cases.size(), 'Every invalid term was refused with a distinct message.');
        }
    }
}
