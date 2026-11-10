-- RDO: Recadastramento e Fiscalização de irregularidade num bloco só por dia × ZA (10/11/2026)
-- Antes: uma linha "Execução" (sigos:exec:<família>) + uma linha "Pendência" (sigos:nexec:<família>).
-- Agora, para essas duas famílias: uma linha só, chave sigos:exec:<família>, tipo Execução, com
-- "N OS executadas, M OS encerradas sem execução (com/sem visita): quebra por serviço" e o detalhe
-- (código → OS) unificado. As demais famílias seguem como antes.
-- Aplicada reescrevendo a definição atual de public.rdo_eventos (substituições conferidas uma a uma).
do $mig$
declare
  d text := pg_get_functiondef('public.rdo_eventos(date,date)'::regprocedure);
  a text; b text; i int;
  subs text[][] := array[
    [$a$s.cod_servico cod, s.desc_servico
      from$a$,
     $b$s.cod_servico cod, s.desc_servico,
           case when public.sigos_servico_grupo(s.desc_servico) in ('Recadastramento', 'Fiscalização de irregularidade')
                then 'todas' else s.situacao end sk   -- famílias que viram um bloco só (executadas + encerradas sem execução)
      from$b$],
    [$a$select d, z, grp, sit, jsonb_agg(jsonb_build_object('cod', cod, 'oss', oss) order by cod) det$a$,
     $b$select d, z, grp, sk, jsonb_agg(jsonb_build_object('cod', cod, 'oss', oss) order by cod) det$b$],
    [$a$select sg.d, sg.z, sg.grp, sg.sit, coalesce$a$, $b$select sg.d, sg.z, sg.grp, sg.sk, coalesce$b$],
    [$a$select d, z, grp, sit, public.sigos_servico_nome(desc_servico) srv$a$, $b$select d, z, grp, sk, public.sigos_servico_nome(desc_servico) srv$b$],
    [$a$select d, z, grp, sit, ': ' || string_agg$a$, $b$select d, z, grp, sk, ': ' || string_agg$b$],
    [$a$q.sit = x.sit$a$, $b$q.sk = x.sk$b$],
    [$a$sd.sit = x.sit$a$, $b$sd.sk = x.sk$b$],
    [$a$where x.sit = 'executada'$a$, $b$where x.sk = 'executada'$b$],
    [$a$where x.sit = 'encerrada_sem_execucao' group by x.d, x.z, x.grp, sd.det$a$,
     $b$where x.sk = 'encerrada_sem_execucao' group by x.d, x.z, x.grp, sd.det
    union all   -- Recadastramento / Fiscalização: executadas + encerradas sem execução numa linha
    select x.d, x.z, 'sigos:exec:' || x.grp, 'Execução', 'SIGOS', public.rdo_familia_ordem(x.grp) * 10,
           x.grp || ' — ' || concat_ws(', ',
             nullif(count(*) filter (where x.sit = 'executada'), 0)
               || case when count(*) filter (where x.sit = 'executada') = 1 then ' OS executada' else ' OS executadas' end,
             nullif(count(*) filter (where x.sit = 'encerrada_sem_execucao'), 0)
               || case when count(*) filter (where x.sit = 'encerrada_sem_execucao') = 1 then ' OS encerrada' else ' OS encerradas' end
               || ' sem execução'
               || coalesce(' (' || nullif(concat_ws(', ',
                    nullif(count(*) filter (where x.sit = 'encerrada_sem_execucao' and x.st ilike '%C/ VISITA%'), 0) || ' com visita',
                    nullif(count(*) filter (where x.sit = 'encerrada_sem_execucao' and x.st ilike '%S/ VISITA%'), 0) || ' sem visita'), '') || ')', ''))
             || min(q.q),
           count(*)::numeric,
           sd.det
      from sg_extra x join sg_que q on q.d = x.d and q.z = x.z and q.grp = x.grp and q.sk = x.sk
      join sg_det sd on sd.d = x.d and sd.z = x.z and sd.grp = x.grp and sd.sk = x.sk
     where x.sk = 'todas' group by x.d, x.z, x.grp, sd.det$b$]
  ];
begin
  if position('''todas''' in d) > 0 then raise notice 'já aplicada'; return; end if;
  for i in 1 .. array_length(subs, 1) loop
    a := subs[i][1]; b := subs[i][2];
    if position(a in d) = 0 then raise exception 'trecho % não encontrado: %', i, left(a, 60); end if;
    d := replace(d, a, b);
  end loop;
  execute d;
end $mig$;
