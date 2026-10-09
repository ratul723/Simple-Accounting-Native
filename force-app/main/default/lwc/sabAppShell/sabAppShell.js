import { LightningElement, wire } from 'lwc';
import { NavigationMixin, CurrentPageReference } from 'lightning/navigation';
import { loadStyle } from 'lightning/platformResourceLoader';
import { publish, MessageContext } from 'lightning/messageService';
import SAB_FONTS from '@salesforce/resourceUrl/sabFonts';
import COMPANY_CONTEXT_CHANNEL from '@salesforce/messageChannel/SABCompanyContext__c';
import getAccessibleCompanies from '@salesforce/apex/SABCompanyContextController.getAccessibleCompanies';
import getCompanyContext from '@salesforce/apex/SABCompanyContextController.getCompanyContext';
import getShellContext from '@salesforce/apex/SABAppShellController.getShellContext';
import searchRecords from '@salesforce/apex/SABAppShellController.search';
import { formatMonth, initials } from 'c/sabFormat';
import { GROUPS, SETUP_ALLOWED, WORKSPACES, WORKSPACE_BY_ID } from './workspaces';

const COMPANY_STORAGE_KEY = 'sabSelectedAccountingCompanyId';
const THEME_STORAGE_PREFIX = 'sabTheme:';
const STATE_WORKSPACE = 'c__ws';
const STATE_RECORD = 'c__id';
const SEARCH_DELAY_MS = 250;
const SEARCH_MIN_LENGTH = 2;
const SEARCH_MAX_RESULTS = 8;

function reduceError(error) {
    if (!error) {
        return 'Something went wrong.';
    }
    if (Array.isArray(error.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    return (error.body && error.body.message) || error.message || 'Something went wrong.';
}

function readStorage(storage, key) {
    try {
        return storage.getItem(key);
    } catch {
        return null;
    }
}

function writeStorage(storage, key, value) {
    try {
        if (value === null || value === undefined) {
            storage.removeItem(key);
        } else {
            storage.setItem(key, value);
        }
    } catch {
        // Storage can be unavailable (private mode, policy); the preference simply is not kept.
    }
}

/**
 * Simple Accounting Books app shell: top bar, grouped sidebar, URL-driven workspace area,
 * company context, global search, theme and persona. Fills the Lightning App Page below the
 * Lightning Experience header.
 */
export default class SabAppShell extends NavigationMixin(LightningElement) {
    @wire(MessageContext) messageContext;

    pageRef;
    companies = [];
    company;
    shell;
    workspaceId = 'home';
    recordId;
    workspaceCtor;
    loadedWorkspaceId;
    isLoading = true;
    errorMessage;
    companyPopOpen = false;
    userPopOpen = false;
    searchPopOpen = false;
    sidebarOpen = false;
    searchTerm = '';
    searchResults = [];
    searchBusy = false;
    theme;
    appStyle = '';
    loadSequence = 0;
    searchSequence = 0;
    searchTimer;
    fontsLoaded = false;

    @wire(CurrentPageReference)
    handlePageReference(pageRef) {
        this.pageRef = pageRef;
        const state = (pageRef && pageRef.state) || {};
        const next = state[STATE_WORKSPACE] || 'home';
        const nextRecord = state[STATE_RECORD] || undefined;
        if (next !== this.workspaceId || nextRecord !== this.recordId) {
            this.workspaceId = next;
            this.recordId = nextRecord;
            this.loadWorkspace();
        }
    }

    connectedCallback() {
        this.keydownHandler = this.handleDocumentKeydown.bind(this);
        this.resizeHandler = this.sizeToViewport.bind(this);
        document.addEventListener('keydown', this.keydownHandler);
        window.addEventListener('resize', this.resizeHandler);
        this.loadFonts();
        this.initialise();
    }

    disconnectedCallback() {
        document.removeEventListener('keydown', this.keydownHandler);
        window.removeEventListener('resize', this.resizeHandler);
        clearTimeout(this.searchTimer);
    }

    renderedCallback() {
        this.sizeToViewport();
    }

    async loadFonts() {
        if (this.fontsLoaded) {
            return;
        }
        try {
            await loadStyle(this, `${SAB_FONTS}/sabFonts.css`);
            this.fontsLoaded = true;
        } catch {
            // Fallback font stacks apply when the static resource cannot load.
            this.fontsLoaded = false;
        }
    }

    sizeToViewport() {
        const host = this.template.host;
        if (!host || typeof host.getBoundingClientRect !== 'function') {
            return;
        }
        const top = Math.max(0, Math.round(host.getBoundingClientRect().top + window.scrollY));
        const style = `height:calc(100vh - ${top}px)`;
        if (style !== this.appStyle) {
            this.appStyle = style;
        }
    }

    async initialise() {
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            const result = await getAccessibleCompanies();
            this.companies = Array.isArray(result) ? result : [];
            if (!this.companies.length) {
                this.company = undefined;
                this.publishCompany(undefined, false, true);
                await this.loadShell(null);
                return;
            }
            const stored = readStorage(window.sessionStorage, COMPANY_STORAGE_KEY);
            const initial = this.companies.some((c) => c.companyId === stored) ? stored : this.companies[0].companyId;
            await this.selectCompany(initial, false);
        } catch (error) {
            this.errorMessage = reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    async selectCompany(companyId, isSwitch) {
        const context = await getCompanyContext({ companyId });
        this.company = context;
        writeStorage(window.sessionStorage, COMPANY_STORAGE_KEY, context.companyId);
        this.publishCompany(context, isSwitch, false);
        await this.loadShell(context.companyId);
    }

    publishCompany(context, isSwitch, cleared) {
        publish(this.messageContext, COMPANY_CONTEXT_CHANNEL, {
            companyId: context ? context.companyId : null,
            companyName: context ? context.companyName : null,
            companyKey: context ? context.companyKey : null,
            functionalCurrency: context ? context.functionalCurrency : null,
            setupStatus: context ? context.setupStatus : null,
            companySwitched: Boolean(isSwitch),
            companyCleared: Boolean(cleared)
        });
    }

    async loadShell(companyId) {
        this.shell = await getShellContext({ companyId });
        if (this.theme === undefined) {
            this.applyTheme(readStorage(window.localStorage, THEME_STORAGE_PREFIX + this.shell.userId), false);
        }
        await this.loadWorkspace();
    }

    async loadWorkspace() {
        if (!this.shell) {
            return;
        }
        const sequence = ++this.loadSequence;
        const entry = WORKSPACE_BY_ID[this.workspaceId];
        if (!entry || !this.isVisible(this.workspaceId)) {
            if (this.workspaceId !== 'home' && this.isVisible('home')) {
                this.navigateTo('home', undefined, true);
            } else {
                this.workspaceCtor = undefined;
                this.loadedWorkspaceId = undefined;
            }
            return;
        }
        if (this.loadedWorkspaceId === entry.id && this.workspaceCtor) {
            return;
        }
        try {
            const module = await entry.loader();
            if (sequence === this.loadSequence) {
                this.workspaceCtor = module.default;
                this.loadedWorkspaceId = entry.id;
                this.focusMain();
            }
        } catch (error) {
            if (sequence === this.loadSequence) {
                this.workspaceCtor = undefined;
                this.loadedWorkspaceId = undefined;
                this.errorMessage = reduceError(error);
            }
        }
    }

    focusMain() {
        const main = this.template.querySelector('.main');
        if (main) {
            main.scrollTop = 0;
        }
    }

    isVisible(id) {
        const entry = WORKSPACE_BY_ID[id];
        return Boolean(entry && entry.loader && this.shell && (this.shell.visibleWorkspaces || []).includes(id));
    }

    navigateTo(id, recordId, replace) {
        if (!this.isVisible(id)) {
            return;
        }
        this.closePopovers();
        this.sidebarOpen = false;
        const state = { ...((this.pageRef && this.pageRef.state) || {}) };
        state[STATE_WORKSPACE] = id;
        if (recordId) {
            state[STATE_RECORD] = recordId;
        } else {
            delete state[STATE_RECORD];
        }
        if (this.pageRef) {
            this[NavigationMixin.Navigate]({ type: this.pageRef.type, attributes: this.pageRef.attributes, state }, replace === true);
        }
        if (id !== this.workspaceId || recordId !== this.recordId) {
            this.workspaceId = id;
            this.recordId = recordId;
            this.loadWorkspace();
        }
    }

    // ---------- derived state ----------

    get hasCompany() {
        return Boolean(this.company);
    }

    get companyName() {
        return this.company ? this.company.companyName : 'No company';
    }

    get companySub() {
        return this.company ? `${this.company.companyKey}, ${this.company.functionalCurrency}` : '';
    }

    get companyActive() {
        return Boolean(this.company && this.company.setupStatus === 'Active');
    }

    get periodText() {
        if (!this.company) {
            return 'No company selected';
        }
        if (!this.companyActive) {
            return 'Setup in progress';
        }
        if (!this.shell || !this.shell.hasPeriod) {
            return 'No period for today';
        }
        const status = (this.shell.periodStatus || '').toLowerCase();
        return `${this.shell.periodKey} ${formatMonth(this.shell.periodStart)}, ${status}`;
    }

    get periodDotClass() {
        return this.companyActive && this.shell && this.shell.periodStatus === 'Open' ? 'dot open' : 'dot';
    }

    get persona() {
        return (this.shell && this.shell.persona) || {};
    }

    get userInitials() {
        return this.persona.initials || initials(this.persona.userName);
    }

    get companyOptions() {
        const selected = this.company && this.company.companyId;
        return this.companies.map((c) => ({
            ...c,
            className: c.companyId === selected ? 'pop-item sel' : 'pop-item',
            badge: (c.companyKey || c.companyName || '').slice(0, 2).toUpperCase(),
            sub: `${c.companyKey}, ${c.functionalCurrency}, ${c.setupStatus === 'Active' ? 'active' : 'setup in progress'}`,
            selected: c.companyId === selected ? 'true' : 'false'
        }));
    }

    get navGroups() {
        return GROUPS.map((group) => {
            const items = WORKSPACES.filter((w) => w.group === group && this.isVisible(w.id)).map((w) => ({
                ...w,
                className: w.id === this.workspaceId ? 'nav-item active' : 'nav-item',
                current: w.id === this.workspaceId ? 'page' : undefined
            }));
            return { name: group, items };
        }).filter((g) => g.items.length);
    }

    get currentEntry() {
        return WORKSPACE_BY_ID[this.workspaceId] || WORKSPACE_BY_ID.home;
    }

    get showSetupEmpty() {
        return this.hasCompany && !this.companyActive && !SETUP_ALLOWED.includes(this.workspaceId) && this.isVisible(this.workspaceId);
    }

    get ctorReady() {
        return Boolean(this.workspaceCtor) && this.loadedWorkspaceId === this.currentEntry.id;
    }

    get showShellAware() {
        return !this.showSetupEmpty && this.ctorReady && this.currentEntry.shellAware === true;
    }

    get showLegacy() {
        return !this.showSetupEmpty && this.ctorReady && this.currentEntry.shellAware !== true;
    }

    get showNothing() {
        return !this.isLoading && !this.errorMessage && !this.workspaceCtor && !this.showSetupEmpty;
    }

    get setupEmptyTitle() {
        return `Finish setup to start using ${this.currentEntry.label.toLowerCase()}`;
    }

    get setupEmptyText() {
        const status = this.company ? (this.company.setupStatus || '').toLowerCase() : '';
        return `${this.companyName} is ${status}. Posting opens once tax registration, defaults and opening balances are validated.`;
    }

    get canContinueSetup() {
        return this.isVisible('setup');
    }

    get firstActiveCompany() {
        return this.companies.find((c) => c.setupStatus === 'Active' && (!this.company || c.companyId !== this.company.companyId));
    }

    get switchLabel() {
        return this.firstActiveCompany ? `Switch to ${this.firstActiveCompany.companyName}` : '';
    }

    get awareCompanyId() {
        return this.company ? this.company.companyId : undefined;
    }

    get awareCompanyName() {
        return this.company ? this.company.companyName : undefined;
    }

    get awareCurrency() {
        return this.company ? this.company.functionalCurrency : undefined;
    }

    get awareSetupStatus() {
        return this.company ? this.company.setupStatus : undefined;
    }

    get awarePeriodKey() {
        return this.shell && this.shell.hasPeriod ? this.shell.periodKey : undefined;
    }

    get workspaceCaps() {
        return {
            canCreateJournal: Boolean(this.shell && this.shell.canCreateJournal),
            canCreateInvoice: Boolean(this.shell && this.shell.canCreateInvoice)
        };
    }

    get visibleList() {
        return WORKSPACES.filter((w) => this.isVisible(w.id)).map((w) => w.id);
    }

    get sidebarClass() {
        return this.sidebarOpen ? 'sidebar open' : 'sidebar';
    }

    get scrimClass() {
        return this.sidebarOpen ? 'scrim open' : 'scrim';
    }

    get companyPopClass() {
        return this.companyPopOpen ? 'popover company-pop open' : 'popover company-pop';
    }

    get userPopClass() {
        return this.userPopOpen ? 'popover user-pop open' : 'popover user-pop';
    }

    get searchPopClass() {
        return this.searchPopOpen ? 'popover search-pop open' : 'popover search-pop';
    }

    get companyExpanded() {
        return this.companyPopOpen ? 'true' : 'false';
    }

    get userExpanded() {
        return this.userPopOpen ? 'true' : 'false';
    }

    get hasSearchResults() {
        return this.searchResults.length > 0;
    }

    get searchEmptyText() {
        return this.searchBusy ? 'Searching' : `No matches for "${this.searchTerm.trim()}"`;
    }

    get themeLabel() {
        return 'Toggle light and dark theme';
    }

    // ---------- theme ----------

    applyTheme(value, persist) {
        const theme = value === 'dark' || value === 'light' ? value : null;
        this.theme = theme;
        if (theme) {
            this.setAttribute('data-theme', theme);
        } else {
            this.removeAttribute('data-theme');
        }
        if (persist && this.shell) {
            writeStorage(window.localStorage, THEME_STORAGE_PREFIX + this.shell.userId, theme);
        }
    }

    handleThemeToggle() {
        const prefersDark = typeof window.matchMedia === 'function' && window.matchMedia('(prefers-color-scheme: dark)').matches;
        const current = this.theme || (prefersDark ? 'dark' : 'light');
        this.applyTheme(current === 'dark' ? 'light' : 'dark', true);
    }

    // ---------- top bar ----------

    handleBrandClick(event) {
        event.preventDefault();
        this.navigateTo('home');
    }

    handleMenuToggle() {
        this.sidebarOpen = !this.sidebarOpen;
        this.closePopovers();
    }

    handleScrimClick() {
        this.sidebarOpen = false;
    }

    handleCompanyToggle(event) {
        event.stopPropagation();
        const open = !this.companyPopOpen;
        this.closePopovers();
        this.companyPopOpen = open;
    }

    handleUserToggle(event) {
        event.stopPropagation();
        const open = !this.userPopOpen;
        this.closePopovers();
        this.userPopOpen = open;
    }

    async handleCompanyPick(event) {
        const companyId = event.currentTarget.dataset.id;
        this.closePopovers();
        await this.switchCompany(companyId);
    }

    async handleSwitchToActive() {
        if (this.firstActiveCompany) {
            await this.switchCompany(this.firstActiveCompany.companyId);
        }
    }

    async switchCompany(companyId) {
        if (!companyId || (this.company && companyId === this.company.companyId)) {
            return;
        }
        this.isLoading = true;
        this.errorMessage = undefined;
        try {
            this.loadedWorkspaceId = undefined;
            await this.selectCompany(companyId, true);
        } catch (error) {
            this.errorMessage = reduceError(error);
        } finally {
            this.isLoading = false;
        }
    }

    closePopovers() {
        this.companyPopOpen = false;
        this.userPopOpen = false;
        this.searchPopOpen = false;
    }

    handleShellClick() {
        if (this.companyPopOpen || this.userPopOpen || this.searchPopOpen) {
            this.closePopovers();
        }
    }

    stopClick(event) {
        event.stopPropagation();
    }

    // ---------- navigation ----------

    handleNavClick(event) {
        this.navigateTo(event.currentTarget.dataset.id);
    }

    handleContinueSetup() {
        this.navigateTo('setup');
    }

    handleWorkspaceNavigate(event) {
        event.stopPropagation();
        const detail = event.detail || {};
        this.navigateTo(detail.workspace, detail.recordId);
    }

    handleWorkspaceToast(event) {
        event.stopPropagation();
        const detail = event.detail || {};
        this.toast(detail.message, detail.tone);
    }

    toast(message, tone) {
        const toaster = this.template.querySelector('c-sab-toast');
        if (toaster) {
            toaster.show(message, tone);
        }
    }

    handleRetry() {
        this.initialise();
    }

    // ---------- search ----------

    handleSearchInput(event) {
        this.searchTerm = event.target.value || '';
        clearTimeout(this.searchTimer);
        const term = this.searchTerm.trim();
        if (term.length < SEARCH_MIN_LENGTH) {
            this.searchResults = this.localMatches(term);
            this.searchPopOpen = term.length > 0;
            return;
        }
        this.searchBusy = true;
        this.searchPopOpen = true;
        this.searchResults = this.localMatches(term);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.searchTimer = setTimeout(() => this.runSearch(term), SEARCH_DELAY_MS);
    }

    localMatches(term) {
        const q = term.toLowerCase();
        if (!q) {
            return [];
        }
        return WORKSPACES.filter((w) => this.isVisible(w.id) && `${w.label} workspace`.toLowerCase().includes(q)).map((w) => ({
            key: `ws-${w.id}`,
            kind: 'workspace',
            workspace: w.id,
            title: w.label,
            detail: 'Workspace',
            icon: w.icon
        }));
    }

    async runSearch(term) {
        const sequence = ++this.searchSequence;
        try {
            const rows = await searchRecords({ term });
            if (sequence !== this.searchSequence) {
                return;
            }
            const records = (rows || [])
                .filter((r) => this.isVisible(r.workspace))
                .map((r) => ({ ...r, key: `${r.kind}-${r.recordId}` }));
            this.searchResults = [...records, ...this.localMatches(term)].slice(0, SEARCH_MAX_RESULTS);
        } catch {
            if (sequence === this.searchSequence) {
                this.searchResults = this.localMatches(term);
            }
        } finally {
            if (sequence === this.searchSequence) {
                this.searchBusy = false;
            }
        }
    }

    handleSearchKeydown(event) {
        if (event.key === 'Enter' && this.searchResults.length) {
            event.preventDefault();
            this.openResult(this.searchResults[0]);
        } else if (event.key === 'Escape') {
            event.stopPropagation();
            this.clearSearch();
            event.target.blur();
        }
    }

    handleResultClick(event) {
        const key = event.currentTarget.dataset.key;
        const result = this.searchResults.find((r) => r.key === key);
        if (result) {
            this.openResult(result);
        }
    }

    clearSearch() {
        clearTimeout(this.searchTimer);
        this.searchSequence++;
        this.searchTerm = '';
        this.searchResults = [];
        this.searchBusy = false;
        this.searchPopOpen = false;
        const input = this.template.querySelector('.search-input');
        if (input) {
            input.value = '';
        }
    }

    async openResult(result) {
        this.clearSearch();
        if (result.companyId && this.company && result.companyId !== this.company.companyId) {
            const target = this.companies.find((c) => c.companyId === result.companyId);
            await this.switchCompany(result.companyId);
            this.toast(`Switched to ${target ? target.companyName : 'the record company'} to open ${result.title}`);
        }
        this.navigateTo(result.workspace, result.kind === 'workspace' ? undefined : result.recordId);
    }

    // ---------- keyboard ----------

    handleDocumentKeydown(event) {
        if (event.key === 'Escape') {
            if (this.companyPopOpen || this.userPopOpen || this.searchPopOpen || this.sidebarOpen) {
                this.closePopovers();
                this.sidebarOpen = false;
            }
            return;
        }
        const path = typeof event.composedPath === 'function' ? event.composedPath() : [event.target];
        const origin = path[0] || event.target;
        const tag = origin && origin.tagName ? origin.tagName : '';
        const editable = /INPUT|TEXTAREA|SELECT/.test(tag) || (origin && origin.isContentEditable);
        if (event.key === '/' && !editable) {
            const input = this.template.querySelector('.search-input');
            if (input) {
                event.preventDefault();
                input.focus();
            }
        }
    }
}
