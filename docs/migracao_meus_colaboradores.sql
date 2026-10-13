-- Migração: meus_colaboradores — tela "Meus colaboradores" (substitui a Gestão de Pessoas). Ver docs/MODULOS.md §12.
-- Só ADICIONA objetos (RPC + trigger). Aplicar via MCP apply_migration (name: meus_colaboradores).
-- Rollback:
--   drop trigger if exists trg_perfil_novo_colaborador on public.perfil;
--   drop function if exists public.trg_perfil_novo_colaborador();
--   drop function if exists public.app_meus_colaboradores();

-- Lista de colaboradores ATIVOS: aprovador vê quem o tem como Aprovador 1/2; admin vê todos. Nunca o próprio chamador.
create or replace function public.app_meus_colaboradores()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select case when coalesce("9 - suprimentos".sup_funcao(auth.uid()),'') not in ('aprovador','admin') then '[]'::jsonb else
  coalesce((select jsonb_agg(jsonb_build_object(
      'id',p.id,'nome',p.nome,'email',p.email,'cargo',c.nome,'consorcio',p.consorcio,'codigo_area',p.codigo_area,'area',p.area,
      'frente_empresa',p.frente_empresa,'projeto',p.projeto,'custo_direto_indireto',p.custo_direto_indireto,'modalidade',p.modalidade,
      'matricula',p.matricula,'admissao',p.admissao,'aprovador1',a1.nome,'aprovador2',a2.nome) order by p.nome)
    from public.perfil p
    left join "9 - suprimentos".sup_cargo c on c.id=p.cargo_id
    left join public.perfil a1 on a1.id=p.aprovador_uuid
    left join public.perfil a2 on a2.id=p.aprovador2_uuid
    where p.ativo and p.id <> auth.uid()
      and ("9 - suprimentos".sup_funcao(auth.uid())='admin' or auth.uid() in (p.aprovador_uuid, p.aprovador2_uuid))
  ),'[]'::jsonb) end;
$$;
revoke all on function public.app_meus_colaboradores() from public, anon;
grant execute on function public.app_meus_colaboradores() to authenticated;

-- Aviso "novo colaborador" (invariante §0.9: notificação por trigger, nunca inline; pessoal → sem p_exceto).
-- Dispara para o Aprovador 1/2 que acabou de ser vinculado, ou para os dois quando o colaborador é (re)ativado.
create or replace function public.trg_perfil_novo_colaborador()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_dest uuid[];
begin
  if not coalesce(NEW.ativo, true) then return NEW; end if;
  v_dest := array(
    select distinct x from unnest(array[NEW.aprovador_uuid, NEW.aprovador2_uuid]) as x
    where x is not null and x <> NEW.id
      and ( TG_OP = 'INSERT'
            or not coalesce(OLD.ativo, false)
            or (x is distinct from OLD.aprovador_uuid and x is distinct from OLD.aprovador2_uuid) ));
  if coalesce(array_length(v_dest, 1), 0) > 0 then
    perform "9 - suprimentos".sup_notificar(
      v_dest, 'colaborador_novo', 'Novo colaborador na sua equipe',
      coalesce(NEW.nome, NEW.email) || ' agora tem você como aprovador.', 'meus_colaboradores', null);
  end if;
  return NEW;
end; $$;

drop trigger if exists trg_perfil_novo_colaborador on public.perfil;
create trigger trg_perfil_novo_colaborador
  after insert or update of aprovador_uuid, aprovador2_uuid, ativo on public.perfil
  for each row execute function public.trg_perfil_novo_colaborador();

notify pgrst, 'reload schema';
