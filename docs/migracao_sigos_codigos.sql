-- ============================================================================================================
-- Códigos de serviço × gestor (PDF "Gestão de Ordens de Serviço" v3.6, nov/2026) — tela OS não executadas
-- (MODULOS §21.1). 2026-11-10.
--  * "17 - sigos".codigo_servico: os códigos do PDF (escopo mínimo c/ RMA, sem remuneração, suporte, não usar)
--    + subcódigos de piso de pesquisa/reparo, com gestor, grupo do PDF, família (= agrupamento da Vitrine/RDO),
--    categoria e fluxo A/B. Decisão do usuário: 117 80 00 (HD embaçado cap Y, fora do PDF) = Yasmin, escopo c/ RMA.
--  * public.sigos_cod_info(cod): busca exata; sem achar, cai no código-mãe (últimos 2 dígitos = 00).
--  * Códigos "Compartilhado" (pavimento, manobras, entulho) têm o gestor resolvido pela ORIGEM do serviço:
--    1) Gestão de Pavimento: a OS de recomposição lançada no pavprog → serviço de origem do registro de campo;
--    2) "OS de origem" do próprio SIGOS; 3) OS mais recente de outro código, de gestor único, na mesma matrícula;
--    4) sem nada → fica "Compartilhado".
--  * app_sigos_abertas(): + gestor/família/categoria/grupo/fluxo por OS e a via da atribuição.
--  * app_sigos_codigos(): lista p/ o pop-up "Códigos e responsáveis", com OS abertas/vencidas e o prazo do SIGOS
--    (limite − abertura) por código.
-- ============================================================================================================

create table if not exists "17 - sigos".codigo_servico (
  id        serial primary key,
  cod       text unique,                 -- 7 dígitos sem espaço (null = item do escopo sem código no SICOM)
  descricao text not null,
  gestor    text,                        -- Werneck | Igor | Yasmin | Igor · Werneck | Compartilhado | null (não usar)
  grupo     text not null,               -- seção do PDF
  familia   text not null,               -- agrupamento da Vitrine/RDO
  categoria text not null check (categoria in ('escopo_rma','escopo_sem_rem','suporte','nao_usar')),
  fluxo     text,                        -- A | B | A/B
  mae       text,                        -- subcódigo de piso → código-mãe
  ordem     int not null default 0,
  obs       text
);
alter table "17 - sigos".codigo_servico enable row level security;
revoke all on "17 - sigos".codigo_servico from public, anon, authenticated;

truncate "17 - sigos".codigo_servico restart identity;
insert into "17 - sigos".codigo_servico (cod, descricao, gestor, grupo, familia, categoria, fluxo, mae, ordem, obs) values
-- Werneck · escopo mínimo c/ RMA
('1638200','Instalação de VRP','Werneck','Setorização · DMC e VRP','VRP','escopo_rma','A',null,100,null),
('1638000','Substituição de VRP','Werneck','Setorização · DMC e VRP','VRP','escopo_rma','A',null,101,null),
(null,'Implantação de DMC (sem código)','Werneck','Setorização · DMC e VRP','DMC','escopo_rma','A',null,102,'sem código no SICOM'),
-- Werneck · escopo mínimo sem remuneração própria
('1637900','Manutenção de VRP','Werneck','Manutenção de VRP existente','VRP','escopo_sem_rem','A',null,110,null),
(null,'Instalação de controlador de pressão (VRP DN ≥ 100, sem código)','Werneck','Controladores de pressão','VRP','escopo_sem_rem','A',null,111,'sem O.S. cadastrada no SIGOS'),
('2807900','Instalação de logger definitivo','Werneck','Loggers','Telemetria','escopo_sem_rem','A',null,112,null),
('2487900','Pesquisa de vazamento invisível','Werneck','Vazamentos','Pesquisa de vazamento','escopo_sem_rem','A',null,113,'km medidos pelo AcquaHub: a O.S. não conta na produção'),
('2587900','Reparo de vazamento (redes, ramais e cavaletes)','Werneck','Vazamentos','Pesquisa de vazamento','escopo_sem_rem','A',null,114,'a O.S. executada conta como reparo (ação 4.2.10)'),
-- Igor · escopo mínimo c/ RMA
('1807900','Rede VCA (vala a céu aberto)','Igor','Redes','Rede de água','escopo_rma','A',null,200,null),
('1808000','Rede HDD (não destrutivo)','Igor','Redes','Rede de água','escopo_rma','A',null,201,null),
('2017900','Instalação de ramal VCA','Igor','Ramais','Ramal predial','escopo_rma','A/B',null,202,null),
('2018000','Instalação de ramal HDD','Igor','Ramais','Ramal predial','escopo_rma','A/B',null,203,null),
('1437900','Substituição de ramal','Igor','Ramais','Ramal predial','escopo_rma','A/B',null,204,null),
-- Yasmin · escopo mínimo c/ RMA
('1068000','Remanejamento de hidrômetro','Yasmin','Hidrômetro','Padrão de ligação','escopo_rma','B',null,300,null),
('1177800','Troca de HD · cap. A','Yasmin','Hidrômetro','Troca de hidrômetro','escopo_rma','B',null,301,null),
('1174800','Troca de HD · cap. B','Yasmin','Hidrômetro','Troca de hidrômetro','escopo_rma','B',null,302,null),
('1174900','Troca de HD · cap. C','Yasmin','Hidrômetro','Troca de hidrômetro','escopo_rma','B',null,303,null),
('1175800','Troca de HD · cap. D','Yasmin','Hidrômetro','Troca de hidrômetro','escopo_rma','B',null,304,null),
('1175900','Troca de HD · cap. E','Yasmin','Hidrômetro','Troca de hidrômetro','escopo_rma','B',null,305,null),
('1176800','Troca de HD · cap. F','Yasmin','Hidrômetro','Troca de hidrômetro','escopo_rma','B',null,306,null),
('1176900','Troca de HD · cap. G','Yasmin','Hidrômetro','Troca de hidrômetro','escopo_rma','B',null,307,null),
('1177900','Troca de HD · cap. Y','Yasmin','Hidrômetro','Troca de hidrômetro','escopo_rma','B',null,308,null),
('1178000','Troca de HD embaçado · cap. Y (class. B)','Yasmin','Hidrômetro','Troca de hidrômetro','escopo_rma','B',null,309,'fora do PDF v3.6 — atribuído à Yasmin (decisão de 10/11/2026)'),
('1990100','Recadastramento','Yasmin','Cadastro comercial','Recadastramento','escopo_rma','B',null,310,null),
-- Yasmin · escopo mínimo sem remuneração própria
('6767900','Fiscalização de fraudes (vistoria de imóvel)','Yasmin','Pesquisa de fraude','Vistoria de imóvel','escopo_sem_rem','B',null,320,null),
('7327900','Mobilização social','Yasmin','Comunicação e mobilização social','Mobilização social','escopo_sem_rem','B',null,321,null),
-- Suporte · Werneck (16)
('1347900','Inst. maleta/logger — imóvel cadastrado','Werneck','Suporte','Loggers de pressão','suporte',null,null,400,null),
('1348000','Ret. maleta/logger — imóvel cadastrado','Werneck','Suporte','Loggers de pressão','suporte',null,null,401,null),
('1348100','Inst. maleta/logger — imóvel não cadastrado','Werneck','Suporte','Loggers de pressão','suporte',null,null,402,null),
('1348200','Ret. maleta/logger — imóvel não cadastrado','Werneck','Suporte','Loggers de pressão','suporte',null,null,403,null),
('1447900','Substituição de registro de manobra danificado','Werneck','Suporte','Instalação de registro','suporte',null,null,404,null),
('1597900','Macromedidor — manutenção','Werneck','Suporte','Macromedidor','suporte',null,null,405,null),
('1598000','Macromedidor — substituição','Werneck','Suporte','Macromedidor','suporte',null,null,406,null),
('1598100','Macromedidor — retirada','Werneck','Suporte','Macromedidor','suporte',null,null,407,null),
('1598200','Macromedidor — instalação em novo ponto','Werneck','Suporte','Macromedidor','suporte',null,null,408,null),
('1638100','Válvula controladora de pressão — retirada','Werneck','Suporte','VRP','suporte',null,null,409,null),
('1827900','Instalação de registro de manobra','Werneck','Suporte','Instalação de registro','suporte',null,null,410,null),
('2808000','Telemetria — manutenção','Werneck','Suporte','Telemetria','suporte',null,null,411,null),
('2808100','Telemetria — substituição','Werneck','Suporte','Telemetria','suporte',null,null,412,null),
('2808200','Telemetria — retirada','Werneck','Suporte','Telemetria','suporte',null,null,413,null),
('5127900','Construção de caixa de registro de manobra','Werneck','Suporte','Instalação de registro','suporte',null,null,414,null),
('5137900','Instalação de registro','Werneck','Suporte','Instalação de registro','suporte',null,null,415,null),
-- Suporte · Igor · Werneck
('1417900','Sondagem de rede','Igor · Werneck','Suporte','Rede de água','suporte',null,null,420,null),
-- Suporte · compartilhados (gestor pela origem)
('5040400','Reaterro de vala (contrato manut. água)','Compartilhado','Suporte','Recomposição de pavimento','suporte',null,null,430,'gestor pela origem do serviço'),
('5050201','Recomposição (contrato) — vegetação/passeio cimento','Compartilhado','Suporte','Recomposição de pavimento','suporte',null,null,431,'gestor pela origem do serviço'),
('5057900','Recomposição','Compartilhado','Suporte','Recomposição de pavimento','suporte',null,null,432,'gestor pela origem do serviço'),
('5057901','Recomposição — passeio cimento','Compartilhado','Suporte','Recomposição de pavimento','suporte',null,null,433,'gestor pela origem do serviço'),
('5077900','Retirada de entulho','Compartilhado','Suporte','Recomposição de pavimento','suporte',null,null,434,'gestor pela origem do serviço'),
('5417900','Fechamento de registro — espaço confinado','Compartilhado','Suporte','Manobra de registro','suporte',null,null,435,'gestor pela origem do serviço'),
('5418000','Fechamento de registro — externo','Compartilhado','Suporte','Manobra de registro','suporte',null,null,436,'gestor pela origem do serviço'),
('5427900','Abertura de registro — espaço confinado','Compartilhado','Suporte','Manobra de registro','suporte',null,null,437,'gestor pela origem do serviço'),
('5428000','Abertura de registro — externo','Compartilhado','Suporte','Manobra de registro','suporte',null,null,438,'gestor pela origem do serviço'),
-- Suporte · Yasmin (7)
('1138000','Religação do tamponamento da ligação (tamp. H)','Yasmin','Suporte','Ligação de água','suporte',null,null,440,null),
('1138100','Religação do tamponamento da ligação (tamp. T)','Yasmin','Suporte','Ligação de água','suporte',null,null,441,null),
('1158000','Religação de supressão de água','Yasmin','Suporte','Ligação de água','suporte',null,null,442,null),
('1188000','Instalação de hidrômetro','Yasmin','Suporte','Ligação de água','suporte',null,null,443,null),
('1267900','Interligação de rede de água','Yasmin','Suporte','Rede de água','suporte',null,null,444,null),
('1358000','Padronização','Yasmin','Suporte','Padrão de ligação','suporte',null,null,445,null),
('1477900','Transferência de ligação de água','Yasmin','Suporte','Ligação de água','suporte',null,null,446,null),
-- Suporte · Yasmin · irregularidades identificadas (152 xx 00)
('1520100','Violação de suspensão','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,501,null),
('1520200','Violação de tamponamento c/ retirada do HD','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,502,null),
('1520300','Violação de supressão','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,503,null),
('1520400','Derivação de ramal predial','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,504,null),
('1520500','Conf. de infração — violação de tamponamento s/ retirada do HD','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,505,null),
('1520600','Ligação clandestina de água','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,506,null),
('1520700','Lacre do padrão violado','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,507,null),
('1520800','Hidrômetro invertido','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,508,null),
('1520900','Hidrômetro danificado','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,509,null),
('1521000','Hidrômetro extraviado/retirado','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,510,null),
('1521100','Instalação de dispositivo de sucção','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,511,null),
('1521200','Intervenção indevida no ramal predial','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,512,null),
('1521300','Impedimento de acesso ao ramal predial','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,513,null),
('1521400','Construção impedindo acesso ao ramal/instalação','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,514,null),
('1521500','Fornecimento de água a terceiro','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,515,null),
('1521600','Interconexão com sistema próprio','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,516,null),
('1521700','Desperdício de água em calçada pública','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,517,null),
('1521800','Violação de hidrômetro','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,518,null),
('1521900','Lacre do hidrômetro violado','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,519,null),
('1522000','Inexistência de caixa de gordura','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,520,null),
('1522100','Despejo de água pluvial','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,521,null),
('1522200','Violação de tamponamento de esgoto','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,522,null),
('1522300','Lançamento de líquidos residuais','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,523,null),
('1522400','Danificação de sistemas de água/esgoto','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,524,null),
('1522500','Ligação de esgoto não cadastrada','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,525,null),
('1522700','Obstrução da rede de esgoto por mau uso','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,527,null),
('1522800','Recebimento de esgoto de terceiros','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,528,null),
('1522900','Descumprimento de qualquer outra exigência técnica','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,529,null),
('1523000','Adulteração de documento (infração 22, res. 149/21)','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,530,null),
('1523100','Prestação de informação falsa (infração 21, res. 149/21)','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,531,null),
('1523200','Descumprimento da obrigação de conexão à rede de água','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,532,null),
('1523300','Descumprimento da obrigação de conexão à rede de esgoto','Yasmin','Irregularidades identificadas (152)','Fiscalização de irregularidade','suporte',null,null,533,null),
-- Não usar (5)
('1897900','Manutenção no ramal','—','Não usar','Ramal predial','nao_usar',null,null,600,'não usar'),
('5157900','Pintura estratigráfica','—','Não usar','Outros','nao_usar',null,null,601,'não usar'),
('5217900','Melhorias operacionais','—','Não usar','Outros','nao_usar',null,null,602,'não usar'),
('5298000','Fiscalização','—','Não usar','Outros','nao_usar',null,null,603,'não usar'),
('5307900','Retorno de serviço de empreiteira','—','Não usar','Outros','nao_usar',null,null,604,'não usar');

-- subcódigos de piso (mesmo tratamento do código-mãe)
insert into "17 - sigos".codigo_servico (cod, descricao, gestor, grupo, familia, categoria, fluxo, mae, ordem)
select m.c||lpad(p.i::text,2,'0'), m.d||' — '||p.piso, 'Werneck', 'Vazamentos', 'Pesquisa de vazamento', 'escopo_sem_rem', 'A', m.c||'00', m.o+p.i
from (values ('24879','Detecção de vazamento invisível',113),('25879','Reparo de vazamento',114)) m(c,d,o)
cross join (values (1,'passeio cimento'),(2,'passeio terra'),(3,'rua terra'),(4,'cimento + asfalto'),(5,'rua asfalto'),
  (6,'passeio/rua c/ pavimento'),(7,'rua poliédrico'),(8,'passeio/rua terra'),(9,'rua paralelepípedo'),(10,'rua pré-moldado')) p(i,piso);
-- ordem dos subcódigos depois da mãe
update "17 - sigos".codigo_servico set ordem = ordem*100 where mae is null;
update "17 - sigos".codigo_servico s set ordem = (select m.ordem from "17 - sigos".codigo_servico m where m.cod=s.mae) + right(s.cod,2)::int
 where s.mae is not null;

-- busca exata; sem achar, o código-mãe (xx xx 00)
create or replace function public.sigos_cod_info(p_cod text)
returns "17 - sigos".codigo_servico
language sql stable set search_path = public, "17 - sigos" as $$
  select c.* from "17 - sigos".codigo_servico c
   where c.cod = p_cod or (length(p_cod)=7 and c.cod = left(p_cod,5)||'00')
   order by (c.cod = p_cod) desc limit 1
$$;
revoke all on function public.sigos_cod_info(text) from public, anon;

-- serviço de origem do Gestão de Pavimento → gestor
create or replace function public.sigos_gestor_pav_origem(p_origem text)
returns text language sql immutable as $$
  select case p_origem when 'vazamento' then 'Werneck' when 'vrp' then 'Werneck' when 'dmc' then 'Werneck'
    when 'ramal' then 'Igor' when 'rede_vca' then 'Igor' when 'rede_hdd' then 'Igor' when 'fiscalizacao' then 'Yasmin' end
$$;
revoke all on function public.sigos_gestor_pav_origem(text) from public, anon;

create or replace function public.app_sigos_abertas()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', '17 - sigos'
as $function$
declare r jsonb;
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;

  with o as (
    select a.*, f.enviado_em as carteira_de, "17 - sigos".end_chave(a.endereco) as chave,
           ((now() at time zone 'America/Sao_Paulo')::date - a.abertura::date) as idade,
           ci.gestor as c_gestor, ci.familia as c_fam, ci.categoria as c_cat, ci.grupo as c_grp, ci.fluxo as c_fluxo,
           ci.descricao as c_desc, ci.cod as c_cod
    from os_aberta a join arquivo f on f.id = a.arquivo_id
    left join lateral (select * from public.sigos_cod_info(a.cod_servico)) ci on true
  ),
  nmat as (select matricula, count(*) n from os_aberta where matricula > 0 group by 1 having count(*) > 1),
  -- todas as OS por matrícula (carteira + encerradas) com gestor único, p/ resolver os compartilhados pela origem
  hist as (
    select h.matricula, h.numero, h.desc_servico, h.em, ci.gestor
      from (select matricula, numero, cod_servico, desc_servico, abertura as em from os_aberta where matricula > 0
            union all
            select matricula, numero, cod_servico, desc_servico, data_geracao from os_encerrada where matricula > 0) h
      join codigo_servico ci on ci.cod in (h.cod_servico, left(h.cod_servico,5)||'00')   -- mãe e subcódigo têm o mesmo gestor
     where ci.gestor in ('Werneck','Igor','Yasmin')
       -- só serviço que abre vala/quebra pavimento pode ser a origem (vistoria/HD/recadastro na mesma matrícula não)
       and left(h.cod_servico,3) in ('143','201','180','189','258','163','182','144','512','513','159','141','126')
  ),
  comp as (   -- gestor dos códigos compartilhados: 1) Gestão de Pavimento 2) OS de origem do SIGOS 3) matrícula
    select o.numero,
      coalesce(pv.g, og.g, mt.g) as g,
      case when pv.g is not null then 'pavimento' when og.g is not null then 'origem' when mt.g is not null then 'matricula' else 'sem_origem' end as via,
      coalesce(pv.ref, og.ref, mt.ref) as ref
    from o
    left join lateral (
      select public.sigos_gestor_pav_origem(p.servico_origem) g,
             'Gestão de Pavimento: serviço de origem '||p.servico_origem||coalesce(' (OS '||nullif(p.os_sigos,'')||')','') ref
        from "8 - coleta_campo".pav_recomposicao p
       where coalesce(p.os_recomposicao,'') <> '' and public.sigos_os_base(p.os_recomposicao) = public.sigos_os_base(o.numero)
         and public.sigos_gestor_pav_origem(p.servico_origem) is not null
       limit 1) pv on true
    left join lateral (
      select ci.gestor g, 'OS de origem '||o.os_origem||' · '||coalesce(o.desc_os_origem,'') ref
        from public.sigos_cod_info(o.cod_os_origem) ci
       where coalesce(o.os_origem,'') <> '' and ci.gestor in ('Werneck','Igor','Yasmin')) og on true
    left join lateral (
      select h.gestor g, 'mesma matrícula: OS '||h.numero||' · '||coalesce(h.desc_servico,'') ref
        from hist h
       where o.matricula > 0 and h.matricula = o.matricula and h.numero <> o.numero
       order by (h.em <= o.abertura + interval '1 day') desc, h.em desc limit 1) mt on true
    where o.c_gestor = 'Compartilhado'
  ),
  x as (
    select o.*, lg.geom as g_cad, lg.setor, lg.rota, lg.bairro_cad,
           ge.geom as g_end, ge.fonte as f_end, ge.precisao as p_end,
           nm.n as n_mat, cp.g as cp_g, cp.via as cp_via, cp.ref as cp_ref,
           (select jsonb_build_object('os', e.numero, 'srv', e.desc_servico, 'em', e.execucao)
              from os_encerrada e
             where o.matricula > 0 and e.matricula = o.matricula and e.execucao >= o.abertura
             order by e.execucao desc limit 1) as enc_depois
    from o
    left join lateral (
      select l.geom, l.setor, l.rota,
             (select b.nome from "1 - suporte_geografico".bairros b
               where b.cd_localidade = l.cd_localidade || lpad(l.cd_bairro::text, 6, '0') limit 1) as bairro_cad
        from "3 - comercial".ligacoes l
       where o.matricula > 0 and l.matricula = o.matricula and l.geom is not null
       limit 1) lg on true
    left join geo_endereco ge on ge.chave = o.chave and ge.geom is not null
    left join nmat nm on nm.matricula = o.matricula
    left join comp cp on cp.numero = o.numero
  ),
  y as (
    select x.*, coalesce(g_cad, g_end) as g,
           case when g_cad is not null then 'cadastro' when g_end is not null then f_end end as gf,
           case when g_cad is not null then 'numero' else p_end end as gp,
           case when c_gestor = 'Compartilhado' then coalesce(cp_g, 'Compartilhado')
                when c_gestor is null then 'Sem cadastro' else c_gestor end as gestor_final
    from x
  )
  select jsonb_build_object(
    'gerado_em', now(),
    'carteiras', (select jsonb_object_agg(consorcio, carteira_de) from (select distinct consorcio, carteira_de from o) c),
    'itens', coalesce(jsonb_agg(jsonb_build_object(
      'n', numero, 'za', consorcio, 'cod', cod_servico, 'srv', desc_servico, 'cls', classificacao,
      'st', status, 'eq', equipe, 'resp', responsavel, 'ta', tipo_atendimento,
      'mat', matricula, 'end', endereco,
      'bai', coalesce(bairro_cad, "17 - sigos".end_partes(endereco)->>'bairro'),
      'setor', setor, 'rota', rota,
      'ab', abertura, 'lim', limite, 'encp', enc_previsto, 'encr', enc_realizado,
      'vis', coalesce(visitas, 0), 'rk', ranqueamento, 'orig', desc_os_origem,
      'idade', idade,
      'lat', round(ST_Y(ST_Transform(g, 4326))::numeric, 6),
      'lon', round(ST_X(ST_Transform(g, 4326))::numeric, 6),
      'gf', gf, 'gp', gp, 'chave', chave,
      'nmat', coalesce(n_mat, 1),
      'exec_sigos', (status ilike 'EXECUTADA%' or enc_realizado is not null),
      'enc_depois', enc_depois,
      -- classificação pelo código (PDF v3.6)
      'gest', gestor_final, 'fam', coalesce(c_fam, public.sigos_servico_grupo(desc_servico)),
      'cat', coalesce(c_cat, 'sem_cadastro'), 'grp', c_grp, 'fluxo', c_fluxo, 'cdesc', c_desc, 'ccod', c_cod,
      'gcomp', c_gestor = 'Compartilhado', 'gvia', cp_via, 'gref', cp_ref
    ) order by idade desc nulls last), '[]'::jsonb)
  ) into r
  from y;
  return r;
end $function$;

-- pop-up "Códigos e responsáveis": todos os códigos + carteira aberta e prazo do SIGOS (limite − abertura, em dias)
create or replace function public.app_sigos_codigos()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', '17 - sigos'
as $function$
declare r jsonb;
begin
  if not public.sigos_pode_ver(auth.uid()) then raise exception 'sem permissão'; end if;
  with res as (   -- código do SIGOS → código do PDF (subcódigo/mãe), resolvido 1× por código distinto
    select cs, (public.sigos_cod_info(cs)).cod rc
      from (select distinct cod_servico cs from os_aberta union select distinct cod_servico from os_encerrada) d),
  pz as (   -- prazo observado por código (carteira + encerradas)
    select r.rc as cod, (limite::date - abertura::date) d from os_aberta a join res r on r.cs = a.cod_servico
     where limite is not null and abertura is not null
    union all
    select r.rc, (limite::date - data_geracao::date) from os_encerrada e join res r on r.cs = e.cod_servico
     where limite is not null and data_geracao is not null
  ),
  pzc as (select cod, count(*) n, percentile_disc(0.5) within group (order by d) med, min(d) mn, max(d) mx from pz where d >= 0 and cod is not null group by 1),
  ab as (select coalesce(r.rc, a.cod_servico) cod, bool_or(r.rc is null) fora_pdf, count(*) n, count(*) filter (where limite < now()) venc,
                round(avg(((now() at time zone 'America/Sao_Paulo')::date - abertura::date)))::int idade
           from os_aberta a join res r on r.cs = a.cod_servico group by 1),
  fora as (   -- código na carteira que não está no PDF
    select ab.cod, (select max(desc_servico) from os_aberta a where a.cod_servico = ab.cod) descr, ab.n, ab.venc, ab.idade
      from ab where ab.fora_pdf)
  select jsonb_build_object(
    'codigos', (select jsonb_agg(jsonb_build_object(
        'cod', c.cod, 'desc', c.descricao, 'gestor', c.gestor, 'grupo', c.grupo, 'fam', c.familia, 'cat', c.categoria,
        'fluxo', c.fluxo, 'mae', c.mae, 'obs', c.obs,
        'abertas', coalesce(ab.n, 0), 'vencidas', coalesce(ab.venc, 0), 'idade', ab.idade,
        'prazo', pzc.med, 'prazo_min', pzc.mn, 'prazo_max', pzc.mx, 'prazo_n', coalesce(pzc.n, 0)
      ) order by c.ordem)
      from codigo_servico c left join ab on ab.cod = c.cod left join pzc on pzc.cod = c.cod),
    'fora', coalesce((select jsonb_agg(jsonb_build_object('cod', f.cod, 'desc', f.descr, 'abertas', f.n, 'vencidas', f.venc,
        'prazo', (select percentile_disc(0.5) within group (order by (a.limite::date - a.abertura::date)) from os_aberta a where a.cod_servico = f.cod and a.limite is not null))) from fora f), '[]'::jsonb)
  ) into r;
  return r;
end $function$;
revoke all on function public.app_sigos_codigos() from public, anon;
grant execute on function public.app_sigos_codigos() to authenticated;
revoke all on function public.app_sigos_abertas() from public, anon;
grant execute on function public.app_sigos_abertas() to authenticated;
