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
import { LightningElement, api } from 'lwc';

// "Run details" panel shown beside the score gauge and distribution
// bar chart on the assessment results view. Surfaces the run's timing (start /
// finish / duration) which previously lived only on the run record. Reads the
// AssessmentRunResult DTO's startedAt / completedAt (startedAt prefers
// Scan_Start_Time__c, falls back to CreatedDate — set server-side).
export default class KbRunDetailsPanel extends LightningElement {
    @api startedAt;   // ISO datetime string
    @api completedAt; // ISO datetime string

    get startedDisplay() {
        return this.startedAt ? this._fmt(this.startedAt) : '—';
    }

    get completedDisplay() {
        return this.completedAt ? this._fmt(this.completedAt) : 'In progress';
    }

    // Human duration startedAt → completedAt. Blank until both ends are known.
    get durationDisplay() {
        if (!this.startedAt || !this.completedAt) {
            return '—';
        }
        const ms = new Date(this.completedAt).getTime() - new Date(this.startedAt).getTime();
        if (isNaN(ms) || ms < 0) {
            return '—';
        }
        const totalSec = Math.round(ms / 1000);
        if (totalSec < 60) {
            return `${totalSec}s`;
        }
        const min = Math.floor(totalSec / 60);
        const sec = totalSec % 60;
        if (min < 60) {
            return sec ? `${min}m ${sec}s` : `${min}m`;
        }
        const hr = Math.floor(min / 60);
        const remMin = min % 60;
        return remMin ? `${hr}h ${remMin}m` : `${hr}h`;
    }

    _fmt(iso) {
        const d = new Date(iso);
        if (isNaN(d.getTime())) {
            return '—';
        }
        // Local short date + time, e.g. "Jun 23, 2026, 1:42 PM"
        return d.toLocaleString(undefined, {
            month: 'short',
            day: 'numeric',
            year: 'numeric',
            hour: 'numeric',
            minute: '2-digit'
        });
    }
}
