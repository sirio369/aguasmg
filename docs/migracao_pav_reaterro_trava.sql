-- Gestão de Pavimento — TRAVA do ensaio de reaterro no banco. 2026-11-02.
-- ⚠️ Aplicar só DEPOIS que o front v314 (pergunta "Necessita ensaio?" na pavprog) estiver no ar: até lá o app não tem como
-- responder e "Criar OS" seria recusado em todo tipo novo. Requer migracao_pav_reaterro.sql.
-- Regra: OS da recomposição só entra em tipo que ainda não tem OS se a pergunta foi respondida e, quando o ensaio foi pedido,
-- se ele foi APROVADO. Trocar/limpar a OS de um tipo que já tem OS segue livre (inclui os registros antigos, sem resposta).
-- Idempotente.

create or replace function public.app_pav_os_itens(p_itens jsonb)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid:=auth.uid(); v_nome text; n int;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=v_id and (funcao='admin' or coalesce(aux_acesso,false))) then raise exception 'sem permissão'; end if;
  if jsonb_typeof(p_itens) is distinct from 'array' then raise exception 'p_itens deve ser uma lista [{id,os}]'; end if;
  if exists (select 1 from jsonb_array_elements(p_itens) e
               join "8 - coleta_campo".pav_recomposicao r on r.id = (e->>'id')::uuid
              where nullif(btrim(e->>'os'),'') is not null and r.os_recomposicao is null
                and (r.reaterro_necessario is null or (r.reaterro_necessario and r.reaterro_status is distinct from 'aprovado'))) then
    raise exception 'responda se o pavimento precisa de ensaio de reaterro (e, se pedido, aguarde a aprovação) antes de lançar a OS';
  end if;
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

-- legado (app em cache ≤ v281): mesma trava
create or replace function public.app_pav_os(p_grupo uuid, p_os text)
returns integer language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid:=auth.uid(); v_nome text; n int; v_os text:=nullif(btrim(p_os),''); v_partes text[]; v_n int;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not exists(select 1 from public.perfil where id=v_id and (funcao='admin' or coalesce(aux_acesso,false))) then raise exception 'sem permissão'; end if;
  if v_os is not null and exists (select 1 from "8 - coleta_campo".pav_recomposicao r
              where r.grupo = p_grupo and r.os_recomposicao is null
                and (r.reaterro_necessario is null or (r.reaterro_necessario and r.reaterro_status is distinct from 'aprovado'))) then
    raise exception 'responda se o pavimento precisa de ensaio de reaterro (e, se pedido, aguarde a aprovação) antes de lançar a OS';
  end if;
  select coalesce(nome,email) into v_nome from public.perfil where id=v_id;
  v_partes := case when v_os is null then null else regexp_split_to_array(v_os, '\s*[,;]\s*') end;
  select count(*) into v_n from "8 - coleta_campo".pav_recomposicao where grupo = p_grupo;
  if v_n > 1 and cardinality(v_partes) = v_n and not exists(select 1 from unnest(v_partes) p where p !~ '^\d+$') then
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
