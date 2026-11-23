# ERP IMPlay

Sistema de gestão da IMPlay: https://implaylive.github.io/erp/

- `index.html`: ERP (sócios e equipe)
- `seller/`: app das sellers
- `lives/`: agenda aberta das lives

## Como propor uma mudança
1. Crie uma branch a partir da `main`.
2. Faça a mudança e abra um Pull Request.
3. A mudança só entra no ar depois de aprovada pelo administrador.

## Mudanças no banco (Supabase)
Quando uma mudança precisa de SQL novo, o arquivo fica em `sql/` e alguém com acesso ao Supabase roda no SQL Editor **antes** de a mudança entrar no ar. Pode rodar de novo sem estragar nada.
- `sql/implay_calendario_sugestoes.sql` (v77): sugestões do cliente no calendário da marca.
