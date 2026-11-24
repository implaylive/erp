-- v77 · Calendário da marca: o cliente sugere mudanças por live, a equipe aceita ou recusa.
-- Rodar UMA vez no SQL Editor do Supabase, DEPOIS do implay_calendario_ok.sql (v74). Pode rodar de novo sem estragar nada.
--
-- O que muda:
--   1) imp_cal_envios ganha duas colunas: sugestoes (o que o cliente propôs, live a live) e aprova_com_ajustes
--      (o cliente já aprovou, desde que as mudanças sejam aceitas).
--   2) imp_cal_ver passa a devolver também as sugestões (a página do cliente mostra o que ele mandou e o que a equipe decidiu).
--   3) imp_cal_responder2: resposta do cliente com sugestões. A imp_cal_responder antiga continua existindo.
--   4) imp_cal_decidir: a equipe registra aceitar/recusar de cada sugestão.
--
-- imp_cal_equipe(): ligação pelo imp_membros.user_id = auth.uid(); sócio, equipe e operador decidem.

alter table public.imp_cal_envios add column if not exists sugestoes jsonb;
alter table public.imp_cal_envios add column if not exists aprova_com_ajustes boolean not null default false;

-- quem é da equipe (sócio ou CLT ativo); seller não decide
create or replace function public.imp_cal_equipe() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.imp_membros m
    where m.user_id = auth.uid() and m.papel in ('socio', 'basico', 'operador') and m.status = 'ativo')
$$;

-- página pública do cliente: o link (token longo) é a credencial. Sem token válido, devolve nulo.
drop function if exists public.imp_cal_ver(text);
create function public.imp_cal_ver(p_token text) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(e) - 'token' - 'criado_por'
  from public.imp_cal_envios e
  where length(coalesce(p_token, '')) >= 24 and e.token = p_token
  limit 1
$$;

-- resposta do cliente. p_ok = aprova; p_sug = [{id,tipo:'alterar'|'remover',inicio,fim,de_inicio,de_fim,obs}].
--   sem sugestões  + p_ok  -> aprovado
--   com sugestões  + p_ok  -> ajuste, já aprovado se a equipe aceitar (aprova_com_ajustes)
--   qualquer outro caso    -> ajuste
-- Só vale a primeira resposta de cada link (resposta_em nulo): depois, a equipe gera outro link.
create or replace function public.imp_cal_responder2(p_token text, p_ok boolean, p_nome text, p_obs text, p_sug jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_sug jsonb := '[]'::jsonb;
  n int;
begin
  if length(coalesce(p_token, '')) < 24 or btrim(coalesce(p_nome, '')) = '' then return false; end if;
  if jsonb_typeof(p_sug) = 'array' then
    if jsonb_array_length(p_sug) > 60 then return false; end if;
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', x->>'id', 'tipo', x->>'tipo',
             'inicio', x->>'inicio', 'fim', x->>'fim',
             'de_inicio', x->>'de_inicio', 'de_fim', x->>'de_fim',
             'obs', left(coalesce(x->>'obs', ''), 300))), '[]'::jsonb)
      into v_sug
      from jsonb_array_elements(p_sug) x
      where x->>'tipo' in ('alterar', 'remover') and coalesce(x->>'id', '') <> '';
  end if;
  update public.imp_cal_envios set
    status = case when coalesce(p_ok, false) and jsonb_array_length(v_sug) = 0 then 'aprovado' else 'ajuste' end,
    aprova_com_ajustes = coalesce(p_ok, false) and jsonb_array_length(v_sug) > 0,
    resposta_nome = left(btrim(p_nome), 120),
    resposta_obs = left(nullif(btrim(coalesce(p_obs, '')), ''), 2000),
    resposta_em = now(),
    sugestoes = case when jsonb_array_length(v_sug) > 0 then v_sug end
  where token = p_token and resposta_em is null;
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- decisão da equipe: grava o estado de cada sugestão, o calendário final (itens) e, se for o caso, o status.
create or replace function public.imp_cal_decidir(p_id text, p_sug jsonb, p_itens jsonb, p_status text)
returns boolean language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.imp_cal_equipe() then return false; end if;
  if p_status is not null and p_status not in ('aprovado', 'ajuste') then return false; end if;
  update public.imp_cal_envios set
    sugestoes = p_sug,
    itens = coalesce(p_itens, itens),
    status = coalesce(p_status, status)
  where id::text = p_id;
  get diagnostics n = row_count;
  return n > 0;
end $$;

revoke all on function public.imp_cal_equipe() from public, anon;
revoke all on function public.imp_cal_decidir(text, jsonb, jsonb, text) from public, anon;
grant execute on function public.imp_cal_equipe() to authenticated;
grant execute on function public.imp_cal_decidir(text, jsonb, jsonb, text) to authenticated;
grant execute on function public.imp_cal_ver(text) to anon, authenticated;
grant execute on function public.imp_cal_responder2(text, boolean, text, text, jsonb) to anon, authenticated;
