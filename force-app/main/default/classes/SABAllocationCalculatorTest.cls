@IsTest
private class SABAllocationCalculatorTest {

    private static String failure(Decimal amount, List<Decimal> weights, String policy) {
        try {
            SABAllocationCalculator.split(amount, weights, policy);
        } catch (SABAllocationCalculator.AllocationCalculationException ex) {
            return ex.getMessage();
        }
        return null;
    }

    @IsTest
    static void largestRemainderAlwaysSumsToTheAmount() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            SABAllocationCalculator.SplitResult thirds = SABAllocationCalculator.split(100, new List<Decimal>{1, 1, 1}, null);
            System.assertEquals(new List<Decimal>{33.34, 33.33, 33.33}, thirds.shares, 'The leftover cent goes to the first tie.');
            SABAllocationCalculator.SplitResult utilities = SABAllocationCalculator.split(100.01, new List<Decimal>{60, 40}, 'Largest Remainder');
            System.assertEquals(new List<Decimal>{60.01, 40.00}, utilities.shares, 'The larger remainder (0.006) gets the cent.');
            SABAllocationCalculator.SplitResult credit = SABAllocationCalculator.split(-100, new List<Decimal>{1, 1, 1}, null);
            System.assertEquals(new List<Decimal>{-33.34, -33.33, -33.33}, credit.shares, 'Credit balances split with the same pattern.');
            System.assertEquals(0, thirds.roundingResidual, 'No residual under Largest Remainder.');
        }
    }

    @IsTest
    static void lastTargetAndRoundingAccountPolicies() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            SABAllocationCalculator.SplitResult last = SABAllocationCalculator.split(100.01, new List<Decimal>{1, 1, 1}, 'Last Target');
            System.assertEquals(new List<Decimal>{33.34, 33.34, 33.33}, last.shares, 'The last target absorbs the rounding.');
            SABAllocationCalculator.SplitResult residual = SABAllocationCalculator.split(100.01, new List<Decimal>{1, 1, 1}, 'Rounding Account');
            System.assertEquals(new List<Decimal>{33.34, 33.34, 33.34}, residual.shares, 'Every share is rounded half-up.');
            System.assertEquals(-0.01, residual.roundingResidual, 'Over-allocation leaves a negative residual for the rounding account.');
            SABAllocationCalculator.SplitResult creditResidual = SABAllocationCalculator.split(-100.01, new List<Decimal>{1, 1, 1}, 'Rounding Account');
            System.assertEquals(0.01, creditResidual.roundingResidual, 'The residual keeps the balance sign convention.');
        }
    }

    @IsTest
    static void rejectsInvalidInput() {
        System.runAs(new User(Id = UserInfo.getUserId())) {
            System.assert(failure(null, new List<Decimal>{1}, null).contains('at least one weight'), 'Amount is required.');
            System.assert(failure(10, new List<Decimal>(), null).contains('at least one weight'), 'Weights are required.');
            System.assert(failure(10, new List<Decimal>{1, 0}, null).contains('greater than zero'), 'Zero weights are rejected.');
            System.assert(failure(10, new List<Decimal>{1}, 'Coin Toss').contains('Unsupported rounding policy'), 'Unknown policies are rejected.');
        }
    }
}
