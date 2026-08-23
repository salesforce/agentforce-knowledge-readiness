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
import LightningDatatable from "lightning/datatable";
import articleCellTemplate from "./articleCellTemplate.html";

/**
 * Extension of lightning-datatable that registers an 'articleCell' custom type,
 * used by knowledgeAuditQueue to render the Article A / Article B columns
 * with the existing kbCandidateArticleCell (truncating link + hover popover).
 * All other columns fall back to the standard lightning-datatable types — which
 * gives the Duplicates queue resizable columns and native wrap/clip on the long
 * Reasoning text for free. The standard 'action' type provides the row menu.
 */
export default class KnowledgeAuditDatatable extends LightningDatatable {
  static customTypes = {
    articleCell: {
      template: articleCellTemplate,
      standardCellLayout: true,
      typeAttributes: ["articleId"],
    },
  };
}
