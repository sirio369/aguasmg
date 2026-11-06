-- Carga SIGOS (2026-11-06) — Auxiliar de Programação › Carga SIGOS.
-- 4 campos de envio no app (Relação ZA1004 / Relação ZA0200 / Encerradas ZA1004 / Encerradas ZA0200).
-- Fluxo: app sobe o .csv no bucket privado `sigos-relatorios/<tipo>/<ZA>/<AAAA-MM-DD>/<uuid>_<nome>`
--        → app_sigos_registrar (linha pendente em "17 - sigos".arquivo)
--        → Edge Function `sigos-ingest` (com o JWT do usuário): baixa, decodifica (UTF-16 LE), separa por ';'
--        → sigos_processar(arquivo, cabeçalho, linhas): TODA a regra fica aqui, numa transação.
-- Regras (decididas pelo usuário):
--   • Relação de Serviços (não executadas) = SUBSTITUIÇÃO: apaga a carteira da ZA do campo e grava o arquivo novo.
--   • Encerradas (executadas, janela de 30 dias no SIGOS) = ACUMULATIVA: só entra OS nova (pelo Número); nunca apaga.
--   • Arquivo que não bate com o campo (tipo pelo cabeçalho, ZA pela Gerência/Unidade das linhas) é recusado sem mexer no banco.
-- LGPD: "Responsável" vem "CPF - NOME" → só o nome; Identificador do Cliente, Telefone e Placa não são gravados. Bucket privado.
-- Acesso: helper único public.sigos_pode_carregar(uid) — por ora qualquer usuário logado e ativo (usuário define depois).

create schema if not exists "17 - sigos";
revoke all on schema "17 - sigos" from public;

-- ---------------------------------------------------------------- de-para gerência → ZA (editável)
create table if not exists "17 - sigos".gerencia_za (
  gerencia  text primary key,
  consorcio text not null check (consorcio in ('ZA1004','ZA0200'))
);
insert into "17 - sigos".gerencia_za values ('GRCN','ZA1004'), ('GRMS','ZA0200'), ('ELBE','ZA0200')
on conflict (gerencia) do nothing;

-- ---------------------------------------------------------------- log de cargas (nunca apaga)
create table if not exists "17 - sigos".arquivo (
  id             uuid primary key default gen_random_uuid(),
  slot_tipo      text not null check (slot_tipo in ('relacao','encerradas')),
  slot_za        text not null check (slot_za in ('ZA1004','ZA0200')),
  storage_path   text not null unique,
  nome_original  text,
  tamanho_bytes  int,
  sha256         text,
  tipo_detectado text,
  za_detectada   text,
  gerencias      text,
  periodo_ini    date,
  periodo_fim    date,
  linhas_lidas   int,
  inseridas      int,
  ja_existentes  int,
  removidas      int,
  status         text not null default 'pendente' check (status in ('pendente','ok','erro')),
  erro           text,
  aviso          text,
  enviado_por    uuid references public.perfil(id),
  enviado_em     timestamptz not null default now(),
  processado_em  timestamptz
);
create index if not exists arquivo_slot_idx on "17 - sigos".arquivo (slot_tipo, slot_za, enviado_em desc);
create index if not exists arquivo_sha_idx  on "17 - sigos".arquivo (sha256);

-- ---------------------------------------------------------------- carteira atual (Relação de Serviços)
create table if not exists "17 - sigos".os_aberta (
  numero              text primary key,
  consorcio           text not null,
  unidade             text,
  empresa             text,
  cod_servico         text,
  desc_servico        text,
  os_origem           text,
  cod_os_origem       text,
  desc_os_origem      text,
  equipe              text,
  responsavel         text,
  tipo_atendimento    text,
  classificacao       text,
  status              text,
  unidade_operacional text,
  matricula           bigint,
  endereco            text,
  abertura            timestamp,
  limite              timestamp,
  enc_previsto        timestamp,
  enc_realizado       timestamp,
  visitas             int,
  ranqueamento        int,
  arquivo_id          uuid not null references "17 - sigos".arquivo(id)
);
create index if not exists os_aberta_za_idx  on "17 - sigos".os_aberta (consorcio);
create index if not exists os_aberta_mat_idx on "17 - sigos".os_aberta (matricula);

-- ---------------------------------------------------------------- histórico acumulado (Encerradas)
create table if not exists "17 - sigos".os_encerrada (
  numero                text primary key,
  consorcio             text not null,
  diretoria             text,
  superintendencia      text,
  gerencia              text,
  escritorio_local      text,
  empresa               text,
  classificacao         text,
  status                text,
  cod_servico           text,
  desc_servico          text,
  os_origem             text,
  cod_os_origem         text,
  desc_os_origem        text,
  caracteristica_equipe text,
  origem                text,
  unidade_operacional   text,
  matricula             bigint,
  endereco              text,
  lat_imovel            numeric,
  lon_imovel            numeric,
  lat_foto              numeric,
  lon_foto              numeric,
  geom_imovel           geometry(Point,31983),
  geom_foto             geometry(Point,31983),
  data_geracao          timestamp,
  limite                timestamp,
  execucao              timestamp,
  tempo_padrao_min      numeric,
  tempo_execucao_min    numeric,
  tempo_atendimento     numeric,
  visitas               int,
  equipe                text,
  responsavel           text,
  qtde_empregados       int,
  integrantes           text,
  empresa_contratada    text,
  reclamacao            text,
  resultado             text,
  ocorrencia            text,
  arquivo_id            uuid not null references "17 - sigos".arquivo(id),
  carregado_em          timestamptz not null default now()
);
create index if not exists os_enc_za_idx   on "17 - sigos".os_encerrada (consorcio, execucao);
create index if not exists os_enc_mat_idx  on "17 - sigos".os_encerrada (matricula);
create index if not exists os_enc_gimv_idx on "17 - sigos".os_encerrada using gist (geom_imovel);

alter table "17 - sigos".gerencia_za  enable row level security;   -- sem policy: só via RPC definer
alter table "17 - sigos".arquivo      enable row level security;
alter table "17 - sigos".os_aberta    enable row level security;
alter table "17 - sigos".os_encerrada enable row level security;
revoke all on all tables in schema "17 - sigos" from public, anon, authenticated;

-- ---------------------------------------------------------------- helpers
-- Quem pode enviar/ver as cargas. ⚠️ Por ora: qualquer usuário logado e ativo (regra definitiva = trocar só esta função).
create or replace function public.sigos_pode_carregar(p_uid uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select p_uid is not null and exists(select 1 from public.perfil where id = p_uid and coalesce(ativo, true));
$$;
revoke all on function public.sigos_pode_carregar(uuid) from public, anon;
grant execute on function public.sigos_pode_carregar(uuid) to authenticated;

-- Cabeçalho → chave: minúsculo, sem acento, não-alfanumérico vira '_' ("Matrícula do Imóvel" → matricula_do_imovel).
create or replace function "17 - sigos".norm_cab(t text)
returns text language sql immutable as $$
  select trim(both '_' from regexp_replace(
    translate(lower(btrim(coalesce(t,''), E' \t\r\n﻿')), 'áàâãäéèêëíìîïóòôõöúùûüç', 'aaaaaeeeeiiiiooooouuuuc'),
    '[^a-z0-9]+', '_', 'g'));
$$;

-- Valor: tira o ="…" do SIGOS, apara e vazio vira null.
create or replace function "17 - sigos".val(o jsonb, k text)
returns text language sql immutable as $$
  select nullif(btrim(regexp_replace(coalesce(o->>k, ''), '^="(.*)"$', '\1')), '');
$$;
create or replace function "17 - sigos".ts(v text)
returns timestamp language sql immutable as $$
  select case when v ~ '^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}(:\d{2})?)?$' then v::timestamp end;
$$;
create or replace function "17 - sigos".num(v text)
returns numeric language sql immutable as $$
  select case when replace(v, ',', '.') ~ '^-?\d+(\.\d+)?$' then replace(v, ',', '.')::numeric end;
$$;
create or replace function "17 - sigos".inteiro(v text)
returns int language sql immutable as $$
  select case when v ~ '^-?\d{1,9}$' then v::int end;
$$;
create or replace function "17 - sigos".matric(v text)
returns bigint language sql immutable as $$
  select case when v ~ '^\d{1,18}$' then v::bigint end;
$$;
-- Nome sem CPF: "70310072670 - CIBELE FELIX" → "CIBELE FELIX".
create or replace function "17 - sigos".sem_cpf(v text)
returns text language sql immutable as $$
  select nullif(btrim(regexp_replace(coalesce(v,''), '^\s*[0-9.\-]{11,14}\s*-\s*', '')), '');
$$;
-- Ponto WGS84 → 31983; 0,0 / vazio vira null.
create or replace function "17 - sigos".ponto(lat numeric, lon numeric)
returns geometry language sql immutable as $$
  select case when lat is not null and lon is not null and lat <> 0 and lon <> 0
              then st_transform(st_setsrid(st_makepoint(lon, lat), 4326), 31983) end;
$$;

-- ---------------------------------------------------------------- RPCs do app
-- 1) Registra o arquivo já enviado ao bucket (path tem que estar na pasta do campo).
create or replace function public.app_sigos_registrar(p_slot_tipo text, p_slot_za text, p_path text, p_nome text, p_tamanho int default null)
returns uuid language plpgsql volatile security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  if not public.sigos_pode_carregar(auth.uid()) then raise exception 'sem permissão'; end if;
  if p_slot_tipo not in ('relacao','encerradas') or p_slot_za not in ('ZA1004','ZA0200') then raise exception 'campo inválido'; end if;
  if p_path is null or p_path not like p_slot_tipo || '/' || p_slot_za || '/%' then raise exception 'caminho fora da pasta do campo'; end if;
  insert into "17 - sigos".arquivo (slot_tipo, slot_za, storage_path, nome_original, tamanho_bytes, enviado_por)
  values (p_slot_tipo, p_slot_za, p_path, left(p_nome, 300), p_tamanho, auth.uid())
  returning id into v_id;
  return v_id;
end $$;

-- 2) Info do arquivo p/ a Edge Function (path + campo).
create or replace function public.app_sigos_arquivo_info(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare r jsonb;
begin
  if not public.sigos_pode_carregar(auth.uid()) then raise exception 'sem permissão'; end if;
  select jsonb_build_object('id', id, 'storage_path', storage_path, 'slot_tipo', slot_tipo, 'slot_za', slot_za, 'status', status)
    into r from "17 - sigos".arquivo where id = p_id;
  if r is null then raise exception 'arquivo não encontrado'; end if;
  return r;
end $$;

-- 3) Falha antes do processamento (download/decodificação) — grava o erro p/ o campo mostrar "Reprocessar".
create or replace function public.app_sigos_falha(p_id uuid, p_erro text)
returns void language plpgsql volatile security definer set search_path to 'public' as $$
begin
  if not public.sigos_pode_carregar(auth.uid()) then raise exception 'sem permissão'; end if;
  update "17 - sigos".arquivo set status = 'erro', erro = left(p_erro, 1000), processado_em = now()
   where id = p_id and status <> 'ok';
end $$;

-- 4) Processa: valida contra o campo e aplica a regra. Nunca levanta erro de validação: grava status/erro e devolve o resumo.
--    p_cabecalho = 1ª linha do CSV (texto cru); p_linhas = array de arrays (texto cru, na ordem do cabeçalho).
create or replace function public.sigos_processar(p_arquivo uuid, p_cabecalho text[], p_linhas jsonb,
                                                 p_sha256 text default null, p_tamanho int default null)
returns jsonb language plpgsql volatile security definer set search_path to 'public', '17 - sigos' as $$
declare
  a "17 - sigos".arquivo%rowtype;
  cab text[]; v_tipo text; v_n int; v_za text; v_ger text; v_sem text; v_err text; v_aviso text;
  v_ins int := 0; v_rem int := 0; v_ini date; v_fim date; v_mais_nova timestamptz;
begin
  if not public.sigos_pode_carregar(auth.uid()) then raise exception 'sem permissão'; end if;
  select * into a from "17 - sigos".arquivo where id = p_arquivo for update;
  if not found then raise exception 'arquivo não encontrado'; end if;
  if a.status = 'ok' then
    return jsonb_build_object('ok', true, 'ja_processado', true, 'id', a.id, 'tipo', a.tipo_detectado, 'za', a.za_detectada,
      'linhas', a.linhas_lidas, 'inseridas', a.inseridas, 'ja_existentes', a.ja_existentes, 'removidas', a.removidas, 'aviso', a.aviso);
  end if;
  -- uma carga por campo de cada vez
  perform pg_advisory_xact_lock(hashtext('sigos:' || a.slot_tipo || ':' || a.slot_za));

  cab := array(select "17 - sigos".norm_cab(x) from unnest(p_cabecalho) x);
  v_tipo := case when 'abertura_os' = any(cab) and 'os' = any(cab) then 'relacao'
                 when 'data_de_execucao' = any(cab) and 'numero' = any(cab) then 'encerradas' end;

  drop table if exists _sigos_l;
  create temp table _sigos_l on commit drop as
    select t.ord, (select coalesce(jsonb_object_agg(cab[e.i], e.v), '{}'::jsonb)
                     from jsonb_array_elements_text(t.r) with ordinality e(v, i)
                    where e.i <= coalesce(array_length(cab, 1), 0) and cab[e.i] <> '') o
      from jsonb_array_elements(coalesce(p_linhas, '[]'::jsonb)) with ordinality t(r, ord)
     where jsonb_typeof(t.r) = 'array';
  alter table _sigos_l add column ger text, add column za text, add column numero text;
  update _sigos_l set
    ger    = upper(case when v_tipo = 'relacao' then "17 - sigos".val(o, 'unidade')
                        else coalesce("17 - sigos".val(o, 'gerencia'), "17 - sigos".val(o, 'escritorio_local')) end),
    numero = "17 - sigos".val(o, case when v_tipo = 'relacao' then 'os' else 'numero' end);
  delete from _sigos_l where numero is null;   -- linhas vazias / rodapé
  update _sigos_l l set za = g.consorcio from "17 - sigos".gerencia_za g where g.gerencia = l.ger;
  select count(*) into v_n from _sigos_l;
  select string_agg(distinct ger, ', ') into v_ger from _sigos_l;
  select string_agg(distinct coalesce(ger, '(vazia)'), ', ') into v_sem from _sigos_l where za is null;
  select string_agg(distinct za, ', ') into v_za from _sigos_l where za is not null;

  -- validações (não mexem nos dados)
  if v_tipo is null then
    v_err := 'Arquivo não reconhecido: o cabeçalho não é de "Relação de Serviços" nem de "Encerradas" do SIGOS.';
  elsif v_tipo <> a.slot_tipo then
    v_err := format('Este arquivo é de %s, mas foi enviado no campo de %s.',
                    case v_tipo when 'relacao' then 'Relação de Serviços' else 'Encerradas' end,
                    case a.slot_tipo when 'relacao' then 'Relação de Serviços' else 'Encerradas' end);
  elsif v_n = 0 then
    v_err := 'Arquivo sem nenhuma OS.';
  elsif v_sem is not null then
    v_err := format('Gerência/unidade sem ZA cadastrada: %s.', v_sem);
  elsif v_za <> a.slot_za then
    v_err := format('Este arquivo é da %s (%s), mas foi enviado no campo da %s.',
                    v_za, case v_za when 'ZA1004' then 'Contagem' when 'ZA0200' then 'Betim' else 'mais de uma ZA' end, a.slot_za);
  elsif v_tipo = 'relacao' then
    select max(enviado_em) into v_mais_nova from "17 - sigos".arquivo
     where slot_tipo = a.slot_tipo and slot_za = a.slot_za and status = 'ok' and enviado_em > a.enviado_em;
    if v_mais_nova is not null then
      v_err := format('Já existe uma Relação mais nova carregada neste campo (enviada em %s); esta não substitui a carteira.',
                      to_char(v_mais_nova at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'));
    end if;
  end if;

  if p_sha256 is not null then
    select format('Arquivo idêntico ao já enviado em %s.', to_char(enviado_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'))
      into v_aviso from "17 - sigos".arquivo
     where sha256 = p_sha256 and status = 'ok' and id <> a.id order by enviado_em desc limit 1;
  end if;

  if v_err is not null then
    update "17 - sigos".arquivo set status = 'erro', erro = v_err, tipo_detectado = v_tipo, za_detectada = v_za,
           gerencias = v_ger, linhas_lidas = v_n, sha256 = coalesce(p_sha256, sha256),
           tamanho_bytes = coalesce(p_tamanho, tamanho_bytes), processado_em = now()
     where id = a.id;
    return jsonb_build_object('ok', false, 'id', a.id, 'erro', v_err, 'tipo', v_tipo, 'za', v_za, 'linhas', v_n);
  end if;

  -- aplica a regra (bloco próprio: se der erro inesperado, desfaz só os dados e grava o erro no log)
  begin
    if v_tipo = 'relacao' then
      delete from os_aberta where consorcio = a.slot_za;
      get diagnostics v_rem = row_count;
      insert into os_aberta (numero, consorcio, unidade, empresa, cod_servico, desc_servico, os_origem, cod_os_origem,
        desc_os_origem, equipe, responsavel, tipo_atendimento, classificacao, status, unidade_operacional, matricula, endereco,
        abertura, limite, enc_previsto, enc_realizado, visitas, ranqueamento, arquivo_id)
      select distinct on (l.numero)
        l.numero, a.slot_za, l.ger, val(l.o,'empresa'), val(l.o,'codigo_do_servico'), val(l.o,'descricao_do_servico'),
        val(l.o,'os_de_origem'), val(l.o,'codigo_os_de_origem'), val(l.o,'desc_os_de_origem'),
        nullif(btrim(split_part(x.er, ' - ', 1)), ''),
        case when strpos(x.er, ' - ') > 0 then sem_cpf(substr(x.er, strpos(x.er, ' - ') + 3)) end,
        val(l.o,'tipo_de_atendimento'), val(l.o,'classificacao'), val(l.o,'status_da_os'), val(l.o,'unidade_operacional'),
        matric(val(l.o,'matricula_do_imovel')), val(l.o,'endereco'),
        ts(val(l.o,'abertura_os')), ts(val(l.o,'limite_atendimento')), ts(val(l.o,'encerramento_previsto')),
        ts(val(l.o,'encerramento_realizado')), inteiro(val(l.o,'visitas')), inteiro(val(l.o,'ranqueamento')), a.id
      from _sigos_l l cross join lateral (select val(l.o,'equipe_e_responsavel') er) x
      order by l.numero, l.ord desc
      on conflict (numero) do update set consorcio = excluded.consorcio, arquivo_id = excluded.arquivo_id;
      get diagnostics v_ins = row_count;
    else
      v_ini := to_date(substring(a.nome_original from 'Encerradas(\d{8})a\d{8}'), 'YYYYMMDD');
      v_fim := to_date(substring(a.nome_original from 'Encerradas\d{8}a(\d{8})'), 'YYYYMMDD');
      insert into os_encerrada (numero, consorcio, diretoria, superintendencia, gerencia, escritorio_local, empresa, classificacao,
        status, cod_servico, desc_servico, os_origem, cod_os_origem, desc_os_origem, caracteristica_equipe, origem,
        unidade_operacional, matricula, endereco, lat_imovel, lon_imovel, lat_foto, lon_foto, geom_imovel, geom_foto,
        data_geracao, limite, execucao, tempo_padrao_min, tempo_execucao_min, tempo_atendimento, visitas, equipe, responsavel,
        qtde_empregados, integrantes, empresa_contratada, reclamacao, resultado, ocorrencia, arquivo_id)
      select distinct on (l.numero)
        l.numero, a.slot_za, val(l.o,'diretoria'), val(l.o,'superintendencia'), val(l.o,'gerencia'), val(l.o,'escritorio_local'),
        val(l.o,'empresa'), val(l.o,'classificacao'), val(l.o,'status'), val(l.o,'codigo'), val(l.o,'descricao_do_servico'),
        val(l.o,'os_de_origem'), val(l.o,'codigo_os_de_origem'), val(l.o,'desc_os_de_origem'), val(l.o,'caracteristica_da_equipe'),
        val(l.o,'origem'), val(l.o,'unidade_operacional'), matric(val(l.o,'matricula_imovel')), val(l.o,'endereco'),
        nullif(g.la, 0), nullif(g.lo, 0), nullif(g.fa, 0), nullif(g.fo, 0), ponto(g.la, g.lo), ponto(g.fa, g.fo),
        ts(val(l.o,'data_de_geracao')), ts(val(l.o,'data_limite_atendimento')), ts(val(l.o,'data_de_execucao')),
        num(val(l.o,'tempo_padrao')), num(val(l.o,'tempo_de_execucao_minutos')), num(val(l.o,'tempo_de_atendimento')),
        inteiro(val(l.o,'visitas_realizadas')), val(l.o,'codigo_equipe'), sem_cpf(val(l.o,'responsavel')),
        inteiro(val(l.o,'qtde_de_empregados')), val(l.o,'integrantes_da_equipe'), val(l.o,'empresa_contratada'),
        val(l.o,'reclamacao'), val(l.o,'resultado'), val(l.o,'ocorrencia'), a.id
      from _sigos_l l
      cross join lateral (select num(val(l.o,'latitude')) la, num(val(l.o,'longitude')) lo,
                                 num(val(l.o,'latitudeultimafoto')) fa, num(val(l.o,'longitudeultimafoto')) fo) g
      order by l.numero, l.ord desc
      on conflict (numero) do nothing;
      get diagnostics v_ins = row_count;
    end if;
  exception when others then
    v_err := 'Falha ao gravar: ' || sqlerrm;
  end;

  if v_err is not null then
    update arquivo set status = 'erro', erro = v_err, tipo_detectado = v_tipo, za_detectada = v_za, gerencias = v_ger,
           linhas_lidas = v_n, sha256 = coalesce(p_sha256, sha256), processado_em = now()
     where id = a.id;
    return jsonb_build_object('ok', false, 'id', a.id, 'erro', v_err, 'tipo', v_tipo, 'za', v_za, 'linhas', v_n);
  end if;

  update arquivo set status = 'ok', erro = null, aviso = v_aviso, tipo_detectado = v_tipo, za_detectada = v_za,
         gerencias = v_ger, periodo_ini = v_ini, periodo_fim = v_fim, linhas_lidas = v_n, inseridas = v_ins,
         ja_existentes = case when v_tipo = 'encerradas' then v_n - v_ins end,
         removidas = case when v_tipo = 'relacao' then v_rem end,
         sha256 = coalesce(p_sha256, sha256), tamanho_bytes = coalesce(p_tamanho, tamanho_bytes), processado_em = now()
   where id = a.id;
  return jsonb_build_object('ok', true, 'id', a.id, 'tipo', v_tipo, 'za', v_za, 'linhas', v_n, 'inseridas', v_ins,
    'ja_existentes', case when v_tipo = 'encerradas' then v_n - v_ins end,
    'removidas', case when v_tipo = 'relacao' then v_rem end, 'aviso', v_aviso);
end $$;

-- 5) Os 4 campos: última carga de cada um + o que está no banco agora.
create or replace function public.app_sigos_slots()
returns jsonb language plpgsql stable security definer set search_path to 'public', '17 - sigos' as $$
begin
  if not public.sigos_pode_carregar(auth.uid()) then raise exception 'sem permissão'; end if;
  return (
    select jsonb_agg(jsonb_build_object(
      'tipo', s.tipo, 'za', s.za,
      'ultima', (select jsonb_build_object('id', f.id, 'nome', f.nome_original, 'status', f.status, 'erro', f.erro, 'aviso', f.aviso,
                   'enviado_em', f.enviado_em, 'por', (select coalesce(p.nome, p.email) from perfil p where p.id = f.enviado_por),
                   'linhas', f.linhas_lidas, 'inseridas', f.inseridas, 'ja_existentes', f.ja_existentes, 'removidas', f.removidas,
                   'periodo_ini', f.periodo_ini, 'periodo_fim', f.periodo_fim)
                 from arquivo f where f.slot_tipo = s.tipo and f.slot_za = s.za order by f.enviado_em desc limit 1),
      'ultima_ok_em', (select max(f.enviado_em) from arquivo f where f.slot_tipo = s.tipo and f.slot_za = s.za and f.status = 'ok'),
      'no_banco', case when s.tipo = 'relacao' then (select count(*) from os_aberta where consorcio = s.za)
                       else (select count(*) from os_encerrada where consorcio = s.za) end,
      'exec_min', case when s.tipo = 'encerradas' then (select min(execucao) from os_encerrada where consorcio = s.za) end,
      'exec_max', case when s.tipo = 'encerradas' then (select max(execucao) from os_encerrada where consorcio = s.za) end)
      order by s.ord)
    from (values (1,'relacao','ZA1004'), (2,'relacao','ZA0200'), (3,'encerradas','ZA1004'), (4,'encerradas','ZA0200')) s(ord, tipo, za));
end $$;

-- 6) Histórico de cargas (os 4 campos misturados).
create or replace function public.app_sigos_cargas_listar(p_limite int default 60)
returns jsonb language plpgsql stable security definer set search_path to 'public', '17 - sigos' as $$
begin
  if not public.sigos_pode_carregar(auth.uid()) then raise exception 'sem permissão'; end if;
  return coalesce((
    select jsonb_agg(t.x order by t.em desc) from (
      select f.enviado_em em, jsonb_build_object('id', f.id, 'tipo', f.slot_tipo, 'za', f.slot_za, 'nome', f.nome_original,
               'status', f.status, 'erro', f.erro, 'aviso', f.aviso, 'enviado_em', f.enviado_em,
               'por', (select coalesce(p.nome, p.email) from perfil p where p.id = f.enviado_por),
               'linhas', f.linhas_lidas, 'inseridas', f.inseridas, 'ja_existentes', f.ja_existentes, 'removidas', f.removidas) x
      from arquivo f order by f.enviado_em desc limit greatest(1, least(coalesce(p_limite, 60), 500))) t), '[]'::jsonb);
end $$;

revoke all on function public.app_sigos_registrar(text, text, text, text, int) from public, anon;
revoke all on function public.app_sigos_arquivo_info(uuid) from public, anon;
revoke all on function public.app_sigos_falha(uuid, text) from public, anon;
revoke all on function public.sigos_processar(uuid, text[], jsonb, text, int) from public, anon;
revoke all on function public.app_sigos_slots() from public, anon;
revoke all on function public.app_sigos_cargas_listar(int) from public, anon;
grant execute on function public.app_sigos_registrar(text, text, text, text, int) to authenticated;
grant execute on function public.app_sigos_arquivo_info(uuid) to authenticated;
grant execute on function public.app_sigos_falha(uuid, text) to authenticated;
grant execute on function public.sigos_processar(uuid, text[], jsonb, text, int) to authenticated;
grant execute on function public.app_sigos_slots() to authenticated;
grant execute on function public.app_sigos_cargas_listar(int) to authenticated;

-- ---------------------------------------------------------------- Storage: bucket privado + policies
insert into storage.buckets (id, name, public, file_size_limit)
values ('sigos-relatorios', 'sigos-relatorios', false, 20971520)
on conflict (id) do nothing;

drop policy if exists sigos_rel_insert on storage.objects;
create policy sigos_rel_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'sigos-relatorios' and public.sigos_pode_carregar(auth.uid())
              and split_part(name, '/', 1) in ('relacao','encerradas') and split_part(name, '/', 2) in ('ZA1004','ZA0200'));
drop policy if exists sigos_rel_select on storage.objects;
create policy sigos_rel_select on storage.objects for select to authenticated
  using (bucket_id = 'sigos-relatorios' and public.sigos_pode_carregar(auth.uid()));
-- sem update/delete: o arquivo bruto fica guardado como prova de cada carga.

-- ---------------------------------------------------------------- views de consumo (schema app-only; BI pelo grupo abaixo)
create or replace view "17 - sigos".vw_os_aberta as
select o.*, f.enviado_em as carteira_de,
       (now() at time zone 'America/Sao_Paulo')::date - o.abertura::date as idade_dias,
       coalesce(o.limite < (now() at time zone 'America/Sao_Paulo'), false) as vencida
from "17 - sigos".os_aberta o join "17 - sigos".arquivo f on f.id = o.arquivo_id;

create or replace view "17 - sigos".vw_os_encerrada as
select e.*, (e.execucao <= e.limite) as no_prazo,
       round(st_distance(e.geom_imovel, e.geom_foto)::numeric, 1) as dist_foto_m,
       (e.geom_foto is null) as foto_sem_gps,
       coalesce(st_distance(e.geom_imovel, e.geom_foto) > 200, false) as foto_longe
from "17 - sigos".os_encerrada e;

create or replace view "17 - sigos".vw_os_ligacao as
select 'aberta'::text as fonte, o.numero, o.consorcio, o.cod_servico, o.desc_servico, o.classificacao, o.status,
       o.abertura as data_ref, o.matricula, l.geom
from "17 - sigos".os_aberta o left join "3 - comercial".ligacoes l on l.matricula = o.matricula
union all
select 'encerrada', e.numero, e.consorcio, e.cod_servico, e.desc_servico, e.classificacao, e.status,
       e.execucao, e.matricula, coalesce(l.geom, e.geom_imovel)
from "17 - sigos".os_encerrada e left join "3 - comercial".ligacoes l on l.matricula = e.matricula;

-- BI: grupo próprio (padrão bi_<area>_leitura) concedido ao login genérico bi_leitura. Só as views.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'bi_sigos_leitura') then create role bi_sigos_leitura nologin; end if;
end $$;
grant usage on schema "17 - sigos" to bi_sigos_leitura;
grant select on "17 - sigos".vw_os_aberta, "17 - sigos".vw_os_encerrada, "17 - sigos".vw_os_ligacao to bi_sigos_leitura;
grant bi_sigos_leitura to bi_leitura;

-- search_path fixo nos helpers (advisor function_search_path_mutable) — migração `sigos_searchpath`
alter function "17 - sigos".norm_cab(text) set search_path = pg_catalog;
alter function "17 - sigos".val(jsonb, text) set search_path = pg_catalog;
alter function "17 - sigos".ts(text) set search_path = pg_catalog;
alter function "17 - sigos".num(text) set search_path = pg_catalog;
alter function "17 - sigos".inteiro(text) set search_path = pg_catalog;
alter function "17 - sigos".matric(text) set search_path = pg_catalog;
alter function "17 - sigos".sem_cpf(text) set search_path = pg_catalog;
alter function "17 - sigos".ponto(numeric, numeric) set search_path = pg_catalog, public;
