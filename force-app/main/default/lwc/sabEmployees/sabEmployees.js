import { LightningElement, api } from 'lwc';
import getOptions from '@salesforce/apex/SABPeopleSetupController.getOptions';
import getEmployments from '@salesforce/apex/SABEmployeeCompensationService.getEmployments';
import getCurrentCompensation from '@salesforce/apex/SABEmployeeCompensationService.getCurrentCompensation';
import createEmployee from '@salesforce/apex/SABEmployeeCompensationService.createEmployee';
import saveEmployment from '@salesforce/apex/SABEmployeeCompensationService.createOrUpdateEmployment';
import savePayComponent from '@salesforce/apex/SABEmployeeCompensationService.createOrUpdatePayComponent';
import saveAssignment from '@salesforce/apex/SABEmployeeCompensationService.createOrUpdateAssignment';
import approveAssignment from '@salesforce/apex/SABEmployeeCompensationService.approveAssignment';
import searchUsers from '@salesforce/apex/SABAdminWorkspaceController.searchUsers';
import { formatNumber, formatDate, chipClass } from 'c/sabFormat';
import { reduceError, todayIso, toast } from 'c/sabMoneyShared';

/**
 * Employees and pay for People and payroll (remaining-tasks batch 2): employees with their employment, department and
 * approved pay, and the forms to add an employee, a pay component and a pay line, and to approve draft pay. Payroll
 * runs calculate from approved pay on active employments, so this is where a run gets its lines.
 */
export default class SabEmployees extends LightningElement {
    @api persona;

    options;
    employments = [];
    pay = [];
    errorMessage;
    isLoading = false;
    modal;
    form = {};
    formError;
    saving = false;
    busyId;
    userResults = [];
    loadSequence = 0;
    currentCompanyId;

    @api
    get companyId() {
        return this.currentCompanyId;
    }
    set companyId(value) {
        if (value !== this.currentCompanyId) {
            this.currentCompanyId = value;
            this.load();
        }
    }

    async load() {
        const companyId = this.currentCompanyId;
        const sequence = ++this.loadSequence;
        if (!companyId) {
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const [options, employments, pay] = await Promise.all([getOptions({ companyId }), getEmployments({ companyId, includeEnded: true }),
                getCurrentCompensation({ companyId, asOfDate: null })]);
            if (sequence === this.loadSequence) {
                this.options = options;
                this.employments = employments || [];
                this.pay = [...(pay || []), ...(options.draftPay || [])];
            }
        } catch (error) {
            if (sequence === this.loadSequence) {
                this.errorMessage = reduceError(error);
            }
        } finally {
            if (sequence === this.loadSequence) {
                this.isLoading = false;
            }
        }
    }

    get loaded() {
        return Boolean(this.options) && !this.errorMessage;
    }

    get personaLabel() {
        return (this.persona && this.persona.label) || 'Your';
    }

    get manageDisabled() {
        return !(this.options && this.options.canManage);
    }

    get manageTitle() {
        return this.manageDisabled ? `${this.personaLabel} role cannot manage employees and pay` : undefined;
    }

    get rows() {
        return this.employments.map((e) => {
            const lines = this.pay.filter((p) => p.employmentId === e.employmentId).map((p) => ({
                ...p,
                amountText: p.formulaBased ? 'Formula' : formatNumber(p.amount),
                fromText: formatDate(p.effectiveFrom),
                chip: chipClass(p.status, p.status === 'Draft' ? 'neutral' : undefined),
                canApprove: p.status === 'Draft',
                approveDisabled: !(this.options && this.options.canApprove) || this.busyId === p.assignmentId,
                approveTitle: this.options && this.options.canApprove ? undefined : `${this.personaLabel} role cannot approve pay`
            }));
            const approved = lines.filter((l) => l.status === 'Approved').length;
            return {
                ...e,
                departmentText: [e.departmentName, e.costCenterName].filter(Boolean).join(', ') || '\u2014',
                startText: formatDate(e.startDate),
                chip: chipClass(e.employmentStatus, e.employmentStatus === 'Active' ? 'good' : 'neutral'),
                lines,
                hasLines: lines.length > 0,
                warning: e.employmentStatus === 'Active' && approved === 0 ? 'No approved pay: payroll will not calculate a line for this employee.' : ''
            };
        });
    }

    get hasEmployees() {
        return this.employments.length > 0;
    }

    get summary() {
        const active = this.employments.filter((e) => e.employmentStatus === 'Active').length;
        const draft = this.pay.filter((p) => p.status === 'Draft').length;
        return `${active} active ${active === 1 ? 'employee' : 'employees'}${draft ? `, ${draft} pay ${draft === 1 ? 'line' : 'lines'} waiting for approval` : ''}`;
    }

    // ---------- actions ----------

    async handleApprove(event) {
        const assignmentId = event.currentTarget.dataset.id;
        this.busyId = assignmentId;
        try {
            await approveAssignment({ assignmentId });
            toast(this, 'Pay approved');
            await this.load();
        } catch (error) {
            toast(this, reduceError(error), 'bad');
        } finally {
            this.busyId = undefined;
        }
    }

    openModal(kind, form) {
        this.form = form;
        this.formError = undefined;
        this.userResults = [];
        this.modal = kind;
    }

    handleNewEmployee() {
        this.openModal('employee', { employeeReference: '', search: '', userId: '', departmentId: '', costCenterId: '', startDate: todayIso() });
    }

    handleNewComponent() {
        this.openModal('component', { name: '', componentKey: '', category: 'Basic Salary', expenseAccountId: '', liabilityAccountId: '' });
    }

    handleAddPay(event) {
        const first = ((this.options && this.options.payComponents) || []).find((c) => c.active);
        this.openModal('pay', { employmentId: event.currentTarget.dataset.id, payComponentId: first ? first.value : '', amount: '', effectiveFrom: todayIso() });
    }

    get modalOpen() {
        return Boolean(this.modal);
    }

    get modalHeading() {
        return { employee: 'New employee', component: 'New pay component', pay: 'Add pay' }[this.modal];
    }

    get modalSub() {
        return {
            employee: 'Creates the employee and an active employment in this company.',
            component: 'A pay item such as basic salary or an allowance, with the accounts payroll posts it to.',
            pay: 'Saved as Draft. Approved pay is what payroll calculates.'
        }[this.modal];
    }

    get isEmployeeModal() {
        return this.modal === 'employee';
    }

    get isComponentModal() {
        return this.modal === 'component';
    }

    get isPayModal() {
        return this.modal === 'pay';
    }

    choices(list, selected) {
        return (list || []).map((o) => ({ value: o.value, label: o.label, selected: o.value === selected }));
    }

    get departmentOptions() {
        return this.choices(this.options && this.options.departments, this.form.departmentId);
    }

    get costCenterOptions() {
        return this.choices(this.options && this.options.costCenters, this.form.costCenterId);
    }

    get expenseOptions() {
        return this.choices(this.options && this.options.expenseAccounts, this.form.expenseAccountId);
    }

    get liabilityOptions() {
        return this.choices(this.options && this.options.liabilityAccounts, this.form.liabilityAccountId);
    }

    get componentOptions() {
        return ((this.options && this.options.payComponents) || []).filter((c) => c.active)
            .map((c) => ({ value: c.value, label: `${c.label} (${c.detail})`, selected: c.value === this.form.payComponentId }));
    }

    get categoryOptions() {
        return ((this.options && this.options.categories) || []).map((v) => ({ value: v, label: v, selected: v === this.form.category }));
    }

    get userOptions() {
        return this.userResults.map((u) => ({ ...u, selected: u.value === this.form.userId }));
    }

    get noComponents() {
        return this.isPayModal && this.componentOptions.length === 0;
    }

    async handleUserSearch(event) {
        const term = event.target.value;
        this.form = { ...this.form, search: term };
        if (!term || term.length < 2) {
            this.userResults = [];
            return;
        }
        try {
            this.userResults = (await searchUsers({ companyId: this.currentCompanyId, term })) || [];
        } catch (error) {
            this.formError = reduceError(error);
        }
    }

    handleField(event) {
        this.form = { ...this.form, [event.target.dataset.field]: event.target.value };
    }

    handleClose() {
        if (!this.saving) {
            this.modal = undefined;
        }
    }

    async handleSave() {
        const f = this.form;
        const companyId = this.currentCompanyId;
        this.saving = true;
        this.formError = undefined;
        try {
            if (this.modal === 'employee') {
                if (!f.employeeId) {
                    const employeeId = await createEmployee({ request: { employeeReference: f.employeeReference, status: 'Active', userId: f.userId || null } });
                    this.form = { ...this.form, employeeId };
                }
                await saveEmployment({ request: { employmentId: null, employeeId: this.form.employeeId, companyId, departmentId: f.departmentId || null,
                    costCenterId: f.costCenterId || null, employmentStatus: 'Active', startDate: f.startDate || null, endDate: null } });
                toast(this, `${f.employeeReference} added`);
            } else if (this.modal === 'component') {
                await savePayComponent({ request: { payComponentId: null, name: f.name, companyId, componentKey: f.componentKey, category: f.category,
                    countryRuleKey: null, expenseAccountId: f.expenseAccountId || null, liabilityAccountId: f.liabilityAccountId || null, isActive: true } });
                toast(this, `${f.name} added`);
            } else {
                await saveAssignment({ request: { assignmentId: null, employmentId: f.employmentId, payComponentId: f.payComponentId || null,
                    amount: f.amount === '' ? null : Number(f.amount), currencyCode: this.options.currencyCode, effectiveFrom: f.effectiveFrom || null,
                    effectiveTo: null, formulaParameterJson: null } });
                toast(this, 'Pay added as draft');
            }
            this.modal = undefined;
            this.dispatchEvent(new CustomEvent('changed'));
            await this.load();
        } catch (error) {
            this.formError = reduceError(error);
        } finally {
            this.saving = false;
        }
    }

    handleRetry() {
        this.load();
    }
}
