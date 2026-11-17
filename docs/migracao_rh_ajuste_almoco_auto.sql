-- RH · Ajuste de batidas: o almoço entra sozinho pelo horário previsto (2026-11-17, sw v413)
-- Pedido do usuário: o gestor só informa ENTRADA e SAÍDA; os intervalos do horário previsto (ex.: 12:00–13:00) são
-- inseridos automaticamente quando caem entre a entrada e a saída. Vale no servidor (app_rh_val_tratar), mesmo para app em cache.
-- Motivo: ajuste gravado só com entrada/saída (ex.: 06:46–17:00) fazia calc_marcacoes contar o dia corrido (10:14 em vez de 9:14).

create or replace function "18 - rh".rh_ajuste_almoco(p_horario text, p_marc text[])
returns text[] language plpgsql immutable set search_path to 'public', '18 - rh' as $f$
declare b text[]; e text; s text; r text[]; k int;
begin
  if coalesce(cardinality(p_marc), 0) < 2 then return p_marc; end if;
  e := p_marc[1]; s := p_marc[cardinality(p_marc)];
  select array_agg(lpad(x[1], 5, '0') order by o) into b
    from regexp_matches(coalesce(p_horario, ''), '(\d{1,2}:\d{2})', 'g') with ordinality as t(x, o);
  r := array[e];
  -- intervalos internos do horário = pares (b[2],b[3]), (b[4],b[5])… ; entram só se ficarem inteiros entre a entrada e a saída
  if coalesce(cardinality(b), 0) >= 4 then
    k := 2;
    while k + 1 <= cardinality(b) - 1 loop
      if hm(b[k]) > hm(e) and hm(b[k + 1]) < hm(s) and hm(b[k]) < hm(b[k + 1]) then r := r || b[k] || b[k + 1]; end if;
      k := k + 2;
    end loop;
  end if;
  return r || s;
end $f$;
revoke all on function "18 - rh".rh_ajuste_almoco(text, text[]) from public, anon, authenticated;

-- app_rh_val_tratar: normaliza as marcações (entrada + almoço do horário + saída) antes de validar e gravar
do $mig$ declare d text; n text;
begin
  d := pg_get_functiondef('public.app_rh_val_tratar(bigint,date,text,text[],text,text)'::regprocedure);
  n := replace(d, $xa$  if p_acao = 'ajustar' then
    if coalesce(cardinality(p_marcacoes), 0) = 0 or cardinality(p_marcacoes) % 2 = 1 then$xa$,
                  $xb$  if p_acao = 'ajustar' then
    -- o gestor informa só entrada e saída; o almoço vem do horário previsto (2026-11-17)
    if coalesce(cardinality(p_marcacoes), 0) >= 2 then
      p_marcacoes := "18 - rh".rh_ajuste_almoco((select horario from "18 - rh".ponto_dia where funcionario_id = p_funcionario and data = p_data),
                                                array[p_marcacoes[1], p_marcacoes[cardinality(p_marcacoes)]]);
    end if;
    if coalesce(cardinality(p_marcacoes), 0) = 0 or cardinality(p_marcacoes) % 2 = 1 then$xb$);
  if n = d then raise exception 'replace da app_rh_val_tratar falhou'; end if;
  execute n;
end $mig$;

-- Corrige os ajustes já gravados sem o almoço (3 em 17/11/2026), com rastro em tratativa_evento
with c as (
  select t.funcionario_id, t.data, t.marcacoes as antes,
         "18 - rh".rh_ajuste_almoco(pd.horario, array[t.marcacoes[1], t.marcacoes[cardinality(t.marcacoes)]]) as depois
    from "18 - rh".tratativa t join "18 - rh".ponto_dia pd on pd.funcionario_id = t.funcionario_id and pd.data = t.data
   where t.acao = 'ajustar' and coalesce(cardinality(t.marcacoes), 0) >= 2
), u as (
  update "18 - rh".tratativa t set marcacoes = c.depois from c
   where t.funcionario_id = c.funcionario_id and t.data = c.data and c.depois is distinct from c.antes
  returning t.funcionario_id, t.data, c.antes, c.depois
)
insert into "18 - rh".tratativa_evento (funcionario_id, data, evento, dados, por)
select funcionario_id, data, 'almoco_auto', jsonb_build_object('antes', antes, 'depois', depois,
       'obs', 'almoço do horário previsto inserido automaticamente'), null from u;
