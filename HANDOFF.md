# Ticketing: design document for the next parts

This is a handoff for an agent picking up the Ticketing page. It covers what
exists, the decisions already made with the project owner (don't re-open
these), and the remaining parts in build order, each with a spec and
acceptance criteria.

Read `README.md` in this folder first for the data model and how to run
things. The project owner's hand-drawn mockups are the four
`Ticketing #N.jpeg` files in the repo root (one level up). They're 3 MB
phone photos, so downscale before viewing:
`sips -Z 1100 "Ticketing #1.jpeg" --out /tmp/t1.jpg`.

---

## 1. Where things stand

**Built and tested (93 Dart tests, 42 Firebase emulator tests):**

| Piece | Files |
| --- | --- |
| Data layer: jobs, history, comments, remakes, stock reservation | `lib/src/models/`, `lib/src/data/` |
| Permission checks | `lib/src/rules/permissions.dart` |
| Realtime Database security rules (generated) | `tool/rules_source.dart` → `rules/ticketing.rules.json` |
| Main page: search, In-Progress / Requested / Log tabs, sort, Claim, Unclaim | `lib/src/ui/ticketing_page.dart`, `lib/src/ui/page_logic.dart` |
| Add Job form, also used for Edit | `lib/src/ui/job_form.dart` |
| Preview web app with sample data | `preview/` |

**Not built yet, in order:**

1. Job popup: what you see when you click a job.
2. Remake ("failure") form, opened from the popup.
3. Log popup: what you see when you click a Log entry.
4. Integration into lsicompapp.
5. Deployment prerequisites.
6. Trial run.

Nothing is committed yet. Ask the owner before committing; they review the
code themselves.

---

## 2. Decisions already made (don't change without asking)

**Storage**
- Firebase **Realtime Database**, `team` instance
  (`limbitless-solutions-team.firebaseio.com`), not Firestore. Everything
  lives under `ticketing/`.
- **Parts and stock come from lsicompapp's inventory** (`inventory/{id}`,
  owned by the inventory page). Ticketing only ever reads it and changes
  `stock`. Don't modify the inventory page or any other inventory field.
  Restocking happens on the inventory page.

**The job model**
- A **job** is assembling a bionic arm (not manufacturing or painting). There
  are no request types or stage lists.
  - Status: `requested` → `inProgress` → `completed`, plus `cancelled` and
    `remade`.
  - Tabs: In-Progress = `inProgress`; Requested = `requested`; Log = the
    activity feed.
- **Add Job form fields** (* required):
  - Name \*
  - Requested by \*: pre-filled with the signed-in person, can be changed to
    another active scholar; the signed-in person is saved as `submittedBy`.
  - Due date \*
  - Priority: low / medium / high, optional
  - Parts required \*: a list of inventory items with quantities
  - Comments: optional, saved as the first comment
- A job has **several parts and several claimers**.

**Stock**
- **The first claim takes every part out of inventory** (`stock` goes down).
  The claim is blocked if any part is short ("on hand ≥ needed").
  - Later claimers join without taking more.
  - When the **last claimer leaves**, everything the job holds goes back to
    inventory. **Cancel** does the same.
  - **Complete** changes no stock.

**Roles and permissions**
- **Admin** = `orgData.status == 'OrgStatus.admin'`. Everyone else active is a
  member. Inactive users get nothing.
- **Anyone can claim.** Claimers unclaim themselves; admins can unclaim
  anyone.
- **Requester or submitter** can edit or cancel their open job. The parts
  list only changes before a claim.
- **Comments:** admins, the requester and submitter, every claimer, and the
  Quality, Assembly and Production departments (`department` or
  `subDepartments`; `otherDepartments` is ignored because the security rules
  can't search it). Authors edit their own comments; authors and admins can
  delete them.

**Defects and remakes**
- **A defect always means a new remake ticket.** "Create remake" is available
  on in-progress or completed jobs, to the same people who can comment.
  - The form starts with the job's info. The user picks defective parts, each
    with a count and an optional reason.
  - Saving creates a remake job: Remake label, `remakeOf`, `usedParts` (the
    original's full parts list), `defects`, and lines = the replacements.
  - **The original closes as `remade`** (shown as "Failed" in the Log). Its
    defective parts are **scrapped, never returned** to stock.
  - **The remake is claimed by the person who created it, only.** The
    original's claimers are not carried over. That claim pulls the
    replacements; if anything is short, the remake waits unclaimed in
    Requested.
  - This is two saves (create+close, then claim), on purpose: one save can't
    both scrap and take the same part under the stock rule.

**Consistency**
- Every job save carries `rev = stored + 1` and links a new history row
  (`lastHistoryId`). The rules enforce both.
- For each job line, `stock + held + scrapped` stays constant.
- The repository retries on conflicts.

**UI style**
- Match lsicompapp: use `Theme.of(context)` only (no hard-coded theme), and
  use `secondaryHeaderColor` as the accent.
- Tables look like lsicompapp's `LiteTable`; there's a round + button at the
  bottom left.
- Below 900 px: cards, 44 px tap targets, full-screen dialogs with actions
  pinned to the bottom.

---

## 3. Repository API you'll build on

`TicketingRepository(store:, user:, clock:)`, where every write throws
`TicketingException(message)` with a user-facing message:

| Kind | Methods |
| --- | --- |
| Reads | `getJob`, `listJobs`, `watchJobs`, `watchHistory`, `watchComments`, `listInventory`, `watchInventory`, `getInventoryItem`, `stockFor(job)`, `historyForJob`, `historyForItem`, `commentsForJob`, `remakeChain` |
| Job actions | `createJob`, `editJob`, `claim`, `unclaim(jobId, claimerUid:)`, `complete`, `cancel`, `createRemake(jobId, defects:, jobName:, requestedBy:, dueDate:, priority:, comment:)` |
| Comments | `addComment(jobId, text)`, `editComment(id, text)`, `deleteComment(id)` |

`Permissions.can…(user, job, …)` returns a reason string, or `null` when
allowed. Use it to disable buttons and show the reason as a tooltip. Also
available: `Permissions.shortParts(job, stock)`, `TicketingUser.fromOrgData`.

UI building blocks:
- `TicketingPage(repository:, nameOf:, people:, onOpenJob:, onEditJob:, onAddJob:)`
- `showJobForm(context, repository:, nameOf:, people:, job:)`
- `PartThumbnail(url:)`
- `PageLogic` (labels, sorting, the Log sentences)

**Small API additions you'll probably want.** Add each one to the repository,
with a test:
- `watchJob(jobId)`: `store.watch('ticketing/jobs/$jobId')`, for a popup that
  stays live.
- `watchCommentsForJob(jobId)`: filter `watchComments`, or add a
  `queryEqual`-based watch to `TicketingStore` (it has `watch(path)` only
  today).

---

## 4. Part 1: Job popup

Opens from `TicketingPage.onOpenJob` (clicking a row or card). Today the page
shows a placeholder note when `onOpenJob` is null, so make the page open the
popup by default, the same way `_addJob` opens the form. Use one popup widget
that adapts to the job's status.

**From the mockups (`Ticketing #1` bottom, `#2` top):**

*In-progress job:*
- **Job name**
- **Claimed by:** a list of claimers (scholar names; the mockup shows "a
  scholar dropdown that can add multiple". See open question Q1).
- **Date claimed:** `claimedAt`, filled in automatically.
- **Parts needed:** a scrollable list. Each row: photo
  (`PartThumbnail(item.url)`) | part name | `#itemNumber` | quantity |
  `location`. Read the items with `stockFor(job)` or `watchInventory`.
- **Comments section:** list, add, edit (author only), delete (author or
  admin). Show the author name, time, and "(edited)" when `editedAt` is set.

*Requested job:*
- Name, requested by, date requested (`createdAt`), due date, priority,
  parts required (same rows), comments.

*Remake jobs also show:*
- the **Remake** label
- "Remake of JOB-…" (link: opens that job's popup)
- the **parts used** by the original (`usedParts`)
- the **defects**: count and reason per part

*Actions*, shown only when `Permissions` allows; otherwise hide them, or
disable them with the reason as a tooltip:

| Status | Actions |
| --- | --- |
| requested | **Claim** (if short, show `shortParts` text), **Edit** (`showJobForm` with `job`), **Cancel** (confirm) |
| inProgress | **Unclaim** (self; admin can pick a claimer, see `_unclaim` in the page), **Complete** (confirm), **Create remake** (part 2), **Edit**, **Cancel** (requester/admin; confirm, and say parts go back) |
| completed | **Create remake** |
| cancelled / remade | none; remade jobs show "Remade as JOB-…" with a link |

**Acceptance:**
- Every field above shows. Actions match `Permissions` for an admin, the
  requester, a claimer, a Quality member, and an outsider.
- The popup updates live while it's open: another user claiming or commenting
  shows up.
- On phones it's full screen with actions pinned at the bottom; elsewhere it's
  a dialog of about 620 px.
- Widget tests in `test/job_popup_test.dart` cover each status and role, the
  comment add/edit/delete flow, and short-stock claim messaging.

---

## 5. Part 2: Remake ("failure") form

Opened from the popup's **Create remake**. Mockup `Ticketing #4` top right,
"Failure popup": *Faulty parts* (add multiple) and *Reason for failure*.

- It starts with the job's name, requested by, due date and priority, all
  editable. Reuse `JobForm` widgets/styles where you can.
- **Faulty parts:** list the job's parts (from `job.lines`). The user picks
  which are defective, with a count (1 up to `line.held`) and an optional
  reason (max 500 characters) for each.
- **Comment:** optional first comment.
- On save: `createRemake(...)`.
  - If the returned job is `inProgress`, it was claimed by you and the
    replacements were pulled. Say so.
  - If it's `requested`, stock was short. Say which parts (use
    `Permissions.shortParts` against `stockFor(remake)`) and that it's
    waiting in Requested.
  - Close the popup and show the new remake.
- Validation: at least one defective part, and each count between 1 and what
  the job holds.

**Acceptance:** widget tests for both outcomes (claimed / waiting), the
validation messages, and that the original shows as Remade → Log "Failed".

---

## 6. Part 3: Log popup

Clicking a Log entry opens the job. Mockup `Ticketing #4` shows two log
popups:

| Popup | Fields |
| --- | --- |
| **Completed / any** | name\*, scholars (claimers), date requested, status\*, date completed (not required), parts used\*, comments |
| **Failed** (remade) | name, date failed, scholars, parts used, parts failed, reasons for failure |

- For a failed job, the "date failed", "parts failed" and "reasons" come from
  its remake ticket: follow `remadeAs` and read that job's `defects`, or use
  the `remade` history row's timestamp.
- **Simplest approach:** reuse the Part 1 popup in read-only mode for closed
  jobs, plus a "Failure" section when `status == remade`. Confirm with the
  owner if you want a separate layout.
- The Log's **All / Completed / Failed** chips already exist
  (`PageLogic.logEntries`).

---

## 7. Part 4: Integration into lsicompapp

lsicompapp lives at `../../lsicompapp`, a sibling of this repo's folder. Its
pages follow the pattern of `lib/team/main/cs/sha_keys.dart` (the owner wrote
that one).

1. `lsicompapp/pubspec.yaml`: add
   `lsi_ticketing: { path: ../Ticketing System/ticketing }` (or a git URL once
   this is pushed).
2. Add a page widget, e.g. `lib/team/main/quality/ticketing.dart`, that
   builds:
   - `TicketingUser.fromOrgData(currentUser.uid, userData['orgData'])`
     (null → "no access" message).
   - `RtdbTicketingStore(FirebaseDatabase.instanceFor(app: Firebase.app(), databaseURL: 'https://limbitless-solutions-team.firebaseio.com/'))`.
     In `DevAuthWrapper.isDev`, use `MemoryTicketingStore({...})` with some
     inventory instead.
   - `nameOf: (uid) => usersProfile[uid]?['displayName'] ?? 'Unknown'`.
   - `people`: active users from `usersProfile`. Check how lsicompapp decides
     "active"; `allUsersData` is only loaded for admins.
3. Register it:
   - a route in `lib/start_pages/LSIapp_home.dart` (next to `'/shaKeys'`),
   - an `AppScreens` value in `lib/styles/globals.dart`,
   - a nav tile in `lib/src/navigation/navigation.dart`. Ask the owner which
     menu group.
4. Wrap the page in `PopScope` like the SHA Keys page, so back goes to main.
5. Do **not** change the inventory page.

**Acceptance:** the page opens from the nav, works in DEV_MODE with no
Firebase, and `flutter analyze` and the app's tests still pass.

---

## 8. Part 5: Deployment prerequisites

These need someone with Firebase console access. Write them up; don't do them
yourself.

- **Merge `rules/ticketing.rules.json`** into the team database's existing
  rules; don't replace them.
  - Realtime Database rules **cascade**: a broader grant above `ticketing/`
    would override these, so check that.
  - Signed-in users also need write access to `inventory/{id}/stock` (the
    inventory page already needs it).
- **Confirm the arm parts exist as inventory items.** Nobody has checked the
  live data yet. If they don't, jobs have nothing to reserve.
- **Known risk to tell the inventory page's owner:**
  - Its edit form saves whole items from a stale copy, which can undo a
    reservation.
  - Its old "use" button (`inventory.dart` around line 1292) writes the
    pre-decrement value (`stock--` postfix).

---

## 9. Part 6: Trial run

This is from the original design doc. Run with Assembly, Finishing and Quality
scholars for an agreed period, and track:
- whether part requests go through tickets,
- whether stock matches a physical count afterwards,
- what's confusing.

Fix the top issues before a wider rollout.

---

## 10. Open questions (ask the owner)

- **Q1.** The mockup says "Claimed by is a scholar dropdown that can add
  multiple". Today only **admins** can add someone else as a claimer (rules
  and `Permissions`); members can only add themselves. Should claimers be able
  to add teammates? If yes, update `tool/rules_source.dart` (the `claimers`
  validate), `Permissions`, and add an `addClaimer` repository method with
  tests.
- **Q2.** Sort options: the page has due date, priority, time requested, time
  claimed and job name. Confirm these are right.
- **Q3.** The mockup's In-Progress "Status" column always reads "In
  progress". Should it show something more useful (e.g. overdue, or waiting
  on parts)?
- **Q4.** lsicompapp has no "Assembly" department value. It's allowed by name
  in the comment and remake rules. Which department name does the assembly
  team actually use?
- **Q5.** Which nav menu group the page belongs in, and what to name it.

---

## 11. How to work in this repo

- **Tests:** `flutter test` (Dart). Emulator rule tests: `cd rules_test && npm test`
  (needs Node and Java; first time `npm install`).
- **After changing the repository's writes:** run
  `dart run tool/export_rule_fixtures.dart`, then rerun the emulator tests.
  `test/rules_fixtures_test.dart` fails if you forget.
- **After changing rules:** edit `tool/rules_source.dart`, then
  `dart run tool/build_rules.dart`. `test/rules_test.dart` fails if the JSON
  is stale. Add emulator tests for anything a rule should allow *and* refuse.
- **Preview:** `cd preview && flutter build web` and serve `preview/build/web`,
  e.g. `python3 -m http.server 8078 --bind 127.0.0.1` from that folder. In the
  Claude desktop app's browser pane, launching a server through
  `.claude/launch.json` hung, while attaching to one started from a shell
  worked. `preview/lib/main.dart` has the sample data and a "Signed in as"
  switcher. Add sample data for whatever you build.
- **Code style:**
  - Short lowercase `//` comments explaining *why*, like the existing files.
  - Keep pure rules in plain Dart (no widgets, no Firebase) and unit-test
    them.
  - Show user-facing messages via `TicketingException.message`, written in
    plain words.
- **Gotchas found so far:**
  - Flutter 3.47 deprecates `package:flutter/material.dart`. lsicompapp still
    uses it everywhere, so keep it, with
    `// ignore: deprecated_member_use` and the comment used in the existing
    files.
  - `DropdownButtonFormField` with a `null` item value didn't open on web. Use
    `DropdownMenu` with string values (see `_priorityPicker`).
  - Widget tests use a wide test font. Give text in Rows `Flexible` or
    `Expanded`, and call `tester.ensureVisible(...)` before tapping things in
    scrollable dialogs.
  - Dates: `neededBy` is a calendar day stored as UTC midnight; format it
    without `.toLocal()`. Timestamps are UTC instants; show them with
    `.toLocal()`.
