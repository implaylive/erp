// IMPlay · check-avisos · roda a cada minuto (pg_cron) e manda os avisos do check-in pré-live.
// Deploy: supabase functions deploy check-avisos --no-verify-jwt   (a função confere x-cron-key)
// Secrets: CRON_KEY, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT, ANTHROPIC_API_KEY (opcional, p/ a IA)
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT") || "https://implaylive.github.io/erp/",
  Deno.env.get("VAPID_PUBLIC_KEY")!,
  Deno.env.get("VAPID_PRIVATE_KEY")!,
);
const APP = Deno.env.get("APP_URL") || "https://implaylive.github.io/erp/operador/";
const hm = (iso: string) => new Intl.DateTimeFormat("pt-BR", { hour: "2-digit", minute: "2-digit", timeZone: "America/Sao_Paulo" }).format(new Date(iso));
const resumo = (j: any) => `${j.marca || "Live"} às ${hm(j.inicio)}`;

async function destinatarios(ids: string[]) {
  if (!ids.length) return [];
  const { data } = await sb.from("imp_push_subs").select("endpoint,sub,membro_id").in("membro_id", ids);
  return data || [];
}

// Grava o envio antes de mandar: se já existia (outra rodada do cron), não manda de novo.
async function unico(jobId: string, tipo: string): Promise<boolean> {
  const { data, error } = await sb.from("imp_check_envios").upsert({ job_id: jobId, tipo }, { onConflict: "job_id,tipo", ignoreDuplicates: true }).select();
  return !error && !!data && data.length > 0;
}

async function push(ids: string[], p: { title: string; body: string; url: string; tag: string }) {
  let n = 0;
  for (const s of await destinatarios(ids)) {
    try {
      await webpush.sendNotification(s.sub, JSON.stringify(p), { TTL: 900, urgency: "high" });
      await sb.from("imp_push_subs").update({ ultimo_ok: new Date().toISOString() }).eq("endpoint", s.endpoint);
      n++;
    } catch (e: any) {
      if (e?.statusCode === 404 || e?.statusCode === 410) await sb.from("imp_push_subs").delete().eq("endpoint", s.endpoint);
      else console.error("push falhou", e?.statusCode);
    }
  }
  return n;
}

async function coordenacao(): Promise<string[]> {
  const { data } = await sb.from("imp_check_config").select("valor").eq("chave", "alerta").maybeSingle();
  const ids = Array.isArray(data?.valor) ? data!.valor as string[] : [];
  if (ids.length) return ids;
  const { data: s } = await sb.from("imp_membros").select("id").eq("papel", "socio").eq("status", "ativo");
  return (s || []).map((x: any) => x.id);
}

Deno.serve(async (req) => {
  const key = Deno.env.get("CRON_KEY");
  if (!key || req.headers.get("x-cron-key") !== key) return new Response("não autorizado", { status: 401 });
  const u = new URL(req.url);
  const sim = u.searchParams.get("simular") === "1"; // teste: ?simular=1&job=<id>&min=44 não grava envios
  const agora = Date.now();
  const coord = await coordenacao();
  const out: string[] = [];

  let q = sb.from("imp_jobs").select("*").eq("status", "aberto");
  if (sim && u.searchParams.get("job")) q = q.eq("id", u.searchParams.get("job")!);
  else q = q.gte("inicio", new Date(agora - 5 * 60e3).toISOString()).lte("inicio", new Date(agora + 25 * 3600e3).toISOString());
  const { data: lives, error } = await q;
  if (error) return new Response(error.message, { status: 500 });

  // orientações do cliente (grupo do WhatsApp) criadas ou mudadas na última hora
  const { data: novas } = sim ? { data: [] as any[] } : await sb.from("imp_cli_orient").select("id,cliente_id,titulo,mudou_em")
    .eq("ativo", true).gte("mudou_em", new Date(agora - 60 * 60e3).toISOString());

  for (const j of lives || []) {
    const m = sim && u.searchParams.get("min") ? Number(u.searchParams.get("min")) : (new Date(j.inicio).getTime() - agora) / 60000;
    const id = String(j.id);
    const fire = async (tipo: string, ids: string[], p: { title: string; body: string; url: string; tag: string }) => {
      if (sim) { out.push(`[sim] ${tipo} → ${ids.length} destino(s): ${p.title} · ${p.body}`); return; }
      if (await unico(id, tipo)) out.push(`${tipo}: ${await push(ids, p)} enviado(s) · ${resumo(j)}`);
    };
    const url = `${APP}#live=${id}`;

    // Lista congelada + extras da IA (24 h antes) + aviso para revisar
    let itens = j.checklist_itens;
    if (!itens) { const r = await sb.rpc("imp_chk_garantir", { p_job: id }); itens = r.data || []; }
    if (m <= 24 * 60 && m > 0 && !j.checklist_ia_em && Deno.env.get("ANTHROPIC_API_KEY") && !sim) {
      if (await unico(id, "ia")) {
        const r = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/check-ia`, { method: "POST", headers: { "x-cron-key": key, "content-type": "application/json" }, body: JSON.stringify({ job_id: id }) });
        out.push(`ia: ${r.status} · ${resumo(j)}`);
        const r2 = await sb.from("imp_jobs").select("checklist_itens").eq("id", id).single(); itens = r2.data?.checklist_itens || itens;
      }
    }
    if (m <= 24 * 60 && m > 0 && !j.operador_id) await fire("semop24", coord, { title: "Live sem operador", body: `${resumo(j)} ainda não tem operador. Escolha um no ERP.`, url: APP, tag: `semop-${id}` });
    if (m <= 24 * 60 && m > 45) await fire("rev", coord, { title: "Checklist para revisar", body: `${resumo(j)}: confira os itens do cliente sugeridos pela IA.`, url: APP, tag: `rev-${id}` });

    const { data: marcas } = await sb.from("imp_check_marcas").select("*").eq("job_id", id);
    const feitos = new Set((marcas || []).filter((x: any) => x.estado === "ok" || x.estado === "na").map((x: any) => x.item));
    const pend = (itens || []).filter((i: any) => !feitos.has(i.id));
    const prontos = !!j.checklist_pronto_em;

    // Cliente combinou algo novo antes da live: avisa o operador (a conferência do grupo volta a ficar pendente)
    if (m > 0 && m <= 24 * 60 && j.operador_id) {
      for (const o of (novas || []).filter((o: any) => String(o.cliente_id) === String(j.cliente_id))) {
        await fire(`ori:${o.id}:${new Date(o.mudou_em).getTime()}`, [j.operador_id], { title: `Orientação nova do cliente · ${j.marca || ""}`.trim(), body: `${o.titulo}. Leia no app e confirme de novo a conferência do grupo.`.slice(0, 160), url, tag: `ori-${id}-${o.id}` });
      }
    }

    // Problema marcado pelo operador: avisa a coordenação na hora
    for (const x of (marcas || []).filter((x: any) => x.estado === "problema")) {
      const it = (itens || []).find((i: any) => i.id === x.item);
      await fire(`prob:${x.item}:${new Date(x.em).getTime()}`, coord, { title: `Problema: ${resumo(j)}`, body: `${it?.titulo || x.item} — ${x.nota || ""}`.slice(0, 160), url, tag: `prob-${id}-${x.item}` });
    }
    if (prontos || m > 45 || m <= 0) continue;

    const op = j.operador_id ? [j.operador_id] : [];
    if (!op.length) { await fire("semop45", coord, { title: "Live em breve sem operador", body: `${resumo(j)} não tem operador!`, url: APP, tag: `semop-${id}` }); continue; }
    if (!(await destinatarios(op)).length) await fire("sempush", coord, { title: "Operador sem avisos ativados", body: `${resumo(j)}: o operador não ativou os avisos no celular. Ligue para ele.`, url: APP, tag: `sempush-${id}` });

    const falta = `${pend.length} de ${(itens || []).length} itens pendentes`;
    if (m > 30) {
      const atual = [35, 40, 45].find((s) => m <= s)!;
      await fire(`op${atual}`, op, { title: `Check-in da live às ${hm(j.inicio)}`, body: `${j.marca || ""}: ${falta}. Prazo: ${hm(new Date(new Date(j.inicio).getTime() - 30 * 60e3).toISOString())}.`, url, tag: `op-${id}` });
    } else {
      const slot = Math.floor(m / 5) * 5;
      const nomes = pend.slice(0, 4).map((i: any) => i.titulo).join("; ");
      await fire(`att${slot}`, op, { title: `⚠️ ATRASADO · live às ${hm(j.inicio)}`, body: `${falta}. Faltam ${Math.max(0, Math.round(m))} min. ${nomes}`.slice(0, 180), url, tag: `op-${id}` });
      await fire(`co${slot}`, coord, { title: `Checklist atrasado: ${resumo(j)}`, body: `${falta}. ${nomes}`.slice(0, 180), url: APP, tag: `co-${id}` });
    }
  }
  return new Response(JSON.stringify({ lives: lives?.length || 0, enviados: out }), { headers: { "content-type": "application/json" } });
});
