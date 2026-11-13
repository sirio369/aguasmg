-- RH › Carga RH (2026-11-13) — base única de horas a partir do "Relatório de Ponto do Funcionário" (DIMEP Kairos, PDF).
-- Fluxo: o app lê o PDF no navegador (pdf.js) → app_rh_ponto_checar(sha256) (mesmo arquivo já carregado? para aqui)
--        → sobe o PDF no bucket privado `rh-ponto/<AAAA-MM-DD>/<uuid>_<nome>` (prova da carga)
--        → app_rh_registrar (linha pendente em "18 - rh".arquivo) → app_rh_ponto_processar(arquivo, dados lidos).
--        TODA a regra fica no SQL; o navegador só lê o PDF.
-- Base única (sem duplicação): 1 linha por funcionário × dia em "18 - rh".ponto_dia (PK funcionario_id + data).
--   • Funcionário = empresa (CNPJ do relatório) + CPF. A empresa dá o consórcio (de-para "18 - rh".empresa).
--   • Relatórios com períodos sobrepostos: o dia fica com a versão do relatório EMITIDO POR ÚLTIMO.
--     Relatório mais antigo que o já gravado para aquele dia não mexe nele (conta como "dias antigos").
--   • Dia que mudou entre um relatório e outro (ex.: RH corrigiu no Kairos) → versão anterior vai para ponto_dia_hist
--     e `versao` sobe — é isso que vai permitir à RH conferir as correções dos gestores.
--   • Dia da emissão (ou depois) fica `parcial` (relatório tirado no meio do dia: batidas incompletas).
--   • Mesmo PDF de novo (sha256) → o app nem sobe; se chegar ao banco, só gera aviso (reprocessar é inofensivo).
-- LGPD: CPF/PIS ficam só aqui (schema app-only, RLS sem policy, acesso só por RPC); a tela não mostra CPF.
-- Acesso: public.rh_pode_carregar(uid) = admin OU perfil.rh_acesso (marcado na ⚙️ do RH pelo admin).

create schema if not exists "18 - rh";
revoke all on schema "18 - rh" from public;

alter table public.perfil add column if not exists rh_acesso boolean not null default false;

-- ---------------------------------------------------------------- empresa (CNPJ do relatório) → consórcio
create table if not exists "18 - rh".empresa (
  cnpj      text primary key,                 -- só dígitos
  nome      text not null,
  sigla     text not null,
  consorcio text not null check (consorcio in ('ZA1004','ZA0200'))
);
insert into "18 - rh".empresa values
  ('66149888000137', 'CONSORCIO AGUAS INTEGRADAS',   'AI', 'ZA1004'),
  ('66475418000163', 'CONSORCIO EFICIENCIA HIDRICA', 'EH', 'ZA0200')
on conflict (cnpj) do nothing;

-- ---------------------------------------------------------------- log de cargas (nunca apaga)
create table if not exists "18 - rh".arquivo (
  id             uuid primary key default gen_random_uuid(),
  storage_path   text not null unique,
  nome_original  text,
  tamanho_bytes  int,
  sha256         text,
  cnpj           text,
  empresa        text,
  consorcio      text,
  emitido_em     timestamptz,
  periodo_ini    date,
  periodo_fim    date,
  paginas        int,
  funcionarios   int,
  dias           int,
  dias_novos     int,
  dias_alterados int,
  dias_iguais    int,
  dias_antigos   int,
  status         text not null default 'pendente' check (status in ('pendente','ok','erro')),
  erro           text,
  aviso          text,
  enviado_por    uuid,
  enviado_em     timestamptz not null default now(),
  processado_em  timestamptz
);
create index if not exists rh_arquivo_sha_idx on "18 - rh".arquivo (sha256) where status = 'ok';

-- ---------------------------------------------------------------- funcionário (empresa + CPF)
create table if not exists "18 - rh".funcionario (
  id             bigserial primary key,
  cnpj           text not null references "18 - rh".empresa(cnpj),
  cpf            text not null check (cpf ~ '^\d{11}$'),
  nome           text not null,
  matricula      text,
  pis            text,
  admissao       date,
  cargo          text,
  base_horas     text,
  perfil_id      uuid references public.perfil(id) on delete set null,   -- casado pelo CPF (gestor = aprovador 1/2 do perfil)
  ultimo_arquivo uuid references "18 - rh".arquivo(id),
  atualizado_em  timestamptz not null default now(),
  unique (cnpj, cpf)
);
create index if not exists rh_func_perfil_idx on "18 - rh".funcionario (perfil_id);

-- ---------------------------------------------------------------- base única: funcionário × dia
create table if not exists "18 - rh".ponto_dia (
  funcionario_id bigint not null references "18 - rh".funcionario(id) on delete cascade,
  data           date   not null,
  dia_semana     text,
  horario        text,                 -- jornada prevista ("07:00 - 12:00 | 13:00 - 17:00" / "Descanso Semanal")
  marcacoes      text[] not null default '{}',
  marc_txt       text,
  htrab_min      int,
  he_min         int,
  adn_min        int,
  adnhe_min      int,
  cponte_min     int,
  atraso_min     int not null default 0,
  falta_min      int not null default 0,
  dsr_min        int not null default 0,
  descontos      jsonb not null default '[]',
  bh_deb_min     int,
  bh_cred_min    int,
  justificativa  text,
  parcial        boolean not null default false,
  emitido_em     timestamptz not null,
  arquivo_id     uuid not null references "18 - rh".arquivo(id),
  hash           text not null,
  versao         int not null default 1,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  primary key (funcionario_id, data)
);
create index if not exists rh_dia_data_idx on "18 - rh".ponto_dia (data);

-- versões anteriores de um dia (quando um relatório mais novo trouxe valores diferentes)
create table if not exists "18 - rh".ponto_dia_hist (
  id                bigserial primary key,
  funcionario_id    bigint not null,
  data              date   not null,
  versao            int    not null,
  dados             jsonb  not null,
  arquivo_id        uuid,
  emitido_em        timestamptz,
  substituido_por   uuid,
  substituido_em    timestamptz not null default now()
);
create index if not exists rh_hist_dia_idx on "18 - rh".ponto_dia_hist (funcionario_id, data);

-- rodapé do relatório (por carga × funcionário): totais, HE por percentual, saldos de banco de horas
create table if not exists "18 - rh".ponto_resumo (
  arquivo_id       uuid   not null references "18 - rh".arquivo(id),
  funcionario_id   bigint not null references "18 - rh".funcionario(id) on delete cascade,
  periodo_ini      date,
  periodo_fim      date,
  dias_trabalhados int,
  atrasos_min      int,
  faltas_min       int,
  dsr_min          int,
  he_percentual    jsonb not null default '[]',
  saldos           jsonb not null default '{}',
  primary key (arquivo_id, funcionario_id)
);

alter table "18 - rh".empresa        enable row level security;   -- sem policy: só via RPC definer
alter table "18 - rh".arquivo        enable row level security;
alter table "18 - rh".funcionario    enable row level security;
alter table "18 - rh".ponto_dia      enable row level security;
alter table "18 - rh".ponto_dia_hist enable row level security;
alter table "18 - rh".ponto_resumo   enable row level security;
revoke all on all tables in schema "18 - rh" from public, anon, authenticated;
revoke all on all sequences in schema "18 - rh" from public, anon, authenticated;

-- ---------------------------------------------------------------- helpers
create or replace function public.rh_pode_carregar(p_uid uuid)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select p_uid is not null and exists(select 1 from public.perfil
    where id = p_uid and coalesce(ativo, true) and (funcao = 'admin' or coalesce(rh_acesso, false)));
$$;
revoke all on function public.rh_pode_carregar(uuid) from public, anon;
grant execute on function public.rh_pode_carregar(uuid) to authenticated;

create or replace function "18 - rh".so_digitos(t text)
returns text language sql immutable set search_path = pg_catalog as $$
  select nullif(regexp_replace(coalesce(t, ''), '\D', '', 'g'), '');
$$;

-- ---------------------------------------------------------------- RPCs
-- 0) Mesmo PDF já carregado? (o app chama antes de subir; se vier algo, não sobe de novo)
create or replace function public.app_rh_ponto_checar(p_sha256 text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare r jsonb;
begin
  if not public.rh_pode_carregar(auth.uid()) then raise exception 'sem permissão'; end if;
  select jsonb_build_object('id', a.id, 'enviado_em', a.enviado_em, 'nome', a.nome_original, 'empresa', a.empresa,
           'por', coalesce(p.nome, p.email))
    into r from "18 - rh".arquivo a left join public.perfil p on p.id = a.enviado_por
   where a.sha256 = p_sha256 and a.status = 'ok' order by a.enviado_em limit 1;
  return r;
end $$;

-- 1) Registra o PDF já enviado ao bucket.
create or replace function public.app_rh_registrar(p_path text, p_nome text, p_tamanho int, p_sha256 text)
returns uuid language plpgsql volatile security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  if not public.rh_pode_carregar(auth.uid()) then raise exception 'sem permissão'; end if;
  if p_path is null or p_path !~ '^\d{4}-\d{2}-\d{2}/' then raise exception 'caminho inválido'; end if;
  insert into "18 - rh".arquivo (storage_path, nome_original, tamanho_bytes, sha256, enviado_por)
  values (p_path, left(p_nome, 300), p_tamanho, p_sha256, auth.uid())
  returning id into v_id;
  return v_id;
end $$;

-- 2) Falha antes do processamento (leitura do PDF etc.).
create or replace function public.app_rh_falha(p_id uuid, p_erro text)
returns void language plpgsql volatile security definer set search_path to 'public' as $$
begin
  if not public.rh_pode_carregar(auth.uid()) then raise exception 'sem permissão'; end if;
  update "18 - rh".arquivo set status = 'erro', erro = left(p_erro, 1000), processado_em = now()
   where id = p_id and status <> 'ok';
end $$;

-- 3) Processa o que o app leu do PDF. Nunca levanta erro de validação: grava status/erro e devolve o resumo.
--    p_dados = {empresa, cnpj, emitido_em, periodo_ini, periodo_fim, paginas, funcionarios:[{nome, matricula, pis, cpf,
--               admissao, cargo, base_horas, dias:[{data, dia_semana, horario, marcacoes[], marc_txt, htrab, he, adn, adnhe,
--               cponte, descontos:[{min,tipo}], bh_deb, bh_cred, justificativa}], resumo:{...}}]}
create or replace function public.app_rh_ponto_processar(p_arquivo uuid, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path to 'public', '18 - rh' as $$
declare
  a "18 - rh".arquivo%rowtype;
  e "18 - rh".empresa%rowtype;
  v_cnpj text; v_emit timestamptz; v_hoje date;
  f jsonb; d jsonb; v_fid bigint; v_cpf text; v_hash text; v_row "18 - rh".ponto_dia%rowtype;
  n_func int := 0; n_dias int := 0; n_novo int := 0; n_alt int := 0; n_igual int := 0; n_antigo int := 0;
  v_aviso text; v_dup record; v_data date; v_desc jsonb;
begin
  if not public.rh_pode_carregar(auth.uid()) then raise exception 'sem permissão'; end if;
  select * into a from "18 - rh".arquivo where id = p_arquivo for update;
  if not found then raise exception 'arquivo não encontrado'; end if;
  if a.status = 'ok' then
    return jsonb_build_object('ok', true, 'aviso', 'Esta carga já estava processada.', 'id', a.id);
  end if;
  perform pg_advisory_xact_lock(hashtext('rh:ponto'));

  v_cnpj := so_digitos(p_dados->>'cnpj');
  v_emit := nullif(p_dados->>'emitido_em', '')::timestamptz;
  select * into e from "18 - rh".empresa where cnpj = v_cnpj;
  if not found or v_emit is null or jsonb_array_length(coalesce(p_dados->'funcionarios', '[]')) = 0 then
    update "18 - rh".arquivo set status = 'erro', processado_em = now(), cnpj = v_cnpj, empresa = p_dados->>'empresa',
      erro = case when v_emit is null then 'Não achei a data de emissão do relatório.'
                  when e.cnpj is null then 'Empresa sem consórcio cadastrado: ' || coalesce(p_dados->>'empresa', '?') || ' (' || coalesce(p_dados->>'cnpj', 'sem CNPJ') || ').'
                  else 'Nenhum funcionário no relatório.' end
     where id = a.id;
    return jsonb_build_object('ok', false, 'erro', (select erro from "18 - rh".arquivo where id = a.id));
  end if;
  v_hoje := (v_emit at time zone 'America/Sao_Paulo')::date;

  select x.enviado_em into v_dup from "18 - rh".arquivo x where x.sha256 = a.sha256 and x.status = 'ok' and x.id <> a.id
   order by x.enviado_em limit 1;
  if found then v_aviso := 'Arquivo idêntico ao já carregado em ' || to_char(v_dup.enviado_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || '.'; end if;

  begin
    for f in select * from jsonb_array_elements(p_dados->'funcionarios') loop
      v_cpf := lpad(so_digitos(f->>'cpf'), 11, '0');
      if v_cpf is null or length(v_cpf) <> 11 then raise exception 'CPF inválido para %', f->>'nome'; end if;
      insert into "18 - rh".funcionario as t (cnpj, cpf, nome, matricula, pis, admissao, cargo, base_horas, perfil_id, ultimo_arquivo)
      values (v_cnpj, v_cpf, f->>'nome', f->>'matricula', so_digitos(f->>'pis'), nullif(f->>'admissao','')::date, f->>'cargo', f->>'base_horas',
              (select p.id from public.perfil p where lpad(so_digitos(p.cpf), 11, '0') = v_cpf order by coalesce(p.ativo, true) desc limit 1),
              a.id)
      on conflict (cnpj, cpf) do update set nome = excluded.nome, matricula = excluded.matricula, pis = excluded.pis,
        admissao = excluded.admissao, cargo = coalesce(excluded.cargo, t.cargo), base_horas = excluded.base_horas,
        perfil_id = coalesce(excluded.perfil_id, t.perfil_id), ultimo_arquivo = excluded.ultimo_arquivo, atualizado_em = now()
      returning id into v_fid;
      n_func := n_func + 1;

      insert into "18 - rh".ponto_resumo (arquivo_id, funcionario_id, periodo_ini, periodo_fim, dias_trabalhados, atrasos_min, faltas_min, dsr_min, he_percentual, saldos)
      values (a.id, v_fid,
        (select min((x->>'data')::date) from jsonb_array_elements(f->'dias') x), (select max((x->>'data')::date) from jsonb_array_elements(f->'dias') x),
        nullif(f#>>'{resumo,dias_trabalhados}','')::int, nullif(f#>>'{resumo,atrasos}','')::int, nullif(f#>>'{resumo,faltas}','')::int,
        nullif(f#>>'{resumo,dsr}','')::int, coalesce(f#>'{resumo,he_percentual}', '[]'),
        coalesce(f->'resumo', '{}') - 'he_percentual' - 'dias_trabalhados' - 'atrasos' - 'faltas' - 'dsr')
      on conflict (arquivo_id, funcionario_id) do nothing;

      for d in select * from jsonb_array_elements(coalesce(f->'dias', '[]')) loop
        v_data := (d->>'data')::date;
        n_dias := n_dias + 1;
        v_desc := coalesce(d->'descontos', '[]');
        -- hash só do conteúdo do dia (não da carga): o mesmo dia em dois relatórios iguais = igual
        v_hash := md5(jsonb_build_array(d->'horario', d->'marcacoes', d->'htrab', d->'he', d->'adn', d->'adnhe', d->'cponte',
                                        v_desc, d->'bh_deb', d->'bh_cred', d->'justificativa')::text);
        select * into v_row from "18 - rh".ponto_dia where funcionario_id = v_fid and data = v_data;
        if not found then
          n_novo := n_novo + 1;
        elsif v_row.emitido_em > v_emit then
          n_antigo := n_antigo + 1;   -- já temos versão mais nova deste dia
          continue;
        elsif v_row.hash = v_hash then
          n_igual := n_igual + 1;
          update "18 - rh".ponto_dia set emitido_em = v_emit, arquivo_id = a.id, parcial = (v_data >= v_hoje)
           where funcionario_id = v_fid and data = v_data;
          continue;
        else
          n_alt := n_alt + 1;
          insert into "18 - rh".ponto_dia_hist (funcionario_id, data, versao, dados, arquivo_id, emitido_em, substituido_por)
          values (v_fid, v_data, v_row.versao, to_jsonb(v_row) - 'funcionario_id' - 'data' - 'versao' - 'arquivo_id' - 'emitido_em',
                  v_row.arquivo_id, v_row.emitido_em, a.id);
        end if;
        insert into "18 - rh".ponto_dia as t (funcionario_id, data, dia_semana, horario, marcacoes, marc_txt, htrab_min, he_min, adn_min,
            adnhe_min, cponte_min, atraso_min, falta_min, dsr_min, descontos, bh_deb_min, bh_cred_min, justificativa, parcial,
            emitido_em, arquivo_id, hash)
        values (v_fid, v_data, d->>'dia_semana', d->>'horario',
            coalesce(array(select jsonb_array_elements_text(d->'marcacoes')), '{}'), d->>'marc_txt',
            nullif(d->>'htrab','')::int, nullif(d->>'he','')::int, nullif(d->>'adn','')::int, nullif(d->>'adnhe','')::int,
            nullif(d->>'cponte','')::int,
            coalesce((select sum((x->>'min')::int) from jsonb_array_elements(v_desc) x where x->>'tipo' ilike 'atraso%'), 0),
            coalesce((select sum((x->>'min')::int) from jsonb_array_elements(v_desc) x where x->>'tipo' ilike 'falta%'), 0),
            coalesce((select sum((x->>'min')::int) from jsonb_array_elements(v_desc) x where x->>'tipo' ilike 'dsr%'), 0),
            v_desc, nullif(d->>'bh_deb','')::int, nullif(d->>'bh_cred','')::int, nullif(d->>'justificativa',''),
            v_data >= v_hoje, v_emit, a.id, v_hash)
        on conflict (funcionario_id, data) do update set dia_semana = excluded.dia_semana, horario = excluded.horario,
            marcacoes = excluded.marcacoes, marc_txt = excluded.marc_txt, htrab_min = excluded.htrab_min, he_min = excluded.he_min,
            adn_min = excluded.adn_min, adnhe_min = excluded.adnhe_min, cponte_min = excluded.cponte_min,
            atraso_min = excluded.atraso_min, falta_min = excluded.falta_min, dsr_min = excluded.dsr_min, descontos = excluded.descontos,
            bh_deb_min = excluded.bh_deb_min, bh_cred_min = excluded.bh_cred_min, justificativa = excluded.justificativa,
            parcial = excluded.parcial, emitido_em = excluded.emitido_em, arquivo_id = excluded.arquivo_id, hash = excluded.hash,
            versao = t.versao + 1, atualizado_em = now();
      end loop;
    end loop;
  exception when others then
    update "18 - rh".arquivo set status = 'erro', erro = left('Falha ao gravar: ' || sqlerrm, 1000), processado_em = now(),
      cnpj = v_cnpj, empresa = e.nome, consorcio = e.consorcio where id = a.id;
    return jsonb_build_object('ok', false, 'erro', 'Falha ao gravar: ' || sqlerrm);
  end;

  update "18 - rh".arquivo set status = 'ok', erro = null, aviso = v_aviso, processado_em = now(),
    cnpj = v_cnpj, empresa = e.nome, consorcio = e.consorcio, emitido_em = v_emit,
    periodo_ini = nullif(p_dados->>'periodo_ini','')::date, periodo_fim = nullif(p_dados->>'periodo_fim','')::date,
    paginas = nullif(p_dados->>'paginas','')::int, funcionarios = n_func, dias = n_dias,
    dias_novos = n_novo, dias_alterados = n_alt, dias_iguais = n_igual, dias_antigos = n_antigo
   where id = a.id;
  return jsonb_build_object('ok', true, 'id', a.id, 'empresa', e.sigla, 'consorcio', e.consorcio, 'funcionarios', n_func, 'dias', n_dias,
    'novos', n_novo, 'alterados', n_alt, 'iguais', n_igual, 'antigos', n_antigo, 'aviso', v_aviso,
    'periodo_ini', p_dados->>'periodo_ini', 'periodo_fim', p_dados->>'periodo_fim', 'emitido_em', v_emit);
end $$;

-- 4) Painel "No banco agora" por empresa + quem do relatório não casou com usuário do app (pelo CPF).
create or replace function public.app_rh_painel()
returns jsonb language plpgsql stable security definer set search_path to 'public', '18 - rh' as $$
begin
  if not public.rh_pode_carregar(auth.uid()) then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(x order by x->>'sigla') from (
    select jsonb_build_object('sigla', e.sigla, 'empresa', e.nome, 'consorcio', e.consorcio,
      'funcionarios', (select count(*) from funcionario f where f.cnpj = e.cnpj),
      'sem_usuario', (select coalesce(jsonb_agg(f.nome order by f.nome), '[]') from funcionario f where f.cnpj = e.cnpj and f.perfil_id is null),
      'dias', (select count(*) from ponto_dia d join funcionario f on f.id = d.funcionario_id where f.cnpj = e.cnpj),
      'data_min', (select min(d.data) from ponto_dia d join funcionario f on f.id = d.funcionario_id where f.cnpj = e.cnpj),
      'data_max', (select max(d.data) from ponto_dia d join funcionario f on f.id = d.funcionario_id where f.cnpj = e.cnpj),
      'parciais', (select count(*) from ponto_dia d join funcionario f on f.id = d.funcionario_id where f.cnpj = e.cnpj and d.parcial),
      'ultima_emissao', (select max(a.emitido_em) from arquivo a where a.cnpj = e.cnpj and a.status = 'ok')) x
    from empresa e) s), '[]'::jsonb);
end $$;

-- 5) Últimas cargas.
create or replace function public.app_rh_cargas_listar(p_limite int default 40)
returns jsonb language plpgsql stable security definer set search_path to 'public', '18 - rh' as $$
begin
  if not public.rh_pode_carregar(auth.uid()) then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(to_jsonb(s) order by s.enviado_em desc) from (
    select a.id, a.storage_path as path, a.nome_original as nome, a.status, a.erro, a.aviso, a.enviado_em, a.emitido_em, a.periodo_ini, a.periodo_fim,
           (select e.sigla from empresa e where e.cnpj = a.cnpj) as sigla, a.consorcio, a.funcionarios, a.dias,
           a.dias_novos, a.dias_alterados, a.dias_iguais, a.dias_antigos, coalesce(p.nome, p.email) as por
      from arquivo a left join public.perfil p on p.id = a.enviado_por
     order by a.enviado_em desc limit greatest(1, least(coalesce(p_limite, 40), 200))) s), '[]'::jsonb);
end $$;

-- 6) ⚙️ do RH (só admin): quem faz a Carga RH.
create or replace function public.app_rh_acesso_listar()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not exists(select 1 from public.perfil where id = auth.uid() and funcao = 'admin') then raise exception 'sem permissão'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'email', email, 'cargo', cargo, 'ativo', ativo,
      'admin', funcao = 'admin', 'rh', funcao = 'admin' or coalesce(rh_acesso, false))
      order by (funcao = 'admin') desc, coalesce(rh_acesso, false) desc, coalesce(nome, email))
    from public.perfil where coalesce(ativo, true) or coalesce(rh_acesso, false)), '[]'::jsonb);
end $$;

create or replace function public.app_rh_acesso_set(p_uuid uuid, p_rh boolean)
returns void language plpgsql volatile security definer set search_path to 'public' as $$
begin
  if not exists(select 1 from public.perfil where id = auth.uid() and funcao = 'admin') then raise exception 'sem permissão'; end if;
  update public.perfil set rh_acesso = coalesce(p_rh, false) where id = p_uuid;
end $$;

revoke all on function public.app_rh_ponto_checar(text) from public, anon;
revoke all on function public.app_rh_registrar(text, text, int, text) from public, anon;
revoke all on function public.app_rh_falha(uuid, text) from public, anon;
revoke all on function public.app_rh_ponto_processar(uuid, jsonb) from public, anon;
revoke all on function public.app_rh_painel() from public, anon;
revoke all on function public.app_rh_cargas_listar(int) from public, anon;
revoke all on function public.app_rh_acesso_listar() from public, anon;
revoke all on function public.app_rh_acesso_set(uuid, boolean) from public, anon;
grant execute on function public.app_rh_ponto_checar(text) to authenticated;
grant execute on function public.app_rh_registrar(text, text, int, text) to authenticated;
grant execute on function public.app_rh_falha(uuid, text) to authenticated;
grant execute on function public.app_rh_ponto_processar(uuid, jsonb) to authenticated;
grant execute on function public.app_rh_painel() to authenticated;
grant execute on function public.app_rh_cargas_listar(int) to authenticated;
grant execute on function public.app_rh_acesso_listar() to authenticated;
grant execute on function public.app_rh_acesso_set(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------- Storage: bucket privado + policies
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('rh-ponto', 'rh-ponto', false, 20971520, array['application/pdf'])
on conflict (id) do nothing;

drop policy if exists rh_ponto_insert on storage.objects;
create policy rh_ponto_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'rh-ponto' and public.rh_pode_carregar(auth.uid()) and split_part(name, '/', 1) ~ '^\d{4}-\d{2}-\d{2}$');
drop policy if exists rh_ponto_select on storage.objects;
create policy rh_ponto_select on storage.objects for select to authenticated
  using (bucket_id = 'rh-ponto' and public.rh_pode_carregar(auth.uid()));
-- sem update/delete: o PDF fica guardado como prova de cada carga.

-- ---------------------------------------------------------------- app_me: + rh_acesso (mesma assinatura → create or replace)
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
    'rh_acesso',(v_adm or (coalesce(v_p.rh_acesso,false) and coalesce(v_p.ativo,true))),
    'equipes','[]'::jsonb);
end $function$;

notify pgrst, 'reload schema';
