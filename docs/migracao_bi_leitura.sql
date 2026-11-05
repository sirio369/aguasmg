-- Login genérico de leitura para os BIs (2026-11-05)
-- bi_leitura = o ÚNICO login que os relatórios Power BI usam (somente leitura, timeout 60 s).
-- As permissões ficam em grupos por área, sem login: bi_qsms_leitura (views bi_sst_*). BI novo = criar o grupo
-- bi_<area>_leitura com SELECT nas views dele e `grant bi_<area>_leitura to bi_leitura`.
-- A senha é definida pelo usuário no SQL Editor: alter role bi_leitura password '...';

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'bi_leitura') then
    create role bi_leitura login inherit;
  end if;
end $$;
alter role bi_leitura set default_transaction_read_only = on;
alter role bi_leitura set statement_timeout = '60s';
grant connect on database postgres to bi_leitura;

-- o login antigo do QSMS vira só grupo de permissão
alter role bi_qsms_leitura nologin;
grant bi_qsms_leitura to bi_leitura;
