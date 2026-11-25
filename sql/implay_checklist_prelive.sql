-- IMPlay · v98 · Check-in pré-live (app do operador + avisos)
-- Roda no SQL Editor do Supabase ANTES de o PR entrar no ar. Pode rodar de novo sem estragar nada.
-- Depois rode também sql/implay_checklist_cron.sql (só depois de publicar a Edge Function check-avisos).
-- Não mexe em imp_check_marcar nem em imp_entrar: o checklist antigo (v53) continua como está.

-- 1) Colunas novas na live ---------------------------------------------------------------
alter table public.imp_jobs add column if not exists operador_id uuid;
alter table public.imp_jobs add column if not exists promocoes jsonb;
alter table public.imp_jobs add column if not exists briefing text;
alter table public.imp_jobs add column if not exists briefing_arqs jsonb;
alter table public.imp_jobs add column if not exists checklist_itens jsonb;        -- lista congelada da live (base + extras)
alter table public.imp_jobs add column if not exists checklist_extras jsonb;       -- itens do cliente (IA ou manual)
alter table public.imp_jobs add column if not exists checklist_ia_em timestamptz;  -- quando a IA gerou os extras
alter table public.imp_jobs add column if not exists checklist_pronto_em timestamptz;

-- 2) Tabelas (o tipo do id da live é copiado de imp_jobs.id, seja uuid ou bigint) --------
do $$
declare t text;
begin
  select format_type(a.atttypid, a.atttypmod) into t
    from pg_attribute a where a.attrelid = 'public.imp_jobs'::regclass and a.attname = 'id' and not a.attisdropped;
  if t is null then raise exception 'imp_jobs.id não encontrado'; end if;

  execute format($f$
    create table if not exists public.imp_check_marcas (
      job_id %s not null references public.imp_jobs(id) on delete cascade,
      item text not null,
      estado text not null check (estado in ('ok','problema','na')),
      valor text, nota text, foto_path text,
      por uuid, em timestamptz not null default now(),
      primary key (job_id, item)
    )$f$, t);

  execute format($f$
    create table if not exists public.imp_check_hist (
      id bigserial primary key,
      job_id %s not null, item text not null, estado text not null,
      valor text, nota text, foto_path text,
      por uuid, em timestamptz not null default now()
    )$f$, t);

  execute format($f$
    create table if not exists public.imp_check_envios (
      job_id %s not null references public.imp_jobs(id) on delete cascade,
      tipo text not null,
      em timestamptz not null default now(),
      primary key (job_id, tipo)
    )$f$, t);
end $$;

-- Orientações do cliente (o que combinaram no grupo do WhatsApp): cupom, sorteio, flash sale, overlay, avisos.
do $$
declare t text;
begin
  select format_type(a.atttypid, a.atttypmod) into t
    from pg_attribute a where a.attrelid = 'public.imp_clientes'::regclass and a.attname = 'id' and not a.attisdropped;
  if t is null then raise exception 'imp_clientes.id não encontrado'; end if;
  execute format($f$
    create table if not exists public.imp_cli_orient (
      id bigserial primary key,
      cliente_id %s not null references public.imp_clientes(id) on delete cascade,
      tipo text not null check (tipo in ('cupom','sorteio','flash','overlay','aviso','outro')),
      titulo text not null,
      texto text,
      valido_ate timestamptz,
      anexos jsonb not null default '[]'::jsonb,   -- [{path,nome}] no bucket implay-check, sempre em orient/<cliente>/
      origem text not null default 'manual',       -- manual | ia
      por uuid,
      ativo boolean not null default true,
      criado_em timestamptz not null default now(),
      mudou_em timestamptz not null default now()
    )$f$, t);
end $$;
create index if not exists imp_cli_orient_cli on public.imp_cli_orient(cliente_id, ativo);

create table if not exists public.imp_push_subs (
  endpoint text primary key,
  membro_id uuid not null,
  sub jsonb not null,
  aparelho text,
  criado_em timestamptz not null default now(),
  ultimo_ok timestamptz
);
create index if not exists imp_push_subs_membro on public.imp_push_subs(membro_id);

create table if not exists public.imp_check_config (
  chave text primary key,
  valor jsonb not null,
  atualizado_em timestamptz not null default now()
);

-- Tudo fechado: só as funções abaixo (security definer) e a Edge Function (service role) tocam nas tabelas.
alter table public.imp_check_marcas  enable row level security;
alter table public.imp_check_hist    enable row level security;
alter table public.imp_check_envios  enable row level security;
alter table public.imp_push_subs     enable row level security;
alter table public.imp_check_config  enable row level security;
revoke all on public.imp_check_marcas, public.imp_check_hist, public.imp_check_envios,
              public.imp_push_subs, public.imp_check_config from public, anon, authenticated;
alter table public.imp_cli_orient enable row level security;

-- Quem está logado, como membro da IMPlay (imp_membros.user_id = login). Os ids de membro (operador_id etc.) não são o id do login.
create or replace function public.imp_chk_eu() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.imp_membros where user_id = auth.uid() limit 1
$$;
revoke all on function public.imp_chk_eu() from public, anon;
grant execute on function public.imp_chk_eu() to authenticated;
revoke all on public.imp_cli_orient from public, anon, authenticated;
revoke all on sequence public.imp_cli_orient_id_seq from public, anon, authenticated;

-- 3) Ajudantes -------------------------------------------------------------------------------
create or replace function public.imp_chk_num(p text) returns numeric
language sql immutable as $$
  select case when v ~ '^-?[0-9]+(\.[0-9]+)?$' then v::numeric end
    from (select case when x ~ ',' then replace(replace(x,'.',''),',','.') else x end as v
            from (select regexp_replace(coalesce(p,''), '[^0-9,.\-]', '', 'g') as x) a) b
$$;

-- Lista base (a coordenação pode trocar gravando 'modelo' em imp_check_config).
create or replace function public.imp_chk_modelo_base() returns jsonb
language sql stable as $$
  select coalesce((select valor from public.imp_check_config where chave='modelo'), $j$[
   {"id":"mic","bloco":"Equipamento","titulo":"Microfone carregado e testado","detalhe":"Grave 10 segundos e ouça com fone."},
   {"id":"cam","bloco":"Equipamento","titulo":"Câmera carregada e testada","detalhe":"Enquadramento, foco e bateria."},
   {"id":"aparelho","bloco":"Equipamento","titulo":"Aparelho da transmissão pronto","detalhe":"Bateria acima de 80% ou na tomada, internet testada, notificações silenciadas e 4G de reserva."},
   {"id":"luz","bloco":"Equipamento","titulo":"Luz e áudio do ambiente","detalhe":"Sem eco, sem ruído, rosto e produto bem iluminados."},
   {"id":"conta","bloco":"Conta e plataforma","titulo":"Acesso à conta da live funcionando","detalhe":"TikTok ou Instagram logado no aparelho certo."},
   {"id":"agendada","bloco":"Conta e plataforma","titulo":"Live agendada na plataforma","detalhe":"Horário e título certos."},
   {"id":"sacola","bloco":"Conta e plataforma","titulo":"Produtos na sacola, na ordem do roteiro","detalhe":"Estoque conferido de cada produto."},
   {"id":"flash","bloco":"Conta e plataforma","titulo":"Flash sale do briefing cadastrada","detalhe":"Produto, preço, estoque, limite por comprador e duração. Tire um print da tela.","foto":true},
   {"id":"precos","bloco":"Conta e plataforma","titulo":"Preços batem com o preço base","detalhe":"Digite o preço que está na plataforma. Se a flash sale não for possível, toque em Problema e avise antes.","tipo":"preco"},
   {"id":"briefing","bloco":"Briefing","titulo":"Briefing lido hoje, correto e atualizado","detalhe":"Dúvidas abertas já resolvidas com o cliente."},
   {"id":"cupons","bloco":"Briefing","titulo":"Cupons, links e o que não falar","detalhe":"Revisados e prontos para a seller."},
   {"id":"amostras","bloco":"Cenário e amostras","titulo":"Amostras certas, limpas, organizadas e de frente","detalhe":"As combinadas com o cliente. Tire uma foto.","foto":true},
   {"id":"cenario","bloco":"Cenário e amostras","titulo":"Cenário limpo","detalhe":"Fundo, mesa e chão. Tire uma foto.","foto":true},
   {"id":"seller_chegou","bloco":"Pessoas","titulo":"Live seller a caminho ou já no local","detalhe":"Confirme com ela."},
   {"id":"seller_briefada","bloco":"Pessoas","titulo":"Seller briefada sobre as novidades","detalhe":"Flash sale, amostras novas e pontos de atenção."}
  ]$j$::jsonb)
$$;

-- Orientações valem para a live: ativas e ainda não vencidas na hora dela.
create or replace function public.imp_chk_orient(p_cliente text, p_inicio timestamptz) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'tipo', o.tipo, 'titulo', o.titulo, 'texto', o.texto,
           'valido_ate', o.valido_ate, 'anexos', o.anexos, 'mudou_em', o.mudou_em) order by o.mudou_em desc), '[]'::jsonb)
    from (select * from public.imp_cli_orient
           where cliente_id::text = p_cliente and ativo and (valido_ate is null or valido_ate >= p_inicio)
           order by mudou_em desc limit 30) o
$$;
revoke all on function public.imp_chk_orient(text, timestamptz) from public, anon, authenticated;

create or replace function public.imp_chk_coord_ids() returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(
    nullif(array(select (x)::uuid from jsonb_array_elements_text(
       coalesce((select valor from public.imp_check_config where chave='alerta'), '[]'::jsonb)) x), '{}'),
    array(select id from public.imp_membros where papel='socio' and status='ativo'))
$$;

-- Monta/atualiza a lista congelada da live: base + extras. As marcas já feitas continuam valendo.
create or replace function public.imp_chk_garantir(p_job text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare j public.imp_jobs; itens jsonb; ex jsonb; orient jsonb; din jsonb;
begin
  select * into j from public.imp_jobs where id::text = p_job;
  if not found then return null; end if;
  ex := coalesce(j.checklist_extras, '[]'::jsonb);
  -- itens que dependem do que o cliente combinou no grupo: a conferência do grupo é sempre pedida;
  -- sorteio e overlay só entram quando existe orientação desse tipo
  orient := public.imp_chk_orient(j.cliente_id::text, j.inicio::timestamptz);
  din := jsonb_build_array(jsonb_build_object('id','orientacoes','bloco','Briefing','tipo','orient',
           'titulo','Orientações recentes do cliente conferidas (grupo do WhatsApp)',
           'detalhe','Veja o grupo do cliente e leia as orientações abaixo (cupom, sorteio, flash sale, overlay). Se faltar algo aqui, toque em Problema e escreva o que falta.'));
  if exists (select 1 from jsonb_array_elements(orient) o where o->>'tipo' = 'sorteio') then
    din := din || jsonb_build_array(jsonb_build_object('id','sorteio','bloco','Briefing',
           'titulo','Sorteio combinado: regra, prêmio e momento no roteiro',
           'detalhe','Confira a regra e o prêmio nas orientações e combine com a seller quando anunciar.'));
  end if;
  if exists (select 1 from jsonb_array_elements(orient) o where o->>'tipo' = 'overlay') then
    din := din || jsonb_build_array(jsonb_build_object('id','overlay','bloco','Cenário e amostras',
           'titulo','Overlay e imagens da tela prontos e testados',
           'detalhe','Baixe as imagens combinadas com o cliente, carregue na live e teste antes de começar.'));
  end if;
  itens := public.imp_chk_modelo_base() || din || coalesce((
    select jsonb_agg(jsonb_build_object('id', coalesce(e->>'id','x'||n), 'bloco', 'Do cliente',
              'titulo', e->>'titulo', 'detalhe', e->>'detalhe', 'foto', coalesce((e->>'foto')::boolean,false),
              'origem', coalesce(e->>'origem','manual')) order by n)
      from jsonb_array_elements(ex) with ordinality as t(e, n)
      where coalesce(e->>'titulo','') <> '' and coalesce((e->>'remover')::boolean,false) = false), '[]'::jsonb);
  if j.checklist_itens is distinct from itens then
    update public.imp_jobs set checklist_itens = itens where id::text = p_job;
  end if;
  return itens;
end $$;
revoke all on function public.imp_chk_garantir(text) from public, anon, authenticated;
grant execute on function public.imp_chk_garantir(text) to service_role;

-- Recalcula "pronto": todos os itens resolvidos (ok ou na), nenhum com problema.
create or replace function public.imp_chk_fechar(p_job text) returns void
language plpgsql security definer set search_path = public as $$
declare itens jsonb; faltam int; cid text; ini timestamptz;
begin
  select checklist_itens, cliente_id::text, inicio::timestamptz into itens, cid, ini from public.imp_jobs where id::text = p_job;
  -- a conferência do grupo reabre sozinha se o cliente combinou algo novo depois de o operador marcar
  select count(*) into faltam from jsonb_array_elements(coalesce(itens,'[]'::jsonb)) i
   where not exists (select 1 from public.imp_check_marcas m
                      where m.job_id::text = p_job and m.item = i->>'id' and m.estado in ('ok','na')
                        and not (i->>'id' = 'orientacoes' and exists (
                              select 1 from public.imp_cli_orient o
                               where o.cliente_id::text = cid and o.ativo and (o.valido_ate is null or o.valido_ate >= ini)
                                 and o.mudou_em > m.em)));
  update public.imp_jobs set checklist_pronto_em = case when faltam = 0 and jsonb_array_length(coalesce(itens,'[]'::jsonb)) > 0
                              then coalesce(checklist_pronto_em, now()) else null end where id::text = p_job;
end $$;
revoke all on function public.imp_chk_fechar(text) from public, anon, authenticated;

-- 4) Funções do app ----------------------------------------------------------------------------
create or replace function public.imp_op_entrar() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m record;
begin
  select id, papel, nome into m from public.imp_membros
   where id = public.imp_chk_eu() and status='ativo' and papel in ('operador','basico','socio');
  if not found then return null; end if;
  return jsonb_build_object('id', m.id, 'nome', m.nome, 'papel', m.papel,
    'coord', m.papel in ('socio','basico') or m.id = any(public.imp_chk_coord_ids()));
end $$;

-- Lives do operador (a coordenação enxerga todas). Janela: de 3h atrás até p_dias à frente.
create or replace function public.imp_op_lives(p_dias int default 2) returns jsonb
language plpgsql security definer set search_path = public as $$
declare eu jsonb := public.imp_op_entrar(); coord boolean; r jsonb := '[]'::jsonb; j record; itens jsonb; ms jsonb; cl record;
        ori jsonb; rea boolean;
begin
  if eu is null then raise exception 'sem acesso'; end if;
  coord := (eu->>'coord')::boolean;
  for j in
    select * from public.imp_jobs
     where status = 'aberto'
       and inicio::timestamptz between now() - interval '3 hours' and now() + make_interval(days => greatest(1, least(p_dias, 7)))
       and (coord or operador_id = public.imp_chk_eu())
     order by inicio
  loop
    itens := coalesce(j.checklist_itens, public.imp_chk_garantir(j.id::text));
    ori := public.imp_chk_orient(j.cliente_id::text, j.inicio::timestamptz);
    -- "Orientações conferidas" volta a ficar pendente se o cliente combinou algo novo depois da marcação
    select exists (select 1 from public.imp_check_marcas m where m.job_id = j.id and m.item = 'orientacoes'
                      and exists (select 1 from public.imp_cli_orient o
                                   where o.cliente_id::text = j.cliente_id::text and o.ativo
                                     and (o.valido_ate is null or o.valido_ate >= j.inicio::timestamptz) and o.mudou_em > m.em))
      into rea;
    select coalesce(jsonb_agg(jsonb_build_object('item', m.item, 'estado', m.estado, 'valor', m.valor, 'nota', m.nota,
              'foto_path', m.foto_path, 'por', (select nome from public.imp_membros where id = m.por), 'em', m.em)), '[]'::jsonb)
      into ms from public.imp_check_marcas m where m.job_id = j.id and not (rea and m.item = 'orientacoes');
    select marca, central into cl from public.imp_clientes where id = j.cliente_id;
    r := r || jsonb_build_object(
      'id', j.id, 'numero', j.numero, 'inicio', j.inicio, 'fim', j.fim, 'plataforma', j.plataforma,
      'marca', coalesce(nullif(j.marca,''), cl.marca), 'status', j.status,
      'operador_id', j.operador_id, 'operador', (select nome from public.imp_membros where id = j.operador_id),
      'seller', (select nome from public.imp_membros where id = j.principal_id),
      'promocoes', coalesce(j.promocoes, '[]'::jsonb),
      'briefing', j.briefing, 'briefing_arqs', coalesce(j.briefing_arqs, '[]'::jsonb),
      'central', jsonb_build_object('produtos', cl.central->'produtos', 'cupons', cl.central->'cupons',
                  'links', cl.central->'links', 'nao_falar', cl.central->'nao_falar'),
      'orient', ori, 'orient_reaberta', rea,
      'itens', itens, 'marcas', ms, 'pronto_em', j.checklist_pronto_em, 'meu', j.operador_id = public.imp_chk_eu());
  end loop;
  return r;
end $$;

create or replace function public.imp_op_marcar(p_job text, p_item text, p_estado text,
        p_valor text default null, p_nota text default null, p_foto text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare eu jsonb := public.imp_op_entrar(); j public.imp_jobs; it jsonb; linha jsonb; mapa jsonb; i int; esperado numeric; digitado numeric;
begin
  if eu is null then raise exception 'sem acesso'; end if;
  select * into j from public.imp_jobs where id::text = p_job;
  if not found then raise exception 'live não encontrada'; end if;
  if not ((eu->>'coord')::boolean or j.operador_id = public.imp_chk_eu()) then raise exception 'esta live não é sua'; end if;
  if p_estado not in ('ok','problema','na','limpar') then raise exception 'estado inválido'; end if;
  select x into it from jsonb_array_elements(coalesce(j.checklist_itens, public.imp_chk_garantir(p_job))) x where x->>'id' = p_item;
  if it is null then raise exception 'item não existe nesta live'; end if;

  if p_estado = 'limpar' then
    delete from public.imp_check_marcas where job_id::text = p_job and item = p_item;
    insert into public.imp_check_hist(job_id,item,estado,por) values (j.id,p_item,'limpar',public.imp_chk_eu());
    perform public.imp_chk_fechar(p_job);
    return jsonb_build_object('ok', true);
  end if;
  if p_estado in ('problema','na') and length(btrim(coalesce(p_nota,''))) < 3 then
    raise exception 'conte em poucas palavras o motivo';
  end if;
  if p_estado = 'ok' and coalesce((it->>'foto')::boolean,false) and coalesce(p_foto,'') = '' then
    raise exception 'este item precisa de foto';
  end if;
  if p_estado = 'ok' and it->>'tipo' = 'preco' then
    -- o operador digita o "Por" de cada linha de flash; tem que bater com o do briefing
    mapa := coalesce(nullif(p_valor,''), '{}')::jsonb;
    i := 0;
    for linha in select x from jsonb_array_elements(coalesce(j.promocoes,'[]'::jsonb)) x loop
      if public.imp_chk_num(linha->>'preco_live') is not null then
        esperado := public.imp_chk_num(linha->>'preco_live');
        digitado := public.imp_chk_num(mapa->>(i::text));
        if digitado is null or abs(digitado - esperado) > 0.005 then
          raise exception 'o preço de "%" não bate: o briefing diz R$ %', coalesce(linha->>'produto','produto'), to_char(esperado,'FM999990.00');
        end if;
      end if;
      i := i + 1;
    end loop;
  end if;

  insert into public.imp_check_marcas(job_id,item,estado,valor,nota,foto_path,por,em)
  values (j.id,p_item,p_estado,p_valor,nullif(btrim(coalesce(p_nota,'')),''),nullif(p_foto,''),public.imp_chk_eu(),now())
  on conflict (job_id,item) do update set estado=excluded.estado, valor=excluded.valor, nota=excluded.nota,
     foto_path=coalesce(excluded.foto_path, public.imp_check_marcas.foto_path), por=excluded.por, em=excluded.em;
  insert into public.imp_check_hist(job_id,item,estado,valor,nota,foto_path,por)
  values (j.id,p_item,p_estado,p_valor,nullif(btrim(coalesce(p_nota,'')),''),nullif(p_foto,''),public.imp_chk_eu());
  perform public.imp_chk_fechar(p_job);
  return jsonb_build_object('ok', true, 'pronto_em', (select checklist_pronto_em from public.imp_jobs where id::text = p_job));
end $$;

create or replace function public.imp_op_push_salvar(p_sub jsonb, p_aparelho text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.imp_op_entrar() is null then raise exception 'sem acesso'; end if;
  insert into public.imp_push_subs(endpoint, membro_id, sub, aparelho) values (p_sub->>'endpoint', public.imp_chk_eu(), p_sub, p_aparelho)
  on conflict (endpoint) do update set membro_id = public.imp_chk_eu(), sub = excluded.sub, aparelho = excluded.aparelho;
end $$;

create or replace function public.imp_op_push_remover(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from public.imp_push_subs where endpoint = p_endpoint and membro_id = public.imp_chk_eu()
$$;

-- Coordenação: salvar os itens do cliente (depois de revisar a sugestão da IA) e quem recebe os alertas.
create or replace function public.imp_chk_extras_salvar(p_job text, p_extras jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare eu jsonb := public.imp_op_entrar();
begin
  if eu is null or (eu->>'papel') not in ('socio','basico') then raise exception 'só a coordenação'; end if;
  update public.imp_jobs set checklist_extras = coalesce(p_extras,'[]'::jsonb) where id::text = p_job;
  perform public.imp_chk_garantir(p_job);
  perform public.imp_chk_fechar(p_job);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.imp_chk_alerta_salvar(p_ids uuid[]) returns void
language plpgsql security definer set search_path = public as $$
declare eu jsonb := public.imp_op_entrar();
begin
  if eu is null or (eu->>'papel') <> 'socio' then raise exception 'só sócio'; end if;
  insert into public.imp_check_config(chave, valor) values ('alerta', to_jsonb(coalesce(p_ids,'{}'::uuid[])))
  on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
end $$;

create or replace function public.imp_chk_alerta_ler() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when public.imp_op_entrar() is null then null
         else coalesce((select valor from public.imp_check_config where chave='alerta'), '[]'::jsonb) end
$$;

-- Estado do checklist de cada live para o ERP (quem fechou, quantos itens, problemas).
create or replace function public.imp_chk_painel(p_dias int default 2) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare eu jsonb := public.imp_op_entrar();
begin
  if eu is null or (eu->>'papel') not in ('socio','basico') then raise exception 'só a coordenação'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', j.id, 'cliente_id', j.cliente_id,
        'orient_n', (select count(*) from public.imp_cli_orient o where o.cliente_id = j.cliente_id and o.ativo
                       and (o.valido_ate is null or o.valido_ate >= j.inicio::timestamptz)),
        'itens', jsonb_array_length(coalesce(j.checklist_itens,'[]'::jsonb)),
        'ok', (select count(*) from public.imp_check_marcas m where m.job_id=j.id and m.estado in ('ok','na')),
        'problemas', (select coalesce(jsonb_agg(jsonb_build_object('item', m.item, 'nota', m.nota,
                          'titulo', (select x->>'titulo' from jsonb_array_elements(coalesce(j.checklist_itens,'[]'::jsonb)) x where x->>'id' = m.item limit 1))), '[]'::jsonb)
                        from public.imp_check_marcas m where m.job_id=j.id and m.estado='problema'),
        'pronto_em', j.checklist_pronto_em, 'extras', coalesce(j.checklist_extras,'[]'::jsonb),
        'ia_em', j.checklist_ia_em) order by j.inicio)
    from public.imp_jobs j
    where j.inicio::timestamptz between now() - interval '1 day' and now() + make_interval(days => greatest(1, least(p_dias,14)))), '[]'::jsonb);
end $$;

-- Orientações do cliente (só a coordenação grava; o operador lê pelo imp_op_lives).
-- Atualiza a lista e o "pronto" das lives abertas do cliente.
create or replace function public.imp_chk_orient_refresh(p_cliente text) returns void
language plpgsql security definer set search_path = public as $$
declare j record;
begin
  for j in select id from public.imp_jobs
            where cliente_id::text = p_cliente and status = 'aberto' and inicio::timestamptz > now() - interval '3 hours' loop
    perform public.imp_chk_garantir(j.id::text);
    perform public.imp_chk_fechar(j.id::text);
  end loop;
end $$;
revoke all on function public.imp_chk_orient_refresh(text) from public, anon, authenticated;

create or replace function public.imp_orient_listar(p_cliente text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare eu jsonb := public.imp_op_entrar();
begin
  if eu is null or (eu->>'papel') not in ('socio','basico') then raise exception 'só a coordenação'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'tipo', o.tipo, 'titulo', o.titulo, 'texto', o.texto,
            'valido_ate', o.valido_ate, 'anexos', o.anexos, 'origem', o.origem, 'ativo', o.ativo,
            'criado_em', o.criado_em, 'mudou_em', o.mudou_em, 'por', (select nome from public.imp_membros where id = o.por))
            order by o.ativo desc, o.mudou_em desc)
       from (select * from public.imp_cli_orient where cliente_id::text = p_cliente order by ativo desc, mudou_em desc limit 60) o), '[]'::jsonb);
end $$;

create or replace function public.imp_orient_salvar(p_cliente text, p_id bigint, p_tipo text, p_titulo text, p_texto text,
        p_valido_ate timestamptz default null, p_anexos jsonb default '[]'::jsonb, p_origem text default 'manual') returns bigint
language plpgsql security definer set search_path = public as $$
declare eu jsonb := public.imp_op_entrar(); v bigint; tit text; anx jsonb := coalesce(p_anexos,'[]'::jsonb); txt text := btrim(coalesce(p_texto,''));
begin
  if eu is null or (eu->>'papel') not in ('socio','basico') then raise exception 'só a coordenação'; end if;
  if p_tipo not in ('cupom','sorteio','flash','overlay','aviso','outro') then raise exception 'tipo inválido'; end if;
  if jsonb_typeof(anx) <> 'array' or jsonb_array_length(anx) > 10 then raise exception 'anexos inválidos'; end if;
  if exists (select 1 from jsonb_array_elements(anx) a where coalesce(a->>'path','') not like 'orient/' || p_cliente || '/%') then
    raise exception 'anexo fora da pasta do cliente'; end if;
  if length(txt) < 3 and jsonb_array_length(anx) = 0 then raise exception 'escreva a orientação ou anexe uma imagem'; end if;
  tit := left(coalesce(nullif(btrim(coalesce(p_titulo,'')),''), nullif(txt,''), 'Imagem'), 80);
  if p_id is null then
    insert into public.imp_cli_orient(cliente_id, tipo, titulo, texto, valido_ate, anexos, origem, por)
      select id, p_tipo, tit, left(txt, 2000), p_valido_ate, anx, case when p_origem = 'ia' then 'ia' else 'manual' end, public.imp_chk_eu()
        from public.imp_clientes where id::text = p_cliente
      returning id into v;
    if v is null then raise exception 'cliente não encontrado'; end if;
  else
    update public.imp_cli_orient set tipo = p_tipo, titulo = tit, texto = left(txt, 2000), valido_ate = p_valido_ate,
           anexos = anx, por = public.imp_chk_eu(), mudou_em = now()
     where id = p_id and cliente_id::text = p_cliente returning id into v;
    if v is null then raise exception 'orientação não encontrada'; end if;
  end if;
  perform public.imp_chk_orient_refresh(p_cliente);
  return v;
end $$;

-- Várias de uma vez (as que a IA tirou da conversa e a coordenação aprovou).
create or replace function public.imp_orient_lote(p_cliente text, p_itens jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare x jsonb; n int := 0;
begin
  if jsonb_typeof(coalesce(p_itens,'[]'::jsonb)) <> 'array' then raise exception 'lista inválida'; end if;
  for x in select * from jsonb_array_elements(p_itens) loop
    perform public.imp_orient_salvar(p_cliente, null, x->>'tipo', x->>'titulo', x->>'texto',
              nullif(x->>'valido_ate','')::timestamptz, coalesce(x->'anexos','[]'::jsonb), 'ia');
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.imp_orient_ativar(p_id bigint, p_ativo boolean) returns void
language plpgsql security definer set search_path = public as $$
declare eu jsonb := public.imp_op_entrar(); c text;
begin
  if eu is null or (eu->>'papel') not in ('socio','basico') then raise exception 'só a coordenação'; end if;
  update public.imp_cli_orient set ativo = p_ativo, mudou_em = now(), por = public.imp_chk_eu() where id = p_id returning cliente_id::text into c;
  if c is null then raise exception 'orientação não encontrada'; end if;
  perform public.imp_chk_orient_refresh(c);
end $$;

grant execute on function public.imp_op_entrar(), public.imp_op_lives(int),
  public.imp_op_marcar(text, text, text, text, text, text), public.imp_op_push_salvar(jsonb, text),
  public.imp_op_push_remover(text), public.imp_chk_extras_salvar(text, jsonb), public.imp_chk_alerta_salvar(uuid[]),
  public.imp_chk_alerta_ler(), public.imp_chk_painel(int),
  public.imp_orient_listar(text), public.imp_orient_salvar(text, bigint, text, text, text, timestamptz, jsonb, text),
  public.imp_orient_lote(text, jsonb), public.imp_orient_ativar(bigint, boolean) to authenticated;
revoke execute on function public.imp_op_entrar(), public.imp_op_lives(int),
  public.imp_op_marcar(text, text, text, text, text, text), public.imp_op_push_salvar(jsonb, text),
  public.imp_op_push_remover(text), public.imp_chk_extras_salvar(text, jsonb), public.imp_chk_alerta_salvar(uuid[]),
  public.imp_chk_alerta_ler(), public.imp_chk_painel(int),
  public.imp_orient_listar(text), public.imp_orient_salvar(text, bigint, text, text, text, timestamptz, jsonb, text),
  public.imp_orient_lote(text, jsonb), public.imp_orient_ativar(bigint, boolean) from public, anon;

-- 5) Fotos do checklist --------------------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('implay-check', 'implay-check', false) on conflict (id) do nothing;
drop policy if exists "implay_check_ler" on storage.objects;
create policy "implay_check_ler" on storage.objects for select to authenticated
  using (bucket_id = 'implay-check' and public.imp_op_entrar() is not null);
drop policy if exists "implay_check_enviar" on storage.objects;
create policy "implay_check_enviar" on storage.objects for insert to authenticated
  with check (bucket_id = 'implay-check' and public.imp_op_entrar() is not null
              and (name not like 'orient/%' or (public.imp_op_entrar()->>'papel') in ('socio','basico')));

select 'ok' as resultado;
