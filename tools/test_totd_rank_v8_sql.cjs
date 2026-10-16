// Integration test: actual PostgreSQL migration v5 -> v7 -> v8 via PGlite.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function main() {
  const { PGlite } = require(process.env.PM_PGLITE_MODULE);
  const db = new PGlite();
  const migrations = path.join(__dirname, '../supabase/migrations');
  const source = 'trackmania.io/world-map-leaderboard';
  const totd = 'T'.repeat(27), campaign = 'C'.repeat(27), newTotd = 'N'.repeat(27);
  const totdRelease = new Date(Date.now() - 8 * 3600000).toISOString();
  const campaignRelease = new Date(Date.now() - 8 * 86400000).toISOString();
  const proof = (a, b, c) => Object.fromEntries(['platinum', 'emerald', 'diamond', 'wr'].map((name, i) =>
    [name, { position: [a, b, c, 1][i], playerCount: 5000 }]));
  const register = (n, uid, kind, released) => db.query(`select public.pm${n}_register($1,$2,$3,$4)`,
    [uid, 'Official map', kind, released]);
  const observe = (n, uid, players) => db.query(`select public.pm${n}_observe($1,$2) as result`, [uid, players]);
  const publish = (n, uid, ranks) => db.query(`select public.pm${n}_publish($1,24000,22000,20000,19000,$2,$3,$4) as result`,
    [uid, new Date().toISOString(), source, proof(...ranks)]);
  const catalog = () => db.query('select public.pm_public_catalog() as value').then(result => result.rows[0].value);
  try {
    await db.exec(`create role anon; create role authenticated; create role service_role;
      create schema auth;
      create function auth.role() returns text language sql stable as
      'select current_setting(''request.jwt.claim.role'', true)';
      set request.jwt.claim.role='service_role';`);
    await db.exec(fs.readFileSync(path.join(migrations, '202610150001_world_rank_medals.sql'), 'utf8'));
    await register('', totd, 'totd', totdRelease);
    await db.query("update public.map_medals set threshold_detected_at=eligible_at-interval '1 second' where map_uid=$1", [totd]);
    assert.equal((await observe('', totd, 5000)).rows[0].result.status, 'ready_to_capture');
    assert.equal((await publish('', totd, [5000, 1000, 200])).rows[0].result, true);
    const frozenV5 = (await db.query('select * from public.map_medals where map_uid=$1', [totd])).rows[0];

    await db.exec(fs.readFileSync(path.join(migrations, '202610160001_world_ranks_v7.sql'), 'utf8'));
    await register('7', campaign, 'campaign', campaignRelease);
    await register('7', totd, 'totd', totdRelease);
    for (const uid of [campaign, totd]) {
      await db.query("update public.pm_revised_medals set threshold_detected_at=eligible_at-interval '1 second' where map_uid=$1", [uid]);
      assert.equal((await observe('7', uid, 2500)).rows[0].result.status, 'ready_to_capture');
      assert.equal((await publish('7', uid, uid === totd ? [2500, 500, 100] : [2500, 1000, 200])).rows[0].result, true);
    }
    const frozenV7 = (await db.query('select * from public.pm_revised_medals where map_uid=$1', [totd])).rows[0];
    assert.equal((await catalog()).maps[totd].calculationVersion, 7);

    await db.exec(fs.readFileSync(path.join(migrations, '202610170001_totd_rank_v8.sql'), 'utf8'));
    assert.deepEqual((await db.query('select * from public.map_medals where map_uid=$1', [totd])).rows[0], frozenV5);
    assert.deepEqual((await db.query('select * from public.pm_revised_medals where map_uid=$1', [totd])).rows[0], frozenV7);
    assert.equal((await catalog()).maps[totd].calculationVersion, 7);
    assert.equal((await catalog()).maps[campaign].calculationVersion, 7);
    await register('8', totd, 'totd', totdRelease);
    assert.equal((await observe('8', totd, 2499)).rows[0].result.status, 'waiting_for_players');
    assert.equal((await observe('8', totd, 2500)).rows[0].result.status, 'waiting_extra_hour');
    await assert.rejects(publish('8', totd, [1000, 500, 100]), /premature TOTD capture/);
    assert.equal((await catalog()).maps[totd].calculationVersion, 7); // Old goals remain visible.
    await db.query("update public.pm_totd_medals set threshold_detected_at=now()-interval '2 hours', capture_due_at=now()-interval '1 hour' where map_uid=$1", [totd]);
    assert.equal((await observe('8', totd, 2500)).rows[0].result.status, 'ready_to_capture');
    await assert.rejects(publish('8', totd, [2500, 500, 100]), /invalid or premature TOTD capture/);
    assert.equal((await publish('8', totd, [1000, 500, 100])).rows[0].result, true);
    assert.equal((await publish('8', totd, [1000, 500, 100])).rows[0].result, false);
    assert.equal((await catalog()).maps[totd].calculationVersion, 8);
    assert.equal((await catalog()).maps[campaign].calculationVersion, 7);
    assert.deepEqual((await db.query('select * from public.map_medals where map_uid=$1', [totd])).rows[0], frozenV5);
    assert.deepEqual((await db.query('select * from public.pm_revised_medals where map_uid=$1', [totd])).rows[0], frozenV7);

    await register('8', newTotd, 'totd', new Date(Date.now() - 3 * 3600000).toISOString());
    assert.equal((await observe('8', newTotd, 2500)).rows[0].result.status, 'waiting_extra_hour');
    assert.equal((await catalog()).maps[newTotd].calculationVersion, 8);
    await assert.rejects(db.query('update public.pm_totd_medals set platinum_ms=24001 where map_uid=$1', [totd]), /immutable/);
    await db.exec("set role anon; set request.jwt.claim.role='anon';");
    await assert.rejects(db.query('select * from public.pm_totd_medals'), /permission denied/);
    await assert.rejects(register('8', 'A'.repeat(27), 'totd', totdRelease), /permission denied|publisher only/);
    assert.equal((await catalog()).maps[totd].calculationVersion, 8);
    console.log('PostgreSQL v8: archived TOTD v5/v7 immutable, Platinum 1000, 2500 players and anon refusal OK');
  } finally { await db.close(); }
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
