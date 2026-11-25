-- IMPlay · v95 · agenda a Edge Function check-avisos a cada minuto.
-- Rode DEPOIS de rodar implay_checklist_prelive.sql e de publicar a função (veja supabase/README.md).
-- 1) Troque COLE_AQUI_A_CHAVE pela mesma chave que você guardou no secret CRON_KEY da função.
-- 2) Rode. Pode rodar de novo (troca o agendamento, não duplica).
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- sempre regrava a chave (assim, se alguém rodou antes com a chave errada, rodar de novo conserta)
delete from vault.secrets where name = 'check_cron_key';
select vault.create_secret('COLE_AQUI_A_CHAVE', 'check_cron_key');

select cron.unschedule(jobid) from cron.job where jobname = 'implay-check-avisos';
select cron.schedule('implay-check-avisos', '* * * * *', $cmd$
  select net.http_post(
    url := 'https://agdqlnaedojcgivwluty.supabase.co/functions/v1/check-avisos',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-key', (select decrypted_secret from vault.decrypted_secrets where name = 'check_cron_key')),
    body := '{}'::jsonb, timeout_milliseconds := 20000);
$cmd$);
select 'agendado' as resultado;
