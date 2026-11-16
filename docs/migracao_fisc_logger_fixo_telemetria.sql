-- Consolidador: "Logger fixo — instalação" e "Telemetria" eram o mesmo serviço contado 2×.
-- A OS SIGOS 2807900 (EQUIP.DE TELEMETRIA INST.CONT.PERF.PERDA = instalação de logger definitivo) não casava com o
-- logger do app porque fisc_execucoes lia o campo antigo os_copasa_instalacao; o app grava a OS em os_sigos desde a
-- OS obrigatória (docs/migracao_logger_os_sigos.sql).
-- APLICADO em produção em 2026-11-16 (via MCP). Backup: "12 - retaguarda"._bkp_funcdef_20261116 (def antiga de fisc_execucoes).
do $mig$
declare d text; d0 text;
begin
  d0 := pg_get_functiondef('public.fisc_execucoes'::regproc);
  create table if not exists "12 - retaguarda"._bkp_funcdef_20261116 (nome text, def text, em timestamptz default now());
  insert into "12 - retaguarda"._bkp_funcdef_20261116(nome, def) values ('fisc_execucoes', d0);
  d := d0;
  -- 1) OS do logger (os_sigos, fallback no campo antigo) é atributo da execução do app → a OS SIGOS não vira linha própria
  d := replace(d, $a$    union select public.sigos_os_base(l.os_copasa_instalacao) from "8 - coleta_campo".instalacao_logger_calibracao l where l.data_instalacao is not null$a$,
                  $a$    union select public.sigos_os_base(coalesce(nullif(trim(l.os_sigos), ''), l.os_copasa_instalacao)) from "8 - coleta_campo".instalacao_logger_calibracao l where l.data_instalacao is not null$a$);
  -- 2) instalação: OS mostrada e situação no SIGOS pelo os_sigos
  d := replace(d, $a$           1::numeric, 'un', null::text, l.os_copasa_instalacao,
           coalesce(t.txt, case when l.os_copasa_instalacao is null then$a$,
                  $a$           1::numeric, 'un', null::text, coalesce(nullif(trim(l.os_sigos), ''), l.os_copasa_instalacao),
           coalesce(t.txt, case when coalesce(nullif(trim(l.os_sigos), ''), l.os_copasa_instalacao) is null then$a$);
  d := replace(d, $a$      left join sg_txt t on t.base = public.sigos_os_base(l.os_copasa_instalacao)$a$,
                  $a$      left join sg_txt t on t.base = public.sigos_os_base(coalesce(nullif(trim(l.os_sigos), ''), l.os_copasa_instalacao))$a$);
  -- 3) OS 2807900 sem logger no app → mesma linha "Logger fixo — instalação", em un
  d := replace(d, $a$    select s.d, s.z, s.fam, 'sigos:' || s.numero, 'SIGOS',$a$,
                  $a$    select s.d, s.z, case when s.cod = '2807900' then 'Logger fixo — instalação' else s.fam end, 'sigos:' || s.numero, 'SIGOS',$a$);
  d := replace(d, $a$           1::numeric, 'OS', null::text, s.numero,$a$,
                  $a$           1::numeric, case when s.cod = '2807900' then 'un' else 'OS' end, null::text, s.numero,$a$);
  if position('l.os_copasa_instalacao,
           coalesce(t.txt' in d) > 0
     or position('sg_txt t on t.base = public.sigos_os_base(l.os_copasa_instalacao)' in d) > 0
     or position('base(l.os_copasa_instalacao) from' in d) > 0
     or position('else s.fam end' in d) = 0
     or position('''un'' else ''OS'' end' in d) = 0
  then raise exception 'patch incompleto'; end if;
  execute d;
end $mig$;

-- Conferência (ZA0200, 16/11/2026): sem linha "Telemetria"; Logger fixo — instalação acumulado 74 un
-- (71 do app + 3 OS 2807900 sem logger no app).
