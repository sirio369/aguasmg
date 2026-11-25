-- Projetos · HDD — Puxamento da tubulação: diâmetro (mm) + rua por lançamento (2026-11-25)
-- Aditivo: 2 colunas no log de avanço + RPC para gravar/corrigir em lançamentos novos e antigos.
alter table "13 - projetos_obra".intervencao_avanco
  add column if not exists diametro_mm numeric,
  add column if not exists rua text,
  add column if not exists pux_editado_em timestamptz,
  add column if not exists pux_editado_por uuid;

alter table "13 - projetos_obra".intervencao_avanco
  drop constraint if exists intervencao_avanco_diametro_chk;
alter table "13 - projetos_obra".intervencao_avanco
  add constraint intervencao_avanco_diametro_chk check (diametro_mm is null or diametro_mm > 0);

create or replace function public.app_proj_avanco_pux_set(p_id bigint, p_diametro_mm numeric, p_rua text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', '13 - projetos_obra'
as $function$
declare v_id uuid := auth.uid(); v_row "13 - projetos_obra".intervencao_avanco;
begin
  if v_id is null then raise exception 'nao autenticado'; end if;
  if not "13 - projetos_obra".proj_obras_pode(v_id) then raise exception 'sem permissão (Projetos · responsáveis de obras)'; end if;
  if p_diametro_mm is not null and p_diametro_mm <= 0 then raise exception 'Diâmetro deve ser um número maior que zero'; end if;
  select * into v_row from "13 - projetos_obra".intervencao_avanco where id = p_id;
  if not found then raise exception 'lançamento não encontrado'; end if;
  if v_row.tipo is distinct from 'rede_hdd' or coalesce(v_row.sub,'') not ilike '%puxamento%' then
    raise exception 'só lançamentos de Puxamento da tubulação (HDD) têm diâmetro e rua';
  end if;
  update "13 - projetos_obra".intervencao_avanco
     set diametro_mm = p_diametro_mm, rua = nullif(btrim(p_rua),''),
         pux_editado_em = now(), pux_editado_por = v_id
   where id = p_id returning * into v_row;
  return to_jsonb(v_row);
end $function$;
revoke all on function public.app_proj_avanco_pux_set(bigint,numeric,text) from public, anon;
grant execute on function public.app_proj_avanco_pux_set(bigint,numeric,text) to authenticated;
