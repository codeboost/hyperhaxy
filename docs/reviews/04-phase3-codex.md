Static review only: I compared the working tree with `a2b3f5e`, read the untracked files, and checked the prior implementations. No files were modified and no builds were run.

1. **Blocker — `delete_fork` exposes the account password as a model-controlled argument.**  
   The registered operation includes `password` in its generated schema: [domain/patches.zig:124](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/patches.zig:124), [mcp.zig:257](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:257). `--allow-destructive` does not prevent credential retention in client transcripts.

   **Fix:** choose an **operator-only password bypass**, consistent with [the plan’s operator trust model](/Users/florinbraghis/code/haxy/hyperhaxy/docs/domain-layer-plan.md:477). Expose a password-free MCP adapter; establish its trusted capability at stdio startup, never through tool arguments. Retain confirmation, active-user and forker checks, and retain password verification for web/TUI. Until that separation exists, leave this tool unregistered. Bearer tokens alone would not fix a schema that still requests passwords.

2. **Should-fix — fork confirmation is not bound to the fork being deleted.**  
   `DeleteFork` checks `confirm == identity` and the owner name, but ignores `parsed.name` after loading `fork_id`: [domain/patches.zig:148](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/patches.zig:148). Consequently, `identity=alice:A`, `confirm=alice:A` can delete Alice’s fork of B. This is not cross-user traversal, but the new tool exposes an unreliable confirmation contract. The fork page already validates this relationship: [ui/Fork.zig:60](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Fork.zig:60).

   **Fix:** match the loaded fork’s stored `repo_name` against the identity before deletion; test mismatched identity/id pairs.

3. **Should-fix — several failures after a commit still classify as `changed = false`.**  
   The merge-cleanup wrapper correctly adds `MergedForkKept`, but classification recognizes only that and `CommittedUnconsumed`: [domain.zig:477](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain.zig:477). Other newly exposed operations have equivalent boundaries:

   - Publish commits the target, then performs fallible fork tombstoning and user-record updates: [patch.zig:973](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/patch.zig:973), [patch.zig:991](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/patch.zig:991), [patch.zig:1003](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/patch.zig:1003).
   - `DeleteFork` and draft removal tombstone the fork before allocating its path and deleting its directory: [fork.zig:255](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/fork.zig:255).
   - Mute commits the notification mode before fallible notification dismissal: [notify.zig:269](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/notify.zig:269).

   **Fix:** translate failures at those exact post-commit boundaries into classified errors carrying `changed = true`. Preserve the existing transactions and absence of retries; add fault-injection tests through the public operations.

4. **Should-fix — `merge_patch` bypasses the removal gate despite deleting a fork.**  
   It is always listed and callable because its registry entry lacks `.removal = true`: [mcp.zig:253](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:253). Its execution calls `mergeAndRemoveFork`: [domain/patches.zig:114](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/patches.zig:114).

   **Fix:** gate `merge_patch` behind `--allow-destructive`, and test both listing and invocation without the flag. This concerns actual removal, independently of MCP’s broader `destructiveHint` meaning.

5. **Should-fix — attachment limits are incomplete in MCP.**  
   `prepare` bounds encoded length, calculates decoded size, then immediately allocates and decodes: [mcp.zig:300](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:300). An encoding at `max_encoded_len` can decode to **10 MiB + 1 or + 2 bytes**, depending on padding. The domain eventually rejects it, but only after decoding.

   Also, the actual stdio transport retains a **1 MiB request-line limit**, making its usable attachment limit less than 768 KiB: [mcp/stdio.zig:8](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp/stdio.zig:8). The large-input test calls the server directly and misses this: [test/mcp.zig:965](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/mcp.zig:965).

   **Fix:** check `size > Attachment.max_size` before allocation/decode; test exact-limit and both padding-overflow cases. Size the transport bound for the intended encoded payload plus bounded JSON overhead, or document the smaller transport limit. Route allocation failures from the new `prepare` stage through the setup-error mapper instead of its current uncaught `try`.

6. **Should-fix — object-denial precedence changed in assignment, comment editing and uploads.**  
   Assignment and comment editing now read/parse the body before `canModify`: [web.zig:1715](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1715), [web.zig:1874](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1874). A forbidden caller supplying malformed form encoding can now receive a propagated **500** instead of the old immediate **403**; the outer mapper returns exception names: [web.zig:153](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:153).

   Uploads validate headers and invoke `readerExpectContinue` before object authorization: [web.zig:1659](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1659), [web.zig:1674](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1674). Thus header errors—and potentially `100 Continue`—precede the old authorship rejection.

   **Fix:** restore object preflight before these steps, using shared authorization logic while retaining operation-level checks. **B overstates its scope:** thread editing already checked authorship after reading the body; removal reads no body.

7. **Should-fix — conflict resolution reverses missing-thread versus invalid-title precedence.**  
   `ResolveConflict` validates title before looking up the thread: [domain/threads.zig:432](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/threads.zig:432). Previously, `Issue.update`/`Patch.update` loaded the record first. A missing thread with a blank title now produces **303 to `/resolve`**, rather than the previous kind-specific **404**: [web.zig:2234](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:2234).

   **Fix:** establish existence before field validation and test combined failures, not only each failure independently.

8. **Should-fix — normal patch-state failures are missing from the expected error inventory.**  
   `PatchClosed`, `PatchAlreadyMerged` and `PatchNotPushed` arise from ordinary state checks: [patch.zig:1102](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/patch.zig:1102). Their absence from `domain.Error` makes them `internal`: [domain.zig:476](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain.zig:476).

   **Fix:** classify all three as **`conflict`**. The supplied arguments can be valid while the patch’s current state prevents the operation. Add explicit operation/classification tests. Existing assignment and delete `fromError` projections are correct; merge-state errors need not become edit-form feedback merely to classify them correctly.

9. **Should-fix — `.replace` overclaims idempotence for some newly registered tools.**  
   The registry marks mute, editing and resolution idempotent: [mcp.zig:241](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:241), [mcp.zig:250](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:250). Repeated mute calls unconditionally write another event; repeated comment edits likewise commit again: [notify.zig:269](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/notify.zig:269), [event/Comment.zig:179](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/event/Comment.zig:179). These affect first-class event/undo history, not merely incidental logging.

   Under the [2025-06-18 ToolAnnotations definitions](https://modelcontextprotocol.io/specification/2025-06-18/schema#toolannotations), idempotence concerns repeated effects on the environment. **Fix:** separate destructive and idempotent annotation presets, marking these operations non-idempotent unless they gain no-op detection. `subscribe` and `publish_patch` have repeat-call short-circuits and can retain `idempotentHint = true`; destructive hints are appropriate for all three operations in M.

10. **Should-fix — phase 3’s test coverage is materially incomplete.**  
    Tests generally use the right public operation/read seams and check persisted state. However:

    | Area | Missing verification |
    |---|---|
    | Widgets | The unchanged [thread_widget.zig:12](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/domain/thread_widget.zig:12) tests phase 2 issue creation only. No switched phase 3 path verifies navigation, clearing, retained feedback or stale-session behavior. |
    | Merge lifecycle | Fork/source succeeds across both hashes; branch/squash succeeds only with SHA-256. Missing successful branch/source and fork/squash combinations, plus target-content/commit-graph assertions: [patches.zig:267](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/domain/patches.zig:267), [patches.zig:324](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/domain/patches.zig:324). |
    | Patch failures | Missing closed/already-merged/not-pushed, stale revision, unavailable check/data, and publish/delete post-commit faults. The `MergedForkKept` fault test is meaningful: [patches.zig:363](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/domain/patches.zig:363). |
    | Resolution | Success covers only local xit/SHA-1 issue labels; no patch, hunks, `theirs`, server success or full backend × hash coverage: [resolve_conflict.zig:13](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/domain/resolve_conflict.zig:13). |
    | Attachments | Metadata assertions do not establish byte correctness or streaming. Missing fragmented-reader/EOF/boundary tests; the “tab’s role” test never exercises tab-role denial: [attach.zig:29](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/domain/attach.zig:29), [attach.zig:67](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/domain/attach.zig:67). |
    | Matrix/denials | Attach and Unassign test only two local backend/hash combinations; no local RemoveAttachment case. Several families exercise only issue targets. DeleteFork lacks published-fork deletion coverage. |

    **Fix:** complete these cases, plus HTTP rejection-order and feedback-retention tests. I found no material domain-test tautologies, but an enum/status assertion alone does not prove that source versus squash merged the correct graph. Test-first sequencing cannot be established from this uncommitted snapshot.

11. **Nit — a few small helpers would remove repeated work.**  
    Create/edit duplicate title/label validation: [threads.zig:68](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/threads.zig:68), [threads.zig:299](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/threads.zig:299). Resolve and merge repeat authorization-result mapping. Non-draft patch removal authorizes, resolves and parses twice: [threads.zig:549](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/threads.zig:549), [threads.zig:632](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/threads.zig:632).

    **Fix:** share field validation, parameterize authorization by minimum role, and pass the resolved actor/id to the removal executor. No larger abstraction is necessary.

The per-handler behavior comparison is below. Successful redirects have empty bodies. Shared login/permission failures remain **403** with `"log in to make changes"` / `"you don't have permission to do that"`; missing repositories return **404 `"repo not found"`**: [web.zig:697](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:697). Body-taking handlers retain role preauthorization before reading the body; finding 6 concerns the additional object check.

| Web path | Success, feedback and other responses |
|---|---|
| [Patch new:1255](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1255) | 303 to `<repo>/patch:<id>`. Title/branch failures return to `/patches/new` with `.patch`: title, labels, description, target/source branch and source kind. Invalid labels redirect without feedback. Local fork draft: 404 `"event not found"`. |
| [Thread edit:2070](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:2070) | 303 to base. Failure returns to `/edit`; `.issue`/`.discussion` retain title, labels, description; `.patch` also retains target branch, with empty source/fork source kind for edit. Invalid labels: no flash. Missing object: kind-specific 404. |
| [Comment edit:1855](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1855) | 303 to comment permalink; empty body returns to `/edit` without flash or retained body. Missing comment: 404 `"comment not found"`. |
| [Remove:1944](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1944) | 303 to thread list, parent thread for children, or `/patches/drafts` for drafts. No flash; missing event: 404 `"event not found"`. |
| [Assign:1694](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1694) | 303 to base. `.assignment` retains submitted text and `not_found`, `not_an_email` or `already_assigned`. Missing thread: event-not-found 404. |
| [Unassign:1743](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1743) | 303 to thread URL; no flash/body read. Missing event: event-not-found 404. |
| [Subscribe/Mute:1785](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1785) | 303 to base; no flash/body read. New existence/kind checks produce 404; authorization still uses no tab kind. |
| [Publish:1341](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1341) | 303 to base; no flash. Local/malformed targets return event-not-found 404 before authorization, as previously. Missing/foreign draft now 404. |
| [Merge:1375](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1375) | 303 to canonical patch URL. Conflict: 409 `"merge conflict"`. Unavailable check/data or stale revision: 303 reload. Other errors propagate; no flash. |
| [Resolve:2153](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:2153) | 303 to base; invalid fields return to `/resolve` without flash. Missing thread: kind-specific 404, subject to finding 7. |
| [Attach:1639](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1639) | 204, no Location/flash. 400: `"attachment needs a name"`, `"invalid attachment name"`, `"attachment is empty"`; 411: `"attachments must declare a content length"`; 413: `"attachment is too large"`; target 404 as reported in G. |
| [Fork delete:1129](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1129) | Existing handler reaches `DeleteFork` through `Delete.perform`; success redirects 303 to the user page. `.delete` retains target and confirmation, never password. Missing/non-forker: 404 `"nothing to delete"`. |

The accepted C exception changes post-preauthorization missing-repo/tab responses in edit/assign/unassign/remove/notify to `"repo not found"` through [repoTabFound:610](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:610). Server flash retains the fields above. Local feedback remains more limited: assignment retains text/failure; required-title cookies retain only the variant. Local branch-error feedback still hits the **pre-existing** `InvalidFormFeedback` limitation: [web.zig:483](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:483).

The switched TUI paths preserve these outcomes:

| TUI path | Navigation, clearing and feedback |
|---|---|
| [Patch creation:3068](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/widget/thread.zig:3068) | New patch comments, offset 0. Clears title/labels/description/target, not source input. Patch feedback copies all fields into the session arena; local draft becomes `invalid_source_branch`. |
| [Thread edit:3137](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/widget/thread.zig:3137) | Same status/selected thread; no explicit field clearing. Retains the appropriate thread/patch feedback fields. |
| [Comment edit:3006](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/widget/thread.zig:3006) | Edited comment permalink, offset 0; clears body on success. Invalid body silently leaves the form. |
| [Remove:1725](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/widget/thread.zig:1725) | Drafts list; otherwise same-status list for removed threads, selected parent thread for children. No explicit form clearing. |
| [Assign/Unassign:1624](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/widget/thread.zig:1624) | Thread comments, offset 0. Assignment failures retain copied text and failure. A stale Unassign refreshes unless the repo/tab disappeared. |
| [Subscribe/Mute:1674](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/widget/thread.zig:1674) | Thread comments, offset 0. Local unavailability silently returns; missing thread now propagates if the repo remains. |
| [Resolve:2951](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/widget/thread.zig:2951) | Same status/selected thread; no explicit clearing. Invalid fields silently retain the live form. |
| [Publish/Merge:3207](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/widget/thread.zig:3207) | Publish selects the open patch; merge selects the merged patch. Merge conflict/check/staleness/data errors reload its previous view. Local unavailability silently returns. |
| [Fork delete:245](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Delete.zig:245) | User’s repository list. Wrong confirmation/password retains `.delete` confirmation only; mapped NotFound silently returns. |

Successful navigation clears feedback through [Session.navigate:2775](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:2775). Generally, login-required/forbidden and disappearing repo/tab cases silently return without clearing forms; missing objects in an existing repo and infrastructure failures propagate. Unassign is the deliberate stale-object exception.

Other checks passed static inspection: results are values or arena-owned; temporary fork paths are freed; I found no escaping scratch buffers, added retries or changed transaction boundaries. Attach still passes the request reader through to object-store writing, with the domain’s 10 MiB declared-size check: [threads.zig:678](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/threads.zig:678), [event.zig:1030](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/event.zig:1030). Tool arguments cannot select the actor; IDs are resolved within authorized repositories or the acting user’s fork namespace. Merge obtains revision/fork addressing from stored patch data. I found no new logged-out/read-only non-author write bypass; repo deletion still checks the creator’s namespace: [ui/Delete.zig:72](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Delete.zig:72).

Schema validation still precedes parsing, including the new string-array shape; unknown fields are rejected. Removal/delete tools are filtered from both list and call without the flag, except for the merge issue above. Ordinary execution failures remain `isError: true`, while context setup failures remain `-32603`: [mcp.zig:78](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:78). Read tools correctly retain `readOnlyHint = false` because local refresh runs. Native widget calls retain wasm guards before context construction; no new wasm reachability hazard or MCP import from `ui.zig`/`web.zig` was found. This is not a build-success claim.

Explicit deviation verdicts:

| Deviation | Verdict |
|---|---|
| **A** | **Accept.** Preventing notification entries for nonexistent/wrong-kind/disabled targets is sensible; preserve no-kind authorization. |
| **B** | **Change.** Restore assignment/comment object preflight. Thread editing already behaved this way; removal has no body. |
| **C** | **Accept.** More accurate 404 wording; document and test it as an intentional compatibility exception. |
| **D** | **Accept.** The result distinguishes genuine domain outcomes, and both adapters route drafts correctly. |
| **E** | **Accept.** Domain Forbidden with the existing web 404 projection is appropriate. |
| **F** | **Accept.** Missing/foreign drafts should not produce 500. Merge must still allow a writer to merge another author’s patch, as implemented. |
| **G** | **Change.** Restore authorship-before-headers/Continue ordering. The more specific wrong-kind 404 text is acceptable. |
| **H** | **Accept.** Preserves the previous server-only capability; record it in the plan’s mode matrix. |
| **I** | **Accept.** The core clears the conflict entry on the write; void and its native fields are honest. Update the plan’s union-result claim. |
| **J** | **Change.** All three are expected **conflict** errors. |
| **K** | **Accept.** Correct classification and a meaningful fault test; extend the treatment to the other post-commit boundaries. |
| **L** | **Change.** Use the trusted stdio-operator adapter described in finding 1; never request the password as a tool argument. |
| **M** | **Change.** Destructive hints are appropriate; publish/subscribe may retain idempotence, but mute cannot without no-op detection. |

**Verdict:** phase 4 can build on the overall operation/context design, but this phase should not be treated as complete yet. Fix credential exposure, confirmation binding, partial-commit reporting, destructive gating, attachment bounds and rejection precedence, then add the missing adapter and lifecycle tests. The architecture is usable; its behavioral and verification contracts still need closing.