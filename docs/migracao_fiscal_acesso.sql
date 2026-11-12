-- =====================================================================================================================
-- Acesso "Fiscal" + engrenagem do bloco 🏛️ Fiscalização (tela inicial) — 2026-11-12
--
-- Decisões do usuário:
--   * Novo tipo de acesso (função) "fiscal": a pessoa vê SÓ o bloco Fiscalização da tela inicial (Execução Física,
--     Cadastro técnico, Biblioteca). Os demais módulos SOMEM (não ficam opacos).
--   * Engrenagem no bloco (só admin) define quem acessa o bloco: sem acesso / acessa (além do que já tem) / Fiscal.
--   * Admin sempre acessa.
--
-- Camadas:
--   perfil.fisc_acesso (chave, soma à função) e perfil.funcao = 'fiscal' (função exclusiva).
--   fisc_pode_ver_validado() passa a ser: admin OU fisc_acesso OU função fiscal (antes = sigos_pode_ver).
-- =====================================================================================================================

alter table public.perfil add column if not exists fisc_acesso boolean not null default false;

alter table public.perfil drop constraint if exists perfil_funcao_check;
alter table public.perfil add constraint perfil_funcao_check
  check (funcao = any (array['admin', 'campo', 'aprovador', 'almoxarife', 'qsms', 'frotas', 'fiscal']));

-- quem vê a Execução Física (só o validado)
create or replace function public.fisc_pode_ver_validado(p_uid uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  -- admin OU chave fisc_acesso OU função fiscal (engrenagem do bloco Fiscalização — docs/migracao_fiscal_acesso.sql)
  return p_uid is not null and exists (select 1 from public.perfil
    where id = p_uid and coalesce(ativo, true) and (funcao in ('admin', 'fiscal') or coalesce(fisc_acesso, false)));
end $$;
revoke all on function public.fisc_pode_ver_validado(uuid) from public, anon;

-- detalhe acumulado da obra: também p/ quem vê a Execução Física (Fiscal não tem sigos_pode_ver)
do $$ declare v text;
begin
  v := pg_get_functiondef('public.app_fisc_proj_detalhe(text, bigint, date)'::regprocedure);
  if position('fisc_pode_ver_validado' in v) = 0 then
    v := replace(v, 'if not public.sigos_pode_ver(auth.uid()) then',
                    'if not (public.sigos_pode_ver(auth.uid()) or public.fisc_pode_ver_validado(auth.uid())) then');
    if position('fisc_pode_ver_validado' in v) = 0 then raise exception 'app_fisc_proj_detalhe: trecho de permissão não encontrado'; end if;
    execute v;
  end if;
end $$;

-- app_me: + fisc_acesso e is_fiscal (resto idêntico)
create or replace function public.app_me()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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
    'equipes','[]'::jsonb);
end $function$;

-- Configurações de usuários (⚙️ da tela inicial) também aceita "fiscal"
create or replace function public.sup_admin_set_funcao(p_uid uuid, p_funcao text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if coalesce("9 - suprimentos".sup_funcao(auth.uid()),'')<>'admin' then raise exception 'apenas admin'; end if;
  if p_funcao not in ('campo','aprovador','almoxarife','admin','fiscal') then raise exception 'funcao invalida'; end if;
  if p_funcao<>'admin' and exists(select 1 from public.perfil where id=p_uid and funcao='admin') and (select count(*) from public.perfil where funcao='admin')<=1 then
    raise exception 'nao e possivel remover o ultimo admin'; end if;
  update public.perfil set funcao=p_funcao where id=p_uid;
  if not found then raise exception 'usuario inexistente'; end if;
  return jsonb_build_object('id',p_uid,'funcao',p_funcao);
end; $function$;

-- Engrenagem do bloco Fiscalização: lista e define o nível de cada pessoa
--   'nenhum'  → sem acesso ao bloco (fisc_acesso = false; Fiscal volta a "campo")
--   'acesso'  → acessa o bloco além do que já tem (fisc_acesso = true; Fiscal volta a "campo")
--   'fiscal'  → função Fiscal: só o bloco (funcao = 'fiscal', fisc_acesso = true)
create or replace function public.app_fisc_acesso_listar()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from public.perfil where id = auth.uid() and funcao = 'admin') then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'nome', coalesce(nome, email), 'email', email, 'funcao', funcao, 'ativo', coalesce(ativo, true),
      'nivel', case when funcao = 'admin' then 'admin' when funcao = 'fiscal' then 'fiscal'
                    when coalesce(fisc_acesso, false) then 'acesso' else 'nenhum' end)
      order by (funcao = 'fiscal') desc, coalesce(fisc_acesso, false) desc, coalesce(nome, email)) from public.perfil), '[]'::jsonb);
end $$;

create or replace function public.app_fisc_acesso_set(p_uuid uuid, p_nivel text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_f text;
begin
  if not exists (select 1 from public.perfil where id = auth.uid() and funcao = 'admin') then raise exception 'sem permissão'; end if;
  if p_nivel not in ('nenhum', 'acesso', 'fiscal') then raise exception 'nível inválido'; end if;
  select funcao into v_f from public.perfil where id = p_uuid;
  if v_f is null then raise exception 'usuário inexistente'; end if;
  if v_f = 'admin' then raise exception 'admin sempre acessa — mude a função dele em Configurações de usuários'; end if;
  update public.perfil set
    fisc_acesso = (p_nivel <> 'nenhum'),
    funcao = case when p_nivel = 'fiscal' then 'fiscal' when v_f = 'fiscal' then 'campo' else v_f end
   where id = p_uuid;
  return jsonb_build_object('ok', true, 'funcao_antes', v_f);
end $$;

revoke all on function public.app_fisc_acesso_listar(), public.app_fisc_acesso_set(uuid, text) from public, anon;
grant execute on function public.app_fisc_acesso_listar(), public.app_fisc_acesso_set(uuid, text) to authenticated;
