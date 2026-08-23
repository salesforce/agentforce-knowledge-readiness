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
import OVERALL_HELP from '@salesforce/label/c.KB_Helptext_Overall_Score';

export default class KbOverallScoreCard extends LightningElement {
    @api score = 0;
    @api totalArticles = 0;
    overallHelp = OVERALL_HELP;

    get displayScore() {
        return Math.round(this.score || 0);
    }

    get readinessLabel() {
        const s = this.score || 0;
        if (s >= 80) return 'Ready';
        if (s >= 50) return 'Needs Work';
        return 'Not Ready';
    }

 // ring stroke only (a large graphic; the score number + label are dark/grey
    // text, so contrast is carried there). Keep the recognizable bright amber so the
    // "Needs Work" ring stays distinct from the red "Not Ready" ring.
    get scoreColor() {
        const s = this.score || 0;
        if (s >= 80) return '#2e844a'; // Green
        if (s >= 50) return '#fe9339'; // Amber
        return '#c23934'; // Red
    }

    get dashArray() {
        const circumference = 2 * Math.PI * 45;
        return `${circumference} ${circumference}`;
    }

    get dashOffset() {
        const circumference = 2 * Math.PI * 45;
        const progress = (this.score || 0) / 100;
        return circumference * (1 - progress);
    }

    get pluralSuffix() {
        return this.totalArticles !== 1 ? 's' : '';
    }
}