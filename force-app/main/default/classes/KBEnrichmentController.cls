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
public with sharing class KBEnrichmentController {

    @TestVisible
    private static KBKnowledgePublisher.IPublisher publisher = new KBKnowledgePublisher.RealPublisher();

    @AuraEnabled(cacheable=true)
    public static EnrichmentInboxData getEnrichmentInbox(Integer limitSize, String runId) {
        Integer safeLimit = (limitSize != null && limitSize > 0 && limitSize <= 200) ? limitSize : 100;

        Id runIdSafe = parseOptionalId(runId);
        if (String.isNotBlank(runId) && runIdSafe == null) {
            // Garbage input → empty result, never fall through to all-rows match.
            return new EnrichmentInboxData();
        }

 // Includes Knowledge_Article_Id__c so the LWC's reconcile hook
        // can decide which rows are stale without a re-query.
 // Assessment_Run__c links a candidate back to the assessment run whose
        // recommendations triggered the AI Fix. KBImprovementFixService stamps it on
        // write; the KB_Assessment_Admin / KB_Assessment_Setup_Admin permsets grant FLS
        // so this USER_MODE query can read it. When a runId is supplied we scope to it —
        // without the filter a run-scoped inbox would show cross-run candidates.
        String query = 'SELECT Id, Source_Article_Version_Id__c, Source_Article_Title__c, ' +
                       'Draft_Article_Version_Id__c, Confidence_Score__c, Status__c, ' +
                       'Reason__c, Is_Closed__c, Knowledge_Article_Id__c, ' +
                       'Recommended_Action__c, CreatedDate, ' +
                       'Assessment_Run__c, Assessment_Run__r.Name ' +
                       'FROM Enrichment_Candidate__c ' +
                       'WHERE Is_Closed__c = false';
        Map<String, Object> binds = new Map<String, Object>{ 'safeLimit' => safeLimit };
        if (runIdSafe != null) {
            query += ' AND Assessment_Run__c = :runIdSafe';
            binds.put('runIdSafe', runIdSafe);
        }
        query += ' ORDER BY Confidence_Score__c DESC, CreatedDate DESC LIMIT :safeLimit';

        List<Enrichment_Candidate__c> candidateRows =
            Database.queryWithBinds(query, binds, AccessLevel.USER_MODE);

        if (candidateRows.isEmpty()) {
            return new EnrichmentInboxData();
        }
        // The suggested-drafts list is filtered by the LINKED DRAFT'S
        // PublishStatus below — we only surface a candidate whose draft is
        // still an actual Draft. This replaces the former on-inbox-load DML
        // reconciler (opening a view must not mutate records). The durable
        // Is_Closed__c close happens on the in-app Approve/publish path
        // (publishCandidate → closeEnrichmentCandidatesForDraft on the primary
        // path; the KBEnrichmentReconciler graceful-close fallback only when the
        // draft is already Online/Archived/deleted). A purely-native publish
        // leaves Status open in data but hidden here by this filter (see
        // KBEnrichmentReconciler for the known edge).

        Set<Id> draftIds = new Set<Id>();
        for (Enrichment_Candidate__c row : candidateRows) {
            if (String.isNotBlank(row.Draft_Article_Version_Id__c)) {
                try {
                    draftIds.add(Id.valueOf(row.Draft_Article_Version_Id__c));
                } catch (Exception e) { /* skip malformed IDs */ }
            }
        }

        Map<Id, Knowledge__kav> draftsById = new Map<Id, Knowledge__kav>();
        if (!draftIds.isEmpty()) {
 // part 2 — degrade read (enrichment inbox preview): FLS-strip so a
            // user lacking FLS on a content field still sees the rest of the row.
 // PublishStatus drives the still-a-draft filter — it's a
            // standard always-readable field, so the strip leaves it intact.
            List<Knowledge__kav> draftRows = (List<Knowledge__kav>) Security.stripInaccessible(
                AccessType.READABLE,
                [
                    SELECT Id, Title, Summary, UrlName, LastModifiedDate, PublishStatus
                    FROM Knowledge__kav
                    WHERE Id IN :draftIds
                ]
            ).getRecords();
            for (Knowledge__kav draft : draftRows) {
                draftsById.put(draft.Id, draft);
            }
        }

        EnrichmentInboxData data = new EnrichmentInboxData();
        Integer hiddenPublished = 0;
        for (Enrichment_Candidate__c row : candidateRows) {
 // a suggested draft belongs in the list only while its linked
            // draft is STILL a draft. Once that draft is published (or a newer
            // version supersedes it), the row drops out — filtered here in the
            // UI query, not via a record-mutating procedure on inbox open.
            // Positive-evidence only: we hide a row solely when we resolved the
            // linked draft AND its PublishStatus is present and not Draft. A
            // missing/unresolved draft or a stripped/blank status leaves the row
            // visible, so an FLS or sharing gap can never silently empty the
            // list (mirrors the degrade-read stance already taken above).
            Id linkedDraftId = null;
            if (String.isNotBlank(row.Draft_Article_Version_Id__c)) {
                try { linkedDraftId = Id.valueOf(row.Draft_Article_Version_Id__c); } catch (Exception e) { linkedDraftId = null; }
            }
            if (linkedDraftId != null && draftsById.containsKey(linkedDraftId)) {
                String ps = draftsById.get(linkedDraftId).PublishStatus;
                if (String.isNotBlank(ps) && !KBPublishStatusHelper.isDraft(ps)) {
                    hiddenPublished++;
                    continue;
                }
            }

            SplitProposalRow proposal = new SplitProposalRow();
            proposal.proposalId = String.valueOf(row.Id);
            proposal.sourceArticleId = row.Source_Article_Version_Id__c;
            proposal.sourceArticleTitle = row.Source_Article_Title__c;
            proposal.sourceArticleUrl = String.isNotBlank(row.Source_Article_Version_Id__c) ? '/' + row.Source_Article_Version_Id__c : null;
            proposal.draftArticleId = row.Draft_Article_Version_Id__c;
            proposal.draftArticleUrl = String.isNotBlank(row.Draft_Article_Version_Id__c) ? '/' + row.Draft_Article_Version_Id__c : null;
            proposal.confidenceScore = row.Confidence_Score__c;
            proposal.flagType = 'Enrichment';
            proposal.status = row.Status__c;
            proposal.reason = row.Reason__c;
            proposal.createdDate = row.CreatedDate;
            proposal.recommendedAction = row.Recommended_Action__c;
 // name of the assessment run that triggered this fix (null when unlinked).
            proposal.sourceRunName = row.Assessment_Run__r != null ? row.Assessment_Run__r.Name : null;

            if (String.isNotBlank(row.Draft_Article_Version_Id__c)) {
                Id draftId;
                try { draftId = Id.valueOf(row.Draft_Article_Version_Id__c); } catch (Exception e) { draftId = null; }
                if (draftId != null && draftsById.containsKey(draftId)) {
                    Knowledge__kav draft = draftsById.get(draftId);
                    proposal.draftTitle = draft.Title;
                    proposal.draftSummary = draft.Summary;
                    proposal.draftUrlName = draft.UrlName;
                    proposal.draftLastModifiedDate = draft.LastModifiedDate;
                }
            }

            if (row.Status__c == 'Approved') {
                data.approvedCount++;
            } else if (row.Status__c == 'Rejected') {
                data.rejectedCount++;
            } else {
                data.pendingCount++;
            }
            data.candidates.add(proposal);
        }
 // reflect only drafts still shown (published/superseded rows were
        // filtered out above), so the "Drafts" summary card matches the list.
        data.totalDrafts = data.candidates.size();
        if (hiddenPublished > 0) {
            System.debug(LoggingLevel.INFO, 'getEnrichmentInbox: hid '
                + hiddenPublished + ' candidate(s) whose linked draft is no longer a Draft.');
        }
        return data;
    }

    public class EnrichmentPublishException extends Exception {}

    @AuraEnabled
    public static ActionResult publishCandidate(String candidateId) {
        try {
            return publishCandidateInternal(candidateId);
        } catch (EnrichmentPublishException e) {
            // Validation/business-rule failures — surface the message to the LWC.
            AuraHandledException ahe = new AuraHandledException(e.getMessage());
            ahe.setMessage(e.getMessage());
            throw ahe;
        } catch (Exception e) {
            // Platform errors (DML, publish service) — translate the raw
            // platform message into something readable before bubbling up.
            String friendly = friendlyPublishErrorMessage(e);
            AuraHandledException ahe = new AuraHandledException(friendly);
            ahe.setMessage(friendly);
            throw ahe;
        }
    }

    @AuraEnabled
    public static List<ActionResult> publishCandidatesBulk(List<String> candidateIds) {
        List<ActionResult> results = new List<ActionResult>();
        if (candidateIds == null) {
            return results;
        }
        for (String candidateId : candidateIds) {
            try {
                results.add(publishCandidateInternal(candidateId));
            } catch (EnrichmentPublishException e) {
                System.debug(LoggingLevel.ERROR, 'Enrichment publish validation failed for ' + candidateId + ': ' + e.getMessage());
                ActionResult result = new ActionResult();
                result.candidateId = candidateId;
                result.success = false;
                result.message = e.getMessage();
                results.add(result);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Enrichment publish failed for ' + candidateId + ': ' + e.getMessage());
                ActionResult result = new ActionResult();
                result.candidateId = candidateId;
                result.success = false;
                result.message = friendlyPublishErrorMessage(e);
                results.add(result);
            }
        }
        return results;
    }

    private static ActionResult publishCandidateInternal(String candidateId) {
        if (String.isBlank(candidateId)) {
            throw new EnrichmentPublishException('Candidate ID is required.');
        }
        List<Enrichment_Candidate__c> candidates = [
            SELECT Id, Draft_Article_Version_Id__c, Is_Closed__c, Status__c, Knowledge_Article_Id__c
            FROM Enrichment_Candidate__c
            WHERE Id = :candidateId
            LIMIT 1
        ];
        if (candidates.isEmpty()) {
            throw new EnrichmentPublishException('Candidate not found or no longer accessible.');
        }
        Enrichment_Candidate__c candidate = candidates[0];
        if (candidate.Is_Closed__c == true) {
            ActionResult result = new ActionResult();
            result.candidateId = candidateId;
            result.success = true;
            result.message = 'Already processed (' + candidate.Status__c + ').';
            return result;
        }
        if (String.isBlank(candidate.Draft_Article_Version_Id__c)) {
            throw new EnrichmentPublishException('No draft article is linked to this candidate.');
        }

 // part 2 — ACTION path (publish mutation): enforce FLS with USER_MODE
        // and let it throw. Publishing is a write; if the user can't read the
        // draft's status, the action must not proceed silently.
        List<Knowledge__kav> drafts = [
            SELECT Id, KnowledgeArticleId, PublishStatus
            FROM Knowledge__kav
            WHERE Id = :Id.valueOf(candidate.Draft_Article_Version_Id__c)
            WITH USER_MODE
            LIMIT 1
        ];
        if (drafts.isEmpty()) {
            // The linked draft was deleted, but the user may have published
 // manually from a different version. Try the graceful path.
            ActionResult graceful = tryGracefulCloseFromArticleId(candidate);
            if (graceful != null) return graceful;
            throw new EnrichmentPublishException('Draft article was deleted or is no longer accessible.');
        }
        Knowledge__kav draft = drafts[0];
 // Graceful close: if the linked draft is Online, or has been
        // Archived in favor of a newer Online version, the article was already
        // published — close the candidate instead of throwing.
        if (draft.PublishStatus == 'Online' || draft.PublishStatus == 'Archived') {
            ActionResult graceful = tryGracefulCloseForArticle(
                candidate, draft.KnowledgeArticleId, draft.Id);
            if (graceful != null) return graceful;
            if (draft.PublishStatus == 'Online') {
                throw new EnrichmentPublishException('This article is already published.');
            }
            throw new EnrichmentPublishException(
                'This article is archived and cannot be published as a draft.');
        }

        publisher.publishArticle(draft.KnowledgeArticleId, true);

        // Closes this candidate plus any siblings pointing at the same draft
        // version — KbManagement.PublishingService doesn't reliably fire
        // Apex triggers on Knowledge__kav, so we cascade explicitly here.
        closeEnrichmentCandidatesForDraft(candidate.Draft_Article_Version_Id__c);
        ActionResult result = new ActionResult();
        result.candidateId = candidateId;
        result.success = true;
        result.message = 'Draft published.';
        return result;
    }

    @TestVisible
    private static String friendlyPublishErrorMessage(Exception e) {
        String raw = e.getMessage();
        if (String.isBlank(raw) || raw == 'Script-thrown exception') {
            return 'Could not publish draft. Verify the article still exists and is not already published.';
        }
        if (raw.containsIgnoreCase('INSUFFICIENT_ACCESS')) {
            return 'You do not have permission to publish this article.';
        }
        if (raw.containsIgnoreCase('Invalid ID')) {
            return 'Draft article ID is invalid or no longer exists.';
        }
        if (raw.containsIgnoreCase('already published') || raw.containsIgnoreCase('PublishStatus')) {
            return 'This article is already published.';
        }
 // KbManagement.PublishingService.publishArticle can reject a draft
        // with the deliberately AMBIGUOUS platform message "You can't perform
        // this action. Be sure the action is valid for the current state of the
        // article, and that you have permission to perform it." That single
        // string covers TWO distinct causes, and we can't tell them apart from
        // the text alone:
        //   (a) PERMISSION / record access — the running user can't publish this
        //       article (e.g. they don't own the draft version, which is owned by
        //       the article's Knowledge author lineage, and lack the role/View-All
        //       to publish another user's draft), OR
        //   (b) STATE — the draft can't publish as-is (e.g. it diverged from, or
        //       was superseded by, a separately-published version).
        // (Empirically confirmed on kb-stress-test: the SAME draft that a
        // non-owning user was refused published cleanly as an admin — i.e. (a).)
        // So the message must name BOTH causes rather than asserting one; a
        // message that confidently says "stale, re-run the assessment" would send
        // a permission-blocked user down a dead end.
        //
        // DELIBERATELY NOT routed through KBAccessErrorClassifier.isAccessDenial:
        // that classifier treats "can't perform this action" as a PURE access
        // denial (correct for a USER_MODE DML denial), but a publish-service
        // rejection is genuinely ambiguous (permission OR state) — so this path
        // owns its own both-causes message. Don't "consolidate" this into the
        // classifier; doing so would reassert "permission only" and reintroduce
        // the misleading single-cause message.
        if (raw.containsIgnoreCase('valid for the current state')
                || raw.containsIgnoreCase('can\'t perform this action')
                || raw.containsIgnoreCase('cannot perform this action')) {
            return 'This draft couldn\'t be published. Two things can cause this: '
                + 'you may not have permission to publish this article (ask an admin '
                + 'for Knowledge publish access, or have the article owner publish it); '
                + 'or the article may have been published or updated separately since '
                + 'this draft was generated (re-run the assessment or Fix with AI so '
                + 'the draft reflects the current version), then retry.';
        }
        return raw;
    }

    @AuraEnabled
    public static ActionResult rejectCandidate(String candidateId, String rejectionReason) {
        if (String.isBlank(candidateId)) {
            throw new AuraHandledException('Candidate ID is required.');
        }
        if (String.isBlank(rejectionReason)) {
            throw new AuraHandledException('Rejection reason is required.');
        }
        Database.update(
            new Enrichment_Candidate__c(
                Id = candidateId,
                Status__c = 'Rejected',
                Is_Closed__c = true,
                Rejection_Reason__c = rejectionReason.trim()
            ),
            AccessLevel.USER_MODE
        );
        ActionResult result = new ActionResult();
        result.candidateId = candidateId;
        result.success = true;
        result.message = 'Candidate rejected and closed.';
        return result;
    }

    @AuraEnabled
    public static List<ActionResult> rejectCandidatesBulk(List<String> candidateIds, String rejectionReason) {
        List<ActionResult> results = new List<ActionResult>();
        if (candidateIds == null) {
            return results;
        }
        for (String candidateId : candidateIds) {
            try {
                results.add(rejectCandidate(candidateId, rejectionReason));
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Enrichment reject failed for ' + candidateId + ': ' + e.getMessage());
                ActionResult result = new ActionResult();
                result.candidateId = candidateId;
                result.success = false;
                result.message = e.getMessage();
                results.add(result);
            }
        }
        return results;
    }

    public class SplitProposalRow {
        @AuraEnabled public String proposalId { get; set; }
        @AuraEnabled public String sourceArticleId { get; set; }
        @AuraEnabled public String sourceArticleTitle { get; set; }
        @AuraEnabled public String sourceArticleUrl { get; set; }
        @AuraEnabled public String draftArticleId { get; set; }
        @AuraEnabled public String draftArticleUrl { get; set; }
        @AuraEnabled public String draftTitle { get; set; }
        @AuraEnabled public String draftSummary { get; set; }
        @AuraEnabled public String draftUrlName { get; set; }
        @AuraEnabled public Datetime draftLastModifiedDate { get; set; }
        @AuraEnabled public Decimal confidenceScore { get; set; }
        @AuraEnabled public String flagType { get; set; }
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String recommendedAction { get; set; }
        @AuraEnabled public String reason { get; set; }
        @AuraEnabled public Datetime createdDate { get; set; }
        @AuraEnabled public String sourceRunName { get; set; }
    }

    public class ActionResult {
        @AuraEnabled public String candidateId { get; set; }
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String message { get; set; }
    }

    // ──────────────────────────────────────────────────────────────
    // Improvements inbox (LLM-dimension recommendations)
    // ──────────────────────────────────────────────────────────────

    public class ImprovementArticleGroup {
        @AuraEnabled public String articleId         { get; set; }
        @AuraEnabled public String articleTitle      { get; set; }
        @AuraEnabled public String articleNumber     { get; set; }
        @AuraEnabled public String articleUrl        { get; set; }
        @AuraEnabled public Integer openCount        { get; set; }
        @AuraEnabled public List<ImprovementRow> recommendations { get; set; }
        @AuraEnabled public String pendingDraftId    { get; set; }
        @AuraEnabled public String pendingDraftUrl   { get; set; }

        public ImprovementArticleGroup() {
            this.openCount = 0;
            this.recommendations = new List<ImprovementRow>();
        }
    }

    public class ImprovementRow {
        @AuraEnabled public String  recId        { get; set; }
        @AuraEnabled public String  dimension    { get; set; }
        // Severity model reduced to Impact only (High/Medium/Low). Effort,
        // Priority and the numeric impact-score field were dropped from the
        // analysis row.
        @AuraEnabled public String  impact       { get; set; }
        @AuraEnabled public String  recommendation { get; set; }
        // Status__c is exposed so the LWC can render an "Error/Failed" badge on
        // recs whose previous fix attempt failed (C6). Values: Open / Error.
        // (Resolved / Rejected / Dismissed are filtered out of the inbox query.)
        @AuraEnabled public String  status       { get; set; }
    }

    // Per-article paging cap. We cap by distinct article count rather than
    // total rec count so a single noisy article (600+ recs) cannot starve every
    // other article from the inbox (C5).
    private static final Integer INBOX_ARTICLE_LIMIT = 50;
 // default page size for the paginated inbox. The list is paged by
    // ARTICLE (each article carries its own rec list), so this bounds articles
    // per page, not total recs.
    private static final Integer INBOX_PAGE_SIZE = 25;
    private static final Integer INBOX_MAX_PAGE_SIZE = 100;
 // review — SOQL hard-caps OFFSET at 2000. Clamp here so a deep page
    // request (or the fetch-all loop) degrades to the last reachable page
    // instead of throwing a QueryException the wire surfaces as a load error.
    // Above this window the inbox is effectively unpaginable by offset; the
    // per-article cap keeps a single scope bounded and the run-scoped view keeps
    // real-world scopes well under 2000 distinct issue-articles.
    private static final Integer INBOX_MAX_OFFSET = 2000;

    /**
 * one page of the Improvements Inbox plus the REAL total article
     * count, so the UI can show "X of N articles" (not the old silent 50 cap)
     * and paginate. groups is the current page's article groups; totalArticles
     * is the full count of distinct articles with open/errored issues in scope.
     */
    public class ImprovementInboxPage {
        @AuraEnabled public List<ImprovementArticleGroup> groups   { get; set; }
        @AuraEnabled public Integer totalArticles { get; set; }
        @AuraEnabled public Integer pageSize       { get; set; }
        @AuraEnabled public Integer offset         { get; set; }

        public ImprovementInboxPage() {
            this.groups = new List<ImprovementArticleGroup>();
            this.totalArticles = 0;
            this.pageSize = 0;
            this.offset = 0;
        }
    }

    // Back-compat: the un-paged entry point (record-page / any caller that
    // just wants the groups). Returns the FIRST page at the legacy cap so
    // existing behaviour is unchanged.
    @AuraEnabled(cacheable=true)
    public static List<ImprovementArticleGroup> getImprovementsInbox(String runId) {
        return getImprovementsInboxPage(runId, INBOX_ARTICLE_LIMIT, 0, null).groups;
    }

    // Whitelist of scored dimensions the inbox may filter on. Anything off-list
    // (incl. the pipeline-only Duplication/Conflict) is ignored → no filter,
    // matching the "All dimensions" default rather than trusting arbitrary input
    // in a dynamic SOQL clause.
    private static final Set<String> FILTERABLE_DIMENSIONS = new Set<String>{
        'Completeness', 'Structure', 'Clarity', 'Freshness'
    };

    /**
 * review (blocker 3) — bulk-run completion ledger. Returns how many of
     * the given articles STILL have an open/errored non-dedup issue, independent
     * of any page/dimension the inbox happens to be showing. The LWC's poll
     * fallback (empApi-gated orgs) uses this instead of the visible-page groups
     * to decide "all dispatched articles processed" — so paging or changing the
     * dimension filter mid-run can no longer fire a false completion + tear down
     * the run monitor while the fix is still running.
     *
     * `articleIds` are the article-level (KnowledgeArticleId) ids the bulk fix
     * was dispatched for. Bulk-safe: one COUNT_DISTINCT, no SOQL in a loop.
     */
    @AuraEnabled(cacheable=false)
    public static Integer countArticlesWithOpenIssues(List<Id> articleIds) {
        if (articleIds == null || articleIds.isEmpty()) {
            return 0;
        }
        Set<Id> ids = new Set<Id>(articleIds);
        List<AggregateResult> res = [
            SELECT COUNT_DISTINCT(Article_Assessment__r.Knowledge__c) total
            FROM KB_Dimension_Analysis__c
            WHERE Type__c = 'Issue'
              AND Dimension__c NOT IN ('Duplication', 'Conflict')
              AND Status__c IN ('Open', 'Error')
              AND Article_Assessment__r.Knowledge__c IN :ids
            WITH USER_MODE
        ];
        return res.isEmpty() ? 0 : (Integer) res[0].get('total');
    }

    /**
 * paginated inbox. Returns one page of article groups plus the REAL
     * total article count so the LWC can show "X of N" and paginate instead of
     * silently capping at 50. pageSize/offset page by ARTICLE (each carries its
     * own rec list). offset beyond the total yields an empty page with the true
     * total (the LWC clamps).
     *
     * `dimension` scopes the count, page AND rec fetch to one scored dimension
 * (review — the filter must be server-side so totalArticles, the page,
     * the "select all N" banner and the fetch-all-matching dispatch all agree;
     * a client-only filter let "select all N" dispatch cross-dimension rewrites).
     * Blank / off-list → "All dimensions".
     */
    @AuraEnabled(cacheable=true)
    public static ImprovementInboxPage getImprovementsInboxPage(String runId, Integer pageSize, Integer offset, String dimension) {
        ImprovementInboxPage page = new ImprovementInboxPage();
        Id runIdSafe = parseOptionalId(runId);
        if (String.isNotBlank(runId) && runIdSafe == null) {
            return page;
        }
        Integer safeSize = (pageSize != null && pageSize > 0 && pageSize <= INBOX_MAX_PAGE_SIZE)
            ? pageSize : INBOX_PAGE_SIZE;
        Integer safeOffset = (offset != null && offset >= 0) ? offset : 0;
        // Clamp to SOQL's 2000 OFFSET ceiling — a deeper request would throw
        // QueryException on query1 (surfaced as "Could not load improvements")
        // and silently break the fetch-all-matching loop.
        if (safeOffset > INBOX_MAX_OFFSET) {
            safeOffset = INBOX_MAX_OFFSET;
        }
        page.pageSize = safeSize;
        page.offset   = safeOffset;

        // Optional single-dimension filter (bind, not string-concat — and only
        // an allow-listed value ever reaches the clause).
        String dimFilter = (String.isNotBlank(dimension) && FILTERABLE_DIMENSIONS.contains(dimension))
            ? dimension : null;

        // Real total: count of DISTINCT articles with an open/errored non-dedup
        // issue in scope. COUNT_DISTINCT gives the true N (not the page cap).
        String countQuery = 'SELECT COUNT_DISTINCT(Article_Assessment__r.Knowledge__c) total '
            + 'FROM KB_Dimension_Analysis__c '
            + 'WHERE Type__c = \'Issue\' '
            + 'AND Dimension__c NOT IN (\'Duplication\', \'Conflict\') '
            + 'AND Status__c IN (\'Open\', \'Error\') '
            + 'AND Article_Assessment__r.Knowledge__c != null ';
        Map<String, Object> countBinds = new Map<String, Object>();
        if (runIdSafe != null) {
            countQuery += 'AND Article_Assessment__r.Assessment_Run__c = :runIdSafe ';
            countBinds.put('runIdSafe', runIdSafe);
        }
        if (dimFilter != null) {
            countQuery += 'AND Dimension__c = :dimFilter ';
            countBinds.put('dimFilter', dimFilter);
        }
        List<AggregateResult> countResult = Database.queryWithBinds(countQuery, countBinds, AccessLevel.USER_MODE);
        page.totalArticles = countResult.isEmpty() ? 0 : (Integer) countResult[0].get('total');
        if (page.totalArticles == 0) {
            return page;
        }

        // Step 1: one page of DISTINCT article ids (open/errored, non-dedup).
        // ORDER BY the grouped article id so paging is deterministic across
        // pages (aggregate ORDER BY must reference a grouped/aggregated field).
        String query1 = 'SELECT Article_Assessment__r.Knowledge__c artId '
            + 'FROM KB_Dimension_Analysis__c '
            + 'WHERE Type__c = \'Issue\' '
            + 'AND Dimension__c NOT IN (\'Duplication\', \'Conflict\') '
            + 'AND Status__c IN (\'Open\', \'Error\') '
            + 'AND Article_Assessment__r.Knowledge__c != null ';
        Map<String, Object> binds1 = new Map<String, Object>{
            'pageSize' => safeSize, 'pageOffset' => safeOffset
        };
        if (runIdSafe != null) {
            query1 += 'AND Article_Assessment__r.Assessment_Run__c = :runIdSafe ';
            binds1.put('runIdSafe', runIdSafe);
        }
        if (dimFilter != null) {
            query1 += 'AND Dimension__c = :dimFilter ';
            binds1.put('dimFilter', dimFilter);
        }
        query1 += 'GROUP BY Article_Assessment__r.Knowledge__c '
            + 'ORDER BY Article_Assessment__r.Knowledge__c '
            + 'LIMIT :pageSize OFFSET :pageOffset';
        List<AggregateResult> articleAggregates = Database.queryWithBinds(
            query1,
            binds1,
            AccessLevel.USER_MODE
        );

        if (articleAggregates.isEmpty()) {
            return page;
        }

        Set<Id> articleIds = new Set<Id>();
        for (AggregateResult ar : articleAggregates) {
            Id artId = (Id) ar.get('artId');
            if (artId != null) articleIds.add(artId);
        }
        if (articleIds.isEmpty()) {
            return page;
        }

        // Step 2: fetch every matching rec for the selected articles. No total
        // LIMIT — we already capped by article count above.
        String query2 = 'SELECT Id, Dimension__c, Impact__c, '
            + 'Recommendation__c, Status__c, '
            + 'Article_Assessment__c, '
            + 'Article_Assessment__r.Article_Title__c, '
            + 'Article_Assessment__r.Knowledge__c, '
            + 'Article_Assessment__r.Article_Number__c, '
            + 'Article_Assessment__r.CreatedDate '
            + 'FROM KB_Dimension_Analysis__c '
            + 'WHERE Type__c = \'Issue\' '
            + 'AND Dimension__c NOT IN (\'Duplication\', \'Conflict\') '
            + 'AND Status__c IN (\'Open\', \'Error\') '
            + 'AND Article_Assessment__r.Knowledge__c IN :articleIds ';
        Map<String, Object> binds2 = new Map<String, Object>{ 'articleIds' => articleIds };
        if (runIdSafe != null) {
            query2 += 'AND Article_Assessment__r.Assessment_Run__c = :runIdSafe ';
            binds2.put('runIdSafe', runIdSafe);
        }
        // Same dimension scope as the count/page — so a dimension-filtered "select
        // all N matching" fetches ONLY that dimension's recs, never a cross-
 // dimension rewrite.
        if (dimFilter != null) {
            query2 += 'AND Dimension__c = :dimFilter ';
            binds2.put('dimFilter', dimFilter);
        }
        // CreatedDate DESC must stay first per article so the "latest
        // assessment per article" pass below picks the most recent run.
        query2 += 'ORDER BY Article_Assessment__r.Knowledge__c, Article_Assessment__r.CreatedDate DESC, '
            + 'Dimension__c ASC';
        List<KB_Dimension_Analysis__c> recs = Database.queryWithBinds(
            query2,
            binds2,
            AccessLevel.USER_MODE
        );

        // Only keep recs from the latest assessment per article.
        // Because results are ordered by CreatedDate DESC, the first assessment Id
        // we encounter per article is the most recent one.
        Map<String, Id> latestAssessmentByArticle = new Map<String, Id>();
        for (KB_Dimension_Analysis__c r : recs) {
            if (r.Article_Assessment__r == null) continue;
            String artId = r.Article_Assessment__r.Knowledge__c;
            if (artId == null) continue;
            if (!latestAssessmentByArticle.containsKey(artId)) {
                latestAssessmentByArticle.put(artId, r.Article_Assessment__c);
            }
        }

        // Group by article, skipping recs from older assessments and deduping
        // identical advice (same dimension + recommendation text) per article.
        Map<String, ImprovementArticleGroup> groupByArticle = new Map<String, ImprovementArticleGroup>();
        Map<String, Set<String>> seenKeysByArticle = new Map<String, Set<String>>();
        for (KB_Dimension_Analysis__c r : recs) {
            String artId = r.Article_Assessment__r != null ? r.Article_Assessment__r.Knowledge__c : null;
            if (artId == null) continue;
            if (r.Article_Assessment__c != latestAssessmentByArticle.get(artId)) continue;

            // Dedup: skip if same dimension+text already added for this article
            String dedupeKey = (r.Dimension__c ?? '') + '||' + (r.Recommendation__c ?? '');
            if (!seenKeysByArticle.containsKey(artId)) {
                seenKeysByArticle.put(artId, new Set<String>());
            }
            if (seenKeysByArticle.get(artId).contains(dedupeKey)) continue;
            seenKeysByArticle.get(artId).add(dedupeKey);

            if (!groupByArticle.containsKey(artId)) {
                ImprovementArticleGroup grp = new ImprovementArticleGroup();
                grp.articleId     = artId;
                grp.articleTitle  = r.Article_Assessment__r.Article_Title__c;
                grp.articleNumber = r.Article_Assessment__r.Article_Number__c;
                grp.articleUrl    = '/lightning/r/Knowledge__kav/' + artId + '/view';
                groupByArticle.put(artId, grp);
            }
            ImprovementArticleGroup grp = groupByArticle.get(artId);
            ImprovementRow row = new ImprovementRow();
            row.recId          = r.Id;
            row.dimension      = r.Dimension__c;
            row.impact         = r.Impact__c;
            row.recommendation = r.Recommendation__c;
            row.status         = r.Status__c;
            grp.recommendations.add(row);
            grp.openCount++;
        }

        // Stamp pending enrichment drafts onto groups so the UI can warn before overwriting.
        if (!groupByArticle.isEmpty()) {
            Set<String> draftLookupArticleIds = groupByArticle.keySet();
            List<Enrichment_Candidate__c> pendingCandidates = Database.queryWithBinds(
                'SELECT Id, Source_Article_Version_Id__c, Draft_Article_Version_Id__c '
                + 'FROM Enrichment_Candidate__c '
                + 'WHERE Status__c = \'Pending\' '
                + 'AND Is_Closed__c = false '
                + 'AND Source_Article_Version_Id__c IN :articleIds',
                new Map<String, Object>{ 'articleIds' => draftLookupArticleIds },
                AccessLevel.USER_MODE
            );
            for (Enrichment_Candidate__c ec : pendingCandidates) {
                String artId = ec.Source_Article_Version_Id__c;
                if (groupByArticle.containsKey(artId) && String.isNotBlank(ec.Draft_Article_Version_Id__c)) {
                    ImprovementArticleGroup grp = groupByArticle.get(artId);
                    grp.pendingDraftId  = ec.Draft_Article_Version_Id__c;
                    grp.pendingDraftUrl = '/lightning/r/Knowledge__kav/' + ec.Draft_Article_Version_Id__c + '/view';
                }
            }
        }

        // Preserve the paged article-id order (query1 ORDER BY) in the groups
        // list so the LWC renders pages consistently.
        for (AggregateResult ar : articleAggregates) {
            String artId = String.valueOf(ar.get('artId'));
            if (groupByArticle.containsKey(artId)) {
                page.groups.add(groupByArticle.get(artId));
            }
        }
        return page;
    }

    /**
     * Single-article variant of getImprovementsInbox — returns the open
     * improvement group for one Knowledge__kav, or null if none. Used by
     * the record-page Recommendations panel so the inline Fix button can
     * feed the existing kbFixIssuesModal without reshaping the DTO.
     *
     * Unlike getImprovementsInbox, this query INCLUDES Duplication / Conflict
     * dimensions — the record-page panel surfaces every actionable issue for
     * the article, including dedup-pipeline flags. The LWC visually groups
     * AI-fixable rows (Completeness/Structure/Clarity) from manual-only rows
     * (Duplication/Conflict/Freshness) so users know which ones the AI Fix
     * button can address. The bulk inbox keeps its exclusion because dedup
     * candidates are routed to Action Center (different surface, different
     * resolution flow).
     */
    @AuraEnabled(cacheable=true)
    public static ImprovementArticleGroup getImprovementsForArticle(String articleVersionId) {
        if (String.isBlank(articleVersionId)) return null;

        List<KB_Dimension_Analysis__c> recs = Database.queryWithBinds(
            'SELECT Id, Dimension__c, Impact__c, '
            + 'Recommendation__c, Status__c, '
            + 'Article_Assessment__c, '
            + 'Article_Assessment__r.Article_Title__c, '
            + 'Article_Assessment__r.Knowledge__c, '
            + 'Article_Assessment__r.Article_Number__c, '
            + 'Article_Assessment__r.CreatedDate '
            + 'FROM KB_Dimension_Analysis__c '
            + 'WHERE Type__c = \'Issue\' '
            + 'AND Status__c IN (\'Open\', \'Error\') '
            + 'AND Article_Assessment__r.Knowledge__c = :artId '
            // CreatedDate DESC must stay first so recs[0] is the latest assessment.
            + 'ORDER BY Article_Assessment__r.CreatedDate DESC, '
            + 'Dimension__c ASC',
            new Map<String, Object>{ 'artId' => articleVersionId },
            AccessLevel.USER_MODE
        );
        if (recs.isEmpty()) return null;

        // Latest assessment is the first row's parent (results ordered by CreatedDate DESC).
        Id latestAssessmentId = recs[0].Article_Assessment__c;

        ImprovementArticleGroup grp = new ImprovementArticleGroup();
        grp.articleId     = articleVersionId;
        grp.articleTitle  = recs[0].Article_Assessment__r != null
            ? recs[0].Article_Assessment__r.Article_Title__c
            : null;
        grp.articleNumber = recs[0].Article_Assessment__r != null
            ? recs[0].Article_Assessment__r.Article_Number__c
            : null;
        grp.articleUrl    = '/lightning/r/Knowledge__kav/' + articleVersionId + '/view';

        Set<String> seenKeys = new Set<String>();
        for (KB_Dimension_Analysis__c r : recs) {
            if (r.Article_Assessment__c != latestAssessmentId) continue;
            String dedupeKey = (r.Dimension__c ?? '') + '||' + (r.Recommendation__c ?? '');
            if (seenKeys.contains(dedupeKey)) continue;
            seenKeys.add(dedupeKey);

            ImprovementRow row = new ImprovementRow();
            row.recId          = r.Id;
            row.dimension      = r.Dimension__c;
            row.impact         = r.Impact__c;
            row.recommendation = r.Recommendation__c;
            row.status         = r.Status__c;
            grp.recommendations.add(row);
            grp.openCount++;
        }
        if (grp.openCount == 0) return null;

        // Pending enrichment draft (same lookup as the inbox query, scoped to this article).
        List<Enrichment_Candidate__c> pending = Database.queryWithBinds(
            'SELECT Id, Draft_Article_Version_Id__c '
            + 'FROM Enrichment_Candidate__c '
            + 'WHERE Status__c = \'Pending\' '
            + 'AND Is_Closed__c = false '
            + 'AND Source_Article_Version_Id__c = :artId '
            + 'AND Draft_Article_Version_Id__c != null '
            + 'LIMIT 1',
            new Map<String, Object>{ 'artId' => articleVersionId },
            AccessLevel.USER_MODE
        );
        if (!pending.isEmpty()) {
            grp.pendingDraftId  = pending[0].Draft_Article_Version_Id__c;
            grp.pendingDraftUrl = '/lightning/r/Knowledge__kav/' + grp.pendingDraftId + '/view';
        }

        return grp;
    }

    /**
     * Flips a list of errored recommendations back to 'Open' so the user can
     * retry a fix attempt (C6). Status flip only — does NOT auto-redispatch
     * the LLM. The LWC follows up by calling KBImprovementFixService.dispatchArticleFix
     * for each errored rec the user wants to retry, exactly the same way it
     * does for first-time fixes. Keeping these as two separate user actions
     * lets the user adjust the issue description in the modal before retrying.
     *
     * Only recs currently in 'Error' state are flipped — passing in Open or
     * Resolved recs is a no-op so this is safe to call defensively.
     */
    @AuraEnabled
    public static void requeueErroredRecommendations(List<Id> recIds) {
        if (recIds == null || recIds.isEmpty()) return;
        List<KB_Dimension_Analysis__c> errored = [
            SELECT Id, Status__c
            FROM KB_Dimension_Analysis__c
            WHERE Id IN :recIds AND Status__c = 'Error'
        ];
        if (errored.isEmpty()) return;
        for (KB_Dimension_Analysis__c rec : errored) {
            rec.Status__c = 'Open';
        }
        // USER_MODE consistent with updateRecommendationStatus (S1).
        Database.update(errored, AccessLevel.USER_MODE);
    }

    /**
 * Graceful-publish path #1: the draft KAV is gone but we have an
     * article-level id stamped on the candidate. Look up the current Online
     * version under that article id; if there is one, close all open ECs
     * for that article and report success.
     */
    private static ActionResult tryGracefulCloseFromArticleId(Enrichment_Candidate__c candidate) {
        if (String.isBlank(candidate.Knowledge_Article_Id__c)) return null;
        Id articleId;
        try { articleId = Id.valueOf(candidate.Knowledge_Article_Id__c); }
        catch (Exception e) { return null; }
        List<Knowledge__kav> online = [
            SELECT Id FROM Knowledge__kav
            WHERE KnowledgeArticleId = :articleId
            AND PublishStatus = 'Online'
            AND IsLatestVersion = true
            LIMIT 1
        ];
        if (online.isEmpty()) return null;
        return tryGracefulCloseForArticle(candidate, articleId, online[0].Id);
    }

    /**
 * Graceful-publish path #2: caller already has the article id and
     * the just-published KAV id. Close all open ECs for that article;
     * candidates whose Draft_Article_Version_Id__c matches the published KAV
     * get Status='Published', otherwise 'Superseded'.
     */
    private static ActionResult tryGracefulCloseForArticle(
        Enrichment_Candidate__c candidate, Id knowledgeArticleId, Id onlineKavId
    ) {
        if (knowledgeArticleId == null) return null;
        Set<Id> articleIds = new Set<Id>{ knowledgeArticleId };
        Set<Id> kavIds = new Set<Id>();
        if (onlineKavId != null) kavIds.add(onlineKavId);
        KBEnrichmentReconciler.closeForPublishedArticles(articleIds, kavIds);
        ActionResult result = new ActionResult();
        result.candidateId = candidate.Id;
        result.success = true;
        result.message = (String.valueOf(onlineKavId) == candidate.Draft_Article_Version_Id__c)
            ? 'Draft already published — candidate closed.'
            : 'A different version is already published — candidate superseded.';
        return result;
    }

    // Closes any open Enrichment Candidates whose draft version was just published.
    // Called explicitly after every publish path since KbManagement.PublishingService
    // does not reliably fire Apex triggers on Knowledge__kav.
    public static void closeEnrichmentCandidatesForDraft(String draftVersionId) {
        if (String.isBlank(draftVersionId)) return;
        List<Enrichment_Candidate__c> toClose = [
            SELECT Id FROM Enrichment_Candidate__c
            WHERE Is_Closed__c = false
            AND Draft_Article_Version_Id__c = :draftVersionId
        ];
        if (toClose.isEmpty()) return;
        for (Enrichment_Candidate__c ec : toClose) {
            ec.Status__c    = 'Published';
            ec.Is_Closed__c = true;
        }
        Database.update(toClose, AccessLevel.USER_MODE);
    }

    @AuraEnabled
    public static void updateRecommendationStatus(List<Id> recIds, String status) {
        if (recIds == null || recIds.isEmpty() || String.isBlank(status)) return;
        List<KB_Dimension_Analysis__c> toUpdate = new List<KB_Dimension_Analysis__c>();
        for (Id recId : recIds) {
            toUpdate.add(new KB_Dimension_Analysis__c(Id = recId, Status__c = status));
        }
        // USER_MODE enforces FLS on Status__c. Status__c is a restricted picklist
        // (Open / Queued / Resolved / Error / Dismissed / Rejected) — invalid values throw at
        // DML time with a platform error, so no application-level whitelist is needed.
        Database.update(toUpdate, AccessLevel.USER_MODE);
    }

    public class EnrichmentInboxData {
        @AuraEnabled public Integer pendingCount { get; set; }
        @AuraEnabled public Integer approvedCount { get; set; }
        @AuraEnabled public Integer rejectedCount { get; set; }
        @AuraEnabled public Integer totalDrafts { get; set; }
        @AuraEnabled public List<SplitProposalRow> candidates { get; set; }

        public EnrichmentInboxData() {
            this.pendingCount = 0;
            this.approvedCount = 0;
            this.rejectedCount = 0;
            this.totalDrafts = 0;
            this.candidates = new List<SplitProposalRow>();
        }
    }

    /**
     * Returns Id.valueOf(runId) if it parses to a valid 15/18-char Salesforce
     * Id, null otherwise. Callers treat null + blank input as "no filter";
     * null + non-blank input as "garbage → return empty".
     */
    private static Id parseOptionalId(String raw) {
        if (String.isBlank(raw)) return null;
        try { return Id.valueOf(raw); } catch (Exception e) { return null; }
    }

    // The former `reconcileEnrichmentInbox()` @AuraEnabled hook was removed.
    // It ran a DML-on-inbox-load close procedure (a UI click mutating records),
    // which the team ruled the wrong pattern — the list is now filtered by the
    // linked draft's PublishStatus in getEnrichmentInbox instead. The durable
    // Is_Closed__c close happens on the in-app Approve/publish path
    // (publishCandidate → closeEnrichmentCandidatesForDraft on the primary path;
    // the KBEnrichmentReconciler graceful-close fallback only when the draft is
    // already Online/Archived/deleted).
}