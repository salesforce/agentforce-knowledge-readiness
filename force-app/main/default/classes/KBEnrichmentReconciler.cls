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
 * Closes open Enrichment_Candidate__c rows when their underlying article gets
 * a new published version.
 *
 * Decision matrix per open candidate whose Knowledge_Article_Id__c is in the
 * just-published article id set:
 *   - candidate's Draft_Article_Version_Id__c IS the just-published KAV id
 *     → close as 'Published' (our draft made it to Online, regardless of
 *       which UI clicked the publish button).
 *   - otherwise → close as 'Superseded' (a different version is now Online,
 *     this candidate's draft is no longer relevant).
 *
 * Sharing model: `with sharing` is intentional. This class only
 * UPDATES already-visible candidate rows that the running user can see —
 * callers run in user context. No need to elevate.
 *
 * Callers: KBEnrichmentController's Approve/publish graceful-close path (the
 * in-app publish flow). Publishing an enrichment draft through the Suggested
 * Drafts inbox closes the candidate here.
 *
 * Known edge: an enrichment draft published PURELY natively (from the standard
 * Knowledge layout, without returning to the inbox to Approve) leaves the
 * candidate's Status open in the data — it is still hidden from the inbox by
 * the linked draft's PublishStatus filter, so it is not user-visible. There is
 * no lazy inbox-load reconcile on the enrichment side (that DML-on-view path
 * was removed — opening a view must not mutate records). This edge was
 * previously "covered" by a Knowledge__kav after-update trigger, which was
 * retired after it was proven not to fire reliably on publish (publish
 * generally does not fire Apex triggers on Knowledge__kav — it changes
 * publication status without an incidental save).
 */
public with sharing class KBEnrichmentReconciler {

    /**
     * Closes open enrichment candidates for the given just-published article
     * ids: those whose Draft_Article_Version_Id__c matches a now-Online KAV id
     * are 'Published', the rest 'Superseded'.
     */
    public static void closeForPublishedArticles(Set<Id> publishedArticleIds, Set<Id> nowOnlineKavIds) {
        if (publishedArticleIds == null || publishedArticleIds.isEmpty()) return;

        // Stringify for the Text(18) custom field comparison.
        Set<String> articleIdStrs = new Set<String>();
        for (Id aid : publishedArticleIds) articleIdStrs.add(String.valueOf(aid));

        Set<String> onlineKavIdStrs = new Set<String>();
        if (nowOnlineKavIds != null) {
            for (Id kid : nowOnlineKavIds) onlineKavIdStrs.add(String.valueOf(kid));
        }

        List<Enrichment_Candidate__c> open = [
            SELECT Id, Status__c, Is_Closed__c, Draft_Article_Version_Id__c, Knowledge_Article_Id__c
            FROM Enrichment_Candidate__c
            WHERE Is_Closed__c = false
            AND Knowledge_Article_Id__c IN :articleIdStrs
            LIMIT 1000
        ];
        if (open.isEmpty()) return;

        for (Enrichment_Candidate__c ec : open) {
            ec.Is_Closed__c = true;
            if (onlineKavIdStrs.contains(ec.Draft_Article_Version_Id__c)) {
                ec.Status__c = 'Published';
            } else {
                ec.Status__c = 'Superseded';
            }
        }
        Database.update(open, false);
    }
}
