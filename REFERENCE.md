# Knowledge Readiness — Reference

Companion to the [README](README.md). The README covers install, first-run setup, and running an assessment. This document covers everything else: what the tool does, how it's structured, how scoring and the dedup pipeline work, who can do what, and the operational reference (rate limits, resilience, accessibility, API version, open-source terms).

**Who this document is for.** Sections are ordered so you can stop reading at the depth you need:

- **Product owners / evaluators** — read *At a glance* and *Scoring model*.
- **Knowledge Managers / admins** — add *Application Structure*, *Permission model*, and *Operations*.
- **Engineers / architects** — everything, especially *Architecture*.

<details open>
<summary><b>Table of contents</b></summary>

<ul>
  <li><a href="#at-a-glance">At a glance</a></li>
  <li><a href="#scoring-model">Scoring model</a></li>
  <li><a href="#application-structure">Application Structure</a></li>
  <li><a href="#permission-model">Permission model</a></li>
  <li><a href="#architecture">Architecture</a></li>
  <li><a href="#operations">Operations</a></li>
  <li><a href="#legal--project-info">Legal &amp; project info</a></li>
</ul>

</details>

---

## At a glance

Agentforce Knowledge Readiness is a native Salesforce Lightning App that scores your Knowledge Base for Agentforce readiness across **six dimensions**, produces impact-rated recommendations for each article, and — on demand — drafts AI-generated rewrites for review.

The tool is designed around three guarantees:

- **Scoring is read-only.** Assessment never modifies Knowledge Articles.
- **AI Fix produces Drafts only.** Original articles are never overwritten; every rewrite is a reviewable Draft that requires human approval before it goes live.
- **Fully native to Salesforce.** All AI calls route through the Einstein AI Platform (`ConnectApi.EinsteinLlm`) via GenAI Prompt Templates. No external APIs, no managed package dependencies, no data leaves the Salesforce trust boundary.

At runtime, it scales to thousands of articles via Queueable fan-out and Batch Apex, with real-time progress pushed to the UI through Platform Events. The full [Setup Experience Wizard](README.md#post-install-setup-walkthrough) configures scoring, weights, and the deduplication pipeline in one place.

### Key capabilities

| Capability | What it does | Where it lives |
|---|---|---|
| **Knowledge Readiness Score** | Weighted 0–100 score across six dimensions | [Scoring model](#scoring-model) |
| **AI-driven scoring** | LLM evaluates Completeness, Structure, and Clarity; deterministic fallback if the Einstein call fails | [Scoring model](#scoring-model) |
| **Per-article recommendations** | Impact-rated (High / Medium / Low), actionable | [Scoring model → Per-article output](#per-article-output) |
| **AI Fix flow** | Rewrites articles into reviewable Drafts on demand — never overwrites the live article | [Application Structure → The Actions tab](#the-actions-tab) |
| **Deduplication pipeline** | Multi-tier duplicate/conflict detection via **Data 360 (formerly Data Cloud)** vector search, with LLM triage and consolidation drafts | [Architecture → Deduplication pipeline](#deduplication-pipeline) |
| **Actions triage inbox** | Merge clusters, resolve contradictions, review enrichments, apply improvements | [Application Structure → The Actions tab](#the-actions-tab) |
| **Setup Experience Wizard** | Guided config for content fields, weights, and the dedup pipeline | [README → Post-Install Setup Walkthrough](README.md#post-install-setup-walkthrough) |
| **Two entry points** | Batch LWC (many articles, async) + the Knowledge Assessment panel on the article record page (single article) | [Application Structure](#application-structure) |
| **Async processing** | Queueable fan-out and Batch Apex scale to thousands of articles; real-time progress via Platform Events | [Architecture → Async execution model](#async-execution-model) |

---

## Scoring model

### The six dimensions

| Dimension | Weight | What it checks | LLM Templates |
|-----------|--------|----------------|---------------|
| Completeness | 30% | Title answerability, summary, data categories, body content, deflection phrases, link-heavy ratio | `Evaluate_Completeness` |
| Structure | 20% | Paragraphs, headings, RAG chunk self-containment, cross-references, HTML artifacts, link count | `Evaluate_Structure` |
| Clarity | 10% | Jargon, acronyms, terminology, pronoun ambiguity, vague phrases, within-article contradictions | `Evaluate_Clarity` |
| Freshness | 10% | LastModifiedDate vs configurable staleness thresholds | None (deterministic) |
| Duplication | 15% | Semantic overlap from dedup pipeline | None (reads `Duplicate_Candidate__c`) |
| Conflict | 15% | Contradictory claims from dedup pipeline | None (reads `Duplicate_Candidate__c`) |

Completeness, Structure, and Clarity are **LLM-driven** — Einstein evaluates each article against the prompt template and adds strengths/issues that deterministic rules can't catch (semantic coherence, within-article contradictions). Freshness, Duplication, and Conflict are always **deterministic**.

Metadata Quality and Vector Readiness exist as internal helper scorers folded into Completeness and Structure respectively; they are not separate dimensions.

### How a score is calculated

Each dimension's **deterministic** scoring uses a **strengths vs. issues** model:

- **Base score:** 70 (neutral article — no signals either way)
- **Per strength detected:** +6 points (capped at +30)
- **Per issue detected:** -10 points (capped at -40)
- **No signals at all:** 75 (benefit of the doubt)
- **Final range:** 20–100 (a hard gate failure, e.g. no title/body, bottoms out at 20)

For Completeness, Structure, and Clarity, LLM scoring is **mandatory** and the model's own score is used when the Einstein call succeeds. If that call fails, the dimension falls back gracefully rather than blocking the run — Clarity and Structure to a baseline of 60, and Completeness to the deterministic counting model above (using the gate/link/data-category signals it already collected).

The **overall readiness score** is a weighted average across all assessed dimensions. Unselected dimensions are excluded from the average — weights renormalize automatically.

### Readiness tiers

- **Ready** (80–100): article is agent-consumable
- **Needs Work** (50–79): article needs improvements before Agentforce
- **Not Ready** (0–49): significant gaps — prioritize for remediation

### Per-article output
<a id="per-article-output"></a>

Each article gets impact-rated (**High / Medium / Low**) recommendations, ordered by impact. From the article record page or the Improvements inbox, an admin can dispatch the **AI Fix** flow, which generates a rewritten Draft — never modifying the original article.

---

## Application Structure

### Lightning App tabs

Five-tab Lightning App (label **Knowledge Readiness**, dev name `KB_Readiness_Assessment`):

| Tab Label | Tab Dev Name | Component | Purpose |
|-----------|--------------|-----------|---------|
| **Knowledge** | `Knowledge__kav` | (standard) | Direct access to all Knowledge articles in the org |
| **Assessments** | `KB_Assessment_Console` | `kbAssessmentApp` | Assessment workflow — select articles, run scan, view results and history. Default landing tab. |
| **Actions** | `KB_Candidate_Inbox` | `kbCandidateInbox` | Unified triage inbox — see [The Actions tab](#the-actions-tab) below |
| **Audit** | `KB_Pipeline_Operations` | `kbPipelineOperations` | Pipeline run audit log |
| **Setup** | `KB_Assessment_Setup` | `kbSetupExperienceWizard` | Guided setup wizard — Welcome / Essentials / Validate & Save, with an optional Advanced accordion (admin only) |

The Dashboard / Operations / Diagnostics FlexiPages and LWCs remain URL-reachable but are not part of the default app navigation.

### The Knowledge Assessment panel (on the article record page)

The app deploys one Lightning Web Component that sits on the Knowledge article record page: **`knowledgeConsistencyChecker`**, labelled **Knowledge Assessment** in the UI. It's a single tabbed card with a readiness-score header and a run selector:

- **Issues** — issues from the selected run; AI-fixable ones launch the Fix-with-AI modal, manual-only (Freshness) ones offer Edit-as-Draft. Dimension filter + impact sort, with toggles to reveal resolved/discarded recommendations.
- **Strengths** — what the article does well, for the selected run.
- **Duplicates & Conflicts** — duplication/conflict findings linking to the **Actions** tab.
- **Pre-publish check** — optional, gated behind the `KB_PrePublishCheck_Beta` custom permission while the feature is alpha (assigned manually).

Run history is folded into the run selector + Strengths/Issues tabs. The run set filters by canonical `KnowledgeArticleId` so a fresh "Fix with AI" draft inherits the article's prior run history.

### The Actions tab

<a id="the-actions-tab"></a>

The **Actions** tab is where Knowledge Managers triage pipeline-generated candidates across three inbox tabs: **Duplicates**, **Suggested Article Drafts** (enrichment), and **Issues** (improvement recommendations).

**Duplicates tab** — a unified, status-aware queue. It defaults to the actionable **Pending** set, with independent **Show resolved** and **Show discarded** toggles so it can show the full history when you want it. Row actions are keyed to a candidate's status:

- **Pending** rows: **Compare Articles** (side-by-side view with AI reasoning), **Resolve**, and **Not a Duplicate** (a soft, this-run-only discard, with an optional reason — the pair is re-evaluated on the next assessment and can re-surface).
- **Resolved / Superseded** rows: **Compare** (read-only) and **View Golden Record** — plus **Publish Golden Record** when a merged draft is ready to go live.
- **Discarded** rows: **Compare** only.

**Resolve** opens the modal that matches the candidate's flag type:

- *Duplicate* → **Cluster Merge Modal**: discover neighbors via BFS, merge the pair or the whole cluster → an LLM drafts a Golden Record `Knowledge__kav` in Draft status.
- *Contradiction* → **Contradiction Modal**: pick which article is correct, or mark both valid with different scope.

**Suggested Article Drafts tab** — pending AI-enriched drafts for approval / rejection / publishing.

**Issues tab** — open improvement recommendations grouped by article, each with a single Impact badge (High / Medium / Low). Bulk **Fix with AI** dispatches the AI Fix flow, which rewrites the article body and persists a reviewable Draft.

> **Publish merged articles from the Actions tab — not from the standard Knowledge page.** <a id="publish-golden-record-in-app"></a>When you merge duplicates, the app creates the combined **Golden Record** as a *Draft* and leaves the original articles Online so you can review before anything goes live. Two things have to happen when you're ready to make the merge official: the Golden Record Draft is **published**, and the original duplicate articles it replaces are **archived** so they stop appearing to agents and users.
>
> Use the **Publish Golden Record** action on the merged row in the Duplicates queue to do both in one step. Publishing the Draft with Salesforce's native "Publish" button on the Knowledge article page will make the Golden Record live, but it will **not** archive the originals — they stay Online alongside the merged article, which reintroduces the duplication you just resolved. (This is a platform limitation: publishing a Knowledge article doesn't trigger the automation that would retire the originals.)
>
> **If duplicates were left behind by a native publish,** you can still fix it: click **Publish Golden Record** on that row. It recognises the Golden Record is already live, skips re-publishing, and archives the leftover originals — so the action safely repairs merges that were published the native way.
>
> Publishing and archiving require Knowledge author access (the `KB_Knowledge_Author` permission set — see [Permission model](#permission-model)). If a duplicate can't be archived automatically (for example, an article you don't have delete rights on), the app tells you exactly which ones to archive by hand rather than reporting a false all-clear.

---

## Permission model

### Shipped permission sets

| Permission Set | Who gets it | Access |
|----------------|-------------|--------|
| `KB_Assessment_Setup_Admin` | Org admin / tool owner | Config only: Setup Wizard + configuration. No assessment/candidate data access — assign alongside the Manager set to a user who both configures and runs the app |
| `KB_Assessment_Admin` (labelled **Assessment Manager**) | Knowledge Managers, Quality leads | Run assessments, view/triage/approve results and candidates they own (create/edit/delete their own runs). **Reads** Knowledge to score it — does **not** grant Knowledge write access. Sees its own runs, not other users' |
| `KB_Knowledge_Author` | Users who fix/merge articles | **Additive.** Knowledge `Knowledge__kav` Create/Edit/**Delete** + the standard article-authoring user permissions — the write access the **Fix with AI** and **merge (Golden Record)** actions need. (**Delete** is required because publishing a draft supersedes the prior version — see the permissions note in the [README's User-level requirements](README.md#user-level-requirements-post-deploy).) Assign **on top of** the Manager set only to users who should write drafts; omit it to give a user analysis-only (read/score/triage) access |
| `KB_Assessment_Viewer` | Executives, stakeholders | Read-only, org-wide oversight of assessment results, scores, and run history |

No profiles are shipped with this package — permission sets are the sole access model. Assign users to a blank-slate profile of your own (or any minimal-access profile already in your org) and layer on the KB permission sets.

### Why write access is separate

The Manager persona *analyses* Knowledge (reads it to score, triage, and recommend); *writing* to Knowledge — creating the Draft that Fix-with-AI and merge produce — is a distinct responsibility. Some orgs split those duties across different people (one reviews, another applies fixes) and don't want to hand full article Create/Edit to everyone who runs assessments. Carving the write grant into `KB_Knowledge_Author` lets them assign it to only the users who should write drafts; everyone else gets analysis-only access from the Manager set alone.

### What the permission sets don't grant

**No View All / Modify All on `Knowledge__kav`.** None of these permission sets grant View All / Modify All Records on Knowledge. Knowledge visibility is governed by **data categories** and the org's sharing model, not by record-level permission-set grants — using View All there would override that model and interfere with the customer's intended article visibility. (The Viewer set does grant View All on the app's **own** assessment objects — that's its org-wide oversight role.)

> **These permission sets do not grant the platform Einstein/Data 360 entitlements.** A running user also needs the non-shipped **Data Cloud user** and **Prompt Template user** platform permissions, plus the **Knowledge User** feature license — assign those separately. See [User-level requirements in the README](README.md#user-level-requirements-post-deploy).

---

## Architecture

### 5-layer stack

Multi-surface stack with a unified facade:

```
Surfaces         Batch LWC │ Article Record LWC
Entry Points     @AuraEnabled Controllers
Facade           KBAssessmentFacade (existing-first, sync/async routing, dimension filtering)
Services         KBAssessmentService │ KBScoringService │ PromptTemplateService │ VectorSearchFactory │ …
Scorers          6 dimensions — all extend KBScorerBase
Data             KB_Assessment_Run__c │ KB_Article_Assessment__c │ KB_Dimension_Result__c │ Duplicate_Candidate__c │ …
```

The frontend is **LWC only** — no Aura components, no Visualforce.

### Async execution model
<a id="async-execution-model"></a>

Three-tier execution based on article count:

- **Small runs (≤ 10 articles)** — score synchronously in-request for immediate results.
- **Mid-size runs (11–50 articles)** — Queueable fan-out. Deterministic dimensions get one `KBAssessmentDimensionQueueable` each, while each LLM dimension is split into article chunks that run in parallel in the flex queue.
- **Large runs (> 50 articles)** — `KBAssessmentBatch` (Batch Apex with `Database.AllowsCallouts`); chunk size is governor-informed and up to 5 shards run concurrently.

After scoring, `KBAssessmentPipelineDispatcher` decides whether to run the dedup pipeline or proceed straight to `KBAssessmentPipelineCallback` for finalization. Real-time progress is pushed to LWC via Platform Events (`KB_Assessment_Progress__e`) subscribed through `lightning/empApi`.

This design is **governor-limit safe**: async processing is enforced above the configured batch threshold, and no single transaction exceeds Apex platform limits.

### LLM calls and prompt templates

All AI calls go through `PromptTemplateService` → `ConnectApi.EinsteinLlm.generateMessagesForPromptTemplate()`. No raw LLM calls, no HTTP callouts — calls never leave the Salesforce trust boundary.

**12 GenAI Prompt Templates deployed:** 3 scoring, 7 pipeline, 1 severity annotation (`Annotate_Issue_Severity`), 1 AI Fix (`Fix_Article_Issues_V2`).

Each template's model is **configurable per template** in Prompt Builder — you can point any template at a different Trust-Layer-supported model without a code change.

| Capability | Prompt template(s) |
|---|---|
| Completeness scoring & recommendations | `Evaluate_Completeness` |
| Structure scoring & recommendations | `Evaluate_Structure` |
| Clarity scoring & recommendations | `Evaluate_Clarity` |
| Issue severity (Impact rating) | `Annotate_Issue_Severity` |
| AI Fix — rewrite an article into a Draft | `Fix_Article_Issues_V2` |
| Deduplication — triage, comparison, merge drafting | `Triage_Duplicate_Candidates`, `Extract_Article_Facts`, `Evaluate_Extracted_Facts`, `Published_Anomaly_Evaluator`, `Draft_Merged_Knowledge_Article`, `Consolidate_Knowledge_Articles` |

**Duplication** and **Conflict** are scored from the deduplication results (not driven by an LLM directly), and **Freshness** is computed with no AI at all.

### Deduplication pipeline
<a id="deduplication-pipeline"></a>

Multi-tier detection: vector search via `ConnectApi.CdpQuery` (Data 360) → agentic LLM triage → fact extraction and comparison → consolidation (Golden Record draft creation with cluster-aware merging). Output stored in `Duplicate_Candidate__c` and bridged into the Duplication and Conflict scorers.

### Data flow

Every hop below stays inside the Salesforce Platform; the only path off-platform is Einstein's brokered call to an LLM provider, under the Trust Layer.

```
  [ 1. READ ]     Your Knowledge Base (Knowledge__kav)
                  Read Title, Summary, and admin-selected body fields.
                  Reads run in the running user's sharing context
                  (record-level access is respected).
      |
      v
  [ 2. ANALYZE ]  Article text passed to AI models via Salesforce Prompt Templates
                  (Completeness, Structure, Clarity, severity, duplicate/conflict
                  detection). Freshness is computed with no AI.
      |             |
      |             +--> [ DATA 360 ]  Duplicate detection searches a Knowledge
      |                                index in YOUR OWN Data 360 instance.
      v
  [ 3. PERSIST ]  Results written to custom objects in YOUR org
                  (scores, recommendations, duplicate/conflict findings).
      |
      v
  [ 4. FIX ]      AI cleanup — on demand, human-gated
                  "Fix with AI" writes a NEW Draft article; it never edits or
                  publishes the live one. Merges produce a Draft only after a
                  person approves them.
```

The application makes no external integrations of its own — no Named Credentials, no Remote Site Settings, and no outbound HTTP callouts. Knowledge content is never sent to the project authors or to any third party outside the Einstein Trust Layer arrangements.

### Einstein Trust Layer

Because every AI call routes through Salesforce Prompt Templates, it inherits the platform's Trust Layer controls (zero data retention, no training on your data, data masking, toxicity scoring, and audit logging). These are Salesforce platform guarantees governed by your Einstein / Agentforce terms and your org's configuration — not features this application implements or can weaken.

**Data residency** follows your existing Salesforce org and Einstein platform configuration; the application introduces no new data location.

Reference: <https://www.salesforce.com/artificial-intelligence/trusted-ai/>

---

## Operations

### Rate limits and billing

LLM scoring and the dedup pipeline use Salesforce's Einstein AI Platform, which is subject to org-level rate limits. Each article scored counts toward your org's quota.

> **Billing notice:** Use of Einstein LLM scoring and vector search may contribute to your org's Salesforce AI and Data 360 consumption and could be subject to Salesforce billing and usage charges depending on your contract and edition. Review your org's Agentforce, Generative AI, and Data 360 usage terms before running large scans in production.

### Runtime resilience

Einstein and Data 360 are required (see [Required Salesforce features in the README](README.md#required-salesforce-features)). The runtime additionally carries last-resort safety nets so a transient platform failure degrades gracefully rather than failing the whole run — these are **not** a supported way to run without the dependencies:

| If this fails at runtime | Behavior |
|--------------------------|----------|
| An Einstein scoring call (Completeness / Structure / Clarity) | The dimension falls back to a baseline score, stamped as a fallback rather than a quality assertion. The run completes. **Note:** a prompt template edited to break its JSON return shape triggers this same fallback — see [Editing prompt templates safely in the README](README.md#editing-prompt-templates-safely). |
| Data 360 vector search (Tier 2 dedup) | Falls back to SOQL keyword matching — lower quality, more false positives. Configure a search index on the Setup Wizard's Essentials screen to avoid this. |

The Setup Wizard detects missing dependencies during preflight and surfaces them as blockers or warnings.

---

## Legal & project info

### Accessibility

This project targets **WCAG 2.2 Level AA** as a guideline. Rather than a one-off audit, accessibility is checked **per contribution**: any pull request that **adds or changes UI** should include an accessibility review as part of its normal review — covering keyboard access, focus management in dialogs, colour contrast, ARIA/labelling, and target size.

- The check is **manual**, carried out as part of the code review.
- Contributions that don't touch UI don't need it.
- Known accessibility gaps are tracked as issues and labelled accordingly.

### API version

Source API version: **66.0**

### Open source and support

This accelerator is **intended to be released as open source** for you to evaluate in your own org. The **specific open-source license is still under consideration, and its release is subject to Salesforce legal sign-off** — the final terms will be confirmed at release.

Under the intended open-source terms:

- It is provided **"as is," without warranty of any kind.**
- It is **not a supported Salesforce product** — there is no SLA, no official support channel, and no guaranteed maintenance. Please do not rely on Salesforce for support of it.
- Once deployed, the artifacts run in **your** org and are **yours to operate**.

Because the accelerator runs in your own org, **it is recommended that you review and audit it yourself** against your own security and architecture standards, on your own timeline.
