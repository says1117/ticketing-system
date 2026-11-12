# lsi_ticketing

Data layer for the Ticketing page: **assembly jobs** for bionic arms that
reserve parts from lsicompapp's inventory. There are no screens yet. It's built
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
- **A claimer** can unclaim themselves and complete the job.
- **Create remake:** anyone who can comment on the job (below).
- **Comments:** admins, the requester and submitter, every claimer, and members of the
  Quality, Assembly and Production departments (`department` or
  `subDepartments`). Authors can edit their comments. Authors and admins can
  delete them.

Inactive users (`orgData.active != true`) can't read or write anything.
`otherDepartments` is ignored, because security rules can't search it.
lsicompapp has no Assembly department today; it's allowed by name so it works
once one exists.

## Layout

```
lib/lsi_ticketing.dart          exports for the app
lib/src/models/                 Job, JobLine, InventoryItem, HistoryEntry, Comment, enums
lib/src/rules/permissions.dart  who-can-do-what (mirrors the security rules)
lib/src/data/                   TicketingRepository + RTDB and in-memory stores
tool/rules_source.dart          source for the security rules
rules/ticketing.rules.json      generated security rules
tool/export_rule_fixtures.dart  records the repository's writes for the emulator tests
rules_test/                     security rule tests in the Firebase emulator
```

## Using it in lsicompapp (later)

```yaml
# lsicompapp/pubspec.yaml
lsi_ticketing:
  path: ../Ticketing System/ticketing
```

```dart
final store = RtdbTicketingStore(FirebaseDatabase.instanceFor(
  app: Firebase.app(),
  databaseURL: 'https://limbitless-solutions-team.firebaseio.com/',
));
final user = TicketingUser.fromOrgData(currentUser.uid, userData['orgData'])!; // null = inactive
final repo = TicketingRepository(store: store, user: user);
```

In DEV_MODE, pass a `MemoryTicketingStore({'inventory': ...})` instead.

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
