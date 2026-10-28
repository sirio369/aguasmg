-- Gestão de Pavimento: OS da recomposição POR TIPO de pavimento. 2026-10-28.
-- Antes: a pavprog tinha 1 campo de OS por grupo (app_pav_os grava a mesma OS em todas as linhas) e o
-- programador digitava "OS_tipo1, OS_tipo2" no campo único (6 grupos com vírgula em os_recomposicao).
-- A tabela já é 1 linha por tipo (pav_recomposicao.grupo liga os tipos) → não muda schema, só RPCs:
--   1) app_pav_listar: cada item passa a trazer id + os_recomposicao/os_recomp_em/os_recomp_por da sua linha.
--      Campo do grupo os_recomposicao mantido p/ app em cache (≤ v281): 1 OS → ela; várias → "A, B" na ordem do card.
--   2) app_pav_os_itens(p_itens jsonb [{id,os}]) — NOVA: grava a OS de cada tipo na sua linha.
--   3) app_pav_os(p_grupo,p_os) — LEGADO (app em cache ≤ v281): se vier "A, B" com nº de partes = nº de tipos e
--      todas numéricas, distribui na ordem do card (order by tipo_pavimento); senão grava igual em todas (como antes).
-- Idempotente. Conversão dos dados antigos: script à parte, só após aprovação da planilha.

-- 1) listagem
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
                 'os_recomposicao',os_recomposicao,'os_recomp_em',os_recomp_em,'os_recomp_por',os_recomp_por) order by tipo_pavimento)
      ) g, max(created_at) mc
      from "8 - coleta_campo".pav_recomposicao
      where (p_consorcio is null or consorcio=p_consorcio)
        and (p_servico_origem is null or servico_origem=p_servico_origem)
      group by grupo
      limit 500
    ) q
  );
end$function$;

-- 2) OS por tipo (nova)
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
        os_recomp_por = case when x.os is null then null else v_nome end
    from (select (e->>'id')::uuid id, nullif(btrim(e->>'os'),'') os from jsonb_array_elements(p_itens) e) x
    where r.id = x.id;
  get diagnostics n = row_count; return n;
end$function$;
revoke all on function public.app_pav_os_itens(jsonb) from public, anon;
grant execute on function public.app_pav_os_itens(jsonb) to authenticated;

-- 3) legado: 1 OS por grupo (app em cache). Mesma assinatura → create or replace não cria overload.
create or replace function public.app_pav_os(p_grupo uuid, p_os text)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid:=auth.uid(); v_nome text; n int; v_os text:=nullif(btrim(p_os),''); v_partes text[]; v_n int;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=v_id and (funcao='admin' or coalesce(aux_acesso,false))) then raise exception 'sem permissão'; end if;
  select coalesce(nome,email) into v_nome from public.perfil where id=v_id;
  v_partes := case when v_os is null then null else regexp_split_to_array(v_os, '\s*[,;]\s*') end;
  select count(*) into v_n from "8 - coleta_campo".pav_recomposicao where grupo = p_grupo;
  if v_n > 1 and cardinality(v_partes) = v_n and not exists(select 1 from unnest(v_partes) p where p !~ '^\d+$') then
    -- "A, B" → 1 OS por tipo, na ordem em que o card listava os tipos
    update "8 - coleta_campo".pav_recomposicao r
      set os_recomposicao = v_partes[o.rn], os_recomp_em = now(), os_recomp_por = v_nome
      from (select id, row_number() over (order by tipo_pavimento, created_at, id) rn
              from "8 - coleta_campo".pav_recomposicao where grupo = p_grupo) o
      where r.id = o.id;
  else
    update "8 - coleta_campo".pav_recomposicao
      set os_recomposicao = v_os,
          os_recomp_em = case when v_os is null then null else now() end,
          os_recomp_por = case when v_os is null then null else v_nome end
      where grupo = p_grupo;
  end if;
  get diagnostics n = row_count; return n;
end$function$;
