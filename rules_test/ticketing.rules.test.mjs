// runs rules/ticketing.rules.json in the Realtime Database emulator.
//
// part 1 replays fixtures/writes.json: every write the Dart repository makes in
// a full set of job flows, each as the user who made it. all must be allowed.
// part 2 tries writes the rules must refuse.
//
// the team database's real rules for inventory/ aren't ours and aren't known
// here, so the emulator gets a stand-in that lets any signed-in user write
// inventory (the inventory page writes it from the app today). what's tested
// is that ticketing's own rules refuse a job save whose stock change doesn't
// match the job.
//
// run from rules_test/:  npm test   (starts and stops the emulator itself)

import { test, describe, before, beforeEach, after } from 'node:test';
import { readFileSync } from 'node:fs';
import {
  initializeTestEnvironment,
  assertSucceeds,
  assertFails,
} from '@firebase/rules-unit-testing';

const ticketingRules = JSON.parse(readFileSync(new URL('../rules/ticketing.rules.json', import.meta.url), 'utf8'));
const rules = JSON.stringify({
  rules: {
    ...ticketingRules.rules,
    inventory: { '.read': 'auth != null', '.write': 'auth != null' }, // stand-in, see above
  },
});
const fixtures = JSON.parse(readFileSync(new URL('./fixtures/writes.json', import.meta.url), 'utf8'));
const { writes } = fixtures;

// users/{uid}/orgData as root_page.dart stores it
const USERS = {
  adm: { active: true, status: 'OrgStatus.admin', department: 'OPAL' },
  req: { active: true, status: 'OrgStatus.assistant', department: 'Finishing' },
  man: { active: true, status: 'OrgStatus.assistant', department: 'Manufacturing' },
  man2: { active: true, status: 'OrgStatus.associate', department: 'Manufacturing' },
  qa: { active: true, status: 'OrgStatus.assistant', department: 'Quality' },
  prod: { active: true, status: 'OrgStatus.assistant', department: 'R&D', subDepartments: 'Production' },
  asm: { active: true, status: 'OrgStatus.assistant', department: 'Assembly' },
  mfg: { active: true, status: 'OrgStatus.assistant', department: 'Finishing', subDepartments: 'Manufacturing' },
  lead: { active: true, status: 'OrgStatus.affiliatedFaculty', department: 'Staff' },
  other: { active: true, status: 'OrgStatus.assistant', department: 'Finishing', otherDepartments: { '-a': 'Quality' } },
  gone: { active: false, status: 'OrgStatus.assistant', department: 'Manufacturing' },
};

const FT = '-invFingertip';
const PALM = '-invPalm';
const BASE = '-invBase';

let env;
const db = (uid) => (uid ? env.authenticatedContext(uid) : env.unauthenticatedContext()).database();
const write = (uid, update) => db(uid).ref().update(update);

function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}

async function seed() {
  await env.withSecurityRulesDisabled(async (ctx) => {
    const users = {};
    for (const [uid, orgData] of Object.entries(USERS)) users[uid] = { orgData };
    await ctx.database().ref().set({ users, inventory: fixtures.inventory });
  });
}

// replays the fixture writes up to (not including) the one with this label
async function replay(untilLabel) {
  for (const w of writes) {
    if (untilLabel && w.label === untilLabel) return;
    await write(w.user, w.update);
  }
  if (untilLabel) throw new Error(`no fixture write labelled "${untilLabel}"`);
}

async function readAdmin(path) {
  let value;
  await env.withSecurityRulesDisabled(async (ctx) => {
    value = (await ctx.database().ref(path).get()).val();
  });
  return value;
}

async function setAdmin(path, value) {
  await env.withSecurityRulesDisabled(async (ctx) => ctx.database().ref(path).set(value));
}

let keyN = 0;
const newKey = () => `-test${String(++keyN).padStart(6, '0')}`;
const now = () => new Date().toISOString();
const stockOf = async (id) => readAdmin(`inventory/${id}/stock`);

// the next version of a job the way the repository would write it: change()
// edits a copy, stock sets inventory stock values, history overrides the row
async function jobWrite(uid, jobId, change, { stock = {}, history = {}, rev, noHistory = false } = {}) {
  const cur = await readAdmin(`ticketing/jobs/${jobId}`);
  const next = structuredClone(cur);
  change(next);
  const hid = newKey();
  next.rev = rev ?? cur.rev + 1;
  next.updatedAt = now();
  next.lastHistoryId = hid;
  const update = { [`ticketing/jobs/${jobId}`]: next };
  if (!noHistory) update[`ticketing/history/${hid}`] = { jobId, type: 'edited', user: uid, timestamp: now(), ...history };
  for (const [id, value] of Object.entries(stock)) update[`inventory/${id}/stock`] = value;
  return update;
}

// a brand-new job as the repository creates it
function newJob(uid, { id = 'JOB-0001', lines = { [FT]: { quantity: 2, held: 0, scrapped: 0 } }, extra = {} } = {}) {
  const hid = newKey();
  return {
    'ticketing/counters/job': Number(id.slice(4)),
    [`ticketing/jobs/${id}`]: {
      jobId: id, jobName: 'Test arm', requestedBy: uid, submittedBy: uid, neededBy: '2026-12-01', lines, status: 'requested',
      createdAt: now(), updatedAt: now(), rev: 1, lastHistoryId: hid, ...extra,
    },
    [`ticketing/history/${hid}`]: { jobId: id, type: 'created', user: uid, timestamp: now() },
  };
}

// a claim the way the repository does it, with overridable stock values
async function claimWrite(uid, jobId, { stock } = {}) {
  const cur = await readAdmin(`ticketing/jobs/${jobId}`);
  const s = {};
  for (const [id, line] of Object.entries(cur.lines)) s[id] = (await stockOf(id)) - line.quantity;
  return jobWrite(uid, jobId, (j) => {
    j.status = 'inProgress';
    j.claimedAt = now();
    j.claimers = { ...(j.claimers ?? {}), [uid]: now() };
    for (const line of Object.values(j.lines)) line.held = line.quantity;
  }, { stock: stock ?? s, history: { type: 'claimed' } });
}

before(async () => {
  env = await initializeTestEnvironment({ projectId: 'demo-lsi-ticketing', database: { rules } });
});
after(async () => env?.cleanup());
beforeEach(async () => {
  await env.clearDatabase();
  await seed();
});

describe('every write the app makes is allowed', () => {
  test('replays all repository writes in order', async () => {
    for (const w of writes) {
      try {
        await assertSucceeds(write(w.user, w.update));
      } catch (e) {
        throw new Error(`refused: "${w.label}" as ${w.user}\n${JSON.stringify(w.update, null, 2)}\n${e.message}`);
      }
    }
    const stock = [await stockOf(FT), await stockOf(PALM), await stockOf(BASE)];
    assert(JSON.stringify(stock) === '[6,2,2]', `final stock should be [6,2,2], got ${JSON.stringify(stock)}`);
  });
});

describe('reading', () => {
  test('active users can read jobs; signed-out and inactive users cannot', async () => {
    await replay();
    await assertSucceeds(db('req').ref('ticketing/jobs').get());
    await assertFails(db(null).ref('ticketing/jobs').get());
    await assertFails(db('gone').ref('ticketing/jobs').get());
  });
});

describe('creating jobs', () => {
  test('a correct job is allowed (control)', async () => {
    await assertSucceeds(write('req', newJob('req')));
  });
  test('for another active scholar, with priority and a first comment, is allowed (control)', async () => {
    const job = newJob('req', { extra: { requestedBy: 'man', priority: 'high' } });
    job[`ticketing/comments/${newKey()}`] = { jobId: 'JOB-0001', author: 'req', text: 'Blue please', timestamp: now() };
    await assertSucceeds(write('req', job));
  });
  test('not for an inactive or unknown person, without a due date, or with a made-up priority', async () => {
    await assertFails(write('req', newJob('req', { extra: { requestedBy: 'gone' } })));
    await assertFails(write('req', newJob('req', { extra: { requestedBy: 'nobody' } })));
    await assertFails(write('req', newJob('req', { extra: { neededBy: null } })));
    await assertFails(write('req', newJob('req', { extra: { priority: 'urgent' } })));
  });
  test('not submitted in someone else\'s name, already claimed, or already holding parts', async () => {
    const forged = newJob('req');
    forged['ticketing/jobs/JOB-0001'].submittedBy = 'man';
    await assertFails(write('req', forged));
    await assertFails(write('req', newJob('req', { extra: { status: 'inProgress', claimers: { req: now() } } })));
    await assertFails(write('req', newJob('req', { lines: { [FT]: { quantity: 2, held: 2, scrapped: 0 } } })));
  });
  test('parts must be in inventory, with a whole quantity above zero', async () => {
    await assertFails(write('req', newJob('req', { lines: { '-nope': { quantity: 1, held: 0, scrapped: 0 } } })));
    await assertFails(write('req', newJob('req', { lines: { [FT]: { quantity: 0, held: 0, scrapped: 0 } } })));
    await assertFails(write('req', newJob('req', { lines: { [FT]: { quantity: 1.5, held: 0, scrapped: 0 } } })));
  });
  test('a name, a proper id, and no unknown fields', async () => {
    await assertFails(write('req', newJob('req', { extra: { jobName: '' } })));
    await assertFails(write('req', newJob('req', { extra: { color: 'blue' } })));
    const bad = newJob('req');
    bad['ticketing/jobs/ABC'] = { ...bad['ticketing/jobs/JOB-0001'], jobId: 'ABC' };
    delete bad['ticketing/jobs/JOB-0001'];
    await assertFails(write('req', bad));
  });
  test('the job counter only goes up by one', async () => {
    await assertFails(write('req', { 'ticketing/counters/job': 5 }));
  });
  test('inactive users cannot create jobs', async () => {
    await assertFails(write('gone', newJob('gone')));
  });
});

describe('claiming takes stock', () => {
  // JOB-0001 requested: 5 fingertips, 1 palm, 2 bases; stock 12 / 3 / 4
  beforeEach(async () => replay('first claim takes the parts from inventory'));

  test('a claim that takes exactly the parts is allowed (control)', async () => {
    await assertSucceeds(write('lead', await claimWrite('lead', 'JOB-0001')));
    assert((await stockOf(FT)) === 7, 'fingertip 12 - 5');
  });
  test('holding parts without taking them from inventory is refused', async () => {
    await assertFails(write('man', await claimWrite('man', 'JOB-0001', { stock: {} })));
  });
  test('taking more from inventory than the job holds is refused', async () => {
    await assertFails(write('man', await claimWrite('man', 'JOB-0001', { stock: { [FT]: 0, [PALM]: 2, [BASE]: 2 } })));
  });
  test('a claim that would push stock below zero is refused', async () => {
    await setAdmin(`inventory/${PALM}/stock`, 0);
    await assertFails(write('man', await claimWrite('man', 'JOB-0001')));
  });
  test('a claim based on a stale stock count is refused', async () => {
    const update = await claimWrite('man', 'JOB-0001');
    await setAdmin(`inventory/${FT}/stock`, 20); // the inventory page receives stock meanwhile
    await assertFails(write('man', update));
  });
  test('in progress needs a claimer, and the first claim is in your own name', async () => {
    await assertFails(write('man', await jobWrite('man', 'JOB-0001', (j) => { j.status = 'inProgress'; })));
    const forOther = await claimWrite('man', 'JOB-0001');
    forOther['ticketing/jobs/JOB-0001'].claimers = { man2: now() };
    await assertFails(write('man', forOther));
  });
  test('a stale rev is refused', async () => {
    const cur = await readAdmin('ticketing/jobs/JOB-0001');
    const update = await claimWrite('man', 'JOB-0001');
    update['ticketing/jobs/JOB-0001'].rev = cur.rev;
    await assertFails(write('man', update));
  });
});

describe('working, leaving and finishing', () => {
  // JOB-0001 in progress, claimed by man and man2; holds 5 / 1 / 2
  beforeEach(async () => replay('requester edits the name while in progress'));

  test('a claimer adds an active scholar without touching stock', async () => {
    await assertSucceeds(write('man', await jobWrite('man', 'JOB-0001', (j) => { j.claimers.qa = now(); }, { history: { type: 'claimed', to: 'qa' } })));
    await assertSucceeds(write('adm', await jobWrite('adm', 'JOB-0001', (j) => { j.claimers.lead = now(); }, { history: { type: 'claimed', to: 'lead' } })));
  });
  test('only claimers or an admin add others, and never an inactive or unknown user', async () => {
    const add = (uid, who) => jobWrite(uid, 'JOB-0001', (j) => { j.claimers[who] = now(); }, { history: { type: 'claimed', to: who } });
    await assertFails(write('qa', await add('qa', 'lead')));
    await assertFails(write('req', await add('req', 'qa')));
    await assertFails(write('man', await add('man', 'gone')));
    await assertFails(write('man', await add('man', 'nobody')));
    await assertFails(write('adm', await add('adm', 'gone')));
  });
  test('adding someone cannot also take stock', async () => {
    await assertFails(write('man', await jobWrite('man', 'JOB-0001', (j) => { j.claimers.qa = now(); },
      { stock: { [FT]: (await stockOf(FT)) - 1 }, history: { type: 'claimed', to: 'qa' } })));
  });
  test('the last claimer cannot leave without giving the parts back', async () => {
    await write('man2', await jobWrite('man2', 'JOB-0001', (j) => { delete j.claimers.man2; }, { history: { type: 'unclaimed' } }));
    await assertFails(write('man', await jobWrite('man', 'JOB-0001', (j) => {
      delete j.claimers; delete j.claimedAt; j.status = 'requested';
      for (const l of Object.values(j.lines)) l.held = 0;
    }, { history: { type: 'unclaimed' } })));
  });
  test('parts cannot be scrapped except by closing the job as remade', async () => {
    await assertFails(write('man', await jobWrite('man', 'JOB-0001', (j) => {
      j.lines[FT].held -= 1; j.lines[FT].scrapped += 1;
    }, { history: { type: 'scrapped' } })));
  });
  test('a job cannot complete holding fewer parts than it needs, or without a completion time', async () => {
    await setAdmin(`ticketing/jobs/JOB-0001/lines/${FT}/held`, 4);
    await setAdmin(`inventory/${FT}/stock`, (await stockOf(FT)) + 1);
    await assertFails(write('man', await jobWrite('man', 'JOB-0001', (j) => { j.status = 'completed'; j.completedAt = now(); })));
    await setAdmin(`ticketing/jobs/JOB-0001/lines/${FT}/held`, 5);
    await setAdmin(`inventory/${FT}/stock`, (await stockOf(FT)) - 1);
    await assertFails(write('man', await jobWrite('man', 'JOB-0001', (j) => { j.status = 'completed'; })));
  });
  test('only claimers or an admin complete; a claimer cannot cancel', async () => {
    const complete = (uid) => jobWrite(uid, 'JOB-0001', (j) => { j.status = 'completed'; j.completedAt = now(); }, { history: { type: 'completed' } });
    await assertFails(write('qa', await complete('qa')));
    const giveBack = { [FT]: (await stockOf(FT)) + 5, [PALM]: (await stockOf(PALM)) + 1, [BASE]: (await stockOf(BASE)) + 2 };
    await assertFails(write('man', await jobWrite('man', 'JOB-0001', (j) => {
      j.status = 'cancelled'; for (const l of Object.values(j.lines)) l.held = 0;
    }, { stock: giveBack })));
    await assertSucceeds(write('man', await complete('man')));
  });
  test('the requester can rename but not change quantities or add parts once claimed', async () => {
    await assertSucceeds(write('req', await jobWrite('req', 'JOB-0001', (j) => { j.jobName = 'Renamed'; })));
    await assertFails(write('req', await jobWrite('req', 'JOB-0001', (j) => { j.lines[FT].quantity = 9; })));
    await assertFails(write('req', await jobWrite('req', 'JOB-0001', (j) => { j.lines[BASE + 'x'] = { quantity: 1, held: 0, scrapped: 0 }; })));
  });
  test('the requester can hand the job to another active scholar, not an inactive one', async () => {
    await assertFails(write('req', await jobWrite('req', 'JOB-0001', (j) => { j.requestedBy = 'gone'; })));
    await assertSucceeds(write('req', await jobWrite('req', 'JOB-0001', (j) => { j.requestedBy = 'qa'; })));
  });
  test('nobody can change who submitted it', async () => {
    await assertFails(write('adm', await jobWrite('adm', 'JOB-0001', (j) => { j.submittedBy = 'adm'; })));
  });
  test('someone not on the job cannot edit it', async () => {
    await assertFails(write('qa', await jobWrite('qa', 'JOB-0001', (j) => { j.jobName = 'x'; })));
  });
  test('a claimer cannot change the job details', async () => {
    await assertFails(write('man', await jobWrite('man', 'JOB-0001', (j) => { j.jobName = 'Mine now'; })));
  });
  test('jobs cannot be deleted, even by an admin', async () => {
    await assertFails(write('adm', { 'ticketing/jobs/JOB-0001': null }));
  });
});

describe('remakes', () => {
  // JOB-0001 in progress (man, man2): holds 5 fingertips, 1 palm, 2 bases
  beforeEach(async () => replay('one claimer leaves; parts stay with the job'));

  // closes JOB-0001 as remade and creates its remake ticket, the way the app does
  async function remakeWrite(uid, { defectCount = 1, stock = {}, remakeId = 'JOB-0002', original = 'JOB-0001', pointBack = true } = {}) {
    const update = await jobWrite(uid, original, (j) => {
      j.status = 'remade';
      j.remadeAs = remakeId;
      j.lines[FT].held -= defectCount;
      j.lines[FT].scrapped += defectCount;
    }, { stock, history: { type: 'remade', to: remakeId } });
    const hid = newKey();
    update['ticketing/counters/job'] = Number(remakeId.slice(4));
    update[`ticketing/jobs/${remakeId}`] = {
      jobId: remakeId, jobName: 'Left arm (remake)', requestedBy: 'req', submittedBy: uid, neededBy: '2026-12-02',
      lines: { [FT]: { quantity: defectCount, held: 0, scrapped: 0 } }, status: 'requested',
      createdAt: now(), updatedAt: now(), rev: 1, lastHistoryId: hid,
      ...(pointBack ? { remakeOf: original } : {}),
      usedParts: { [FT]: 5, [PALM]: 1, [BASE]: 2 },
      defects: { [FT]: { count: defectCount, reason: 'cracked' } },
    };
    update[`ticketing/history/${hid}`] = { jobId: remakeId, type: 'created', user: uid, timestamp: now() };
    return update;
  }

  test('a claimer, the requester, Quality or an admin can create a remake (control)', async () => {
    for (const uid of ['man', 'req', 'qa', 'adm']) {
      await env.clearDatabase();
      await seed();
      await replay('one claimer leaves; parts stay with the job');
      await assertSucceeds(write(uid, await remakeWrite(uid)));
    }
    assert((await stockOf(FT)) === 7, 'defective parts are not returned to stock');
  });
  test('someone not on the job and outside those teams cannot', async () => {
    await assertFails(write('other', await remakeWrite('other')));
    await assertFails(write('lead', await remakeWrite('lead')));
  });
  test('defective parts cannot be put back into inventory', async () => {
    await assertFails(write('man', await remakeWrite('man', { stock: { [FT]: (await stockOf(FT)) + 1 } })));
  });
  test('the job and its remake must point at each other', async () => {
    const noRemake = await remakeWrite('man');
    delete noRemake['ticketing/jobs/JOB-0002'];
    await assertFails(write('man', noRemake));
    await assertFails(write('man', await remakeWrite('man', { pointBack: false })));
  });
  test('a remake ticket cannot claim to replace a job that is still open', async () => {
    const fake = await remakeWrite('req');
    delete fake['ticketing/jobs/JOB-0001'];
    for (const k of Object.keys(fake)) if (fake[k]?.type === 'remade') delete fake[k];
    await assertFails(write('req', fake));
  });
  test('not from a requested job', async () => {
    await write('man2', await jobWrite('man2', 'JOB-0001', (j) => { delete j.claimers; delete j.claimedAt; j.status = 'requested';
      for (const l of Object.values(j.lines)) l.held = 0; },
    { stock: { [FT]: (await stockOf(FT)) + 5, [PALM]: (await stockOf(PALM)) + 1, [BASE]: (await stockOf(BASE)) + 2 }, history: { type: 'unclaimed' } }));
    await assertFails(write('req', await remakeWrite('req', { defectCount: 0 })));
  });
  test('after the remake, the old job is closed and its defects are permanent', async () => {
    await write('man', await remakeWrite('man'));
    await assertFails(write('man', await jobWrite('man', 'JOB-0001', (j) => { j.status = 'inProgress'; })));
    await assertFails(write('adm', await jobWrite('adm', 'JOB-0001', (j) => { j.lines[FT].scrapped = 0; j.lines[FT].held = 5; },
      { stock: { [FT]: (await stockOf(FT)) - 1 } })));
    await assertFails(write('req', await jobWrite('req', 'JOB-0002', (j) => { j.defects[FT].count = 9; })));
  });
});

describe('the change log cannot be skipped', () => {
  beforeEach(async () => replay('a second scholar joins'));

  test('a job save without a new history row is refused', async () => {
    await assertFails(write('req', await jobWrite('req', 'JOB-0001', (j) => { j.jobName = 'x'; }, { noHistory: true })));
  });
  test('a history row for a different job, or in someone else\'s name, is refused', async () => {
    await assertFails(write('req', await jobWrite('req', 'JOB-0001', (j) => { j.jobName = 'x'; }, { history: { jobId: 'JOB-0009' } })));
    await assertFails(write('req', await jobWrite('req', 'JOB-0001', (j) => { j.jobName = 'x'; }, { history: { user: 'adm' } })));
  });
  test('history rows cannot be edited or deleted, even by an admin', async () => {
    const id = (await readAdmin('ticketing/jobs/JOB-0001')).lastHistoryId;
    await assertFails(write('adm', { [`ticketing/history/${id}/to`]: 'x' }));
    await assertFails(write('adm', { [`ticketing/history/${id}`]: null }));
  });
});

describe('comments', () => {
  const comment = (uid, extra = {}) => ({
    [`ticketing/comments/${newKey()}`]: { jobId: 'JOB-0001', author: uid, text: 'hi', timestamp: now(), ...extra },
  });
  // JOB-0001 claimed by man and man2, requested by req
  beforeEach(async () => replay('requester edits the name while in progress'));

  test('admins, the requester, every claimer, and Quality, Production and Manufacturing (control)', async () => {
    for (const uid of ['adm', 'req', 'man', 'man2', 'qa', 'prod', 'mfg']) {
      await assertSucceeds(write(uid, comment(uid)));
    }
  });
  test('anyone else is refused, including otherDepartments-only members', async () => {
    // asm: lsicompapp has no Assembly department, so the name grants nothing
    for (const uid of ['other', 'lead', 'asm']) {
      await assertFails(write(uid, comment(uid)));
    }
  });
  test('not in someone else\'s name, not empty, and only on a real job', async () => {
    await assertFails(write('req', comment('adm')));
    await assertFails(write('req', comment('req', { text: '' })));
    await assertFails(write('req', comment('req', { jobId: 'JOB-9999' })));
  });
  test('the author edits the text only; nobody else edits', async () => {
    const c = comment('req');
    await write('req', c);
    const [path, value] = Object.entries(c)[0];
    await assertSucceeds(write('req', { [path]: { ...value, text: 'edited', editedAt: now() } }));
    await assertFails(write('adm', { [path]: { ...value, text: 'admin edit' } }));
    await assertFails(write('req', { [path]: { ...value, timestamp: '2020-01-01T00:00:00.000Z' } }));
  });
  test('the author or an admin deletes; nobody else', async () => {
    const a = comment('req');
    const b = comment('req');
    await write('req', a);
    await write('req', b);
    await assertFails(write('qa', { [Object.keys(a)[0]]: null }));
    await assertSucceeds(write('req', { [Object.keys(a)[0]]: null }));
    await assertSucceeds(write('adm', { [Object.keys(b)[0]]: null }));
  });
});
