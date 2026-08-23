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

// horizontal bar chart of article-readiness distribution. Sized to fit a
// 1-of-3 column alongside the score gauge and run-details panel — bars run full
// width with the status label + count/percent inline (no separate legend
// column), which reads better in the narrow card than a donut did.
export default class KbScoreDistributionChart extends LightningElement {
    @api readyCount = 0;
    @api needsWorkCount = 0;
    @api notReadyCount = 0;

    get total() {
        return (this.readyCount || 0) + (this.needsWorkCount || 0) + (this.notReadyCount || 0);
    }

    get hasData() {
        return this.total > 0;
    }

    get readyPercent() {
        return this.total > 0 ? Math.round((this.readyCount / this.total) * 100) : 0;
    }

    get needsWorkPercent() {
        return this.total > 0 ? Math.round((this.needsWorkCount / this.total) * 100) : 0;
    }

    get notReadyPercent() {
        return this.total > 0 ? Math.round((this.notReadyCount / this.total) * 100) : 0;
    }

    get readyBarStyle() {
        return `width: ${this.readyPercent}%`;
    }

    get needsWorkBarStyle() {
        return `width: ${this.needsWorkPercent}%`;
    }

    get notReadyBarStyle() {
        return `width: ${this.notReadyPercent}%`;
    }
}
