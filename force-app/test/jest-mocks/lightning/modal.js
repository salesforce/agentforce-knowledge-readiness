// Shared manual mock for the lightning/modal base class (LightningModal).
// sfdx-lwc-jest does not ship a stub for `lightning/modal` (only modalBody /
// modalHeader / modalFooter), so any component that `extends LightningModal`
// fails to resolve its import at suite-load time. Routing every suite through
// this one module (via jest.config.js moduleNameMapper) mirrors the approach
// used for lightning/confirm and lightning/empApi.
//
// The mock extends LightningElement so migrated modal components remain valid
// custom elements that can still be mounted with createElement for behavioural
// assertions. `open` is a jest.fn returning a resolved promise by default;
// tests that assert on the open() result set it with
// LightningModal.open.mockResolvedValue(...). `close` records the payload the
// component passed so tests can assert the modal's return value.
import { LightningElement } from 'lwc';

export default class LightningModal extends LightningElement {
    static open = jest.fn().mockResolvedValue(undefined);

    // Instance API surfaced by the real base class. Recorded so tests can
    // assert the component closed with the expected payload.
    close(result) {
        this._closeResult = result;
        this.dispatchEvent(new CustomEvent('close', { detail: result }));
    }

    disableClose = false;
    size;
    label;
    description;
}
