-- Ponto (RH): terceiro fica fora dos relatórios e das análises (2026-11-24)
-- Terceiro = perfil.modalidade = 'TERCEIRO' (mesma regra do bloqueio de módulos). O funcionário do Kairos é casado ao perfil pelo CPF
-- (funcionario.perfil_id). Os dados continuam gravados na base única (ponto_dia); só deixam de entrar em Análise, Horas, Validação e Gestão de pontos.
-- Quem não tem perfil no app (perfil_id nulo) não dá para saber se é terceiro: continua aparecendo, como "sem gestor no app".
-- Idempotente: pode rodar de novo.

create or replace function "18 - rh".rh_terceiro(p_perfil uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from public.perfil p where p.id = p_perfil and upper(coalesce(p.modalidade, '')) = 'TERCEIRO')
$$;
revoke all on function "18 - rh".rh_terceiro(uuid) from public, anon, authenticated;

-- 1) Validação / Gestão de pontos: quem o usuário enxerga
create or replace function "18 - rh".func_visiveis(p_uid uuid)
returns table (funcionario_id bigint) language sql stable security definer set search_path = public, "18 - rh" as $$
  select f.id from "18 - rh".funcionario f
   where not "18 - rh".rh_terceiro(f.perfil_id)
     and (public.rh_pode_carregar(p_uid)
          or exists (select 1 from public.perfil p where p.id = f.perfil_id and p_uid in (p.aprovador_uuid, p.aprovador2_uuid)));
$$;
revoke all on function "18 - rh".func_visiveis(uuid) from public, anon, authenticated;

-- 2) Análise e base dia a dia: acrescenta a condição no join do funcionário com a empresa (em todas as sobrecargas)
do $$
declare r record; d text; pad text := 'join "18 - rh".empresa e on e.cnpj = f.cnpj';
begin
  for r in select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('app_rh_analise', 'app_rh_ponto_dias', 'app_rh_val_lista') loop
    d := pg_get_functiondef(r.oid);
    if d like '%rh_terceiro%' then continue; end if;
    if position(pad in d) = 0 then raise exception 'padrão do join não encontrado em %(%)', r.proname, r.args; end if;
    execute replace(d, pad, pad || ' and not "18 - rh".rh_terceiro(f.perfil_id)');
  end loop;
end $$;
