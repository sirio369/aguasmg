-- Gestão de Pavimento: 3ª etapa = EXECUÇÃO da recomposição, por tipo. 2026-10-28.
-- Fluxo da pavprog: pendente de criação (tipo sem OS) → pendente de execução (OS lançada) → executada.
-- O programador marca a data de execução de cada tipo depois que a OS foi lançada; o rastro não para na OS.
-- Idempotente.

-- 1) colunas (1 linha por tipo)
alter table "8 - coleta_campo".pav_recomposicao
  add column if not exists execucao_data date,          -- dia em que a recomposição foi executada (informado)
  add column if not exists execucao_em timestamptz,     -- quando foi marcado no app
  add column if not exists execucao_por text;           -- quem marcou

-- 2) marcar/desmarcar execução de 1 tipo (p_data null = desfaz)
create or replace function public.app_pav_executar(p_id uuid, p_data date)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid:=auth.uid(); v_nome text; v_os text; v_criado timestamptz; n int;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=v_id and (funcao='admin' or coalesce(aux_acesso,false))) then raise exception 'sem permissão'; end if;
  select coalesce(nome,email) into v_nome from public.perfil where id=v_id;
  select os_recomposicao, created_at into v_os, v_criado from "8 - coleta_campo".pav_recomposicao where id = p_id;
  if not found then raise exception 'registro não encontrado'; end if;
  if p_data is not null then
    if v_os is null then raise exception 'lance a OS da recomposição antes de marcar a execução'; end if;
    if p_data > (now() at time zone 'America/Sao_Paulo')::date then raise exception 'data de execução no futuro'; end if;
    if p_data < (v_criado at time zone 'America/Sao_Paulo')::date then raise exception 'data de execução anterior ao registro do pavimento'; end if;
  end if;
  update "8 - coleta_campo".pav_recomposicao
    set execucao_data = p_data,
        execucao_em = case when p_data is null then null else now() end,
        execucao_por = case when p_data is null then null else v_nome end
    where id = p_id;
  get diagnostics n = row_count; return n;
end$function$;
revoke all on function public.app_pav_executar(uuid, date) from public, anon;
grant execute on function public.app_pav_executar(uuid, date) to authenticated;

-- 3) OS por tipo: limpar a OS também limpa a execução (não existe executada sem OS)
create or replace function public.app_pav_os_itens(p_itens jsonb)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid:=auth.uid(); v_nome text; n int;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=v_id and (funcao='admin' or coalesce(aux_acesso,false))) then raise exception 'sem permissão'; end if;
  if jsonb_typeof(p_itens) is distinct from 'array' then raise exception 'p_itens deve ser uma lista [{id,os}]'; end if;
  select coalesce(nome,email) into v_nome from public.perfil where id=v_id;
  update "8 - coleta_campo".pav_recomposicao r
    set os_recomposicao = x.os,
        os_recomp_em = case when x.os is null then null else now() end,
        os_recomp_por = case when x.os is null then null else v_nome end,
        execucao_data = case when x.os is null then null else r.execucao_data end,
        execucao_em = case when x.os is null then null else r.execucao_em end,
        execucao_por = case when x.os is null then null else r.execucao_por end
    from (select (e->>'id')::uuid id, nullif(btrim(e->>'os'),'') os from jsonb_array_elements(p_itens) e) x
    where r.id = x.id;
  get diagnostics n = row_count; return n;
end$function$;

-- 4) listagem: cada item traz também a execução
create or replace function public.app_pav_listar(p_consorcio text default null, p_servico_origem text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=auth.uid() and (funcao='admin' or coalesce(aux_acesso,false))) then raise exception 'sem permissão'; end if;
  return (
    select coalesce(jsonb_agg(g order by mc desc),'[]')
    from (
      select jsonb_build_object(
        'grupo',grupo,'servico_origem',min(servico_origem),'os_sigos',min(os_sigos),
        'os_recomposicao',case when count(distinct os_recomposicao)<=1 then min(os_recomposicao)
                               else string_agg(os_recomposicao, ', ' order by tipo_pavimento) end,
        'os_recomp_em',max(os_recomp_em),'os_recomp_por',min(os_recomp_por),
        'consorcio',min(consorcio),'created_at',max(created_at),
        'usuario',min(coalesce(usuario_nome,usuario_email)),
        'lat',min(lat),'lon',min(lon),'precisao',min(gps_precisao),
        'itens', jsonb_agg(jsonb_build_object('id',id,'tipo',tipo_pavimento,'dimensao',dimensao,'foto1',foto1,'foto2',foto2,
                 'os_recomposicao',os_recomposicao,'os_recomp_em',os_recomp_em,'os_recomp_por',os_recomp_por,
                 'execucao_data',execucao_data,'execucao_em',execucao_em,'execucao_por',execucao_por) order by tipo_pavimento)
      ) g, max(created_at) mc
      from "8 - coleta_campo".pav_recomposicao
      where (p_consorcio is null or consorcio=p_consorcio)
        and (p_servico_origem is null or servico_origem=p_servico_origem)
      group by grupo
      limit 500
    ) q
  );
end$function$;
