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
public with sharing class KBAssessmentPipelineCallbackSchedulable implements Schedulable {
    private Id assessmentRunId;

    public KBAssessmentPipelineCallbackSchedulable(Id assessmentRunId) {
        this.assessmentRunId = assessmentRunId;
    }

    public void execute(SchedulableContext sc) {
        System.debug(LoggingLevel.INFO,
            'Callback trampoline: execute fired for run ' + this.assessmentRunId + ' triggerId=' + sc.getTriggerId());
        if (this.assessmentRunId != null) {
            System.debug(LoggingLevel.INFO,
                'Callback trampoline: enqueueing KBAssessmentPipelineCallback for run ' + this.assessmentRunId);
            System.enqueueJob(new KBAssessmentPipelineCallback(this.assessmentRunId));
        } else {
            System.debug(LoggingLevel.WARN,
                'Callback trampoline: assessmentRunId is null, callback queueable not enqueued.');
        }
        System.abortJob(sc.getTriggerId());
    }
}
