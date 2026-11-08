import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import OpenAI from "https://esm.sh/openai@4.56.0";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ALLOWED_ORIGINS = new Set([
  "https://professionalesp.com",
  "https://www.professionalesp.com",
  "https://mohamed75090-ops.github.io",
]);
const MAX_FILES = 8;
const MAX_FILE_BYTES = 8 * 1024 * 1024;
const MAX_TOTAL_BYTES = 32 * 1024 * 1024;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ALLOWED_MIME = new Set(["image/jpeg", "image/png", "image/webp"]);

function corsHeaders(origin: string | null) {
  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  if (origin && ALLOWED_ORIGINS.has(origin)) headers["Access-Control-Allow-Origin"] = origin;
  return headers;
}

function reply(data: unknown, status = 200, origin: string | null = null) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders(origin), "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

function toBase64(bytes: Uint8Array) {
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}

serve(async (req) => {
  const origin = req.headers.get("Origin");
  const cors = corsHeaders(origin);

  if (origin && !ALLOWED_ORIGINS.has(origin)) {
    return new Response("Origin not allowed", { status: 403, headers: { "Vary": "Origin" } });
  }
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405, origin);

  try {
    const authHeader = req.headers.get("Authorization") || "";
    const accessToken = authHeader.replace(/^Bearer\s+/i, "").trim();
    if (!accessToken || accessToken === authHeader.trim()) {
      return reply({ error: "Authentication required" }, 401, origin);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const apiKey = Deno.env.get("OPENAI_API_KEY");
    if (!supabaseUrl || !supabaseAnonKey || !apiKey) {
      console.error("Required server configuration is missing");
      return reply({ error: "Server configuration error" }, 500, origin);
    }

    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });
    const { data: { user }, error: authError } = await supabase.auth.getUser(accessToken);
    if (authError || !user) return reply({ error: "Invalid login session" }, 401, origin);

    const { data: profile, error: profileError } = await supabase
      .from("profiles").select("role").eq("id", user.id).single();
    if (profileError || !profile || !["founder", "admin", "results_manager"].includes(profile.role)) {
      return reply({ error: "Not authorized" }, 403, origin);
    }

    const rawBody = await req.text();
    if (rawBody.length > 64 * 1024) return reply({ error: "Request is too large" }, 413, origin);
    let body: any;
    try { body = JSON.parse(rawBody); }
    catch { return reply({ error: "Invalid JSON body" }, 400, origin); }

    if (typeof body.match_id !== "string" || !UUID_RE.test(body.match_id)) {
      return reply({ error: "Invalid match ID" }, 400, origin);
    }
    if (!Array.isArray(body.files) || body.files.length < 1 || body.files.length > MAX_FILES) {
      return reply({ error: `Upload between 1 and ${MAX_FILES} images` }, 400, origin);
    }

    const paths = body.files.map((file: any) => file?.path);
    if (paths.some((path: unknown) =>
      typeof path !== "string" || path.length > 512 ||
      !path.startsWith(`${body.match_id}/`) || path.split("/").length !== 2
    ) || new Set(paths).size !== paths.length) {
      return reply({ error: "Invalid image path" }, 400, origin);
    }

    const ai = new OpenAI({ apiKey });
    const content: any[] = [{
      type: "text",
      text: `Analyze these PUBG MOBILE room result screenshots.

Each visual placement group contains four players from ONE squad.
Keep the four players together even if their username tags differ.
Never identify teams by username tags.

Extract:
- Placement of each group.
- Exactly four player names when visible.
- Individual kills for each player.
- Total kills = sum of the four players' kills.

Do not invent unreadable names or numbers.
If uncertain, explain in note.
Do not duplicate groups.

Return JSON:
{
 "groups": [
  {
   "placement": 1,
   "players": [
    {"player_name": "name", "kills": 0}
   ],
   "total_kills": 0,
   "note": ""
  }
 ]
}`
    }];

    let totalBytes = 0;
    for (const path of paths as string[]) {
      const { data, error } = await supabase.storage.from("room-screenshots").download(path);
      if (error || !data) {
        console.error("Screenshot download failed");
        return reply({ error: "Could not read one of the uploaded images" }, 400, origin);
      }
      if (!ALLOWED_MIME.has(data.type)) {
        return reply({ error: "Only JPEG, PNG, and WebP images are allowed" }, 415, origin);
      }
      if (data.size > MAX_FILE_BYTES) {
        return reply({ error: "Each image must be 8 MB or smaller" }, 413, origin);
      }
      totalBytes += data.size;
      if (totalBytes > MAX_TOTAL_BYTES) {
        return reply({ error: "The combined image size must be 32 MB or smaller" }, 413, origin);
      }
      const bytes = new Uint8Array(await data.arrayBuffer());
      content.push({
        type: "image_url",
        image_url: { url: `data:${data.type};base64,${toBase64(bytes)}`, detail: "high" },
      });
    }

    const response = await ai.chat.completions.create({
      model: "gpt-4.1",
      messages: [{ role: "user", content }],
      response_format: { type: "json_object" },
    });
    const output = response.choices[0]?.message?.content;
    if (!output) throw new Error("OpenAI returned an empty response");

    const result = JSON.parse(output);
    const groups = Array.isArray(result.groups) ? result.groups : [];
    for (const group of groups) {
      group.players = Array.isArray(group.players) ? group.players : [];
      group.players = group.players.map((player: any) => ({
        player_name: String(player.player_name || ""),
        kills: Number.isInteger(player.kills) && player.kills >= 0 ? player.kills : 0,
      }));
      group.total_kills = group.players.reduce((sum: number, player: any) => sum + player.kills, 0);
      if (group.players.length !== 4) group.note = "تنبيه: لم يتم التعرف على أربعة لاعبين بوضوح.";
    }
    return reply({ success: true, groups, warning: "راجع النتائج قبل اعتمادها." }, 200, origin);
  } catch (error) {
    console.error("AI scanner failed:", error instanceof Error ? error.message : "Unknown error");
    return reply({ error: "AI scanner failed. Please try again." }, 500, origin);
  }
});
