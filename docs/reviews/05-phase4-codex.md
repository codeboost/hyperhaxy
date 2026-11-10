I would **not mark phase 4 complete yet**. The extraction largely works, and the strict direct-write criterion passes, but deletion now accepts stale passwords, including through the previously extracted fork-delete path.

This is a static review against **HEAD `a4586a9`**, including the untracked files. Nothing was modified. I did not run builds or tests, so native, wasm and hyperhaxy build success remain unverified.

I found no new input that selects another account as the actor for account, key or notification operations. Repo management checks owner role and conceals inaccessible private repositories; deletion checks the creator’s namespace. Notification IDs are resolved inside the acting user’s inbox. Those protections are present, subject to the stale-context findings below.

The web-handler comparison is:

| Handler | Preserved result and feedback | Differences |
|---|---|---|
| [Repo creation](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:745) | Login before body; invalid hash/access: 400; success: 303 to new repo. Failure retains name, description, hash, access and copy source. | No ordinary behavior difference found. |
| [Repo settings](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:801) | Authorization before body; invalid access/role: 400; success: 303 to renamed settings URL. Failure returns to original URL with all settings fields. | Additional authorization after body can reject newly revoked permissions or a vanished repo. Anonymous requests now perform admin I/O before login rejection. |
| [Members](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:875) | Only grant reads a body. Unknown/already-added names retain name and feedback; missing row: 404. Success returns to the same window, or repo files after self-demotion/revocation. | Additional authorization; anonymous admin-I/O change; target username now resolves against the **pre-body** admin snapshot. |
| [Branches](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:929) | Authorization before body; unprotect decodes its URL argument; 303 to branch list. Failures retain branch name and default/protect selection. | New 170-byte limit affects **both protection and default selection**. Additional authorization and anonymous admin-I/O change. |
| [Registration](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:976) | Recognized session cookie, including removed account: 403 before body. Success creates session and redirects 303 to user page. Failure retains name/email only. | No ordinary HTTP difference. |
| [User settings](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1056) | Success: 303 to posting URL; feedback retains email only. | Removed account is rejected before body parsing. A malformed body with that session now gets 403 instead of a parsing failure. |
| [Add key](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1101) | Success: 303 to posting URL; failure retains key and feedback. | Same earlier removed-account rejection. |
| [Remove key](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1140) | Malformed route/fingerprint length: 404; absent key still redirects 303 to keys tab; removed actor gets login-required. | Operation’s new NotFound is deliberately swallowed, preserving HTTP behavior. |
| [Delete](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1178) | Confirmation before password before ownership/object check. Failure retains confirmation and target kind only. Missing target: 404. Repo/fork success: 303 to actor’s page; account success: 303 `/`, session removal and expired cookie. | Password verification now uses the pre-body snapshot. This also affects **DeleteFork**. |
| [Undo](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:2313) | Authorization precedes index handling; missing/invalid history: 404; success: 303 to unselected undo list. | Missing index skips the former second resolution. Normal status is unchanged; a failure in that redundant resolution no longer masks the 404. Anonymous admin-I/O change applies. |
| [Sync](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:2338) | Invalid base: 404; attempted sync: 303 `/events`; same encoded failure cookie, cleared on success. | New timestamp/context setup occurs outside failure-to-flash handling. |

No changed feedback structure retains a password.

The TUI comparison also largely preserves behavior:

| Path | Comparison with HEAD |
|---|---|
| [NewRepo](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/NewRepo.zig:138) | Same feedback, successful field clearing and new-repo navigation. |
| [NewUser](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/NewUser.zig:128) | Same signup/login/remember-key sequence and clearing. A stale form submitted after login now silently refuses registration instead of creating another account. |
| [Repo settings](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Settings.zig:359), [members](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Members.zig:302), [branches](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Branches.zig:211) | Same retained fields and navigation, including stale-member refresh and self-demotion/revocation landing. Branch cap changes acceptance. Newly possible late authorization failures escape the widgets. |
| [UserSettings](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/UserSettings.zig:207) | Same removed-account logout, email-only feedback and successful navigation that clears password controls. |
| [UserKeys](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/UserKeys.zig:217) | Same add feedback, removed-account handling and refresh. Missing removal target remains a refresh. |
| [Delete](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Delete.zig:189) | Same confirmation-only feedback, silent NotFound and successful navigation/logout. Context construction follows reading TUI inputs, so the HTTP slow-body window is absent. |
| [Undo](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Undo.zig:324) | HostRequest scheduling, failure text and navigation preserved. Synthetic local execution now returns UnavailableHere rather than NotFound; local UI offers no undo. |
| [Sync](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Events.zig:830) | Same “syncing…” scheduling, refresh, failure display and selection reset. Context-setup failures now escape instead of entering `sync_failure`. |
| [Notification composition](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo.zig:450) | Same enriched windows, excluded drafts and viewed-child check. Concurrent dismissal can now produce a warning; it **does not fail the page**, because [Repo.init catches it](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo.zig:383). |
| [UserNotifications](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/UserNotifications.zig:36) | Same pagination, URLs and unread count. Removed accounts now explicitly get an empty inbox, including while residual storage remains. |
| [CLI delete-user](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/serve.zig:59) | Same target, passwordless operator behavior and output messages. Adds context/moment/timestamp setup. |

Two smaller parity findings are **notes**:

- [requestCtx:591](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:591) opens the admin repo even without a session. In settings, members, branches and undo, broken admin storage can therefore produce 500 where HEAD immediately returned login-required 403. **Fix:** retain the context helper but restore the absent-session check before admin I/O.
- Sync context setup sits outside the existing feedback capture in [web.zig:2355](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:2355) and [Events.zig:836](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Events.zig:836). **Fix:** include setup failures in the same flash/`sync_failure` handling.

The strict done criterion **passes**. Searching the handlers and widgets found no remaining targeted direct writes. The remaining presentation/session writes are exactly:

| Current location | Direct write | Assessment |
|---|---|---|
| [ui/Repo.zig:316](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo.zig:316) | `evt.consume` | Local page preparation, outside widget mutation; phase 5 work. |
| [ui/Repo.zig:317](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo.zig:317) | `pch.refreshBranches` | Same preparation path. |
| [ui.zig:2682](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:2682) | `evt.addUserKey` | Remaining account-operation extraction omission. |
| [ui.zig:2687](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:2687) | `evt.setLoginKey(..., .trust)` | Login/session work. |
| [ui.zig:2699](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:2699) | `evt.setLoginKey(..., .forget)` | Logout/session work. |

Static wasm tracing found no new native reachability problem. Changed widget mutations retain compile-time guards before context construction. Undo executes through native host loops; its wasm input path returns before scheduling. [main_wasm.zig:30](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/main_wasm.zig:30) builds widgets from snapshots rather than invoking native page loaders.

The [MCP registry](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:262) contains the reported **32 tools normally, 38 with the flag**. These are its actual annotation groups; columns are read-only, destructive, idempotent and open-world:

| Tools | R / D / I / O | Gated |
|---|---|---|
| `refresh_local`, `list_issues`, `get_issue`, `get_discussion`, `list_patches`, `get_patch`, `list_notifications` | F / F / T / F | No |
| `create_repo`, `grant`, `protect_branch`, `add_key` | F / F / T / F | No |
| `create_thread`, `create_comment`, `attach`, `promote` | F / F / F / F | No |
| `edit_thread`, `resolve_conflict`, `edit_comment`, `mute`, `update_repo_settings`, `demote`, `set_default_branch` | F / T / F / F | No |
| `set_thread_status`, `assign`, `unassign`, `subscribe`, `publish_patch`, `revoke`, `unprotect_branch`, `mark_notification_read`, `dismiss_notification` | F / T / T / F | No |
| `merge_patch`, `remove_thread`, `remove_comment`, `remove_attachment`, `remove_key` | F / T / T / F | Yes |
| `undo` | F / T / F / F | Yes |
| `sync` | F / **F** / F / T | No; destructive hint needs correction below. |

Listing and invocation share the gate. Password-taking operations are absent. The [password guard](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:353) catches every current password field, but only examines top-level names; nested input types would require recursive checking.

Schema derivation correctly distinguishes required, omittable and nullable fields, rejects unknown fields and emits unsigned minimum zero. Every call gets a [fresh arena, admin handle and context](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:89). All ten newly added expected errors have classification arms, with reasonable kinds; nothing is marked retryable. The incomplete part is reporting effects after commits.

The tests generally use the requested public operation seam and independent literal expectations. However, several assertions overstate coverage:

- [Repo copy tests](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/domain/repos.zig:26) do not check copied contents or hash, despite the test title.
- [Progress test](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/domain/sync.zig:98) increments a counter but never asserts invocation or text.
- [MCP notification expectations](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/mcp.zig:1379) copy ID and time from the actual response. Those fields lack an independent oracle; pagination tests also omit newest-first ordering.
- [Branch boundary tests](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/domain/branches.zig:49) encode the new restriction rather than verify HEAD compatibility.
- A8’s “remote failure has no test” claim is outdated: [test/mcp.zig:1481](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/mcp.zig:1481) checks an SSH stand-in’s refusal text. It covers initial fetch refusal, not failure after mutation.

The blockers are:

1. **Blocker — deletion verifies stale credentials.**  
   [handleDelete builds its context before reading the body](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1184). [DeleteRepo](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/repos.zig:133), [DeleteUser](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/users.zig:142), and now the reused [DeleteFork](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/patches.zig:146) verify the captured hash.

   Start a deletion POST, pause its body, change the password from P1 to P2, then finish with P1: the new path accepts the revoked password. Conversely, P2 is rejected. HEAD refreshed the account after reading the body, including in its fork helper.

   **Fix:** reload the active account inside all three deletion operations immediately before credential validation. Preserve confirmation-before-password ordering. Test password rotation and account removal after context construction.

The should-fix items are:

1. **Restore branch-name compatibility.**  
   [repos.zig:313](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/repos.zig:313) replaces actual encoded length with a worst-case 170-byte limit. A valid branch containing 171 ASCII `b`s previously worked and now fails protection/default selection.

   **Fix:** restore the exact encoded-length rule using the existing unreserved-byte semantics, rather than multiplying every byte by three.

2. **Distinguish post-commit failures throughout the new operations.**  
   Repo deletion tombstones before fallible path allocation and directory cleanup at [event.zig:2398](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/event.zig:2398); user deletion does likewise at [event.zig:2598](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/event.zig:2598). Their wrappers propagate ordinary errors, classified with `changed=false`.

   Create/update repo also allocate their returned identity **after** committing: [repos.zig:63](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/repos.zig:63), [repos.zig:106](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/repos.zig:106). Sync can merge locally, then fail consuming, pushing or fetching again at [repos.zig:507](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/repos.zig:507); neither raw errors nor `remote_failure` identify that progress.

   **Fix:** translate failures at the actual commit boundaries into distinct changed outcomes; preallocate repo result identities before writing. Give Sync failure results stage/effect information and preserve it through MCP. Add fault tests without adding retries.

3. **Return notification transaction outcomes instead of inferring them afterward.**  
   [MarkRead:136](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/notifications.zig:136) performs a pre-read, write and post-read. If marking succeeds and a new child arrives before the post-read, it returns `NotificationOutOfDate` with `changed=false` despite having committed. A post-read I/O failure has the same reporting problem.

   **Fix:** make the existing storage transaction return whether it marked, found an already-read item, encountered a newer child, or found nothing. Map that result directly. Return Dismiss’s found/missing outcome from its transaction too; keep transactions and ownership scope unchanged.

4. **Resolve member targets from a fresh admin moment.**  
   [changeMember:231](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/repos.zig:231) resolves the target name from `ctx.moment`, captured before a grant body is read. HEAD read it afterward. A newly registered target is incorrectly unknown; removal and name reuse can resolve the old account ID.

   **Fix:** refresh the admin moment for target-name resolution inside the operation. Preserve existing role rules and test registration/removal/name reuse during the context lifetime.

5. **Handle late authorization failures in the TUI.**  
   [Settings:384](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Settings.zig:384), [Members:315](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Members.zig:315) and [Branches:222](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Branches.zig:222) project form errors but propagate new operation-level authorization failures. Revocation between their precheck and operation can escape through [the terminal input loop](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:2827).

   **Fix:** handle login-required, forbidden and disappeared-repo outcomes like the initial precheck—retain the form or navigate safely—while continuing to propagate infrastructure errors.

6. **Correct the repo-settings input contract.**  
   [repos.zig:84](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/repos.zig:84) silently clears an existing description when omitted. Its nullable role fields also admit `.owner`, despite documenting only read/write/null. The UI [renders owner as “members” and maps it back to write](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Settings.zig:52), so saving an unrelated setting can relax owner-only creation permissions.

   **Fix:** require description for this full replacement operation, or explicitly preserve it on omission. Restrict role inputs to read/write/null unless both frontends gain an accurate owner-only option.

7. **Mark Sync as potentially destructive.**  
   [mcp.zig:244](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:244) declares `destructiveHint=false`, but merging remote events applies edits and tombstones. [Issue.consume](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/event/Issue.zig:108) overwrites records and removes their visible index entries.

   **Fix:** set Sync’s destructive hint to true; retain open-world=true and idempotent=false. This does not itself require flag gating. Test importing an edit and deletion, not only additions.

8. **Check capability before MCP local preparation.**  
   [mcp.zig:143](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:143) refreshes before every local call. Unsupported account/member/notification operations can mutate local data or report a refresh error instead of UnavailableHere.

   **Fix:** check host capability before preparation; skip refresh for unsupported operations and avoid redundant preparation for Sync.

9. **Finish the SSH-key extraction and adapter tests.**  
   [rememberSshKey:2682](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:2682) still bypasses `AddKey`. Separately, the new tests do not establish HTTP or phase-4 widget parity; the rewritten [sync test helper](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/ui.zig:323) calls the operation directly.

   **Fix:** route remembered-key addition through `AddKey`, retaining duplicate/limit handling, and add the adapter tests prioritized below.

The deviation verdicts are:

| ID | Verdict | Evidence and disposition |
|---|---|---|
| A1 | **REVERT** | Restore actual encoded-length acceptance; [repos:313](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/repos.zig:313). Applies to default selection too. |
| A2 | **ACCEPT** | All listed errors have appropriate [classification arms](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain.zig:559). |
| A3 | **ACCEPT** | [Undo:338](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo/Undo.zig:338) preserves the host’s Forbidden behavior; domain authorization remains. |
| A4 | **ACCEPT** | [web:2325](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:2325): normal ordering/status remains equivalent; redundant resolution disappears. |
| A5 | **CHANGE** | Keep the new helpers; restore absent-session rejection before [admin I/O](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:591). |
| A6 | **CHANGE** | Preserve `.read`-grant behavior, but refresh target lookup. The removed-name claim is inaccurate for fresh contexts: [User:109](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/event/User.zig:109) removes the name index. |
| A7 | **ACCEPT** | [repos:132](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/repos.zig:132) preserves confirmation/password/creator order. The same-name guard already existed in HEAD; its repair was intermediate-refactor work. |
| A8 | **CHANGE** | Payload result and progress callback are reasonable; add partial-effect information. [MCP refusal test](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/test/mcp.zig:1481) exists; progress text and later-stage failures remain untested. |
| B1 | **ACCEPT** | Active-context denial plus [stricter web cookie check](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:988) is appropriate. |
| B2 | **ACCEPT** | Earlier removed-account denial at [web:1072](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1072) and [1117](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1117) follows login-before-body. |
| B3 | **ACCEPT** | Accurate operation NotFound with [preserved adapter refresh](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/web.zig:1164). |
| B4 | **ACCEPT** | [Dispatcher:51](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Delete.zig:51) is now self-account-only. Direct mismatched-target calls change behavior, but existing web/TUI callers bind target to actor. The web alias already existed in HEAD. |
| B5 | **ACCEPT** | [Operator entry:152](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/users.zig:152) is separate from decoded inputs; [serve:72](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/serve.zig:72) uses it under the existing operator trust model. |
| B6 | **CHANGE** | Existing validation errors suffice, but deletion cleanup needs a distinct changed failure; [users:157](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/users.zig:157). |
| B7 | **CHANGE** | Refresh credentials within deletion operations; blocker above. Also covers the rewired fork path. |
| B8 | **CHANGE** | Preserve existing name reuse; replace [direct remembered-key addition](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui.zig:2682) with `AddKey`. |
| C1 | **CHANGE** | Conflict classification is suitable; derive it from the transaction, not [post-read state](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/notifications.zig:140). |
| C2 | **CHANGE** | Return transaction outcomes instead of [separate existence checks](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/notifications.zig:136). Current ownership scope is safe. |
| C3 | **ACCEPT** | Explicit absent/already-dismissed NotFound is reasonable for the new operation; [notifications:159](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/notifications.zig:159). |
| C4 | **ACCEPT** | Extra [page context reads](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo.zig:454) are acceptable temporarily; consolidate in phase 5. |
| C5 | **ACCEPT** | [UserNotifications:48](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/UserNotifications.zig:48) correctly suppresses removed-account inboxes. |
| C6 | **ACCEPT** | Enrichment covers returned/searched windows; [draft exclusion](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/domain/reads.zig:160) matches page behavior. |
| C7 | **ACCEPT** | [Repo:475](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/ui/Repo.zig:475) reads establish what was displayed; mutation goes through MarkRead. |
| D1 | **ACCEPT** | Keep the narrow content/history gate, explicitly exempting transient inbox state. [Dismiss](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:319) is not literally reversible to the same row; existing mute also dismisses. |
| D2 | **ACCEPT** | [Registry](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:262) and counts match; password-taking operations remain absent. |
| D3 | **CHANGE** | `add_once` and open-world hints are reasonable; change [Sync destructive hint](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:244) to true. |
| D4 | **ACCEPT** | [Guard](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:353) protects current flat inputs. Recurse before relying on it for nested inputs. |
| D5 | **ACCEPT** | [Unsigned minimum zero](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:501) matches validation. |
| D6 | **CHANGE** | Preserve [isError mapping](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:109), but carry Sync’s stage/effects so partial success is distinguishable. |
| D7 | **CHANGE** | Capability-check before [local refresh](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/mcp.zig:143). |
| D8 | **CHANGE** | Fix description omission and role inputs; preserve repeated promote/demote events and their honest annotations. Update [help:43](/Users/florinbraghis/code/haxy/haxy-hyperhaxy/src/command.zig:43) for new families and undo/remove-key gating. |

Missing tests, in priority order:

1. **Deletion credential freshness:** all three delete targets; password rotation/removal after context construction; delayed HTTP bodies; confirmation ordering.
2. **Post-commit failures:** repo/user cleanup, result allocation, Sync after merge/push, MarkRead after mutation; assert changed outcomes and no retries.
3. **HTTP contracts:** every rewired handler’s status, redirect, flash and retained values; combined login/repo/role/body failures; verify no retained passwords.
4. **Settings/MCP contracts:** omitted description, rejected owner role, unsupported local call with failing refresh, and Sync importing edits/deletions with corrected annotations.
5. **TUI and HostRequest paths:** form retention/clearing, navigation, late role loss, removed sessions, undo failure display, sync refresh and setup failures. Add CLI delete-user output/error tests.
6. **Member and notification races:** target registration/removal/name reuse; `.read` promote/demote; concurrent bump/dismiss; independent notification IDs/times and newest-first order.
7. **Branch compatibility boundaries:** long ASCII, encoded lengths 512/513, literal `%`, Unicode and `/`.
8. **Semantic coverage behind existing claims:** copied repo hash/content, actual progress callback text, later Sync remote failures, SHA-256 sync, and broader notification-page windows.

Phase 5 can build on the operation/context architecture, but should not treat phase 4 as an accepted behavioral baseline yet. Fix stale deletion credentials first, close partial-effect reporting and the settings contracts, then add adapter tests before splitting loaders. The remaining page-preparation writes and duplicate context construction fit naturally into phase 5; carrying the current regressions into snapshot baselines would make them harder to identify later.