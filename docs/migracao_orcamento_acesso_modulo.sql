-- Orçamento: acesso próprio do módulo (⚙️ dentro do Orçamento) — 24/11/2026, sw v450
-- Antes: entrava quem era admin ou tinha dev_acesso (o mesmo acesso do "Em desenvolvimento").
-- Agora: entra o dono do módulo (orc_dono) e quem estiver em orc_usuario; só o dono concede/retira.
-- Continuidade: quem entrava (admin ou dev_acesso, ativo) foi copiado para orc_usuario na aplicação; o dono desmarca.
-- app_me ganha 'orc_acesso' e 'orc_dono' (card da home e página). Sem DROP de dados. Idempotente.

create table if not exists "19 - orcamento".orc_usuario (
  perfil_id     uuid primary key references public.perfil(id) on delete cascade,
  concedido_por uuid,
  criado_em     timestamptz not null default now()
);
alter table "19 - orcamento".orc_usuario enable row level security;  -- só via funções security definer

-- semente de continuidade (só na 1ª aplicação: tabela vazia)
insert into "19 - orcamento".orc_usuario(perfil_id)
select id from public.perfil
where coalesce(ativo,true) and (funcao = 'admin' or coalesce(dev_acesso,false))
  and not exists (select 1 from "19 - orcamento".orc_usuario)
on conflict do nothing;

create or replace function "19 - orcamento".orc_pode(p_uid uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.perfil where id = p_uid and coalesce(ativo,true))
     and ("19 - orcamento".orc_eh_dono(p_uid)
          or exists (select 1 from "19 - orcamento".orc_usuario u where u.perfil_id = p_uid));
$$;

-- engrenagem: lista de usuários (só o dono)
create or replace function public.app_orc_acesso_listar()
returns jsonb language plpgsql stable security definer set search_path to '19 - orcamento', 'public' as $$
declare v_uid uuid := "19 - orcamento".orc_exige();
begin
  if not "19 - orcamento".orc_eh_dono(v_uid) then raise exception 'só o dono do módulo gerencia o acesso ao Orçamento'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id',f.id,'nome',coalesce(nullif(f.nome,''),f.email),'email',f.email,
            'cargo',f.cargo,'funcao',f.funcao,'dono',"19 - orcamento".orc_eh_dono(f.id),
            'acesso',exists(select 1 from orc_usuario u where u.perfil_id = f.id))
            order by coalesce(nullif(f.nome,''),f.email)),'[]')
          from public.perfil f where coalesce(f.ativo,true));
end $$;

create or replace function public.app_orc_acesso_set(p_id uuid, p_on boolean)
returns boolean language plpgsql security definer set search_path to '19 - orcamento', 'public' as $$
declare v_uid uuid := "19 - orcamento".orc_exige();
begin
  if not "19 - orcamento".orc_eh_dono(v_uid) then raise exception 'só o dono do módulo gerencia o acesso ao Orçamento'; end if;
  if not exists (select 1 from public.perfil where id = p_id) then raise exception 'usuário não encontrado'; end if;
  if coalesce(p_on,false) then
    insert into orc_usuario(perfil_id, concedido_por) values (p_id, v_uid) on conflict do nothing;
  else
    delete from orc_usuario where perfil_id = p_id;
  end if;
  return coalesce(p_on,false);
end $$;

revoke all on function public.app_orc_acesso_listar() from public, anon;
revoke all on function public.app_orc_acesso_set(uuid, boolean) from public, anon;
grant execute on function public.app_orc_acesso_listar() to authenticated;
grant execute on function public.app_orc_acesso_set(uuid, boolean) to authenticated;

-- 🔐 por organograma: candidatos = quem entra no módulo
create or replace function public.app_orc_quadro_acesso(p_quadro uuid)
returns jsonb language plpgsql stable security definer set search_path to '19 - orcamento', 'public' as $$
declare v_uid uuid := "19 - orcamento".orc_exige();
begin
  if not "19 - orcamento".orc_quadro_pode(p_quadro, v_uid) then raise exception 'sem acesso a este organograma'; end if;
  return jsonb_build_object(
    'pode_config', "19 - orcamento".orc_quadro_config(p_quadro, v_uid),
    'criado_por', (select criado_por from orc_quadro where id = p_quadro),
    'lista', (select coalesce(jsonb_agg(perfil_id),'[]') from orc_quadro_acesso where quadro_id = p_quadro),
    'candidatos', (select coalesce(jsonb_agg(jsonb_build_object('id',f.id,'nome',coalesce(nullif(f.nome,''),f.email),'email',f.email,
                     'admin', f.funcao = 'admin', 'dono', "19 - orcamento".orc_eh_dono(f.id)) order by coalesce(nullif(f.nome,''),f.email)),'[]')
                   from public.perfil f where "19 - orcamento".orc_pode(f.id)));
end $$;

-- app_me: + orc_acesso / orc_dono (resto igual à definição de 24/11/2026)
create or replace function public.app_me()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
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
    'orc_acesso',"19 - orcamento".orc_pode(v_id),
    'orc_dono',"19 - orcamento".orc_eh_dono(v_id),
    'equipes','[]'::jsonb);
end $function$;
