-- IMPlay · v88 · Desempenho da live (visualizações, seguidores, nota, prints…)
-- GMV, pedidos e horário real já existem em imp_jobs; aqui só entra o resto.
alter table public.imp_jobs add column if not exists desempenho jsonb;
select 'ok' as resultado;
