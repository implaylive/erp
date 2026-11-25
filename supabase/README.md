# Check-in pré-live · publicar no Supabase (quem tem acesso ao projeto)

Ordem: SQL → secrets → funções → cron.

1. **SQL Editor**: rodar `sql/implay_checklist_prelive.sql`.
2. **Chaves de push (uma vez)**: `npx web-push generate-vapid-keys`. A chave *pública* também vai no `operador/index.html` (constante `VAPID_PUBLIC`).
3. **Secrets** (`supabase secrets set ...`):
   `CRON_KEY` (qualquer texto longo), `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` (ex.: `https://implaylive.github.io/erp/`), `ANTHROPIC_API_KEY`, opcional `CHECK_IA_MODEL`, opcional `APP_URL`.
4. **Funções**: `supabase functions deploy check-avisos --no-verify-jwt` e `supabase functions deploy check-ia --no-verify-jwt` (as duas conferem a chave ou o login por dentro).
5. **SQL Editor**: `sql/implay_checklist_cron.sql` (trocar `COLE_AQUI_A_CHAVE` pela `CRON_KEY`).
6. **Teste sem esperar**: `curl -H "x-cron-key: $CRON_KEY" "https://<projeto>.supabase.co/functions/v1/check-avisos?simular=1&job=<id da live>&min=44"` mostra o que seria enviado, sem enviar nem gravar.
