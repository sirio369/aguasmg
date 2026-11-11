-- Carga SIGOS — ignorar escritórios fora das ZAs (2026-11-11).
-- A exportação da GNDS (Gerência de Desenvolvimento Social) traz todos os escritórios dela (GNDSEQBH, GNDSEQRN, GNDSEQSZ…),
-- mas só GNDSEQCT (ZA1004) e GNDSEQBE (ZA0200) são do contrato. Antes o arquivo inteiro era recusado ("sem ZA cadastrada").
-- Agora: linha sem ZA cuja unidade/escritório/gerência casa com um padrão de "17 - sigos".unidade_ignorar é DESCARTADA
-- (contada em arquivo.ignoradas e citada no aviso); qualquer outra unidade sem ZA continua recusando o arquivo (protege
-- contra gerência nova ou erro de exportação). Ignorar = como se a linha não existisse: não entra nem substitui carteira.
-- Depende de docs/migracao_sigos_carga_2campos.sql.

create table if not exists "17 - sigos".unidade_ignorar (
  padrao text primary key,          -- padrão LIKE contra unidade (Relação), escritório local ou gerência (Encerradas)
  motivo text
);
insert into "17 - sigos".unidade_ignorar values
  ('GNDS%', 'Escritórios da GNDS fora das ZAs (BH, RN, SZ…): só GNDSEQCT/GNDSEQBE, que estão em gerencia_za, são do contrato')
on conflict (padrao) do nothing;
alter table "17 - sigos".unidade_ignorar enable row level security;   -- app-only, sem policy (como o resto do schema)

alter table "17 - sigos".arquivo add column if not exists ignoradas int;

create or replace function public.sigos_processar(p_arquivo uuid, p_cabecalho text[], p_linhas jsonb,
                                                 p_sha256 text default null, p_tamanho int default null)
returns jsonb language plpgsql volatile security definer set search_path to 'public', '17 - sigos' as $$
declare
  a "17 - sigos".arquivo%rowtype;
  cab text[]; v_tipo text; v_n int; v_za text; v_ger text; v_sem text; v_err text; v_aviso text;
  v_ins int := 0; v_rem int := 0; v_ini date; v_fim date; v_mais_nova timestamptz;
  v_unids text[]; v_ign int := 0; v_ign_txt text;
begin
  if not public.sigos_pode_carregar(auth.uid()) then raise exception 'sem permissão'; end if;
  select * into a from "17 - sigos".arquivo where id = p_arquivo for update;
  if not found then raise exception 'arquivo não encontrado'; end if;
  if a.status = 'ok' then
    return jsonb_build_object('ok', true, 'ja_processado', true, 'id', a.id, 'tipo', a.tipo_detectado, 'za', a.za_detectada,
      'linhas', a.linhas_lidas, 'inseridas', a.inseridas, 'ja_existentes', a.ja_existentes, 'removidas', a.removidas, 'aviso', a.aviso);
  end if;
  -- uma carga de cada tipo por vez (a Relação apaga/regrava a carteira)
  perform pg_advisory_xact_lock(hashtext('sigos:' || a.slot_tipo));

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
  alter table _sigos_l add column ger text, add column esc text, add column za text, add column numero text;
  update _sigos_l set
    ger    = upper(case when v_tipo = 'relacao' then "17 - sigos".val(o, 'unidade') else "17 - sigos".val(o, 'gerencia') end),
    esc    = case when v_tipo = 'encerradas' then upper("17 - sigos".val(o, 'escritorio_local')) end,
    numero = "17 - sigos".val(o, case when v_tipo = 'relacao' then 'os' else 'numero' end)
   where true;
  delete from _sigos_l where numero is null;   -- linhas vazias / rodapé
  -- Encerradas: o escritório manda quando está no de-para (GNDSEQCT/GNDSEQBE); senão vale a gerência.
  update _sigos_l l set ger = l.esc from "17 - sigos".gerencia_za g where g.gerencia = l.esc;
  update _sigos_l l set ger = coalesce(l.ger, l.esc) where l.ger is null;
  update _sigos_l l set za = g.consorcio from "17 - sigos".gerencia_za g where g.gerencia = l.ger;
  -- linhas de unidades/escritórios fora das ZAs que vêm junto na exportação (ex.: GNDS de BH, RN, SZ…) são descartadas
  -- (lista "17 - sigos".unidade_ignorar); qualquer outra unidade sem ZA continua recusando o arquivo.
  select count(*), string_agg(distinct coalesce(l.esc, l.ger), ', ') into v_ign, v_ign_txt
    from _sigos_l l where l.za is null and exists (select 1 from "17 - sigos".unidade_ignorar i
                                                     where coalesce(l.esc, '') like i.padrao or coalesce(l.ger, '') like i.padrao);
  delete from _sigos_l l where l.za is null and exists (select 1 from "17 - sigos".unidade_ignorar i
                                                          where coalesce(l.esc, '') like i.padrao or coalesce(l.ger, '') like i.padrao);
  select count(*) into v_n from _sigos_l;
  select string_agg(distinct ger, ', ') into v_ger from _sigos_l;
  select string_agg(distinct coalesce(ger, '(vazia)') || case when esc is not null and esc <> coalesce(ger, '') then ' / ' || esc else '' end, ', ')
    into v_sem from _sigos_l where za is null;
  select string_agg(distinct za, ', ' order by za) into v_za from _sigos_l where za is not null;
  select array_agg(distinct ger) into v_unids from _sigos_l;

  -- validações (não mexem nos dados)
  if v_tipo is null then
    v_err := 'Arquivo não reconhecido: o cabeçalho não é de "Relação de Serviços" nem de "Encerradas" do SIGOS.';
  elsif v_tipo <> a.slot_tipo then
    v_err := format('Este arquivo é de %s, mas foi enviado no campo de %s.',
                    case v_tipo when 'relacao' then 'Relação de Serviços' else 'Encerradas' end,
                    case a.slot_tipo when 'relacao' then 'Relação de Serviços' else 'Encerradas' end);
  elsif v_n = 0 then
    v_err := case when v_ign > 0 then format('Nenhuma OS das ZAs no arquivo (%s OS de %s ignoradas).', v_ign, v_ign_txt)
                  else 'Arquivo sem nenhuma OS.' end;
  elsif v_sem is not null then
    v_err := format('Gerência/unidade sem ZA cadastrada: %s.', v_sem);
  elsif a.slot_za is not null and v_za <> a.slot_za then   -- app antigo (4 campos)
    v_err := format('Este arquivo é da %s (%s), mas foi enviado no campo da %s.',
                    v_za, case v_za when 'ZA1004' then 'Contagem' when 'ZA0200' then 'Betim' else 'mais de uma ZA' end, a.slot_za);
  elsif v_tipo = 'relacao' then
    -- não deixa uma Relação velha sobrescrever a carteira de uma unidade que já tem Relação mais nova
    select f.enviado_em into v_mais_nova from "17 - sigos".arquivo f
     where f.slot_tipo = 'relacao' and f.status = 'ok' and f.enviado_em > a.enviado_em
       and string_to_array(f.gerencias, ', ') && v_unids
     order by f.enviado_em desc limit 1;
    if v_mais_nova is not null then
      v_err := format('Já existe uma Relação mais nova carregada para %s (enviada em %s); esta não substitui a carteira.',
                      array_to_string(v_unids, ', '), to_char(v_mais_nova at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'));
    end if;
  end if;

  if p_sha256 is not null then
    select format('Arquivo idêntico ao já enviado em %s.', to_char(enviado_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'))
      into v_aviso from "17 - sigos".arquivo
     where sha256 = p_sha256 and status = 'ok' and id <> a.id order by enviado_em desc limit 1;
  end if;
  if v_ign > 0 then
    v_aviso := concat_ws(' ', format('%s OS de fora das ZAs ignoradas (%s).', v_ign, v_ign_txt), v_aviso);
  end if;

  if v_err is not null then
    update "17 - sigos".arquivo set status = 'erro', erro = v_err, tipo_detectado = v_tipo, za_detectada = v_za,
           gerencias = v_ger, linhas_lidas = v_n, ignoradas = v_ign, sha256 = coalesce(p_sha256, sha256),
           tamanho_bytes = coalesce(p_tamanho, tamanho_bytes), processado_em = now()
     where id = a.id;
    return jsonb_build_object('ok', false, 'id', a.id, 'erro', v_err, 'tipo', v_tipo, 'za', v_za, 'linhas', v_n);
  end if;

  -- aplica a regra (bloco próprio: se der erro inesperado, desfaz só os dados e grava o erro no log)
  begin
    if v_tipo = 'relacao' then
      delete from os_aberta where unidade = any(v_unids);
      get diagnostics v_rem = row_count;
      insert into os_aberta (numero, consorcio, unidade, empresa, cod_servico, desc_servico, os_origem, cod_os_origem,
        desc_os_origem, equipe, responsavel, tipo_atendimento, classificacao, status, unidade_operacional, matricula, endereco,
        abertura, limite, enc_previsto, enc_realizado, visitas, ranqueamento, arquivo_id)
      select distinct on (l.numero)
        l.numero, l.za, l.ger, val(l.o,'empresa'), val(l.o,'codigo_do_servico'), val(l.o,'descricao_do_servico'),
        val(l.o,'os_de_origem'), val(l.o,'codigo_os_de_origem'), val(l.o,'desc_os_de_origem'),
        nullif(btrim(split_part(x.er, ' - ', 1)), ''),
        case when strpos(x.er, ' - ') > 0 then sem_cpf(substr(x.er, strpos(x.er, ' - ') + 3)) end,
        val(l.o,'tipo_de_atendimento'), val(l.o,'classificacao'), val(l.o,'status_da_os'), val(l.o,'unidade_operacional'),
        matric(val(l.o,'matricula_do_imovel')), val(l.o,'endereco'),
        ts(val(l.o,'abertura_os')), ts(val(l.o,'limite_atendimento')), ts(val(l.o,'encerramento_previsto')),
        ts(val(l.o,'encerramento_realizado')), inteiro(val(l.o,'visitas')), inteiro(val(l.o,'ranqueamento')), a.id
      from _sigos_l l cross join lateral (select val(l.o,'equipe_e_responsavel') er) x
      order by l.numero, l.ord desc
      on conflict (numero) do update set consorcio = excluded.consorcio, unidade = excluded.unidade, arquivo_id = excluded.arquivo_id;
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
        l.numero, l.za, val(l.o,'diretoria'), val(l.o,'superintendencia'), val(l.o,'gerencia'), val(l.o,'escritorio_local'),
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
           linhas_lidas = v_n, ignoradas = v_ign, sha256 = coalesce(p_sha256, sha256), processado_em = now()
     where id = a.id;
    return jsonb_build_object('ok', false, 'id', a.id, 'erro', v_err, 'tipo', v_tipo, 'za', v_za, 'linhas', v_n);
  end if;

  update arquivo set status = 'ok', erro = null, aviso = v_aviso, tipo_detectado = v_tipo, za_detectada = v_za,
         gerencias = v_ger, periodo_ini = v_ini, periodo_fim = v_fim, linhas_lidas = v_n, ignoradas = v_ign, inseridas = v_ins,
         ja_existentes = case when v_tipo = 'encerradas' then v_n - v_ins end,
         removidas = case when v_tipo = 'relacao' then v_rem end,
         sha256 = coalesce(p_sha256, sha256), tamanho_bytes = coalesce(p_tamanho, tamanho_bytes), processado_em = now()
   where id = a.id;
  return jsonb_build_object('ok', true, 'id', a.id, 'tipo', v_tipo, 'za', v_za, 'unidades', v_ger, 'linhas', v_n, 'ignoradas', v_ign, 'inseridas', v_ins,
    'ja_existentes', case when v_tipo = 'encerradas' then v_n - v_ins end,
    'removidas', case when v_tipo = 'relacao' then v_rem end, 'aviso', v_aviso);
end $$;

-- histórico: + ignoradas
create or replace function public.app_sigos_cargas_listar(p_limite int default 60)
returns jsonb language plpgsql stable security definer set search_path to 'public', '17 - sigos' as $$
begin
  if not public.sigos_pode_carregar(auth.uid()) then raise exception 'sem permissão'; end if;
  return coalesce((
    select jsonb_agg(t.x order by t.em desc) from (
      select f.enviado_em em, jsonb_build_object('id', f.id, 'tipo', f.slot_tipo, 'za', coalesce(f.za_detectada, f.slot_za),
               'slot_za', f.slot_za, 'unidades', f.gerencias, 'nome', f.nome_original,
               'status', f.status, 'erro', f.erro, 'aviso', f.aviso, 'enviado_em', f.enviado_em,
               'por', (select coalesce(p.nome, p.email) from perfil p where p.id = f.enviado_por),
               'linhas', f.linhas_lidas, 'ignoradas', f.ignoradas, 'inseridas', f.inseridas, 'ja_existentes', f.ja_existentes, 'removidas', f.removidas) x
      from arquivo f order by f.enviado_em desc limit greatest(1, least(coalesce(p_limite, 60), 500))) t), '[]'::jsonb);
end $$;
