// Manual mock for lightning/empApi. A fresh factory per test file, re-armed in
// beforeEach so no suite can leak a stale subscribe/onError implementation into
// a sibling suite under a shared Jest worker.
export const subscribe = jest.fn().mockResolvedValue({ id: 'sub' });
export const unsubscribe = jest.fn().mockResolvedValue({});
export const onError = jest.fn();
export const setDebugFlag = jest.fn().mockResolvedValue();
export const isEmpEnabled = jest.fn().mockResolvedValue();
