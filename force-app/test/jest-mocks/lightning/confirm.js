// Shared manual mock for lightning/confirm. sfdx-lwc-jest ships a real stub whose
// .open() throws; suites that drive a confirm dialog must supply their own resolved
// value. Routing every suite through this one module (via jest.config.js
// moduleNameMapper) instead of per-file jest.mock(..., { virtual: true }) avoids the
// suite-ordering hazard where the inline virtual mock loses to the real stub on a
// shared Jest worker. Tests set the outcome with
// LightningConfirm.open.mockResolvedValue(true/false) in beforeEach.
const open = jest.fn().mockResolvedValue(true);

export default { open };
