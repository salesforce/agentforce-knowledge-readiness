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
 * Sibling of KBEnrichmentReconciler for Duplicate_Candidate__c. A DC ties
 * three article-level ids: the two source articles in the duplicate pair
 * and (post-Tier 4) the merged Golden Record draft.
 *
 * Decision matrix per open candidate whose article-level fields intersect
 * the just-published article ids:
 *   - Merged_Article__c IS the just-published KAV id
 *     → close as 'Resolved' (our merged draft made it to Online).
 *   - otherwise → close as 'Superseded' (one of the linked articles was
 *     republished outside our flow; the candidate is no longer relevant).
 *
 * Sharing model: `with sharing` is intentional. Same rationale as
 * KBEnrichmentReconciler — this class only UPDATES candidates the running
 * user already sees. Candidate visibility is controlled-by-parent (master-detail
 * to the assessment run), so there is no insert-side sharing to elevate.
 *
 * Callers of closeForPublishedArticles: DuplicateCandidateController's
 * publishGoldenRecord (the in-app "Publish Golden Record" action, which
 * publishes the merged draft then closes + archives here). The duplicates
 * queue additionally reconciles lazily on inbox load via reconcileInboxRows
 * (reconcileActiveCandidates) — that path catches a source article republished
 * out of band. (Both replaced a Knowledge__kav after-update trigger retired
 * once it was proven not to fire reliably on publish.)
 */
public with sharing class KBDuplicateCandidateReconciler {

 // archiving a loser goes through the publisher indirection so tests
    // (where KAVs can't reach Online) can stub it.
    @TestVisible
    private static KBKnowledgePublisher.IPublisher publisher = new KBKnowledgePublisher.RealPublisher();

    /**
     * Closes candidates for the just-published article ids and archives merged
     * "loser" articles. Returns the article ids whose archive was attempted but
     * failed (empty on full success) so a caller can report a partial outcome
     * rather than a blanket success — archiving is best-effort per loser and
     * must not roll back the successful publish/close.
     */
    public static List<Id> closeForPublishedArticles(Set<Id> publishedArticleIds, Set<Id> nowOnlineKavIds) {
        if (publishedArticleIds == null || publishedArticleIds.isEmpty()) return new List<Id>();

 // a merge-survivor draft just went Online — retire any "loser"
        // articles that were merged into it (derived from the candidate junction).
        // Deferred-archive: we only retire losers once their enriched survivor is
        // actually published, never while the survivor is still a draft.
        List<Id> failedArchiveIds = archiveMergedLosers(publishedArticleIds);

        Set<String> articleIdStrs = new Set<String>();
        for (Id aid : publishedArticleIds) articleIdStrs.add(String.valueOf(aid));

        Set<String> onlineKavIdStrs = new Set<String>();
        if (nowOnlineKavIds != null) {
            for (Id kid : nowOnlineKavIds) onlineKavIdStrs.add(String.valueOf(kid));
        }

        List<Duplicate_Candidate__c> open = [
            SELECT Id, Status__c,
                   Knowledge_Article_Id_1__c, Knowledge_Article_Id_2__c,
                   Merged_Knowledge_Article_Id__c, Merged_Article__c
            FROM Duplicate_Candidate__c
            WHERE Status__c = 'Pending'
            AND (Knowledge_Article_Id_1__c IN :articleIdStrs
              OR Knowledge_Article_Id_2__c IN :articleIdStrs
              OR Merged_Knowledge_Article_Id__c IN :articleIdStrs)
            LIMIT 1000
        ];
        if (open.isEmpty()) return failedArchiveIds;

        for (Duplicate_Candidate__c dc : open) {
            // If our merged-article draft just went Online, that's the
            // happy "Resolved" path — the merge succeeded.
            if (String.isNotBlank(dc.Merged_Article__c)
                && onlineKavIdStrs.contains(dc.Merged_Article__c)) {
                dc.Status__c = 'Resolved';
            } else {
                dc.Status__c = 'Superseded';
            }
        }
        Database.update(open, false);
        return failedArchiveIds;
    }

    /**
     * Lazy reconciliation hook for the duplicates inbox loader, operating over
     * the three DC article-id slots. (The enrichment inbox filters its list by
     * PublishStatus rather than reconciling on load; this duplicate-candidate
     * path reconciles on load instead.)
     */
    public static Set<Id> reconcileInboxRows(List<Duplicate_Candidate__c> rows) {
        Set<Id> closedIds = new Set<Id>();
        if (rows == null || rows.isEmpty()) return closedIds;

        // Collect every article id referenced by any open DC, plus the
        // KAV-version ids the DC was originally created against (the recency
        // guard below uses these to skip DCs whose source versions are still
        // the live published version).
        Map<Id, Set<String>> articleIdsByCandidate = new Map<Id, Set<String>>();
        Map<Id, Set<String>> sourceKavsByCandidate = new Map<Id, Set<String>>();
        Set<String> allArticleIds = new Set<String>();
        for (Duplicate_Candidate__c dc : rows) {
            if (dc.Status__c != 'Pending') continue;
            Set<String> ids = new Set<String>();
            if (String.isNotBlank(dc.Knowledge_Article_Id_1__c)) ids.add(dc.Knowledge_Article_Id_1__c);
            if (String.isNotBlank(dc.Knowledge_Article_Id_2__c)) ids.add(dc.Knowledge_Article_Id_2__c);
            if (String.isNotBlank(dc.Merged_Knowledge_Article_Id__c)) ids.add(dc.Merged_Knowledge_Article_Id__c);
            if (!ids.isEmpty()) {
                articleIdsByCandidate.put(dc.Id, ids);
                allArticleIds.addAll(ids);
            }
            Set<String> sourceKavs = new Set<String>();
            if (String.isNotBlank(dc.Knowledge_Article_1__c)) sourceKavs.add(dc.Knowledge_Article_1__c);
            if (String.isNotBlank(dc.Knowledge_Article_2__c)) sourceKavs.add(dc.Knowledge_Article_2__c);
            sourceKavsByCandidate.put(dc.Id, sourceKavs);
        }
        if (allArticleIds.isEmpty()) return closedIds;

        Map<String, Id> onlineKavByArticle = new Map<String, Id>();
        Set<Id> onlineKavIdSet = new Set<Id>();
        for (Knowledge__kav k : [
            SELECT Id, KnowledgeArticleId
            FROM Knowledge__kav
            WHERE PublishStatus = 'Online'
            AND IsLatestVersion = true
            AND KnowledgeArticleId IN :allArticleIds
        ]) {
            onlineKavByArticle.put(String.valueOf(k.KnowledgeArticleId), k.Id);
            onlineKavIdSet.add(k.Id);
        }
        if (onlineKavByArticle.isEmpty()) return closedIds;

        List<Duplicate_Candidate__c> toUpdate = new List<Duplicate_Candidate__c>();
        for (Duplicate_Candidate__c dc : rows) {
            if (dc.Status__c != 'Pending') continue;
            Set<String> aIds = articleIdsByCandidate.get(dc.Id);
            if (aIds == null || aIds.isEmpty()) continue;

 // Recency guard: a DC is created from already-Online
            // articles. Only treat as stale if the now-Online KAV is DIFFERENT
            // from the version the DC was created against (or our merged draft).
            // If both source KAVs are still Online (no manual republish),
            // skip the DC.
            Set<String> sourceKavs = sourceKavsByCandidate.get(dc.Id);
            Boolean isStale = false;
            for (String articleId : aIds) {
                Id onlineKav = onlineKavByArticle.get(articleId);
                if (onlineKav == null) continue;
                String onlineKavStr = String.valueOf(onlineKav);
                if (sourceKavs != null && sourceKavs.contains(onlineKavStr)) {
                    // Same source version still Online — not stale for this slot.
                    continue;
                }
                isStale = true;
                break;
            }
            if (!isStale) continue;

            // Merged-draft happy path takes precedence over Superseded.
            Id mergedKavId = null;
            if (String.isNotBlank(dc.Merged_Article__c)) {
                try { mergedKavId = Id.valueOf(dc.Merged_Article__c); } catch (Exception ignore) {}
            }
            if (mergedKavId != null && onlineKavIdSet.contains(mergedKavId)) {
                dc.Status__c = 'Resolved';
            } else {
                dc.Status__c = 'Superseded';
            }
            toUpdate.add(dc);
            closedIds.add(dc.Id);
        }
        if (!toUpdate.isEmpty()) Database.update(toUpdate, false);
        return closedIds;
    }

    /**
 * retire "loser" articles whose enriched survivor just went Online.
     *
     * The merge relationship lives on the Duplicate_Candidate__c junction, NOT
     * on the loser article: a probe (CDO49, 2026-06-16) proved Knowledge__kav
     * custom fields are writable ONLY on a Draft version — an Online or Archived
     * KAV write fails with FIELD_INTEGRITY_EXCEPTION ("Only draft articles can be
     * updated"). The earlier design stamped Merged_Into__c on the loser's Online
     * version at merge time, which silently no-opped, so losers were never
     * archived. We instead derive losers from the junction, whose article-level
     * master ids survive version churn:
     *   - the survivor master = Merged_Knowledge_Article_Id__c (set at merge),
     *   - the loser master = whichever of Knowledge_Article_Id_1/2__c is NOT the
     *     survivor master (a candidate is always a PAIR, even within a cluster,
     *     which fans out into one resolved pair per loser — so this enumerates
     *     all N losers of an N:1 merge naturally).
     * Once the survivor publishes (its master id is in publishedArticleIds) we
     * archive each loser's Online version. Best-effort per article — a failure to
     * archive one loser must not block the candidate reconciliation above, but the
     * failed loser article ids are returned so the caller can surface a partial
     * outcome instead of a false "all archived".
     */
    private static List<Id> archiveMergedLosers(Set<Id> publishedArticleIds) {
        List<Id> failedArchiveIds = new List<Id>();
        Set<String> survivorMasterIds = new Set<String>();
        for (Id aid : publishedArticleIds) survivorMasterIds.add(String.valueOf(aid));

        // Resolved merge candidates whose survivor (Merged_Knowledge_Article_Id__c)
        // just published. Each row's loser is the non-survivor article id.
        Set<String> loserMasterIds = new Set<String>();
        for (Duplicate_Candidate__c dc : [
            SELECT Knowledge_Article_Id_1__c, Knowledge_Article_Id_2__c,
                   Merged_Knowledge_Article_Id__c
            FROM Duplicate_Candidate__c
            WHERE Status__c = 'Resolved'
            AND Merged_Knowledge_Article_Id__c IN :survivorMasterIds
            LIMIT 1000
        ]) {
            String survivorMaster = dc.Merged_Knowledge_Article_Id__c;
            for (String loser : new List<String>{
                dc.Knowledge_Article_Id_1__c, dc.Knowledge_Article_Id_2__c
            }) {
                // Skip blanks and the survivor itself (never archive the article
                // that just published).
                if (String.isNotBlank(loser) && loser != survivorMaster
                    && !survivorMasterIds.contains(loser)) {
                    loserMasterIds.add(loser);
                }
            }
        }
        if (loserMasterIds.isEmpty()) return failedArchiveIds;

        // Archive only losers still Online (latest version).
        List<Knowledge__kav> losers = [
            SELECT KnowledgeArticleId
            FROM Knowledge__kav
            WHERE KnowledgeArticleId IN :loserMasterIds
            AND PublishStatus = 'Online'
            AND IsLatestVersion = true
            LIMIT 1000
        ];
        for (Knowledge__kav loser : losers) {
            try {
                publisher.archiveOnlineArticle(loser.KnowledgeArticleId);
            } catch (Exception e) {
                failedArchiveIds.add(loser.KnowledgeArticleId);
                System.debug(LoggingLevel.WARN,
                    'KBDuplicateCandidateReconciler.archiveMergedLosers: failed to archive '
                    + loser.KnowledgeArticleId + ': ' + e.getMessage());
            }
        }
        return failedArchiveIds;
    }
}
