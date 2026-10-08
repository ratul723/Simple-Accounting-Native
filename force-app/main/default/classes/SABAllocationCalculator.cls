/**
 * G14: splits an amount across weighted targets with a rounding policy. Pure calculation, no SOQL or DML.
 *
 *   Largest Remainder  every share is truncated to the minor unit, then leftover units go to the largest remainders
 *                      (ties: earlier target first). Shares always sum exactly to the amount.
 *   Last Target        every share but the last is rounded half-up; the last target takes the difference.
 *   Rounding Account   every share is rounded half-up; any residual is returned for the rounding account.
 *
 * Works on the absolute amount and re-applies the sign, so credit balances split the same way as debits.
 */
public with sharing class SABAllocationCalculator {
    public class AllocationCalculationException extends Exception {}

    public static final String LARGEST_REMAINDER = 'Largest Remainder';
    public static final String LAST_TARGET = 'Last Target';
    public static final String ROUNDING_ACCOUNT = 'Rounding Account';
    private static final Integer SCALE = 2;
    private static final Decimal UNIT = 0.01;

    public class SplitResult {
        public List<Decimal> shares = new List<Decimal>();
        public Decimal roundingResidual = 0;
    }

    public static SplitResult split(Decimal amount, List<Decimal> weights, String policy) {
        if (amount == null || weights == null || weights.isEmpty()) {
            throw new AllocationCalculationException('An amount and at least one weight are required.');
        }
        Decimal totalWeight = 0;
        for (Decimal w : weights) {
            if (w == null || w <= 0) {
                throw new AllocationCalculationException('Every allocation weight must be greater than zero.');
            }
            totalWeight += w;
        }
        Decimal sign = amount < 0 ? -1 : 1;
        Decimal absolute = amount.abs().setScale(SCALE, RoundingMode.HALF_UP);
        String rule = String.isBlank(policy) ? LARGEST_REMAINDER : policy;
        SplitResult result = new SplitResult();
        List<Decimal> shares = new List<Decimal>();
        if (rule == LARGEST_REMAINDER) {
            List<Decimal> remainders = new List<Decimal>();
            Decimal allocated = 0;
            for (Decimal w : weights) {
                Decimal exact = absolute * w / totalWeight;
                Decimal floorShare = exact.setScale(SCALE, RoundingMode.DOWN);
                shares.add(floorShare);
                remainders.add(exact - floorShare);
                allocated += floorShare;
            }
            Integer leftoverUnits = ((absolute - allocated) / UNIT).setScale(0, RoundingMode.HALF_UP).intValue();
            for (Integer n = 0; n < leftoverUnits; n++) {
                Integer best = 0;
                for (Integer i = 1; i < remainders.size(); i++) {
                    if (remainders[i] > remainders[best]) {
                        best = i;
                    }
                }
                shares[best] += UNIT;
                remainders[best] = -1;
            }
        } else if (rule == LAST_TARGET || rule == ROUNDING_ACCOUNT) {
            Decimal allocated = 0;
            for (Integer i = 0; i < weights.size(); i++) {
                Decimal share = (absolute * weights[i] / totalWeight).setScale(SCALE, RoundingMode.HALF_UP);
                if (rule == LAST_TARGET && i == weights.size() - 1) {
                    share = absolute - allocated;
                }
                shares.add(share);
                allocated += share;
            }
            if (rule == ROUNDING_ACCOUNT) {
                result.roundingResidual = (absolute - allocated) * sign;
            }
        } else {
            throw new AllocationCalculationException('Unsupported rounding policy: ' + rule + '.');
        }
        for (Decimal share : shares) {
            result.shares.add(share * sign);
        }
        return result;
    }
}
