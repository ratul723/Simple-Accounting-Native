/**
 * Simple Accounting Books formatting helpers. Output matches the Harbourline demo exactly:
 * negatives in parentheses, en-AU grouping, "25 Sep 2026" dates and compact axis labels.
 */
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const LOCALE = 'en-AU';

const TONES = {
    Posted: 'good', Paid: 'good', Active: 'good', Succeeded: 'good', Complete: 'good', Committed: 'good',
    Approved: 'good', Closed: 'neutral', Valid: 'good', Effective: 'good', Settled: 'good', Matched: 'good',
    'In Service': 'good', Validated: 'good', Lodged: 'good', Enabled: 'good', Pass: 'good', Confirmed: 'good',
    Draft: 'neutral', Planned: 'neutral', 'Not Started': 'neutral', Inactive: 'neutral', Superseded: 'neutral',
    Disposed: 'neutral', Retired: 'neutral', 'Not Configured': 'neutral', Queued: 'neutral', Unpaid: 'neutral',
    Uploaded: 'neutral', Pending: 'info', Submitted: 'info', Issued: 'info', 'In Progress': 'info',
    Calculated: 'info', Authorized: 'info', Open: 'accent', Running: 'info', Parsed: 'info', Ready: 'info',
    'In Flight': 'info', Preparing: 'info', Reserved: 'info', Review: 'info', Due: 'warn', 'Part Paid': 'warn',
    'Part Settled': 'warn', 'Part Received': 'warn', Overdue: 'bad', Failed: 'bad', Blocked: 'bad',
    Rejected: 'bad', Error: 'bad', 'Part Failed': 'warn', Retry: 'warn', Warning: 'warn', Reversed: 'warn',
    Cancelled: 'neutral', Fail: 'bad', Duplicate: 'bad', Proposed: 'info', Received: 'good', Impaired: 'warn',
    Invalidated: 'neutral'
};

function toNumber(value) {
    if (value === null || value === undefined || value === '') {
        return null;
    }
    const n = Number(value);
    return Number.isFinite(n) ? n : null;
}

/** 1,234.50 or (1,234.50); blank for empty input. */
export function formatNumber(value, decimals = 2) {
    const n = toNumber(value);
    if (n === null) {
        return '';
    }
    const text = Math.abs(n).toLocaleString(LOCALE, {
        minimumFractionDigits: decimals,
        maximumFractionDigits: decimals
    });
    return n < 0 ? `(${text})` : text;
}

/** Money parts for a figure: tabular value plus a small currency suffix. */
export function moneyParts(value, currency, decimals = 2) {
    const n = toNumber(value);
    return {
        text: formatNumber(n, decimals),
        currency: currency || '',
        negative: n !== null && n < 0,
        className: n !== null && n < 0 ? 'num neg' : 'num'
    };
}

/** Compact axis label: 1.25m, 12.4k, 950; minus sign for negatives. */
export function formatCompact(value) {
    const n = toNumber(value) || 0;
    const a = Math.abs(n);
    let text;
    if (a >= 1e6) {
        text = `${(a / 1e6).toFixed(2)}m`;
    } else if (a >= 1e4) {
        text = `${(a / 1e3).toFixed(1)}k`;
    } else {
        text = formatNumber(a, 0);
    }
    return (n < 0 ? '\u2212' : '') + text;
}

function parts(iso) {
    if (!iso) {
        return null;
    }
    const match = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso));
    if (!match) {
        return null;
    }
    return { y: Number(match[1]), m: Number(match[2]), d: Number(match[3]) };
}

/** 25 Sep 2026 */
export function formatDate(iso) {
    const p = parts(iso);
    return p ? `${p.d} ${MONTHS[p.m - 1]} ${p.y}` : '';
}

/** 25 Sep */
export function formatDateShort(iso) {
    const p = parts(iso);
    return p ? `${p.d} ${MONTHS[p.m - 1]}` : '';
}

/** Sep 2026 */
export function formatMonth(iso) {
    const p = parts(iso);
    return p ? `${MONTHS[p.m - 1]} ${p.y}` : '';
}

/** Sep */
export function monthName(iso) {
    const p = parts(iso);
    return p ? MONTHS[p.m - 1] : '';
}

/** 25 Sep 2026 14:05 from an ISO datetime, in the viewer's local time. */
export function formatDateTime(isoDateTime) {
    if (!isoDateTime) {
        return '';
    }
    const d = new Date(isoDateTime);
    if (Number.isNaN(d.getTime())) {
        return '';
    }
    const hh = String(d.getHours()).padStart(2, '0');
    const mm = String(d.getMinutes()).padStart(2, '0');
    return `${d.getDate()} ${MONTHS[d.getMonth()]} ${d.getFullYear()} ${hh}:${mm}`;
}

/** Status tone used by chips: good, warn, bad, info, accent or neutral. */
export function toneOf(status, override) {
    return override || TONES[status] || 'neutral';
}

/** CSS class list for a status chip. */
export function chipClass(status, override) {
    return `chip t-${toneOf(status, override)}`;
}

/** Up to two initials from a display name. */
export function initials(name) {
    return String(name || '')
        .split(/\s+/)
        .filter(Boolean)
        .map((word) => word[0])
        .join('')
        .slice(0, 2)
        .toUpperCase();
}

/** "1 approval" or "3 approvals". */
export function plural(count, singular, pluralForm) {
    const n = Number(count) || 0;
    return `${n} ${n === 1 ? singular : pluralForm || `${singular}s`}`;
}

/** Good morning / afternoon / evening for an hour of the day. */
export function greeting(hour) {
    if (hour < 12) {
        return 'Good morning';
    }
    return hour < 18 ? 'Good afternoon' : 'Good evening';
}

/** Title for disabled buttons, as the demo's guard() did. */
export function guardTitle(allowed, persona, action) {
    return allowed ? undefined : `${persona || 'Your'} role cannot ${action || 'do this'}`;
}

export const MONTH_NAMES = MONTHS;
