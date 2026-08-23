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
import LightningDatatable from 'lightning/datatable';
import contentCellTemplate from './contentCellTemplate.html';

/**
 * Extension of lightning-datatable that registers a 'contentCell' custom
 * type. Used by kbArticleSelector to render content-field columns with
 * clamped text + a Show more toggle. All other columns fall
 * back to the standard lightning-datatable types unchanged.
 */
export default class KbArticleSelectorDatatable extends LightningDatatable {
    static customTypes = {
        contentCell: {
            template: contentCellTemplate,
            standardCellLayout: true,
            typeAttributes: []
        }
    };
}
