// Integration smoke test with actual PostgreSQL (PGlite), not a SQL text mock.
// Run with PM_PGLITE_MODULE pointing to the PGlite installation outside the repo.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function main() {
  const { PGlite } = require(process.env.PM_PGLITE_MODULE);
  const db = new PGlite();
  const sql = fs.readFileSync(path.join(__dirname, '../supabase/migrations/202610150001_world_rank_medals.sql'), 'utf8');
  const uid = 'T'.repeat(27);
  const campaign = 'C'.repeat(27);
  const source = 'trackmania.io/world-map-leaderboard';
  const expectRejected = async (operation, pattern) => {
    await assert.rejects(operation, pattern);
  };
  try {
    await db.exec(`create role anon; create role authenticated; create role service_role;
      create schema auth;
      create function auth.role() returns text language sql stable as
      'select current_setting(''request.jwt.claim.role'', true)';
      set request.jwt.claim.role = 'service_role';`);
    await db.exec(sql);

    const released = new Date(Date.now() - 5 * 3600000).toISOString();
    const register = (id, kind, date) => db.query('select public.pm_register($1,$2,$3,$4)', [id, 'Test map', kind, date]);
    const observe = (id, count) => db.query('select public.pm_observe($1,$2) as result', [id, count]);
    const publish = (id, captured) => db.query(
      'select public.pm_publish($1,24000,22000,20000,19000,$2,$3,$4) as applied',
      [id, captured, source, { platinum: { position: 5000 }, emerald: { position: 1000 }, diamond: { position: 200 } }]);
    await register(uid, 'totd', released);
    assert.equal((await observe(uid, 4999)).rows[0].result.status, 'waiting_for_players');
    assert.equal((await observe(uid, 5000)).rows[0].result.status, 'waiting_extra_hour');
    const first = (await db.query('select threshold_detected_at, capture_due_at from public.map_medals where map_uid=$1', [uid])).rows[0];
    assert.ok(first.threshold_detected_at && first.capture_due_at);
    await expectRejected(publish(uid, new Date().toISOString()), /invalid or premature capture/);
    assert.equal((await db.query('select platinum_ms from public.map_medals where map_uid=$1', [uid])).rows[0].platinum_ms, null);
    await db.query('select public.pm_retry($1,$2)', [uid, 'network']);
    assert.equal((await db.query('select status from public.map_medals where map_uid=$1', [uid])).rows[0].status, 'retry_pending');
    await observe(uid, 5000);
    const after = (await db.query('select threshold_detected_at, capture_due_at from public.map_medals where map_uid=$1', [uid])).rows[0];
    assert.equal(String(after.threshold_detected_at), String(first.threshold_detected_at));
    assert.equal(String(after.capture_due_at), String(first.capture_due_at));

    // Independent popular campaign: threshold observed before J+7, publish now.
    await register(campaign, 'campaign', new Date(Date.now() - 8 * 86400000).toISOString());
    await db.query("update public.map_medals set threshold_detected_at = eligible_at - interval '1 day' where map_uid=$1", [campaign]);
    assert.equal((await observe(campaign, 5000)).rows[0].result.status, 'ready_to_capture');
    assert.equal((await publish(campaign, new Date().toISOString())).rows[0].applied, true);
    assert.equal((await publish(campaign, new Date().toISOString())).rows[0].applied, false);
    await expectRejected(db.query('update public.map_medals set platinum_ms=24001 where map_uid=$1', [campaign]), /immutable/);
    await expectRejected(db.query('delete from public.map_medals where map_uid=$1', [campaign]), /immutable/);
    const publicCatalog = (await db.query('select public.pm_public_catalog() as data')).rows[0].data;
    assert.equal(publicCatalog.maps[campaign].timesMs[0], 24000);
    assert.equal(publicCatalog.maps[uid].timesMs, null);
    assert.equal(publicCatalog.maps[campaign].calculationVersion, 5);
    assert.equal((await db.query('select count(*)::int as n from public.map_medal_publications')).rows[0].n, 1);

    await db.exec("set role anon; set request.jwt.claim.role = 'anon';");
    await expectRejected(db.query('select * from public.map_medals'), /permission denied/);
    await expectRejected(register('A'.repeat(27), 'totd', released), /permission denied|publisher only/);
    const anonCatalog = (await db.query('select public.pm_public_catalog() as data')).rows[0].data;
    assert.equal(anonCatalog.maps[campaign].timesMs[2], 20000);
    console.log('PostgreSQL: deadlines, retry, atomic publication, immutability and anonymous isolation OK');
  } finally { await db.close(); }
}

main().catch(error => { console.error(error.message); process.exitCode = 1; });
