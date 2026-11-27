-- Gestão de Frotas: carga direta dos relatórios do cartão Ticket Log (2026-11-27)
-- O app passa a ler os arquivos como saem do Ticket Log ("RelatorioParametrizado*.xls", que são tabelas HTML):
--   • GERAL ............ abastecimentos de um período;
--   • CADASTRO POSTO ... CNPJ → nome do posto;
--   • cadastro de motorista e de veículo NÃO são usados nem enviados (o de motorista traz CPF, RG e nascimento).
-- O relatório não diz de qual consórcio é: o campo da tela define. Cada GERAL substitui SÓ o mesmo consórcio dentro do
-- período do arquivo; o resto (outro consórcio e outros períodos) continua. Não vão para o banco: nº do cartão e matrícula.
-- Depende de docs/migracao_frota_bi.sql. Pode rodar mais de uma vez.

create table if not exists "10 - Frotas".frota_bi_posto (
  cnpj text primary key, nome text not null, cidade text, uf text, atualizado_em timestamptz not null default now()
);
alter table "10 - Frotas".frota_bi_posto enable row level security;
alter table "10 - Frotas".frota_bi_abast add column if not exists cnpj text;

create or replace function public.app_frota_ticket_carga(
  p_consorcio text, p_nome text default null, p_sha256 text default null,
  p_ini date default null, p_fim date default null,
  p_linhas jsonb default '[]'::jsonb, p_postos jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_outro text; v_n int; v_rep int; v_meus int; v_deles int; v_id bigint; v_sub int := 0; v_total int; v_postos int := 0;
  v_fora int; v_alertas int; v_ant timestamptz; v_aviso text;
begin
  if not "10 - Frotas".frota_carga_pode(auth.uid()) then raise exception 'sem permissão para carregar arquivos da Frota'; end if;
  if p_consorcio is null or p_consorcio not in ('Águas Integradas', 'Eficiência Hídrica') then raise exception 'consórcio inválido'; end if;
  if jsonb_typeof(coalesce(p_linhas, '[]'::jsonb)) <> 'array' or jsonb_typeof(coalesce(p_postos, '[]'::jsonb)) <> 'array' then raise exception 'conteúdo inválido'; end if;
  perform pg_advisory_xact_lock(hashtext('frota_ticket_log'));

  insert into "10 - Frotas".frota_bi_posto (cnpj, nome, cidade, uf)
  select distinct on (x.cnpj) x.cnpj, left(x.nome, 200), left(x.cidade, 100), left(x.uf, 2)
    from jsonb_to_recordset(coalesce(p_postos, '[]'::jsonb)) as x(cnpj text, nome text, cidade text, uf text)
   where nullif(btrim(x.cnpj), '') is not null and nullif(btrim(x.nome), '') is not null
  on conflict (cnpj) do update set nome = excluded.nome, cidade = excluded.cidade, uf = excluded.uf, atualizado_em = now();
  get diagnostics v_postos = row_count;
  update "10 - Frotas".frota_bi_abast a set posto = p.nome from "10 - Frotas".frota_bi_posto p where a.cnpj = p.cnpj and a.posto is distinct from p.nome;

  v_n := jsonb_array_length(coalesce(p_linhas, '[]'::jsonb));
  if v_n = 0 then
    if v_postos = 0 then raise exception 'nenhuma linha válida no arquivo — nada foi alterado'; end if;
    return jsonb_build_object('postos', v_postos, 'linhas', 0);
  end if;
  if v_n > 20000 then raise exception 'arquivo grande demais'; end if;
  if p_ini is null or p_fim is null or p_ini > p_fim then raise exception 'período do relatório não identificado — nada foi alterado'; end if;
  if exists (select 1 from jsonb_to_recordset(p_linhas) as x(data date, litros numeric, valor_total numeric)
              where x.data is null or x.data < p_ini or x.data > p_fim or x.litros is null or x.valor_total is null) then
    raise exception 'há linha sem data, litros ou valor, ou fora do período do relatório — nada foi alterado';
  end if;

  -- proteção contra o arquivo no consórcio errado
  v_outro := case when p_consorcio = 'Águas Integradas' then 'Eficiência Hídrica' else 'Águas Integradas' end;
  select count(*) into v_rep from jsonb_to_recordset(p_linhas) as x(data date, placa text, litros numeric, valor_total numeric)
   where exists (select 1 from "10 - Frotas".frota_bi_abast a join "10 - Frotas".frota_bi_carga k on k.id = a.carga_id and k.ativa
                  where a.consorcio = v_outro and a.data = x.data and a.litros = x.litros and a.valor_total = x.valor_total
                    and upper(coalesce(a.placa, '')) = upper(coalesce(x.placa, '')));
  if v_rep >= least(v_n, greatest(3, ceil(v_n * 0.2)::int)) then
    raise exception 'esse relatório já está carregado em % (% de % abastecimentos iguais) — confira o campo; nada foi alterado', v_outro, v_rep, v_n;
  end if;
  select count(*) filter (where "10 - Frotas".frota_consorcio(v.consorcio) = p_consorcio),
         count(*) filter (where "10 - Frotas".frota_consorcio(v.consorcio) = v_outro)
    into v_meus, v_deles
    from jsonb_to_recordset(p_linhas) as x(placa text)
    join "10 - Frotas".frota_veiculo v on regexp_replace(upper(v.placa), '[^A-Z0-9]', '', 'g') = regexp_replace(upper(coalesce(x.placa, '')), '[^A-Z0-9]', '', 'g');
  if v_deles >= 10 and v_deles > v_meus * 2 then
    raise exception 'a maioria dos veículos desse relatório é da frota de % (% contra %) — confira o campo; nada foi alterado', v_outro, v_deles, v_meus;
  end if;

  select max(concluido_em) into v_ant from "10 - Frotas".frota_bi_carga where tipo = 'abastecimento' and status = 'ok' and sha256 = p_sha256;
  if v_ant is not null then v_aviso := 'arquivo idêntico a um já enviado em ' || to_char(v_ant at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI') || '. '; end if;
  insert into "10 - Frotas".frota_bi_carga (tipo, nome_original, sha256)
  values ('abastecimento', left(p_consorcio || ' · ' || to_char(p_ini, 'DD/MM') || ' a ' || to_char(p_fim, 'DD/MM/YYYY') || ' · ' || coalesce(p_nome, ''), 300), p_sha256)
  returning id into v_id;

  -- o que está fora do consórcio/período do arquivo passa para a carga nova; o resto é substituído
  update "10 - Frotas".frota_bi_abast set carga_id = v_id
   where carga_id in (select id from "10 - Frotas".frota_bi_carga where tipo = 'abastecimento' and ativa)
     and not (consorcio = p_consorcio and data between p_ini and p_fim);
  delete from "10 - Frotas".frota_bi_abast where carga_id in (select id from "10 - Frotas".frota_bi_carga where tipo = 'abastecimento' and ativa);
  get diagnostics v_sub = row_count;
  update "10 - Frotas".frota_bi_carga set ativa = false where tipo = 'abastecimento' and ativa;

  insert into "10 - Frotas".frota_bi_abast (carga_id, data, mes, placa, motorista, consorcio, combustivel, litros, preco_litro, valor_total, posto, alerta, cnpj)
  select v_id, x.data, date_trunc('month', x.data)::date, nullif(btrim(x.placa), ''), nullif(btrim(x.motorista), ''), p_consorcio, nullif(btrim(x.combustivel), ''),
         x.litros, x.preco_litro, x.valor_total,
         coalesce(p.nome, case when nullif(btrim(x.cnpj), '') is not null then 'CNPJ ' || x.cnpj || ' (fora do cadastro de postos)' end),
         (select 'Veículo da frota de ' || "10 - Frotas".frota_consorcio(v.consorcio) || ' abastecido no cartão de ' || p_consorcio
            from "10 - Frotas".frota_veiculo v
           where regexp_replace(upper(v.placa), '[^A-Z0-9]', '', 'g') = regexp_replace(upper(coalesce(x.placa, '')), '[^A-Z0-9]', '', 'g')
             and "10 - Frotas".frota_consorcio(v.consorcio) = v_outro limit 1),
         nullif(btrim(x.cnpj), '')
    from jsonb_to_recordset(p_linhas) as x(data date, placa text, motorista text, combustivel text, litros numeric, preco_litro numeric, valor_total numeric, cnpj text)
    left join "10 - Frotas".frota_bi_posto p on p.cnpj = btrim(x.cnpj);

  select count(*), count(*) filter (where posto like 'CNPJ %(fora do cadastro de postos)' and consorcio = p_consorcio and data between p_ini and p_fim),
         count(*) filter (where alerta is not null and consorcio = p_consorcio and data between p_ini and p_fim)
    into v_total, v_fora, v_alertas from "10 - Frotas".frota_bi_abast where carga_id = v_id;
  v_aviso := coalesce(v_aviso, '')
    || case when v_sub > v_n then '⚠️ ATENÇÃO: o arquivo tem MENOS abastecimentos (' || v_n || ') do que havia nesse período (' || v_sub || '). Se for um relatório antigo, envie de novo o mais recente. ' else '' end
    || v_n || ' abastecimentos no arquivo, ' || v_sub || ' do mesmo período substituídos; ' || v_total || ' no total'
    || case when v_fora > 0 then '; ' || v_fora || ' com posto fora do cadastro' else '' end
    || case when v_alertas > 0 then '; ' || v_alertas || ' com veículo da outra frota' else '' end;
  update "10 - Frotas".frota_bi_carga set status = 'ok', ativa = true, linhas = v_total, aviso = v_aviso, concluido_em = now() where id = v_id;
  return jsonb_build_object('carga_id', v_id, 'linhas', v_n, 'substituidas', v_sub, 'total', v_total, 'postos', v_postos, 'fora_cadastro', v_fora, 'alertas', v_alertas, 'aviso', v_aviso);
end $$;

create or replace function public.app_frota_ticket_resumo()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not "10 - Frotas".frota_bi_pode(auth.uid()) then raise exception 'sem permissão'; end if;
  return jsonb_build_object(
    'consorcios', coalesce((select jsonb_agg(jsonb_build_object('consorcio', z.consorcio, 'linhas', z.n, 'de', z.de, 'ate', z.ate, 'valor', z.valor)) from (
        select a.consorcio, count(*) n, min(a.data) de, max(a.data) ate, sum(a.valor_total) valor
          from "10 - Frotas".frota_bi_abast a join "10 - Frotas".frota_bi_carga k on k.id = a.carga_id and k.ativa group by a.consorcio) z), '[]'::jsonb),
    'postos', (select count(*) from "10 - Frotas".frota_bi_posto));
end $$;

revoke all on function public.app_frota_ticket_carga(text, text, text, date, date, jsonb, jsonb) from public, anon;
revoke all on function public.app_frota_ticket_resumo() from public, anon;
grant execute on function public.app_frota_ticket_carga(text, text, text, date, date, jsonb, jsonb) to authenticated;
grant execute on function public.app_frota_ticket_resumo() to authenticated;
