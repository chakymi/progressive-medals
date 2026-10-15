// Deploy with JWT verification disabled: this function exposes only the curated
// public RPC. Neither the service key nor private map rows leave Supabase.
Deno.serve(async (request) => {
  if (request.method !== 'GET') return new Response(null, { status: 405, headers: { Allow: 'GET' } });
  const base = Deno.env.get('SUPABASE_URL');
  const anon = Deno.env.get('SUPABASE_ANON_KEY');
  if (!base || !anon) return new Response('Unavailable', { status: 503 });
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8000);
    let response: Response;
    try {
      response = await fetch(`${base}/rest/v1/rpc/pm_public_catalog`, {
        method: 'POST', headers: { apikey: anon, 'Content-Type': 'application/json' },
        body: '{}', signal: controller.signal,
      });
    } finally { clearTimeout(timeout); }
    if (!response.ok) return new Response('Unavailable', { status: 503 });
    const body = await response.text();
    if (body.length > 500_000) return new Response('Unavailable', { status: 503 });
    const catalog = JSON.parse(body);
    if (catalog?.schema !== 3 || !Number.isSafeInteger(catalog.version) ||
        typeof catalog.maps !== 'object' || catalog.maps === null || Array.isArray(catalog.maps)) {
      return new Response('Unavailable', { status: 503 });
    }
    return new Response(body, { status: 200, headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'public, max-age=300', 'X-Content-Type-Options': 'nosniff',
    } });
  } catch { return new Response('Unavailable', { status: 503 }); }
});
