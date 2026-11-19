-- Segurança do Trabalho — registro de cada toque em "Emitir" (APR/PT/PET) — 2026-11-19 (sw v436)
-- Motivo: o celular recusa a emissão sem falar com o servidor (pendências do formulário), então "tentou e não
-- conseguiu" não deixava rastro. O app chama app_seg_tentativa a cada toque (sem fila, ignora erro/offline).
-- resultado: 'falta' (faltava preencher) | 'bloqueio' (trava de segurança) | 'enviando' (passou na validação) | 'erro'
-- Aditivo: o front v436 funciona sem esta migração (a chamada só falha em silêncio).

create table if not exists "16 - qsms".qsms_tentativa (
  id           bigserial primary key,
  criado_em    timestamptz not null default now(),
  usuario_uuid uuid not null default auth.uid(),
  tipo         text,          -- APR | PT | PET
  status       text,          -- emitida | impedida (o que a pessoa tentou)
  resultado    text not null,
  falta        text[],
  bloqueio     text[],
  precisao     numeric,       -- precisão do GPS (m) no momento do toque
  erro         text,
  versao       text,          -- coleta-vN do app
  dispositivo  text
);
create index if not exists qsms_tentativa_usuario_em on "16 - qsms".qsms_tentativa (usuario_uuid, criado_em desc);
alter table "16 - qsms".qsms_tentativa enable row level security;  -- sem policy: só via RPC

create or replace function public.app_seg_tentativa(
  p_tipo text, p_status text, p_resultado text,
  p_falta text[] default null, p_bloqueio text[] default null, p_precisao numeric default null,
  p_erro text default null, p_versao text default null, p_dispositivo text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'nao autenticado'; end if;
  if p_resultado not in ('falta','bloqueio','enviando','erro') then return; end if;
  insert into "16 - qsms".qsms_tentativa (tipo,status,resultado,falta,bloqueio,precisao,erro,versao,dispositivo)
  values (left(p_tipo,10), left(p_status,20), p_resultado, p_falta[1:30], p_bloqueio[1:30], p_precisao,
          left(p_erro,500), left(p_versao,30), left(p_dispositivo,200));
end $$;
revoke all on function public.app_seg_tentativa(text,text,text,text[],text[],numeric,text,text,text) from public, anon;
grant execute on function public.app_seg_tentativa(text,text,text,text[],text[],numeric,text,text,text) to authenticated;

-- Consulta de diagnóstico (ex.: quem tentou hoje):
-- select t.criado_em at time zone 'America/Sao_Paulo', p.email, t.tipo, t.resultado, t.falta, t.bloqueio, t.precisao, t.erro, t.versao
-- from "16 - qsms".qsms_tentativa t left join public.perfil p on p.id = t.usuario_uuid
-- where t.criado_em >= current_date order by t.criado_em desc;
