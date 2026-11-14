-- =====================================================================
-- RH — acesso por tela (⚙️ do hub RH, só admin) + módulo sai de "Em desenvolvimento" para Suporte
-- perfil.rh_telas text[] ⊂ {modulo, colab, val, analise}; a Carga RH continua em perfil.rh_acesso
-- (rh_acesso = "visão RH": carrega, vê todos na Validação/Análise e valida/devolve).
-- rh_tela(uid, tela): admin sempre; senão perfil ativo + 'modulo' + a tela ('carga' = rh_acesso).
-- Seed: quem usa o RH hoje (dev_acesso + aprovador/rh_acesso) mantém módulo + telas que já via.
-- =====================================================================
alter table public.perfil add column if not exists rh_telas text[] not null default '{}';
alter table public.perfil drop constraint if exists perfil_rh_telas_ck;
alter table public.perfil add constraint perfil_rh_telas_ck check (rh_telas <@ array['modulo','colab','val','analise']::text[]);

create or replace function public.rh_tela(p_uid uuid, p_tela text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.funcao = 'admin'
      or (coalesce(p.ativo, true) and 'modulo' = any(p.rh_telas)
          and case when p_tela = 'carga' then coalesce(p.rh_acesso, false)
                   when p_tela = 'modulo' then true
                   else p_tela = any(p.rh_telas) end)
    from public.perfil p where p.id = p_uid), false);
$$;
revoke all on function public.rh_tela(uuid, text) from public, anon;
grant execute on function public.rh_tela(uuid, text) to authenticated;

-- seed (só quem ainda não tem nada marcado)
update public.perfil p set rh_telas = array_remove(array['modulo',
       case when p.funcao = 'aprovador' then 'colab' end, 'val', 'analise'], null)
 where coalesce(p.dev_acesso, false) and coalesce(p.ativo, true) and p.funcao <> 'admin'
   and (p.funcao = 'aprovador' or coalesce(p.rh_acesso, false)) and p.rh_telas = '{}';

-- ⚙️: lista com as telas de cada um
drop function if exists public.app_rh_acesso_listar();
create or replace function public.app_rh_acesso_listar()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not exists(select 1 from public.perfil where id = auth.uid() and funcao = 'admin') then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'email', email, 'cargo', cargo, 'ativo', ativo,
      'admin', funcao = 'admin', 'aprovador', funcao in ('aprovador','admin'),
      'rh', funcao = 'admin' or coalesce(rh_acesso, false), 'telas', rh_telas)
      order by (funcao = 'admin') desc, cardinality(rh_telas) > 0 desc, coalesce(nome, email))
    from public.perfil where coalesce(ativo, true) or cardinality(rh_telas) > 0 or coalesce(rh_acesso, false)), '[]'::jsonb);
end $$;

-- ⚙️: marca/desmarca uma tela ('modulo' | 'colab' | 'carga' | 'val' | 'analise').
-- Marcar uma tela já libera o módulo; tirar o módulo tira todas as telas (inclusive a Carga RH).
create or replace function public.app_rh_tela_set(p_uuid uuid, p_tela text, p_on boolean)
returns jsonb language plpgsql volatile security definer set search_path to 'public' as $$
declare r public.perfil%rowtype;
begin
  if not exists(select 1 from public.perfil where id = auth.uid() and funcao = 'admin') then raise exception 'sem permissão'; end if;
  if p_tela not in ('modulo','colab','carga','val','analise') then raise exception 'tela inválida'; end if;
  select * into r from public.perfil where id = p_uuid for update;
  if not found then raise exception 'usuário não encontrado'; end if;
  if p_tela = 'modulo' and not p_on then
    update public.perfil set rh_telas = '{}', rh_acesso = false where id = p_uuid;
  elsif p_tela = 'carga' then
    update public.perfil set rh_acesso = p_on,
      rh_telas = case when p_on and not 'modulo' = any(rh_telas) then rh_telas || 'modulo'::text else rh_telas end where id = p_uuid;
  elsif p_on then
    update public.perfil set rh_telas = (select array_agg(distinct t) from unnest(rh_telas || array['modulo', p_tela]) t) where id = p_uuid;
  else
    update public.perfil set rh_telas = array_remove(rh_telas, p_tela) where id = p_uuid;
  end if;
  select * into r from public.perfil where id = p_uuid;
  return jsonb_build_object('telas', r.rh_telas, 'rh', coalesce(r.rh_acesso, false));
end $$;
revoke all on function public.app_rh_tela_set(uuid, text, boolean) from public, anon;
grant execute on function public.app_rh_tela_set(uuid, text, boolean) to authenticated;
revoke all on function public.app_rh_acesso_listar() from public, anon;
grant execute on function public.app_rh_acesso_listar() to authenticated;

-- ---------------------------------------------------------------- app_me + RPCs com o gate por tela (mesmas assinaturas)
CREATE OR REPLACE FUNCTION public.app_me()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid := auth.uid(); v_email text := coalesce(auth.jwt() ->> 'email',''); v_p public.perfil%rowtype; v_adm boolean; v_areas text[];
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  insert into public.perfil (id, email, nome, funcao) values (v_id, v_email, nullif(initcap(replace(split_part(v_email,'@',1),'.',' ')),''), 'campo') on conflict (id) do nothing;
  select * into v_p from public.perfil where id=v_id;
  v_adm := (v_p.funcao='admin');
  v_areas := array(select area from "9 - suprimentos".sup_acesso_area where colaborador_uuid=v_id);
  return jsonb_build_object('id',v_p.id,'email',v_p.email,'nome',v_p.nome,'cargo',v_p.cargo,'funcao',v_p.funcao,
    'is_admin',v_adm, 'is_almoxarife',(v_p.funcao in ('almoxarife','admin')), 'pode_aprovar',(v_p.funcao in ('aprovador','admin')),
    'frota_admin',coalesce(v_p.frota_admin,false), 'pessoas_admin',coalesce(v_p.pessoas_admin,false),
    'dev_acesso',(v_adm or coalesce(v_p.dev_acesso,false)),
    'proj_sup',(v_adm or coalesce(v_p.proj_sup_acesso,false)),
    'proj_obras',"13 - projetos_obra".proj_obras_pode(v_id),
    'vrp_gestao',(v_adm or coalesce(v_p.vrp_gestao_acesso,false) or coalesce(v_p.aux_acesso,false)),
    'aux_acesso',(v_adm or coalesce(v_p.aux_acesso,false)),
    'qsms',"16 - qsms".qsms_pode(v_id),
    'qsms_campo',"16 - qsms".sst_campo_pode(v_id),
    'qualidade',"8 - coleta_campo".pav_qualidade_pode(v_id),
    'epi_gestor',"9 - suprimentos".sup_epi_gestor(v_id),
    'sup_areas', jsonb_build_object('baixas', v_adm or ('baixas'=any(v_areas)), 'insumo', v_adm or ('insumo'=any(v_areas)), 'equip', v_adm or ('equip'=any(v_areas)), 'epi', v_adm or ('epi'=any(v_areas)), 'ferramenta', v_adm or ('ferramenta'=any(v_areas)), 'controle', v_adm or ('controle'=any(v_areas))),
    'fisc_acesso',(v_adm or v_p.funcao='fiscal' or coalesce(v_p.fisc_acesso,false)),
    'is_fiscal',(v_p.funcao='fiscal'),
    'rh_acesso',(v_adm or (coalesce(v_p.rh_acesso,false) and coalesce(v_p.ativo,true))),
    'rh_telas',to_jsonb(case when v_adm then array['modulo','colab','val','analise'] when coalesce(v_p.ativo,true) then coalesce(v_p.rh_telas,'{}') else '{}'::text[] end),
    'equipes','[]'::jsonb);
end $function$;

CREATE OR REPLACE FUNCTION public.app_rh_val_lista(p_ini date, p_fim date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', '18 - rh'
AS $function$
declare v_uid uuid := auth.uid(); v_rh boolean;
begin
  if v_uid is null then raise exception 'não autenticado'; end if;
  v_rh := public.rh_pode_carregar(v_uid);
  if not public.rh_tela(v_uid, 'val') then raise exception 'sem permissão'; end if;
  if p_fim < p_ini or p_fim - p_ini > 92 then raise exception 'período inválido (máx. 3 meses)'; end if;
  return jsonb_build_object('rh', v_rh, 'itens', coalesce((select jsonb_agg(jsonb_build_object(
      'fid', f.id, 'nome', f.nome, 'matricula', f.matricula, 'sigla', e.sigla, 'consorcio', e.consorcio,
      'gestor', coalesce(g1.nome, g1.email), 'gestor2', coalesce(g2.nome, g2.email), 'sem_usuario', f.perfil_id is null,
      'data', i.data, 'tipos', i.tipos, 'interjornada_min', i.interjornada_min,
      'dia_semana', pd.dia_semana, 'horario', pd.horario, 'marcacoes', pd.marcacoes, 'htrab', pd.htrab_min, 'he', pd.he_min,
      'falta', pd.falta_min, 'atraso', pd.atraso_min, 'justificativa', pd.justificativa, 'versao', pd.versao,
      'trat', case when t.funcionario_id is null then null else jsonb_build_object(
        'acao', t.acao, 'marcacoes', t.marcacoes, 'motivo', t.motivo, 'obs', t.obs, 'status', t.status,
        'gestor', coalesce(pg.nome, pg.email), 'gestor_em', t.gestor_em, 'versao_dia', t.versao_dia,
        'rh', coalesce(pr.nome, pr.email), 'rh_em', t.rh_em, 'rh_obs', t.rh_obs,
        'kairos_atualizado', pd.versao > coalesce(t.versao_dia, pd.versao),
        'kairos_bate', case t.acao when 'ajustar' then pd.marcacoes = t.marcacoes
                                    when 'falta' then pd.falta_min > 0
                                    when 'justificar' then case when t.tipos && array['falta','falta_pos_deslig'] then pd.falta_min = 0 end
                                    else null end) end)
      order by f.nome, i.data)
    from "18 - rh".inconsistencias(p_ini, p_fim) i
    join func_visiveis(v_uid) fv on fv.funcionario_id = i.funcionario_id
    join "18 - rh".funcionario f on f.id = i.funcionario_id
    join "18 - rh".empresa e on e.cnpj = f.cnpj
    join "18 - rh".ponto_dia pd on pd.funcionario_id = i.funcionario_id and pd.data = i.data
    left join public.perfil p on p.id = f.perfil_id
    left join public.perfil g1 on g1.id = p.aprovador_uuid
    left join public.perfil g2 on g2.id = p.aprovador2_uuid
    left join "18 - rh".tratativa t on t.funcionario_id = i.funcionario_id and t.data = i.data
    left join public.perfil pg on pg.id = t.gestor_uuid
    left join public.perfil pr on pr.id = t.rh_uuid), '[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION public.app_rh_val_tratar(p_funcionario bigint, p_data date, p_acao text, p_marcacoes text[] DEFAULT NULL::text[], p_motivo text DEFAULT NULL::text, p_obs text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', '18 - rh'
AS $function$
declare v_uid uuid := auth.uid(); v_tipos text[]; v_ver int; v_st text; m text; prev int := -1;
begin
  if v_uid is null or not public.rh_tela(v_uid, 'val') or not exists(select 1 from func_visiveis(v_uid) where funcionario_id = p_funcionario) then
    raise exception 'sem permissão para este colaborador'; end if;
  if p_acao not in ('ajustar','falta','justificar','ok') then raise exception 'ação inválida'; end if;
  select status into v_st from "18 - rh".tratativa where funcionario_id = p_funcionario and data = p_data;
  if v_st = 'validado' then raise exception 'dia já validado pela RH'; end if;
  select versao into v_ver from "18 - rh".ponto_dia where funcionario_id = p_funcionario and data = p_data;
  if v_ver is null then raise exception 'dia não encontrado'; end if;
  if p_acao = 'ajustar' then
    if coalesce(cardinality(p_marcacoes), 0) = 0 or cardinality(p_marcacoes) % 2 = 1 then
      raise exception 'informe pares de entrada e saída'; end if;
    foreach m in array p_marcacoes loop
      if hm(m) is null or hm(m) >= 1440 then raise exception 'horário inválido: %', m; end if;
      if hm(m) <= prev then raise exception 'os horários precisam estar em ordem crescente'; end if;
      prev := hm(m);
    end loop;
  else p_marcacoes := null; end if;
  if p_acao = 'justificar' and coalesce(trim(p_motivo), '') = '' then raise exception 'informe o motivo'; end if;
  select i.tipos into v_tipos from "18 - rh".inconsistencias(p_data, p_data) i where i.funcionario_id = p_funcionario;
  insert into "18 - rh".tratativa as t (funcionario_id, data, tipos, acao, marcacoes, motivo, obs, versao_dia, status, gestor_uuid, gestor_em)
  values (p_funcionario, p_data, coalesce(v_tipos, '{}'), p_acao, p_marcacoes, nullif(trim(p_motivo), ''), nullif(trim(p_obs), ''),
          v_ver, 'tratado', v_uid, now())
  on conflict (funcionario_id, data) do update set tipos = excluded.tipos, acao = excluded.acao, marcacoes = excluded.marcacoes,
    motivo = excluded.motivo, obs = excluded.obs, versao_dia = excluded.versao_dia, status = 'tratado',
    gestor_uuid = excluded.gestor_uuid, gestor_em = now(), rh_uuid = null, rh_em = null, rh_obs = null;
  insert into "18 - rh".tratativa_evento (funcionario_id, data, evento, dados, por)
  values (p_funcionario, p_data, 'tratado', jsonb_build_object('acao', p_acao, 'marcacoes', p_marcacoes, 'motivo', p_motivo, 'obs', p_obs, 'tipos', v_tipos), v_uid);
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.app_rh_val_rh(p_funcionario bigint, p_data date, p_validar boolean, p_obs text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', '18 - rh'
AS $function$
declare v_uid uuid := auth.uid(); v_st text;
begin
  if not public.rh_pode_carregar(v_uid) or not public.rh_tela(v_uid, 'val') then raise exception 'sem permissão'; end if;
  select status into v_st from "18 - rh".tratativa where funcionario_id = p_funcionario and data = p_data for update;
  if v_st is null then raise exception 'o gestor ainda não tratou este dia'; end if;
  if not p_validar and coalesce(trim(p_obs), '') = '' then raise exception 'diga ao gestor o que falta'; end if;
  update "18 - rh".tratativa set status = case when p_validar then 'validado' else 'devolvido' end,
         rh_uuid = v_uid, rh_em = now(), rh_obs = nullif(trim(p_obs), '')
   where funcionario_id = p_funcionario and data = p_data;
  insert into "18 - rh".tratativa_evento (funcionario_id, data, evento, dados, por)
  values (p_funcionario, p_data, case when p_validar then 'validado' else 'devolvido' end, jsonb_build_object('obs', p_obs), v_uid);
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.app_rh_analise(p_ini date, p_fim date, p_consorcio text DEFAULT NULL::text, p_area text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', '18 - rh'
AS $function$
declare v_uid uuid := auth.uid(); r jsonb;
begin
  if v_uid is null then raise exception 'não autenticado'; end if;
  if not public.rh_tela(v_uid, 'analise') then raise exception 'sem permissão'; end if;
  if p_fim < p_ini or p_fim - p_ini > 366 then raise exception 'período inválido (máx. 1 ano)'; end if;
  with fv0 as (
    select f.id, f.nome, e.sigla, e.consorcio,
           coalesce(nullif(trim(p.area), ''), 'Sem área') as area,
           coalesce(g1.nome, g1.email, g2.nome, g2.email, 'Sem gestor no app') as gestor
      from func_visiveis(v_uid) x
      join "18 - rh".funcionario f on f.id = x.funcionario_id
      join "18 - rh".empresa e on e.cnpj = f.cnpj
      left join public.perfil p  on p.id  = f.perfil_id
      left join public.perfil g1 on g1.id = p.aprovador_uuid
      left join public.perfil g2 on g2.id = p.aprovador2_uuid
     where p_consorcio is null or e.consorcio = p_consorcio
  ), fv as (
    select * from fv0 where p_area is null or area = p_area
  ), d as (
    select pd.*, fv.nome, fv.sigla, fv.consorcio, fv.area, fv.gestor, "18 - rh".prev_min(pd.horario) as prev
      from "18 - rh".ponto_dia pd join fv on fv.id = pd.funcionario_id
     where pd.data between p_ini and p_fim
  ), inc as (
    select i.*, fv.nome, fv.sigla, fv.area, fv.gestor,
           case when t.funcionario_id is null or t.status = 'devolvido' then 'pend' when t.status = 'validado' then 'val' else 'trat' end as st
      from "18 - rh".inconsistencias(p_ini, p_fim) i join fv on fv.id = i.funcionario_id
      left join "18 - rh".tratativa t on t.funcionario_id = i.funcionario_id and t.data = i.data
  ), inc_t as (
    select unnest(tipos) tipo, funcionario_id from inc
  ), func as (
    select d.funcionario_id, min(d.nome) nome, min(d.sigla) sigla, min(d.area) area, min(d.gestor) gestor,
           sum(coalesce(d.he_min, 0)) he, sum(d.falta_min) falta, count(*) filter (where d.falta_min > 0) dias_falta,
           sum(d.atraso_min) atraso, count(*) filter (where coalesce(d.he_min, 0) > 120) dias_he2,
           sum(coalesce(d.htrab_min, 0)) htrab, count(*) filter (where cardinality(d.marcacoes) > 0) dias_trab,
           sum(d.prev) filter (where not d.parcial) prev
      from d group by d.funcionario_id
  ), agg as (   -- uma linha por grupo (área / gestor) com os mesmos indicadores
    select 'area' k, area g, count(distinct funcionario_id) funcionarios,
           sum(prev) filter (where not parcial) prev, sum(coalesce(htrab_min, 0)) htrab, sum(coalesce(he_min, 0)) he,
           sum(falta_min) filter (where not parcial) falta, sum(atraso_min) atraso,
           count(*) filter (where atraso_min > 0) n_atrasos,
           count(*) filter (where cardinality(marcacoes) > 0 and prev > 0) dias_prev_trab,
           count(*) filter (where not parcial) dias_aval, count(*) filter (where coalesce(he_min, 0) > 120) dias_he2
      from d group by area
    union all
    select 'gestor', gestor, count(distinct funcionario_id), sum(prev) filter (where not parcial), sum(coalesce(htrab_min, 0)),
           sum(coalesce(he_min, 0)), sum(falta_min) filter (where not parcial), sum(atraso_min), count(*) filter (where atraso_min > 0),
           count(*) filter (where cardinality(marcacoes) > 0 and prev > 0), count(*) filter (where not parcial),
           count(*) filter (where coalesce(he_min, 0) > 120)
      from d group by gestor
  ), agg_inc as (
    select 'area' k, area g, count(*) dias_inc, count(*) filter (where st = 'pend') pend, count(*) filter (where st = 'trat') trat,
           count(*) filter (where st = 'val') val, count(*) filter (where interjornada_min is not null) interj
      from inc group by area
    union all
    select 'gestor', gestor, count(*), count(*) filter (where st = 'pend'), count(*) filter (where st = 'trat'),
           count(*) filter (where st = 'val'), count(*) filter (where interjornada_min is not null)
      from inc group by gestor
  ), grp as (
    select a.k, jsonb_agg(jsonb_build_object('nome', a.g, 'funcionarios', a.funcionarios, 'prev', coalesce(a.prev, 0),
             'htrab', a.htrab, 'he', a.he, 'falta', coalesce(a.falta, 0), 'atraso', a.atraso, 'n_atrasos', a.n_atrasos,
             'dias_prev_trab', a.dias_prev_trab, 'dias_aval', a.dias_aval, 'dias_he2', a.dias_he2,
             'dias_inc', coalesce(i.dias_inc, 0), 'pend', coalesce(i.pend, 0), 'trat', coalesce(i.trat, 0),
             'val', coalesce(i.val, 0), 'interj', coalesce(i.interj, 0))
             order by coalesce(i.pend, 0) desc, a.g) j
      from agg a left join agg_inc i on i.k = a.k and i.g = a.g
     group by a.k
  )
  select jsonb_build_object(
    'periodo', jsonb_build_object('ini', p_ini, 'fim', p_fim, 'data_min', (select min(data) from d), 'data_max', (select max(data) from d),
                                  'parciais', (select count(*) from d where parcial)),
    'areas', (select coalesce(jsonb_agg(jsonb_build_object('nome', area, 'n', n) order by area = 'Sem área', area), '[]')
                from (select area, count(*) n from fv0 group by area) s),
    'tot', (select jsonb_build_object('funcionarios', count(distinct funcionario_id),
              'dias_trab', count(*) filter (where cardinality(marcacoes) > 0),
              'htrab', sum(coalesce(htrab_min, 0)), 'he', sum(coalesce(he_min, 0)), 'adn', sum(coalesce(adn_min, 0)),
              'falta_min', sum(falta_min), 'dias_falta', count(*) filter (where falta_min > 0),
              'atraso_min', sum(atraso_min), 'n_atrasos', count(*) filter (where atraso_min > 0),
              'dsr', count(*) filter (where dsr_min > 0),
              'prev', coalesce(sum(prev) filter (where not parcial), 0),
              'falta_aval', coalesce(sum(falta_min) filter (where not parcial), 0),
              'dias_prev_trab', count(*) filter (where cardinality(marcacoes) > 0 and prev > 0),
              'dias_aval', count(*) filter (where not parcial),
              'dias_he2', count(*) filter (where coalesce(he_min, 0) > 120)) from d),
    'por_area',   coalesce((select j from grp where k = 'area'), '[]'),
    'por_gestor', coalesce((select j from grp where k = 'gestor'), '[]'),
    'por_empresa', (select coalesce(jsonb_agg(x order by x->>'sigla'), '[]') from (select jsonb_build_object('sigla', sigla, 'consorcio', consorcio,
              'funcionarios', count(distinct funcionario_id), 'he', sum(coalesce(he_min, 0)), 'htrab', sum(coalesce(htrab_min, 0)),
              'falta_min', sum(falta_min), 'dias_falta', count(*) filter (where falta_min > 0), 'atraso_min', sum(atraso_min)) x
              from d group by sigla, consorcio) s),
    'por_dia', (select coalesce(jsonb_agg(x order by x->>'data'), '[]') from (select jsonb_build_object('data', d.data,
              'he', sum(coalesce(he_min, 0)), 'falta_min', sum(falta_min), 'presentes', count(*) filter (where cardinality(marcacoes) > 0),
              'inc', (select count(*) from inc where inc.data = d.data),
              'pend', (select count(*) from inc where inc.data = d.data and st = 'pend')) x
              from d group by d.data) s),
    'inc', (select coalesce(jsonb_object_agg(tipo, jsonb_build_object('casos', n, 'pessoas', p)), '{}') from
              (select tipo, count(*) n, count(distinct funcionario_id) p from inc_t group by tipo) s),
    'inc_st', (select coalesce(jsonb_object_agg(tipo, jsonb_build_object('pend', pd, 'trat', tr, 'val', vl)), '{}') from
              (select u.tipo, count(*) filter (where st = 'pend') pd, count(*) filter (where st = 'trat') tr,
                      count(*) filter (where st = 'val') vl
                 from inc, unnest(inc.tipos) u(tipo) group by u.tipo) s),
    'interjornada', (select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'sigla', sigla, 'area', area, 'data', data, 'descanso', interjornada_min)
              order by interjornada_min), '[]') from inc where interjornada_min is not null),
    'func', (select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'sigla', sigla, 'area', area, 'gestor', gestor,
              'he', he, 'falta', falta, 'dias_falta', dias_falta, 'atraso', atraso, 'dias_he2', dias_he2, 'htrab', htrab,
              'dias_trab', dias_trab, 'prev', coalesce(prev, 0),
              'interj', (select count(*) from inc where inc.funcionario_id = func.funcionario_id and interjornada_min is not null),
              'dias_inc', (select count(*) from inc where inc.funcionario_id = func.funcionario_id),
              'pend', (select count(*) from inc where inc.funcionario_id = func.funcionario_id and st = 'pend'))
              order by he desc), '[]') from func),
    'tratativas', (select jsonb_build_object('pendentes', count(*) filter (where st = 'pend'),
              'tratadas', count(*) filter (where st = 'trat'), 'validadas', count(*) filter (where st = 'val')) from inc)
  ) into r;
  return r;
end $function$;
