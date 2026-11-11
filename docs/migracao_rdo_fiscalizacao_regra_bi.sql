-- RDO + Vitrine: Fiscalização de irregularidade com a MESMA regra do BI Dashboard Producao (2026-11-11)
--
-- Regra do BI (consulta qRealizado + tabela dCodigo + aba Regras do Parametros_Modelo.xlsx):
--   * 676 79 00 (VISTORIA DE IMOVEL CONT.PERF.PERDAS) = fiscalização de fraudes/irregularidades, sempre (ação 4.2.7);
--   * 152 05 00 (CONF. DE INFRACAO VIOL.TAMP.S/RET.HIDR) só conta como fiscalização se a OS foi GERADA até 31/10/2026
--     (Regras[fiscalizacao_152_gerada_ate]); depois é Suporte = confirmação da infração;
--   * na fiscalização conta EXECUTADA **e** "NÃO EXEC. C/ VISITA" (Regras[fiscalizacao_status_extra]); sem visita não conta.
--
-- No app:
--   * public.sigos_familia(cod, desc, abertura) = família da OS com essa exceção; o resto continua sigos_servico_grupo(desc);
--   * os CONF. DE INFRACAO que não são fiscalização viram a família nova "Confirmação de fraude" (Suporte), mostrada à parte
--     para ver as duas coisas: primeiro a fiscalização, depois a OS de confirmação;
--   * public.sigos_conta(familia, situacao, status) = a OS conta como feita (executada; na fiscalização também c/ visita);
--   * rdo_eventos: linha própria da Fiscalização ("N fiscalizações (x executadas, y não executadas com visita)";
--     sem visita aparece à parte e não conta); Confirmação de fraude segue o bloco único (executadas + encerradas sem execução);
--   * app_vitrine_feed: família pela regra; fiscalização c/ visita entra no total; fraude registrada na pesquisa (ocorrência
--     do app) deixa de somar na Fiscalização e vai para Pesquisa de vazamento (igual ao RDO).
-- app_vitrine_sigos / app_vitrine_dados (só app em cache antigo) e app_sigos_abertas não mudam.

create or replace function public.sigos_fisc_corte() returns date
language sql immutable as $$ select date '2026-10-31' $$;   -- = Regras[fiscalizacao_152_gerada_ate] do BI

create or replace function public.sigos_familia(p_cod text, p_desc text, p_abertura timestamp)
returns text language sql immutable set search_path to 'public' as $$
  select case
    when c = '6767900' then 'Fiscalização de irregularidade'
    when c = '1520500' and p_abertura is not null and p_abertura::date <= public.sigos_fisc_corte() then 'Fiscalização de irregularidade'
    when p_desc ~* '^CONF\.? DE INFRACAO' then 'Confirmação de fraude'
    when p_desc ~* '^VISTORIA DE IMOVEL' then 'Vistoria de imóvel'   -- só o 676 79 00 é fiscalização
    else public.sigos_servico_grupo(p_desc) end
  from (select lpad(regexp_replace(coalesce(p_cod, ''), '\D', '', 'g'), 7, '0') c) t
$$;

create or replace function public.sigos_conta(p_familia text, p_situacao text, p_status text)
returns boolean language sql immutable as $$
  select p_situacao = 'executada'
      or (p_familia = 'Fiscalização de irregularidade' and upper(btrim(coalesce(p_status, ''))) = 'NÃO EXEC. C/ VISITA')
$$;

revoke all on function public.sigos_fisc_corte(), public.sigos_familia(text, text, timestamp), public.sigos_conta(text, text, text) from public, anon;

create or replace function public.rdo_familia_ordem(p_grupo text)
 returns integer language sql immutable as $function$
  select case p_grupo
    when 'Pesquisa de vazamento' then 10 when 'Loggers de pressão' then 20 when 'VRP' then 30 when 'Telemetria' then 35
    when 'Recomposição de pavimento' then 40 when 'Ramal predial' then 45 when 'Manobra de registro' then 47 when 'Rede de água' then 48
    when 'Troca de hidrômetro' then 50 when 'Fiscalização de irregularidade' then 60 when 'Confirmação de fraude' then 62 when 'Vistoria de imóvel' then 65
    when 'Recadastramento' then 70 when 'Padrão de ligação' then 75 when 'Mobilização social' then 78 when 'Atendimento comercial' then 80 when 'Obras (projetos)' then 90
    else 85 end;
$function$;

-- troca de trechos conferida (aborta se o trecho não aparecer o nº de vezes esperado)
create or replace function pg_temp.rep(t text, a text, b text, n int default 1) returns text language plpgsql as $$
declare k int := (length(t) - length(replace(t, a, ''))) / greatest(length(a), 1);
begin
  if k <> n then raise exception 'trecho achado % vez(es), esperado %: %', k, n, left(a, 90); end if;
  return replace(t, a, b);
end $$;

do $mig$
declare d text;
begin
  -- ---------- rdo_eventos
  d := pg_get_functiondef('public.rdo_eventos(date,date)'::regprocedure);
  if position('sigos_familia' in d) = 0 then
    d := pg_temp.rep(d, $a$public.sigos_servico_grupo(s.desc_servico) grp$a$,
                        $a$public.sigos_familia(s.cod_servico, s.desc_servico, s.abertura) grp$a$);
    d := pg_temp.rep(d, $a$select sg.*, coalesce(e.matricula, a.matricula) mat$a$,
                        $a$select sg.*, public.sigos_conta(sg.grp, sg.sit, sg.st) conta, coalesce(e.matricula, a.matricula) mat$a$);
    d := pg_temp.rep(d, $a$     where x.sk = 'todas' group by x.d, x.z, x.grp, sd.det$a$,
$a$     where x.sk = 'todas' and x.grp <> 'Fiscalização de irregularidade' group by x.d, x.z, x.grp, sd.det
    union all   -- Fiscalização de irregularidade = regra do BI Produção: conta EXECUTADA + NÃO EXEC. C/ VISITA; sem visita não conta
    select x.d, x.z, 'sigos:exec:' || x.grp,
           case when count(*) filter (where x.conta) = 0 then 'Pendência' else 'Execução' end, 'SIGOS', public.rdo_familia_ordem(x.grp) * 10,
           x.grp || ' — ' || count(*) filter (where x.conta)
             || case when count(*) filter (where x.conta) = 1 then ' fiscalização' else ' fiscalizações' end
             || coalesce(' (' || nullif(concat_ws(', ',
                  nullif(count(*) filter (where x.sit = 'executada'), 0)
                    || case when count(*) filter (where x.sit = 'executada') = 1 then ' executada' else ' executadas' end,
                  nullif(count(*) filter (where x.sit <> 'executada' and x.conta), 0)
                    || case when count(*) filter (where x.sit <> 'executada' and x.conta) = 1 then ' não executada com visita' else ' não executadas com visita' end), '') || ')', '')
             || coalesce('; ' || nullif(count(*) filter (where not x.conta), 0)
                  || case when count(*) filter (where not x.conta) = 1 then ' OS sem visita (não conta)' else ' OS sem visita (não contam)' end, '')
             || min(q.q),
           (count(*) filter (where x.conta))::numeric,
           sd.det
      from sg_extra x join sg_que q on q.d = x.d and q.z = x.z and q.grp = x.grp and q.sk = x.sk
      join sg_det sd on sd.d = x.d and sd.z = x.z and sd.grp = x.grp and sd.sk = x.sk
     where x.sk = 'todas' and x.grp = 'Fiscalização de irregularidade' group by x.d, x.z, x.grp, sd.det$a$);
    execute d;
  end if;

  -- ---------- app_vitrine_feed
  d := pg_get_functiondef('public.app_vitrine_feed(date)'::regprocedure);
  if position('sigos_familia' in d) = 0 then
    d := pg_temp.rep(d, $a$case when o.tipo ilike 'Fraude%' then 'Fiscalização de irregularidade' else 'Pesquisa de vazamento' end$a$,
                        $a$'Pesquisa de vazamento'::text$a$);   -- fraude registrada na pesquisa fica na pesquisa (fiscalização = só SIGOS)
    d := pg_temp.rep(d, $a$public.sigos_servico_grupo(s.desc_servico) f$a$,
                        $a$public.sigos_familia(s.cod_servico, s.desc_servico, s.abertura) f$a$);
    d := pg_temp.rep(d, $a$s.data_execucao ts, s.situacao sit$a$,
                        $a$s.data_execucao ts, s.situacao sit,
           public.sigos_conta(public.sigos_familia(s.cod_servico, s.desc_servico, s.abertura), s.situacao, s.status_sigos) conta$a$);
    d := pg_temp.rep(d, $a$where sg.sit = 'executada' and sg.base not in (select base from dup)$a$,
                        $a$where sg.conta and sg.base not in (select base from dup)$a$);
    d := pg_temp.rep(d, $a$from sg where sit <> 'executada' group by 1, 2, 3$a$,
                        $a$from sg where not conta group by 1, 2, 3$a$);
    d := pg_temp.rep(d, $a$public.sigos_servico_grupo(a.desc_servico) f$a$,
                        $a$public.sigos_familia(a.cod_servico, a.desc_servico, a.abertura) f$a$);
    execute d;
  end if;
end $mig$;
