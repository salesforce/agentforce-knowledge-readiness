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

export default class KbScoreGauge extends LightningElement {
    @api score = 0;
    @api label = 'Score';
    @api size = 'medium'; // small | medium | large

    get scoreValue() {
        return Math.round(this.score || 0);
    }

    get tierLabel() {
        const s = this.scoreValue;
        if (s >= 80) return 'Ready';
        if (s >= 50) return 'Needs Work';
        return 'Critical';
    }

 // the "Needs Work" tier keeps the recognizable bright amber (#fe9339) on
    // the ring — a large graphic redundant with the dark number+label — so it stays
    // visually distinct from the red "Critical" tier. The earlier deep-orange
    // (#c14a00) fix passed contrast but read too close to red (#c62828), so the tier
    // was hard to tell apart. Contrast is now carried by the TEXT: the score number
    // and badge text darken to #3d2400 (6.5:1 on the amber fill / cream badge, and
    // high contrast on white) rather than recoloring the fill.
    get tierColor() {
        const s = this.scoreValue;
        if (s >= 80) return '#2e7d32';
        if (s >= 50) return '#fe9339';
        return '#c62828';
    }

    // Text/number color — dark on the amber tier so it passes AA against white and
    // the cream badge without shifting the amber hue toward red.
    get tierTextColor() {
        const s = this.scoreValue;
        if (s >= 80) return '#2e7d32';
        if (s >= 50) return '#3d2400';
        return '#c62828';
    }

    get tierBgColor() {
        const s = this.scoreValue;
        if (s >= 80) return '#e8f5e9';
        if (s >= 50) return '#fff8e1';
        return '#ffebee';
    }

    get containerClass() {
        return `gauge-container gauge-${this.size}`;
    }

    get ringStyle() {
        const pct = Math.min(100, Math.max(0, this.scoreValue));
        const circumference = 2 * Math.PI * 54; // radius=54
        const offset = circumference - (pct / 100) * circumference;
        return `stroke-dasharray: ${circumference}; stroke-dashoffset: ${offset}; stroke: ${this.tierColor};`;
    }

    get bgRingStyle() {
        const circumference = 2 * Math.PI * 54;
        return `stroke-dasharray: ${circumference}; stroke-dashoffset: 0;`;
    }

    get scoreStyle() {
        return `color: ${this.tierTextColor};`;
    }

    get badgeStyle() {
        return `background-color: ${this.tierBgColor}; color: ${this.tierTextColor};`;
    }
}