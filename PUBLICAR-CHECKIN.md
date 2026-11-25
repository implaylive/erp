# Publicar o check-in pré-live (passo a passo para quem tem os acessos)

Branch: `checklist-prelive` (repositório `implaylive/erp`). Projeto Supabase: `agdqlnaedojcgivwluty`.
Ordem importa: **Supabase primeiro, página no ar depois**. A página nova funciona sozinha só depois dos passos 2 a 6.

## O que você precisa ter
- Acesso de administrador ao projeto Supabase (SQL Editor, Secrets e Edge Functions).
- Supabase CLI (`brew install supabase/tap/supabase`) e Node 18+.
- Acesso de escrita ao repositório no GitHub.
- (Opcional) chave da API da Anthropic, para a IA sugerir itens e ler a conversa do grupo. Sem ela, tudo funciona, só os botões "Gerar com IA" e "Ler com IA" ficam indisponíveis.

## 1. Pegar o código
```bash
git clone https://github.com/implaylive/erp.git
cd erp
git checkout checklist-prelive
```

## 2. Gerar as chaves do push (uma vez)
```bash
npx web-push generate-vapid-keys
```
Guarde as duas. A **pública** vai na página; a **privada** só vai no Supabase (nunca no código nem em conversa).

Abra `operador/index.html`, procure `const VAPID_PUBLIC="";` e cole a chave pública entre as aspas. Faça commit e push dessa linha na mesma branch.

## 3. Banco de dados
No Supabase › **SQL Editor**, rode o conteúdo de `sql/implay_checklist_prelive.sql` inteiro. O resultado final deve ser uma linha com `ok`. Pode rodar de novo sem problema.

## 4. Secrets e funções
```bash
supabase login
supabase link --project-ref agdqlnaedojcgivwluty
supabase secrets set CRON_KEY="<texto longo e aleatório, guarde>" \
  VAPID_PUBLIC_KEY="<chave pública>" VAPID_PRIVATE_KEY="<chave privada>" \
  VAPID_SUBJECT="https://implaylive.github.io/erp/" \
  ANTHROPIC_API_KEY="<chave da Anthropic, opcional>"
supabase functions deploy check-avisos --no-verify-jwt
supabase functions deploy check-ia --no-verify-jwt
```

## 5. Agendar o aviso a cada minuto
Abra `sql/implay_checklist_cron.sql`, troque `COLE_AQUI_A_CHAVE` pelo mesmo valor do `CRON_KEY` e rode no SQL Editor. Resultado: `agendado`. Conferir em `select * from cron.job_run_details order by start_time desc limit 5;` (deve aparecer uma execução por minuto, com status `succeeded`).

## 6. Colocar a página no ar
Abra o Pull Request da branch para a `main`. O administrador (Tae) aprova e faz o merge. Em até alguns minutos a página `https://implaylive.github.io/erp/operador/` passa a responder (hoje dá 404).

## 7. Teste de ponta a ponta (com um celular)
1. No iPhone, abra o endereço acima no **Safari** › Compartilhar › **Adicionar à Tela de Início**. Abra pelo ícone novo.
2. Entre com o e-mail e a senha do ERP (a pessoa precisa ser Operador, Sócio ou CLT) e toque em **Ativar avisos**. Deve aparecer o aviso "Avisos ativados".
3. No ERP, crie uma live **daqui a 46 minutos**, com essa pessoa como **operador**. No minuto em que faltar 45, chega o aviso "Check-in da live às HH:MM" (é o push real, vindo do servidor).
4. Para ver o que seria enviado sem enviar nada: `curl -H "x-cron-key: <CRON_KEY>" "https://agdqlnaedojcgivwluty.supabase.co/functions/v1/check-avisos?simular=1&job=<id da live>&min=44"`.

Se o aviso não chegar: veja `supabase functions logs check-avisos`, confirme que o celular aparece em `select * from imp_push_subs;` e que o iPhone não está em Foco / Não Perturbe.

## 8. Depois de funcionar
- Em **Lives › Checklist do dia**, marcar quem recebe os avisos de atraso (sem ninguém marcado vão todos os sócios).
- Treinar os operadores com `operador/treinamento.html`.
- Conferir no TikTok Seller Center as regras de preço da flash sale antes de tratá-las como regra.
