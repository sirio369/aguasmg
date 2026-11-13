-- Consolidador › Pesquisa de vazamento: TRAÇADO DE CAMPO SEGUE O SIGOS (2026-11-13)
-- Pedido do usuário: a atividade é executada num dia e registrada no SIGOS depois; a medição é pelo SIGOS → seguir o SIGOS.
-- O traçado (km pesquisados por colaborador × dia, AcquaHub) se liga à OS SIGOS do dia lançada no Relatório diário da pesquisa
-- ("12 - retaguarda".pesquisa_dia_os). OS já executada no SIGOS → o traçado vai para o dia da OS no SIGOS e conta os km lá
-- (os_sigos = OS, extra._campo = dia do campo). Sem OS executada → fica no dia do campo com 0 km e situação "aguardando
-- execução no SIGOS" / "sem OS SIGOS lançada" (extra._aguarda), fora do hash da linha (fisc_linhas) → não marca "mudou".
-- Nenhuma linha de Pesquisa validada até hoje e nenhum dia validado (set/2026) tem pesquisa → nada validado muda.
-- Patch textual sobre a definição vigente (mesmo padrão de migracao_fisc_loggers.sql); falha se algum trecho não casar.

-- 1) fisc_execucoes: e_pq com janela maior + pq_os/pq_sg + e_pesq seguindo o SIGOS
do $mig$
declare d text; d0 text;
begin
  d0 := pg_get_functiondef('public.fisc_execucoes(date,date)'::regprocedure);
  d := d0;
  d0 := d;
  d := replace(d0, $a$     where e.executado_em is not null
       and (e.executado_em at time zone 'America/Sao_Paulo')::date between p_de and p_ate
     group by 1, 2, 3
  ),
$a$,
    $a$     where e.executado_em is not null
       -- o traçado vai para o dia da OS no SIGOS (até ~90 dias depois do campo) → janela do campo começa antes
       and (e.executado_em at time zone 'America/Sao_Paulo')::date between p_de - 90 and p_ate
     group by 1, 2, 3
  ),
  -- OS SIGOS do dia lançada pelo backoffice no Relatório diário da pesquisa (colaborador × dia × consórcio);
  -- consórcio vazio = lançamento antigo, vale se não houver o do consórcio
  pq_os as (
    select q.d, q.z, q.u, x.os_sigos os, public.sigos_os_base(x.os_sigos) b
      from e_pq q
      join lateral (select o.os_sigos from "12 - retaguarda".pesquisa_dia_os o
                     where o.colaborador_uuid = q.u and o.dia = q.d and coalesce(o.consorcio, '') in (q.z, '')
                       and nullif(trim(o.os_sigos), '') is not null
                     order by (o.consorcio = q.z) desc limit 1) x on true
  ),
  pq_sg as (   -- OS da pesquisa que já conta no SIGOS: data do SIGOS manda (medição é pelo SIGOS)
    select distinct on (o.b) o.b, s.numero, s.d from pq_os o join sgc s on s.base = o.b order by o.b, s.d
  ),
$a$);
  if d = d0 then raise exception 'public.fisc_execucoes(date,date): trecho 1 não encontrado'; end if;
  d0 := d;
  d := replace(d0, $a$  e_pesq as (
    select q.d, q.z, 'Pesquisa de vazamento', 'app:pesquisa:' || coalesce(q.u::text, '-') || ':' || q.d, 'AcquaHub',
           'Rede pesquisada',
           replace(round(q.m / 1000.0, 2)::text, '.', ',') || ' km de rede pesquisados (' || q.n || ' trecho' || case when q.n = 1 then '' else 's' end || ')',
           null::text, p.nome,
           to_char(q.t0 at time zone 'America/Sao_Paulo', 'HH24:MI') || '–' || to_char(q.t1 at time zone 'America/Sao_Paulo', 'HH24:MI'),
           round(q.m / 1000.0, 3), 'km', null::text, null::text, null::text, '{}'::text[], q.g, '{}'::jsonb
      from e_pq q left join public.perfil p on p.id = q.u
  ),
$a$,
    $a$  -- traçado de campo (km pesquisados) SEGUE O SIGOS (13/11/2026): com OS do dia executada no SIGOS → entra no dia da OS no SIGOS e
  -- conta os km ali (o front aninha o traçado no card da OS); sem isso → fica no dia do campo, 0 km, "aguardando SIGOS"
  -- (extra._aguarda, fora do hash da linha). extra._campo = dia do campo quando ele mudou de dia.
  e_pesq as (
    select coalesce(s.d, q.d), q.z, 'Pesquisa de vazamento', 'app:pesquisa:' || coalesce(q.u::text, '-') || ':' || q.d, 'AcquaHub',
           'Rede pesquisada',
           replace(round(q.m / 1000.0, 2)::text, '.', ',') || ' km de rede pesquisados (' || q.n || ' trecho' || case when q.n = 1 then '' else 's' end || ')',
           null::text, p.nome,
           to_char(q.t0 at time zone 'America/Sao_Paulo', 'HH24:MI') || '–' || to_char(q.t1 at time zone 'America/Sao_Paulo', 'HH24:MI'),
           case when s.b is not null then round(q.m / 1000.0, 3) else 0 end, 'km', null::text, coalesce(s.numero, o.os),
           case when s.b is not null then t.txt
                when o.os is not null then 'aguardando execução no SIGOS'
                else 'sem OS SIGOS lançada no Relatório diário' end,
           '{}'::text[], q.g,
           case when s.b is null then jsonb_build_object('_aguarda', true)
                when s.d <> q.d then jsonb_build_object('_campo', q.d)
                else '{}'::jsonb end
      from e_pq q left join public.perfil p on p.id = q.u
      left join pq_os o on o.d = q.d and o.z = q.z and o.u is not distinct from q.u
      left join pq_sg s on s.b = o.b
      left join sg_txt t on t.base = s.b
  ),
$a$);
  if d = d0 then raise exception 'public.fisc_execucoes(date,date): trecho 2 não encontrado'; end if;
  execute d;
end $mig$;

-- 2) fisc_linhas: traçado aguardando SIGOS (extra._aguarda) fora do hash da linha
do $mig$
declare d text; d0 text;
begin
  d0 := pg_get_functiondef('public.fisc_linhas(date,date,text)'::regprocedure);
  d := d0;
  d0 := d;
  d := replace(d0, $a$           md5(string_agg(e.exec_id || '|' || coalesce(e.descricao, '') || '|' || e.qtd || '|' || coalesce(e.sigos_sit, ''), '§' order by e.exec_id)) h
$a$,
    $a$           md5(coalesce(string_agg(e.exec_id || '|' || coalesce(e.descricao, '') || '|' || e.qtd || '|' || coalesce(e.sigos_sit, ''), '§' order by e.exec_id)
                 filter (where not coalesce(e.extra ? '_aguarda', false)), '')) h   -- traçado aguardando SIGOS não entra
$a$);
  if d = d0 then raise exception 'public.fisc_linhas(date,date,text): trecho 1 não encontrado'; end if;
  execute d;
end $mig$;
