-- Avisos de solicitação de FERRAMENTA iam como se fossem de insumo (2026-11-26)
-- Antes: sup_trg_solicitacao não distinguia ferramenta → "Nova solicitação de material" (link aprovar),
-- "Material a separar" para a área INSUMO (link almox) e avisos ao colaborador com link pedidos (Insumos).
-- Agora: se a solicitação tem item sup_material.ferramenta → textos de ferramenta, área 'ferramenta' e links
-- ferramenta_aprovar / ferramenta_almox / ferramenta_pedidos (acts que já existem no app).
-- O trigger vira CONSTRAINT TRIGGER DEFERRABLE INITIALLY DEFERRED: no INSERT o cabeçalho entra antes dos
-- itens (sup_solicitar / sup_ferramenta_solicitar), então só no fim da transação dá pra saber o tipo.

create or replace function "9 - suprimentos".sup_trg_solicitacao()
 returns trigger language plpgsql security definer set search_path to 'public'
as $function$
declare v_ator uuid := auth.uid(); v_nome text; v_fer boolean;
begin
  v_fer := exists(select 1 from "9 - suprimentos".sup_solicitacao_item i join "9 - suprimentos".sup_material m on m.id=i.material_id
                  where i.solicitacao_id=NEW.id and m.ferramenta);
  if TG_OP='INSERT' then
    select nome into v_nome from public.perfil where id=NEW.solicitante_uuid;
    perform "9 - suprimentos".sup_notificar("9 - suprimentos".sup_aprovadores_de(NEW.solicitante_uuid),
      'solicitacao', case when v_fer then 'Nova solicitação de ferramenta' else 'Nova solicitação de material' end,
      coalesce(v_nome,'Colaborador')||case when v_fer then ' enviou uma solicitação de ferramentas.' else ' enviou uma solicitação de insumos.' end,
      case when v_fer then 'ferramenta_aprovar' else 'aprovar' end, v_ator);
  elsif TG_OP='UPDATE' and NEW.status is distinct from OLD.status then
    if NEW.status='aprovada' then
      perform "9 - suprimentos".sup_notificar("9 - suprimentos".sup_uuids_por_area(case when v_fer then 'ferramenta' else 'insumo' end),
        'aprovada', case when v_fer then 'Ferramenta a separar' else 'Material a separar' end,
        case when v_fer then 'Há uma solicitação de ferramenta aprovada para separação.' else 'Há uma solicitação aprovada para separação.' end,
        case when v_fer then 'ferramenta_almox' else 'almox' end, v_ator);
      perform "9 - suprimentos".sup_notificar(array[NEW.solicitante_uuid],
        'aprovada','Solicitação aprovada', case when v_fer then 'Seu pedido de ferramenta foi aprovado.' else 'Seu pedido de material foi aprovado.' end,
        case when v_fer then 'ferramenta_pedidos' else 'pedidos' end);
    elsif NEW.status='segregada' then
      perform "9 - suprimentos".sup_notificar(array[NEW.solicitante_uuid],
        'segregada', case when v_fer then 'Ferramenta separada — pode retirar' else 'Material separado — pode retirar' end,
        case when v_fer then 'Sua ferramenta está separada no almoxarifado' else 'Seu material está separado no almoxarifado' end||coalesce(' · código '||NEW.codigo_retirada,'')||'.',
        case when v_fer then 'ferramenta_pedidos' else 'pedidos' end);
    elsif NEW.status='em_falta' then
      perform "9 - suprimentos".sup_notificar(array[NEW.solicitante_uuid],
        'em_falta', case when v_fer then 'Ferramenta em falta' else 'Material em falta' end,'Sua solicitação está sem estoque no almoxarifado.',
        case when v_fer then 'ferramenta_pedidos' else 'pedidos' end);
    elsif NEW.status='rejeitada' then
      perform "9 - suprimentos".sup_notificar(array[NEW.solicitante_uuid],
        'rejeitada','Solicitação rejeitada', case when v_fer then 'Seu pedido de ferramenta foi rejeitado.' else 'Seu pedido de material foi rejeitado.' end,
        case when v_fer then 'ferramenta_pedidos' else 'pedidos' end);
    end if;
  end if;
  return null;
end; $function$;

drop trigger if exists trg_sup_solicitacao on "9 - suprimentos".sup_solicitacao;
create constraint trigger trg_sup_solicitacao
  after insert or update on "9 - suprimentos".sup_solicitacao
  deferrable initially deferred
  for each row execute function "9 - suprimentos".sup_trg_solicitacao();
