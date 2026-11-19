# Getting started on the Ticketing page

For someone picking up one of the remaining parts. It covers setup, running
and testing, where things are, the house rules, and a brief for each part
that's open for someone else to take.

Read these too:

- **`README.md`**: how the data model works (jobs, stock, remakes, who can
  do what).
- **`HANDOFF.md`**: the full plan, the decisions already made with the
  project owner, and the open questions. Don't reverse a decision in its
  section 2 or 10 without asking the owner.

## 1. Setup

```bash
git clone https://github.com/says1117/ticketing-system.git ticketing
cd ticketing
flutter pub get
cd preview && flutter pub get && cd ..
```

- **Flutter:** use the stable channel. It's developed on Flutter 3.50.
- **Firebase emulator tests only:** Node and Java, then `cd rules_test && npm install`.
- **Mockups:** the owner's hand-drawn mockups (`Ticketing #1–4.jpeg`) aren't
  in the repo. Ask the owner for them if your part has a screen.
- **lsicompapp:** expected as a sibling folder. lsicompapp's `pubspec.yaml`
  points here with `path: ../Ticketing System/ticketing`, so keep that
  layout or change the path.

## 2. Run it

The package isn't an app by itself. `preview/` is a small web app that shows
the page with lsicompapp's dark theme and sample data in memory. It never
touches Firebase.

```bash
cd preview
flutter run -d chrome
```

- In the terminal: `r` hot-reloads, `R` restarts (and rebuilds the sample
  data), `q` quits.
- **Switching users:** the "Signed in as" menu, top right, switches between
  an admin and several scholars, so you can see what each role is allowed
  to do.
- **Sample data:** lives in `sampleStore()` in `preview/lib/main.dart`.

Or build it once and serve it:

```bash
cd preview && flutter build web
cd build/web && python3 -m http.server 8078 --bind 127.0.0.1
```

Then open http://127.0.0.1:8078.

## 3. Test it

Run these from the `ticketing` folder. All of them must pass before you
hand anything back.

| Command | What it checks |
| --- | --- |
| `flutter test` | All Dart tests: rules, the repository, every screen |
| `flutter analyze` | Must say "No issues found!" |
| `cd rules_test && npm test` | The Firebase security rules, in the emulator |

Two generated files have tests that fail if you forget to regenerate them:

- **Changed a write in `ticketing_repository.dart`?** Run
  `dart run tool/export_rule_fixtures.dart`, then the emulator tests.
- **Changed `tool/rules_source.dart`?** Run `dart run tool/build_rules.dart`.

## 4. Where things are

```
lib/
  lsi_ticketing.dart        what the package exports (nothing runs here)
  src/models/               Job, JobLine, Defect, Comment, InventoryItem, enums
  src/data/
    ticketing_store.dart        the storage interface
    memory_ticketing_store.dart in memory: tests, preview, dev mode
    rtdb_ticketing_store.dart   Firebase Realtime Database
    ticketing_repository.dart   every read and write; enforces the rules
  src/rules/permissions.dart    who may do what (mirrors the security rules)
  src/ui/
    ticketing_page.dart     the page: tabs, tables, search, + button
    job_form.dart           Add / Edit job
    job_popup.dart          what opens when you click a job
    remake_form.dart        report faulty parts, create a remake
    *_logic.dart            plain-Dart rules behind each screen
tool/                       generates the security rules and test fixtures
rules/                      the generated security rules (don't hand-edit)
rules_test/                 emulator tests for those rules
preview/                    the sample web app
```

How a change flows: a screen calls a `TicketingRepository` method. The
repository checks `Permissions`, builds the new job and a history row, and
saves both in one `store.update(...)`. Every screen watches the store, so it
redraws on its own. Screens never write to the store directly.

## 5. House rules

- **Theme:** take every color from `Theme.of(context)`, with
  `secondaryHeaderColor` as the accent, like lsicompapp. No hard-coded
  theme.
- **Inventory:** ticketing only reads lsicompapp's inventory and changes
  `stock`. Never change the inventory page or any other inventory field.
- **Logic out of widgets:** decisions go in a `*_logic.dart` file or the
  repository, with unit tests. Widgets only display.
- **Messages:** errors reach users as `TicketingException(message)`, in
  plain words.
- **Comments:** short, lowercase `//` comments explaining *why*, like the
  existing files.
- **Formatting:** this package formats at 120 columns
  (`dart format -l 120 <file>`), except `job_popup.dart` and its test,
  which use the default 80. Match the file you're in.
- **Material:** keep `package:flutter/material.dart` with the existing
  `// ignore: deprecated_member_use` comment. lsicompapp still uses it.
- **Tests:** every change comes with tests, including the "should be
  refused" cases.
- **Committing:** the owner reviews all code, so ask them before you commit
  and how they want your changes delivered. A branch with a pull request
  is the easiest to review.

## 6. Parts you can pick up

The screens (Parts 1–3) are built, and A and B below are done (see README.md, "Using it in lsicompapp"). Each part below is independent of them
and of each other, apart from B using A's loader in dev mode.

### A. Fake JSON data for development (done)

- **Decision:** the owner's supervisor said development shouldn't connect to
  Firebase. Instead, load a fake JSON file into `MemoryTicketingStore`.
- **Build:**
  - `dev_data.json`, in the same shape as the database:
    - `inventory/{id}` items with `name`, `itemNumber`, `stock`,
      `threshold`, `location` and `url`.
    - Optionally, a few jobs under `ticketing/`.
    - Use realistic arm parts; the preview's inventory is a good starting
      list.
  - A small loader that reads the JSON and returns a `MemoryTicketingStore`
    (its constructor takes the decoded `Map`).
- **Know:** writes stay in memory and reset on reload. That's intended.
- **Done when:** a test loads the file and `listInventory()` returns its
  items, and a claim reduces their stock.

### B. Add the page to lsicompapp (Part 4) (done)

Full steps are in `HANDOFF.md` section 7. In short:

- Add the package to lsicompapp's `pubspec.yaml`.
- Write a page widget that builds:
  - the `TicketingUser` (null means "no access"),
  - the store: Firebase normally, or the loader from part A in dev mode,
  - `nameOf` and the list of active scholars.
- Register a route and an `AppScreens` value.
- Add a nav tile named **Ticketing** in the **Engine** group.
- Wrap the page in `PopScope` like the SHA Keys page.

Check how lsicompapp decides who is "active": `allUsersData` only loads for
admins.

- **Done when:** the page opens from the nav, works in dev mode with no
  Firebase, and lsicompapp's `flutter analyze` and tests still pass.

### C. Deployment checklist (Part 5). Needs Firebase console access.

Write it up and walk through it with the database owner; don't change live
rules alone.

- **Merge the rules:** merge `rules/ticketing.rules.json` into the team
  database's existing rules. Don't replace them. Realtime Database rules
  cascade, so a broader grant above `ticketing/` would override these.
- **Stock writes:** confirm signed-in users can write `inventory/{id}/stock`.
- **Arm parts:** confirm the arm parts exist as inventory items. Nobody has
  checked the live data.

### D. Inventory page issues, for its owner

These aren't ours to fix (see "Inventory" in the house rules), but they need passing on:

- **The "use" button** writes the old value: `stock--` is applied after the
  value is read, around line 1292 of `inventory.dart`.
- **The edit form** saves whole items from a stale copy, which can undo a
  reservation.

## 7. When you're stuck

- **Why a rule is the way it is:** `HANDOFF.md` sections 2 and 10, then the
  comment at the top of the relevant file.
- **What a change does to the data:** the repository tests in
  `test/repository_test.dart` read like a spec.
- **Anything about scope or wording:** ask the project owner.
