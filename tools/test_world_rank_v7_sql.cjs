// Actual PostgreSQL integration test via PGlite, no Supabase production writes.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function main() {
  const { PGlite } = require(process.env.PM_PGLITE_MODULE);
  const db = new PGlite();
  const root = path.join(__dirname, '../supabase/migrations');
  const v5 = fs.readFileSync(path.join(root, '202610150001_world_rank_medals.sql'), 'utf8');
  const v7 = fs.readFileSync(path.join(root, '202610160001_world_ranks_v7.sql'), 'utf8');
  const campaign = 'C'.repeat(27), oldTotd = 'T'.repeat(27), newTotd = 'N'.repeat(27);
  const releases = [new Date(Date.now() - 8 * 86400000).toISOString(), new Date(Date.now() - 8 * 3600000).toISOString()];
  const source = 'trackmania.io/world-map-leaderboard';
  const evidence = (...positions) => Object.fromEntries(['platinum', 'emerald', 'diamond', 'wr'].map((name, index) =>
    [name, { position: positions[index], playerCount: positions[0] }]));
  const observe = (prefix, uid, count) => db.query(`select public.${prefix}_observe($1,$2) as result`, [uid, count]);
  const register = (prefix, uid, kind, released) => db.query(`select public.${prefix}_register($1,$2,$3,$4)`,
    [uid, 'Published map', kind, released]);
  const publish = (prefix, uid, ranks) => db.query(
    `select public.${prefix}_publish($1,24000,22000,20000,19000,$2,$3,$4) as result`,
    [uid, new Date().toISOString(), source, evidence(...ranks)]);
  try {
    await db.exec(`create role anon; create role authenticated; create role service_role;
      create schema auth;
      create function auth.role() returns text language sql stable as
      'select current_setting(''request.jwt.claim.role'', true)';
      set request.jwt.claim.role = 'service_role';`);
    await db.exec(v5);
    // Two real historical policies are already published and immutable.
    for (const [uid, kind, released] of [[campaign, 'campaign', releases[0]], [oldTotd, 'totd', releases[1]]]) {
      await register('pm', uid, kind, released);
      await db.query("update public.map_medals set threshold_detected_at=eligible_at-interval '1 second' where map_uid=$1", [uid]);
      assert.equal((await observe('pm', uid, 5000)).rows[0].result.status, 'ready_to_capture');
      assert.equal((await publish('pm', uid, [5000, 1000, 200, 1])).rows[0].result, true);
    }
    const before = (await db.query('select map_uid, platinum_ms, captured_at from public.map_medals order by map_uid')).rows;
    await db.exec(v7);
    assert.deepEqual((await db.query('select map_uid, platinum_ms, captured_at from public.map_medals order by map_uid')).rows, before);
    const catalog = () => db.query('select public.pm_public_catalog() as value').then(x => x.rows[0].value);
    assert.equal((await catalog()).maps[campaign].calculationVersion, 5);
    assert.equal((await catalog()).maps[oldTotd].calculationVersion, 5);
    for (const [uid, kind, released] of [[campaign, 'campaign', releases[0]], [oldTotd, 'totd', releases[1]]]) {
      await register('pm7', uid, kind, released);
      assert.equal((await observe('pm7', uid, 2499)).rows[0].result.status, 'waiting_for_players');
      assert.equal((await observe('pm7', uid, 2500)).rows[0].result.status, 'waiting_extra_hour');
      await assert.rejects(publish('pm7', uid, [2500, kind === 'totd' ? 500 : 1000,
                                                   kind === 'totd' ? 100 : 200, 1]), /invalid or premature capture/);
      // An old publication remains readable until all new v7 goals are frozen.
      assert.equal((await catalog()).maps[uid].calculationVersion, 5);
      await db.query("update public.pm_revised_medals set threshold_detected_at=now()-interval '2 hours', capture_due_at=now()-interval '1 hour' where map_uid=$1", [uid]);
      assert.equal((await observe('pm7', uid, 2500)).rows[0].result.status, 'ready_to_capture');
      const expected = [2500, kind === 'totd' ? 500 : 1000, kind === 'totd' ? 100 : 200, 1];
      if (kind === 'totd') await assert.rejects(publish('pm7', uid, [2500, 1000, 200, 1]), /invalid or premature capture/);
      assert.equal((await publish('pm7', uid, expected)).rows[0].result, true);
      assert.equal((await publish('pm7', uid, expected)).rows[0].result, false);
      assert.equal((await catalog()).maps[uid].calculationVersion, 7);
    }
    // New TOTD still starts empty and follows H+1 / 2,500 before publishing.
    await register('pm7', newTotd, 'totd', new Date(Date.now() - 3 * 3600000).toISOString());
    assert.equal((await observe('pm7', newTotd, 2500)).rows[0].result.status, 'waiting_extra_hour');
    assert.equal((await catalog()).maps[newTotd].status, 'waiting_extra_hour');
    assert.deepEqual((await db.query('select map_uid, platinum_ms, captured_at from public.map_medals order by map_uid')).rows, before);
    assert.equal((await db.query('select count(*)::int as n from public.map_medal_publications')).rows[0].n, 2);
    assert.equal((await db.query('select count(*)::int as n from public.pm_revised_medal_publications')).rows[0].n, 2);
    await assert.rejects(db.query('update public.pm_revised_medals set platinum_ms=24001 where map_uid=$1', [campaign]), /immutable/);
    await db.exec("set role anon; set request.jwt.claim.role='anon';");
    await assert.rejects(db.query('select * from public.pm_revised_medals'), /permission denied/);
    await assert.rejects(register('pm7', 'A'.repeat(27), 'totd', releases[1]), /permission denied|publisher only/);
    assert.equal((await catalog()).maps[campaign].calculationVersion, 7);
    console.log('PostgreSQL v7: old campaign/TOTD immutable, exact 2500 ranks, atomic replacement and anon isolation OK');
  } finally { await db.close(); }
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
