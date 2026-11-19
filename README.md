# lsi_ticketing

Data layer for the Ticketing page: **assembly jobs** for bionic arms that
reserve parts from lsicompapp's inventory. It includes the main page, job form, and live job popup. It's built
as its own package so it can be dropped into lsicompapp later.

## Where the data lives

Everything is in the Realtime Database **`team` instance**
(`limbitless-solutions-team.firebaseio.com`):

| Path | Owner | Holds |
| --- | --- | --- |
| `ticketing/jobs/{JOB-0042}` | ticketing | Jobs, keyed by their readable id |
| `ticketing/history/{pushId}` | ticketing | Change log, append only |
| `ticketing/comments/{pushId}` | ticketing | Comments on jobs |
| `ticketing/counters/job` | ticketing | Last job number used |
| `inventory/{itemId}` | **inventory page** | Parts. Ticketing reads them and only ever changes `stock` |

Ticketing never touches any other inventory field. Restocking, thresholds,
photos and everything else stay with the inventory page.

## A job

The Add Job form has these fields (* = required):

| Field | Saved as |
| --- | --- |
| Name * | `jobName` |
| Requested by * | `requestedBy`: pre-filled with the signed-in person; any active scholar can be picked. The signed-in person is saved as `submittedBy`. |
| Due date * | `neededBy` (a calendar day) |
| Priority | `priority`: `low`, `medium` or `high`, optional |
| Parts required * | `lines`: one per inventory item, with a `quantity` needed, plus `held` (good parts the job has taken) and `scrapped` (defective) |
| Comments | saved as the job's **first comment**, in the same save as the job |

After that a job also has:

- **Claimers:** one or more people, each with the time they claimed.
- **Status:** `requested` (nobody has it), `inProgress` (claimed), `completed`,
  `cancelled`, or `remade` (replaced by a remake ticket). Completed, cancelled
  and remade jobs belong on the Log tab.

## Defects and remakes

A defect always means a new ticket:

1. On an in-progress or completed job, someone chooses **Create remake**. The
   form starts with the job's name, requester, due date and priority.
2. They select the defective parts, each with a number of defects and an
   optional reason, and can add a first comment.
3. Saving creates a **remake ticket**, labelled Remake, which records:
   - `remakeOf`: the original job
   - `usedParts`: the full parts list of the original
   - `defects`: count and reason per part
   - `lines`: the replacement parts to order

   The person who created it is added as its only claimer (the original's
   claimers aren't carried over), which pulls the replacements from inventory.
   If a replacement is short, the remake waits unclaimed in Requested instead.
4. In the same save, the original job closes as **Remade** (`remadeAs` points at
   the remake). Its defective parts move from `held` to `scrapped` and are never
   returned to stock. Its good parts stay with the arm.

A remake can itself be remade. `remakeChain(jobId)` follows the chain.

## Stock

| What happens | Inventory `stock` | History |
| --- | --- | --- |
| **First claim** (blocked if any part is short) | − every part's quantity | `reserved` |
| Someone else joins | no change | `claimed` |
| **Last claimer leaves**, or the job is cancelled | + everything the job holds | `returned` |
| Complete | no change (taken at claim) | `completed` |
| **Create remake** | no change: defective parts are scrapped, not returned | `scrapped`, `remade` |
| Remake claimed (by its creator, or later if stock was short) | − the replacement parts | `reserved` |

For each part line, `stock + held + scrapped` never changes. The security rule
on every job line checks this, so a job save that moves stock by the wrong
amount, or would push stock below zero, is refused. Stock is written as exact
values, not increments: if the inventory page changed the stock since it was
read, the save is refused and the repository re-reads and retries.

## Who can do what

Worked out from `users/{uid}/orgData` (what root_page.dart already loads):

- **Admin:** `orgData.status` is `OrgStatus.admin`. Can do everything, including
  unclaiming anyone.
- **Any active member** can request a job and claim any open job.
- **The requester** (the person it's for, or whoever submitted it for them) can
  edit their open job (name, requester, due date and priority any time; the
  parts list only before a claim) or cancel it.
- **A claimer** can unclaim themselves, complete the job, and add other active
  scholars to it ("Add scholar" in the popup). Adding someone takes no stock;
  the added scholar can unclaim themselves like any claimer.
- **Create remake:** anyone who can comment on the job (below).
- **Comments:** admins, the requester and submitter, every claimer, and members of the
  Quality, Manufacturing and Production departments (`department` or
  `subDepartments`). Authors can edit their comments. Authors and admins can
  delete them.

Inactive users (`orgData.active != true`) can't read or write anything.
`otherDepartments` is ignored, because security rules can't search it.
The assembly team is Manufacturing; lsicompapp has no Assembly department.

## The main page

`TicketingPage` (`lib/src/ui/ticketing_page.dart`) follows the mockups:

- **Top:** a search bar, then the **In-Progress | Requested | Log** tabs with a
  Sort by dropdown on the right.
- **In-Progress:** Job Name | Status | Time Requested | Time Claimed |
  Requested By | Edit | Unclaim.
  Status reads **Overdue** (in red) once the due date has passed.
- **Requested:** Job Name | Requested By | Priority | Date Requested | Claim.
- **Log:** an activity feed with All / Completed / Failed filters (Failed means
  remade).
- **The + button** (bottom left) requests a job.

Below 900 px wide the lists switch from tables to cards with 44 px buttons.
The page reads `Theme.of(context)` only, so in lsicompapp it follows the user's
theme. Pass `people` (uid → name of active scholars) for the form's "Requested
by" picker.

### Add Job form

The **+** button opens `showJobForm` (`lib/src/ui/job_form.dart`), and the
**Edit** button opens the same form pre-filled:

- **Name \*** and **Requested by \*** (a searchable scholar picker, starting
  as the signed-in person).
- **Due date \*** (MM/DD/YYYY with a calendar) and **Priority** (None, Low,
  Medium or High).
- **Parts required \*:** a box with + that opens a searchable inventory picker
  (name, part #, location, stock, photo). Each part gets − / + for quantity,
  shows how many are on hand, and warns when there aren't enough to claim yet.
- **Comments** become the job's first comment (new jobs only).

Required fields are marked with a red *, and each one says what's missing if
you submit without it. Once a job is claimed, the parts list is locked when
editing. On phones the form is full screen with Submit pinned to the bottom.

Clicking a job opens `showJobPopup` by default; `onOpenJob` can override it.
The popup watches the job, comments and inventory, shows part photos and
locations, and supports claim, unclaim, edit, complete, cancel and comment
add/edit/delete using the existing repository permissions. Below 900 px it is
full screen with job actions pinned at the bottom; wider screens use a 620 px
dialog. Remake links open the related job and remake details show used parts
and defects.

**Create remake** opens the remake form (`showRemakeForm`,
`lib/src/ui/remake_form.dart`); `onCreateRemake` replaces it. The form starts
with the job's name, requester, due date and priority (all editable), lists the
job's parts to tick as faulty with a count (1 up to what the job holds) and an
optional reason, and takes an optional comment. Saving calls `createRemake`,
then closes the failed job's popup and opens the remake's with the result:
claimed by you (replacements taken from inventory), or waiting in Requested
with the short parts named. The form's rules are plain Dart in
`lib/src/ui/remake_logic.dart`; the requester, due date and priority fields are
shared with the job form through `lib/src/ui/form_fields.dart`.

Closed jobs open the same popup, read-only (clicked from a table or from the
Log). Headings follow the status ("Scholars" instead of "Claimed by", "Parts
used"), and the popup shows when the job closed: Date completed, Date
cancelled, or Date failed. A failed job also has a **Failure** section: the
number of parts that failed and, per part, the count and reason. Those come
from its remake ticket, which the popup watches live through `remadeAs`.
The rules are plain Dart in `lib/src/ui/closed_job_logic.dart`
(`ClosedJobLogic`, `FailureDetails`). Only actions the permissions allow
appear, which on a closed job is just Create remake on a completed one.

The search, sorting and Log sentences are plain functions in
`lib/src/ui/page_logic.dart`.

### Preview

`preview/` is a small web app that shows the page with lsicompapp's dark theme
and sample data in memory, so it never touches Firebase. Use the "Signed in as"
menu to switch between an admin and scholars.

```
cd preview
flutter run -d chrome
```

## Layout

```
lib/lsi_ticketing.dart          exports for the app
lib/src/models/                 Job, JobLine, InventoryItem, HistoryEntry, Comment, enums
lib/src/rules/permissions.dart  who-can-do-what (mirrors the security rules)
lib/src/data/                   TicketingRepository + RTDB and in-memory stores
lib/src/ui/                     the main page, the Add Job form, and search/sort/log logic
preview/                        web app showing the page with sample data
tool/rules_source.dart          source for the security rules
rules/ticketing.rules.json      generated security rules
tool/export_rule_fixtures.dart  records the repository's writes for the emulator tests
rules_test/                     security rule tests in the Firebase emulator
```

## Using it in lsicompapp

lsicompapp's `ticketing` branch shows this page under **Engine > Ticketing**.
It gets the package from GitHub:

```yaml
# lsicompapp/pubspec.yaml
lsi_ticketing:
  # path: ../Ticketing System/ticketing
  git:
    url: https://github.com/says1117/ticketing-system.git
```

The lock file pins one commit. After pushing changes here, run
`flutter pub upgrade lsi_ticketing` in lsicompapp. To try unpushed changes,
use the `path:` line instead.

The lsicompapp side is in `lib/team/main/engineering/`:

| File | What it does |
| --- | --- |
| `ticketing.dart` | `TicketingScreen` (route `/ticketing`): reads the app's globals and opens the store: Firebase's `team` database, or in DEV_MODE the sample data below |
| `ticketing_host.dart` | `TicketingHost`: builds the `TicketingUser` (inactive means a "no access" message), opens the store once, and shows `TicketingPage` |
| `ticketing_setup.dart` | Who appears in the pickers (active scholars for admins, who have `allUsersData`; everyone in `usersProfile` otherwise) and `nameOf` |
| `ticketing_dev_data.dart` | Reads `assets/json/ticketing_dev_data.json`, the DEV_MODE sample inventory and scholars, with clear errors for a malformed file |

In DEV_MODE the page runs on a `MemoryTicketingStore` seeded from that JSON
file. It's loaded once per app session, so jobs survive leaving the page but
reset on reload. The nav tile shows for admins and the Manufacturing,
Production, Finishing and Quality departments (plus Computer Science while
testing, marked `// TESTING`).

## Security rules

`rules/ticketing.rules.json` covers only the `ticketing` branch. Merge it into
the team database's existing rules file; don't replace the file with it.

- **Rules cascade.** If any rule above `ticketing/` already grants write access,
  these rules can't take it back. Check the team database's current rules before
  deploying.
- **Inventory writes still need permission.** A job's save also writes
  `inventory/{id}/stock`, so signed-in users need write access there. The
  inventory page needs the same access today.
- **Known gaps:** these rules can't stop a save from changing the stock of an
  item that isn't on the job, removing a part line from a claimed job, or one
  member removing another from the claimers. The app never does any of these,
  and every save is logged in history under the person who made it.

To change a rule, edit `tool/rules_source.dart`, then run:

```
dart run tool/build_rules.dart
```

## Tests

```
flutter test
```

### Security rules in the Firebase emulator

`rules_test/` runs `rules/ticketing.rules.json` in the Realtime Database
emulator. It needs Node and Java, and it uses a demo project, so nothing
touches the real database.

```
cd rules_test
npm install      # first time only
npm test
```

- **Allowed writes:** `fixtures/writes.json` holds a starting inventory and
  every write the Dart repository makes across all the job flows (38 writes:
  submit with a first comment, submit on someone's behalf, edit, remakes from in-progress and completed jobs, claim, join, restock, unclaim, complete, cancel, admin actions and comments). Each
  write is replayed as the user who made it, and every one must be allowed.
- **Refused writes:** the other tests try writes the rules must refuse, such as
  taking parts without lowering stock, lowering stock by the wrong amount,
  pushing stock below zero, saving on a stale count, leaving without giving parts
  back, completing with parts missing, skipping history, or commenting from
  outside the allowed teams.

The emulator gets a stand-in rule letting signed-in users write `inventory/`,
because the team database's real inventory rules aren't known here.

After changing the repository, re-record the writes with
`dart run tool/export_rule_fixtures.dart`.
`test/rules_fixtures_test.dart` fails if you forget.
# ticketing-system
