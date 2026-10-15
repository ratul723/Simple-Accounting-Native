import { createElement } from 'lwc';
import SabEmployees from 'c/sabEmployees';
import getOptions from '@salesforce/apex/SABPeopleSetupController.getOptions';
import getEmployments from '@salesforce/apex/SABEmployeeCompensationService.getEmployments';
import getCurrentCompensation from '@salesforce/apex/SABEmployeeCompensationService.getCurrentCompensation';
import createEmployee from '@salesforce/apex/SABEmployeeCompensationService.createEmployee';
import saveEmployment from '@salesforce/apex/SABEmployeeCompensationService.createOrUpdateEmployment';
import savePayComponent from '@salesforce/apex/SABEmployeeCompensationService.createOrUpdatePayComponent';
import saveAssignment from '@salesforce/apex/SABEmployeeCompensationService.createOrUpdateAssignment';
import approveAssignment from '@salesforce/apex/SABEmployeeCompensationService.approveAssignment';
import searchUsers from '@salesforce/apex/SABAdminWorkspaceController.searchUsers';

jest.mock('@salesforce/apex/SABPeopleSetupController.getOptions', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABEmployeeCompensationService.getEmployments', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABEmployeeCompensationService.getCurrentCompensation', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABEmployeeCompensationService.createEmployee', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABEmployeeCompensationService.createOrUpdateEmployment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABEmployeeCompensationService.createOrUpdatePayComponent', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABEmployeeCompensationService.createOrUpdateAssignment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABEmployeeCompensationService.approveAssignment', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/SABAdminWorkspaceController.searchUsers', () => ({ default: jest.fn() }), { virtual: true });

const OPTIONS = {
    canManage: true, canApprove: true, currencyCode: 'AUD', categories: ['Basic Salary', 'Incentive'],
    payComponents: [{ value: 'PC1', label: 'Basic salary', detail: 'Basic Salary', active: true }, { value: 'PC2', label: 'Old', detail: 'Other', active: false }],
    departments: [{ value: 'D1', label: 'Operations' }], costCenters: [{ value: 'K1', label: 'HO' }],
    expenseAccounts: [{ value: 'E1', label: '6000 Wages' }], liabilityAccounts: [{ value: 'L1', label: '2200 Payroll payable' }],
    draftPay: [{ assignmentId: 'A2', employmentId: 'M1', payComponentName: 'Basic salary', category: 'Basic Salary', amount: 500, effectiveFrom: '2026-10-01', status: 'Draft' }]
};
const EMPLOYMENTS = [
    { employmentId: 'M1', employeeReference: 'EMP-001', employmentStatus: 'Active', startDate: '2026-01-01', departmentName: 'Operations' },
    { employmentId: 'M2', employeeReference: 'EMP-002', employmentStatus: 'Active', startDate: '2026-02-01' },
    { employmentId: 'M3', employeeReference: 'EMP-003', employmentStatus: 'Ended', startDate: '2025-02-01' }
];
const PAY = [{ assignmentId: 'A1', employmentId: 'M1', payComponentName: 'Basic salary', category: 'Basic Salary', amount: 6000, effectiveFrom: '2026-01-01', status: 'Approved' }];

async function flush() {
    for (let i = 0; i < 8; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

function mount() {
    const el = createElement('c-sab-employees', { is: SabEmployees });
    el.persona = { label: 'HR' };
    el.companyId = 'a01000000000001AAA';
    document.body.appendChild(el);
    return el;
}

function set(root, field, value) {
    const input = root.querySelector(`c-sab-modal [data-field="${field}"]`);
    input.value = value;
    input.dispatchEvent(new CustomEvent(input.tagName === 'SELECT' ? 'change' : 'input'));
}

describe('c-sab-employees', () => {
    beforeEach(() => {
        getOptions.mockResolvedValue(OPTIONS);
        getEmployments.mockResolvedValue(EMPLOYMENTS);
        getCurrentCompensation.mockResolvedValue(PAY);
        createEmployee.mockResolvedValue('E9');
        [saveEmployment, savePayComponent, saveAssignment, approveAssignment].forEach((m) => m.mockResolvedValue('X'));
        searchUsers.mockResolvedValue([{ value: 'U1', label: 'Maya Chen (maya@x.com)' }]);
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('lists employees with approved and draft pay and warns where payroll has nothing to calculate', async () => {
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.sub').textContent).toBe('2 active employees, 1 pay line waiting for approval');
        const emps = root.querySelectorAll('.emp');
        expect(emps[0].querySelectorAll('.pay tr').length).toBe(2);
        expect(emps[0].querySelector('.warn')).toBeNull();
        expect(emps[1].querySelector('.warn').textContent).toContain('No approved pay');
        expect(emps[2].querySelector('.warn')).toBeNull();
        approveAssignment.mockRejectedValueOnce({ body: { message: 'Overlapping pay.' } });
        const toast = jest.fn();
        el.addEventListener('sabtoast', toast);
        root.querySelector('.sab-approve-pay').click();
        await flush();
        expect(toast.mock.calls[0][0].detail.tone).toBe('bad');
        root.querySelector('.sab-approve-pay').click();
        await flush();
        expect(approveAssignment).toHaveBeenLastCalledWith({ assignmentId: 'A2' });
    });

    it('adds an employee linked to a user, a pay component and pay', async () => {
        saveEmployment.mockRejectedValueOnce({ body: { message: 'Start date is required.' } });
        const el = mount();
        const changed = jest.fn();
        el.addEventListener('changed', changed);
        await flush();
        const root = el.shadowRoot;
        root.querySelector('.sab-new-employee').click();
        await flush();
        set(root, 'employeeReference', 'EMP-010');
        const search = root.querySelector('.sab-user-search');
        search.value = 'Ma';
        search.dispatchEvent(new CustomEvent('input'));
        await flush();
        set(root, 'userId', 'U1');
        set(root, 'departmentId', 'D1');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(root.querySelector('.form-error').textContent).toBe('Start date is required.');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(createEmployee).toHaveBeenCalledTimes(1);
        expect(createEmployee.mock.calls[0][0].request).toEqual({ employeeReference: 'EMP-010', status: 'Active', userId: 'U1' });
        expect(saveEmployment.mock.calls[1][0].request).toMatchObject({ employeeId: 'E9', companyId: 'a01000000000001AAA', departmentId: 'D1', employmentStatus: 'Active' });
        expect(changed).toHaveBeenCalled();

        root.querySelector('.sab-new-component').click();
        await flush();
        set(root, 'name', 'Basic salary');
        set(root, 'componentKey', 'BASIC');
        set(root, 'expenseAccountId', 'E1');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(savePayComponent.mock.calls[0][0].request).toMatchObject({ name: 'Basic salary', componentKey: 'BASIC', category: 'Basic Salary', expenseAccountId: 'E1', isActive: true });

        root.querySelectorAll('.sab-add-pay')[1].click();
        await flush();
        expect(root.querySelectorAll('c-sab-modal [data-field="payComponentId"] option').length).toBe(1);
        set(root, 'amount', '5200');
        root.querySelector('.sab-modal-save').click();
        await flush();
        expect(saveAssignment.mock.calls[0][0].request).toMatchObject({ employmentId: 'M2', payComponentId: 'PC1', amount: 5200, currencyCode: 'AUD' });
    });

    it('handles empty lists, missing components, permissions and errors', async () => {
        getOptions.mockResolvedValue({ ...OPTIONS, canManage: false, canApprove: false, payComponents: [], draftPay: [] });
        getEmployments.mockResolvedValueOnce([]);
        const el = mount();
        await flush();
        expect(el.shadowRoot.querySelector('.empty h3').textContent).toBe('No employees yet');
        expect(el.shadowRoot.querySelector('.sab-new-employee').title).toBe('Needs the SAB Manage Employee Compensation Action permission set');

        getOptions.mockResolvedValue({ ...OPTIONS, payComponents: [] });
        const el2 = mount();
        await flush();
        el2.shadowRoot.querySelector('.sab-add-pay').click();
        await flush();
        expect(el2.shadowRoot.querySelector('c-sab-modal p.muted').textContent).toContain('Add a pay component first');
        el2.shadowRoot.querySelector('.sab-modal-close').click();

        getEmployments.mockRejectedValueOnce({ body: { message: 'No access to employments.' } });
        const el3 = mount();
        await flush();
        expect(el3.shadowRoot.querySelector('.banner').textContent).toContain('No access to employments.');
        el3.shadowRoot.querySelector('.banner .btn').click();
        await flush();
        expect(el3.shadowRoot.querySelector('.sab-employees')).not.toBeNull();
    });

    it('names the missing permission sets and shows a status for employments without one', async () => {
        getOptions.mockResolvedValue({ ...OPTIONS, canManage: false, canApprove: false });
        getEmployments.mockResolvedValue([{ employmentId: 'M7', employeeReference: 'Emp_KV', startDate: '2026-09-27' }]);
        const el = mount();
        await flush();
        const root = el.shadowRoot;
        expect(root.querySelector('.perm-note').textContent).toContain('SAB Manage Employee Compensation Action');
        expect(root.querySelector('.perm-note').textContent).toContain('SAB Approve Employee Compensation Action');
        expect(root.querySelector('.emp .chip').textContent).toContain('No status');
    });
});
