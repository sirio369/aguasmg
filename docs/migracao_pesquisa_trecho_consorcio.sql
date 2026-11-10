-- Consórcio do trecho de pesquisa pela geometria (2026-11-10) — APLICADA em 10/11/2026 (migração `pesquisa_trecho_consorcio_geom`).
-- Problema: app_pesquisa_trecho_registrar grava p_consorcio vindo do localStorage do aparelho; vinha errado ou vazio
--   (Marcos 185 trechos em Betim gravados ZA1004; Roberto 61 trechos em Contagem sem consórcio desde 29/10).
-- Correção: gatilho BEFORE INSERT/UPDATE põe a ZA do limite_za que contém st_pointonsurface(geom)
--   (public.pp_trecho_consorcio); o valor do app só fica se o trecho cair fora das ZAs. Acerto dos já gravados no fim
--   (246 linhas em 10/11; os gatilhos trg_pp_cruzar/trg_snap são só de INSERT, então o UPDATE não recalcula a programação).

create or replace function "8 - coleta_campo".tg_trecho_consorcio()
returns trigger language plpgsql set search_path to 'public' as $$
begin
  if new.geom is not null then
    new.consorcio := public.pp_trecho_consorcio(new.geom, new.consorcio);
  end if;
  return new;
end $$;

-- nome "trg_tz_" → roda depois do trg_snap_trecho_inicio (BEFORE triggers em ordem alfabética)
drop trigger if exists trg_tz_consorcio on "8 - coleta_campo".pesquisa_trecho;
create trigger trg_tz_consorcio
  before insert or update of geom, consorcio on "8 - coleta_campo".pesquisa_trecho
  for each row execute function "8 - coleta_campo".tg_trecho_consorcio();

comment on function "8 - coleta_campo".tg_trecho_consorcio() is
  'pesquisa_trecho.consorcio = ZA do limite_za que contém st_pointonsurface(geom); o valor enviado pelo app só fica se o trecho cair fora das ZAs.';

update "8 - coleta_campo".pesquisa_trecho
   set consorcio = public.pp_trecho_consorcio(geom, consorcio)
 where geom is not null
   and consorcio is distinct from public.pp_trecho_consorcio(geom, consorcio);
