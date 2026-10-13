/** Shared helpers for the Sales, Purchases and Payments workspaces. */
export function reduceError(error) {
    if (!error) {
        return 'Something went wrong.';
    }
    if (Array.isArray(error.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return (error.body && error.body.message) || error.message || 'Something went wrong.';
}

export function newKey(prefix, id) {
    const random = typeof crypto !== 'undefined' && crypto.randomUUID ? crypto.randomUUID() : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
    return `${prefix}-${id || 'new'}-${random}`;
}

export function todayIso() {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

export function daysBetween(fromIso, toIso) {
    if (!fromIso || !toIso) {
        return 0;
    }
    return Math.round((Date.parse(toIso) - Date.parse(fromIso)) / 86400000);
}

/** Display state of a posted document: Overdue, Paid or Part Paid; otherwise its status. */
export function documentState(doc) {
    if (doc.status !== 'Posted' || doc.outstanding === null || doc.outstanding === undefined) {
        return doc.status;
    }
    if (doc.outstanding <= 0) {
        return 'Paid';
    }
    if (doc.daysPastDue > 0) {
        return 'Overdue';
    }
    return doc.outstanding < doc.total ? 'Part Paid' : 'Posted';
}

export function hsteps(labels, index) {
    return labels.map((label, i) => ({
        key: label,
        label,
        number: i + 1,
        done: i < index,
        className: i < index ? 'hstep done' : i === index ? 'hstep now' : 'hstep'
    }));
}

export function toast(element, message, tone) {
    element.dispatchEvent(new CustomEvent('sabtoast', { detail: { message, tone }, bubbles: true, composed: true }));
}