/*
 * Copyright (c) 2026, Salesforce, Inc.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
/**
 * Shared navigation helper for the KB readiness LWCs.
 *
 * WHY THIS EXISTS: under Lightning Web Security, `window.open(url,
 * '_blank')` throws "Cannot open same-origin URL in a new browsing context" —
 * LWS blocks the `window.open` API for same-origin URLs regardless of how the
 * URL was produced (it fails even with a NavigationMixin.GenerateUrl URL). The
 * block is on the API, not the URL.
 *
 * A browser-driven navigation — a real DOM anchor with target="_blank" that the
 * user's click gesture activates — is permitted. This is the same mechanism
 * `kbArticleScoreCard` already uses via a static markup `<a target="_blank">`;
 * the callsites here can't be markup anchors (they hang off button / row-action
 * handlers), so we synthesize the anchor, click it, and drop it.
 *
 * Plain ES module (isExposed=false) — import it, don't place it on a page.
 */

// Only these href shapes are allowed through openInNewTab. Anchor clicks are
// FAR more dangerous than the window.open they replaced: a clicked
// <a href="javascript:…"> executes script in the Lightning origin, whereas
// window.open('javascript:…') was comparatively inert. All current callers
// pass server-built same-origin URLs (a leading "/", or an absolute http(s)),
// so this allowlist is transparent to them — it's a guard against a FUTURE
// caller passing a data-controlled href (e.g. a Knowledge URL/text field an
// author sets). We allowlist safe shapes rather than blocklist scheme names so
// obfuscated variants (`\tjavascript:`, `JavaScript:`, `&#x6a;…`) can't slip
// through: anything that isn't clearly a relative path or an http(s) URL is
// refused.
const SAFE_URL = /^(?:\/(?!\/)|https?:\/\/)/i;

/**
 * Open a URL in a new browser tab via a synthesized native anchor click.
 *
 * Call this synchronously from the user's click handler so the navigation is
 * attributed to the gesture (browsers block programmatic new-tab opens that
 * aren't). Accepts a same-origin relative URL (`/lightning/r/<id>/view`, a
 * Setup deep-link, …) or an absolute `http(s)` URL — any other scheme
 * (`javascript:`, `data:`, `vbscript:`, protocol-relative `//host`) is refused
 * as a no-op, since a clicked anchor would otherwise execute it in this origin.
 *
 * rel="noopener noreferrer" prevents reverse-tabnabbing (the opened page can't
 * reach back through `window.opener`); modern browsers default to this for
 * target="_blank" but legacy / enterprise configs may not.
 *
 * @param {string} url - the destination href. No-op if blank or unsafe-scheme.
 */
export function openInNewTab(url) {
    if (!url) return;
    // Trim so leading-whitespace obfuscation (`\tjavascript:…`) can't dodge the
    // allowlist, then require a safe shape (relative "/path" or http(s)://…).
    const href = String(url).trim();
    if (!SAFE_URL.test(href)) {
        // eslint-disable-next-line no-console
        console.warn('openInNewTab: refusing unsafe or unsupported URL', url);
        return;
    }
    const a = document.createElement('a');
    a.href = href;
    a.target = '_blank';
    a.rel = 'noopener noreferrer';
    // Attach → click → detach. Chrome/Safari navigate a detached anchor, but
    // Firefox requires the node to be in the document for a synthetic click to
    // fire the navigation — so we append briefly and remove immediately. The
    // anchor never renders (zero layout, same tick), leaving the DOM as it was.
    // removeChild runs in finally so a throwing click() (proxied DOM ops under
    // LWS can, in principle) never orphans the invisible anchor in the DOM.
    document.body.appendChild(a);
    try {
        a.click();
    } finally {
        document.body.removeChild(a);
    }
}
