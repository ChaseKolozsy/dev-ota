export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const token = env.DEVOTA_RELAY_TOKEN || "";
    const store = env.DEVOTA_MAIL_EVENTS;
    if (!store) return json({ error: "DEVOTA_MAIL_EVENTS KV binding is required" }, 500);

    if (!authorized(request, token)) {
      return json({ error: "unauthorized" }, 401, {
        "WWW-Authenticate": 'Basic realm="DevOTA Postmark Relay"',
      });
    }

    if (request.method === "POST" && url.pathname === "/postmark/inbound") {
      const payload = await request.json();
      const id = String(payload.MessageID || payload.MessageId || crypto.randomUUID());
      const event = {
        id,
        receivedAt: new Date().toISOString(),
        payload,
      };
      await store.put(`event:${id}`, JSON.stringify(event), {
        expirationTtl: Number(env.DEVOTA_RELAY_TTL_SECONDS || 604800),
      });
      return json({ status: "ok", id });
    }

    if (request.method === "GET" && url.pathname === "/events") {
      const listed = await store.list({ prefix: "event:", limit: 100 });
      const events = [];
      for (const key of listed.keys) {
        const raw = await store.get(key.name);
        if (!raw) continue;
        try {
          events.push(JSON.parse(raw));
        } catch {
          events.push({ id: key.name.slice("event:".length), raw });
        }
      }
      if (url.searchParams.get("delete") !== "0") {
        await Promise.all(listed.keys.map((key) => store.delete(key.name)));
      }
      return json({ status: "ok", events, truncated: Boolean(listed.list_complete === false) });
    }

    return json({ error: "not found" }, 404);
  },
};

function authorized(request, token) {
  if (!token) return false;
  const bearer = request.headers.get("authorization") || "";
  if (bearer === `Bearer ${token}`) return true;
  if (bearer.startsWith("Basic ")) {
    try {
      const decoded = atob(bearer.slice("Basic ".length));
      const password = decoded.includes(":") ? decoded.split(":").slice(1).join(":") : decoded;
      if (password === token) return true;
    } catch {}
  }
  return request.headers.get("x-devota-relay-token") === token;
}

function json(value, status = 200, headers = {}) {
  return new Response(JSON.stringify(value, null, 2), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...headers,
    },
  });
}
