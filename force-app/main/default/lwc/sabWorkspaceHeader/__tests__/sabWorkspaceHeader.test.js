import { createElement } from 'lwc';
import SabWorkspaceHeader from 'c/sabWorkspaceHeader';

describe('c-sab-workspace-header', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('renders crumbs, title, description and optional tag', () => {
        const el = createElement('c-sab-workspace-header', { is: SabWorkspaceHeader });
        el.companyName = 'Harbourline Trading';
        el.group = 'Optional modules';
        el.heading = 'Capital & equity';
        el.description = 'Share register.';
        el.optionalModule = true;
        document.body.appendChild(el);
        const root = el.shadowRoot;
        expect(root.querySelector('.crumbs').textContent).toBe('Harbourline Trading/Optional modulesOptional module');
        expect(root.querySelector('.ws-title').textContent).toBe('Capital & equity');
        expect(root.querySelector('.ws-desc').textContent).toBe('Share register.');
    });

    it('omits crumbs and description when not given', () => {
        const el = createElement('c-sab-workspace-header', { is: SabWorkspaceHeader });
        el.heading = 'Finance home';
        document.body.appendChild(el);
        expect(el.shadowRoot.querySelector('.crumbs')).toBeNull();
        expect(el.shadowRoot.querySelector('.ws-desc')).toBeNull();
    });
});
