/* ============================================================================
   Painel de Compras (Suprimentos) — componente montável do AcquaHub.
   window.PainelCompras.mount(containerEl, DATA)
   DATA = { meta:{...}, rows:[...] }  (vindo da RPC app_compras_dashboard)
   Métricas derivadas (funil/aging/lead/flags) calculadas aqui, espelhando
   build_data.py, usando meta.asOf (data do export) como referência.
   Fase 1: sem cotações (aba Cotações e ligações a cotação omitidas).
   Tudo escopado sob .pcdash — não vaza CSS/JS para o app.
   ============================================================================ */
(function () {
  const CSS = `
.pcdash{
  --surface-1:#fcfcfb; --surface-2:#ffffff; --page:#f9f9f7;
  --text-primary:#0b0b0b; --text-secondary:#52514e; --text-muted:#898781;
  --grid:#e1e0d9; --axis:#c3c2b7; --border:rgba(11,11,11,0.10); --success-text:#006300;
  --series-1:#2a78d6; --series-2:#eb6834; --series-3:#1baf7a; --series-4:#eda100;
  --series-5:#e87ba4; --series-6:#008300; --series-7:#4a3aa7; --series-8:#e34948;
  --seq-100:#cde2fb;--seq-150:#b7d3f6;--seq-200:#9ec5f4;--seq-250:#86b6ef;--seq-300:#6da7ec;
  --seq-350:#5598e7;--seq-400:#3987e5;--seq-450:#2a78d6;--seq-500:#256abf;--seq-550:#1c5cab;
  --seq-600:#184f95;--seq-650:#104281;--seq-700:#0d366b;
  --div-pole-a:#2a78d6; --div-pole-b:#e34948; --div-mid:#f0efec;
  --status-good:#0ca30c; --status-warning:#fab219; --status-serious:#ec835a; --status-critical:#d03b3b;
  --pcradius:10px;
  color:var(--text-primary);
  font-family:system-ui,-apple-system,"Segoe UI",sans-serif; font-size:14px; line-height:1.45;
}
@media (prefers-color-scheme:dark){ .pcdash{
  --surface-1:#1a1a19; --surface-2:#202020; --page:#0d0d0d;
  --text-primary:#ffffff; --text-secondary:#c3c2b7; --text-muted:#898781;
  --grid:#2c2c2a; --axis:#383835; --border:rgba(255,255,255,0.10); --success-text:#0ca30c;
  --series-1:#3987e5;--series-2:#d95926;--series-3:#199e70;--series-4:#c98500;
  --series-5:#d55181;--series-6:#008300;--series-7:#9085e9;--series-8:#e66767;
  --div-pole-a:#3987e5; --div-pole-b:#e66767; --div-mid:#383835;
}}
.pcdash *{box-sizing:border-box;}
.pcdash .pchead{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:10px;}
.pcdash .pchead .subtitle{color:var(--text-secondary);font-size:12.5px;}
.pcdash .badge-pill{font-size:11.5px;color:var(--text-secondary);background:var(--page);border:1px solid var(--border);border-radius:999px;padding:4px 10px;white-space:nowrap;margin-left:auto;}
.pcdash .filter-bar{background:var(--surface-1);border:1px solid var(--border);border-radius:var(--pcradius);padding:10px 12px;display:flex;gap:14px;align-items:flex-end;flex-wrap:wrap;margin-bottom:10px;position:sticky;top:0;z-index:20;}
.pcdash .filter-field{display:flex;flex-direction:column;gap:4px;}
.pcdash .filter-field label{font-size:11px;color:var(--text-muted);text-transform:uppercase;letter-spacing:.03em;}
.pcdash .filter-field select{font-family:inherit;font-size:13px;padding:6px 8px;border-radius:8px;border:1px solid var(--border);background:var(--surface-2);color:var(--text-primary);min-width:150px;}
.pcdash .filter-reset{border:1px solid var(--border);background:transparent;color:var(--text-secondary);border-radius:8px;padding:7px 12px;cursor:pointer;font-size:12.5px;margin-left:auto;}
.pcdash .filter-count{font-size:12px;color:var(--text-muted);align-self:center;}
.pcdash .tab-nav{display:flex;gap:2px;border-bottom:1px solid var(--border);overflow-x:auto;margin-bottom:6px;}
.pcdash .tab-btn{border:none;background:transparent;color:var(--text-secondary);padding:11px 14px;font-size:13.5px;font-weight:500;cursor:pointer;border-bottom:2px solid transparent;white-space:nowrap;font-family:inherit;}
.pcdash .tab-btn:hover{color:var(--text-primary);}
.pcdash .tab-btn.active{color:var(--series-1);border-bottom-color:var(--series-1);}
.pcdash .tab-panel{display:none;padding:12px 0 20px;}
.pcdash .tab-panel.active{display:block;}
.pcdash .kpi-row{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;margin-bottom:16px;}
.pcdash .grid-2{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-bottom:16px;}
.pcdash .grid-3{display:grid;grid-template-columns:2fr 1fr;gap:14px;margin-bottom:16px;}
@media (max-width:860px){ .pcdash .grid-2,.pcdash .grid-3{grid-template-columns:1fr;} }
.pcdash .section-title{font-size:13px;font-weight:600;color:var(--text-secondary);text-transform:uppercase;letter-spacing:.03em;margin:22px 0 10px;}
.pcdash .section-intro{color:var(--text-secondary);font-size:13px;margin:-4px 0 14px;max-width:900px;}
.pcdash .card{background:var(--surface-1);border:1px solid var(--border);border-radius:var(--pcradius);padding:14px 16px;}
.pcdash .stat-tile .label{font-size:12px;color:var(--text-muted);}
.pcdash .stat-tile .value{font-size:26px;font-weight:600;margin:4px 0 2px;letter-spacing:-0.01em;}
.pcdash .stat-tile .sub{font-size:12px;color:var(--text-secondary);}
.pcdash .stat-tile .sub.good{color:var(--success-text);}
.pcdash .stat-tile .sub.bad{color:var(--status-critical);}
.pcdash .chart-card{position:relative;}
.pcdash .chart-card .chead{display:flex;justify-content:space-between;align-items:flex-start;gap:10px;margin-bottom:8px;}
.pcdash .chart-card .ctitle{font-size:13.5px;font-weight:600;}
.pcdash .chart-card .csub{font-size:12px;color:var(--text-secondary);margin-top:2px;}
.pcdash .table-toggle{border:1px solid var(--border);background:transparent;color:var(--text-muted);border-radius:6px;padding:4px 8px;font-size:11.5px;cursor:pointer;white-space:nowrap;font-family:inherit;}
.pcdash .table-toggle:hover{color:var(--text-primary);}
.pcdash .chart-body{overflow-x:auto;}
.pcdash .chart-body svg{display:block;max-width:100%;}
.pcdash .chart-body.as-table svg{display:none;}
.pcdash .mini-table{display:none;width:100%;border-collapse:collapse;font-size:12.5px;}
.pcdash .chart-body.as-table .mini-table{display:table;}
.pcdash .mini-table td{padding:4px 6px;border-bottom:1px solid var(--grid);}
.pcdash .mini-table td.num{text-align:right;font-variant-numeric:tabular-nums;}
.pcdash .legend{display:flex;gap:14px;flex-wrap:wrap;margin-top:8px;font-size:12px;color:var(--text-secondary);}
.pcdash .legend-item{display:flex;align-items:center;gap:6px;}
.pcdash .legend-swatch{width:10px;height:10px;border-radius:2px;display:inline-block;}
.pcdash .legend-line{width:14px;height:2px;border-radius:1px;display:inline-block;}
.pcdash .table-wrap{max-height:560px;overflow:auto;border:1px solid var(--border);border-radius:var(--pcradius);}
.pcdash table.data-table{width:100%;border-collapse:collapse;font-size:12.8px;}
.pcdash table.data-table thead th{position:sticky;top:0;background:var(--surface-1);text-align:left;z-index:5;padding:8px 10px;font-size:11.5px;color:var(--text-muted);text-transform:uppercase;letter-spacing:.02em;border-bottom:1px solid var(--border);white-space:nowrap;}
.pcdash table.data-table thead th.sortable{cursor:pointer;user-select:none;}
.pcdash table.data-table thead th.sortable:hover{color:var(--text-primary);}
.pcdash table.data-table thead th .arrow{font-size:10px;margin-left:3px;color:var(--series-1);}
.pcdash table.data-table tbody td{padding:7px 10px;border-bottom:1px solid var(--grid);color:var(--text-primary);vertical-align:top;}
.pcdash table.data-table tbody tr:hover td{background:rgba(42,120,214,0.06);}
.pcdash table.data-table td.num,.pcdash table.data-table th.num{text-align:right;font-variant-numeric:tabular-nums;}
.pcdash table.data-table tbody tr.group-row td{background:var(--page);font-weight:600;color:var(--text-secondary);font-size:12px;text-transform:uppercase;letter-spacing:.02em;padding-top:10px;padding-bottom:6px;}
.pcdash .wrap-cell{max-width:320px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
.pcdash .text-muted{color:var(--text-muted);}
.pcdash .text-sub{color:var(--text-secondary);font-size:11.8px;}
.pcdash .search-input{font-family:inherit;font-size:13px;padding:7px 10px;border-radius:8px;border:1px solid var(--border);background:var(--surface-2);color:var(--text-primary);width:100%;max-width:320px;margin-bottom:10px;}
.pcdash .badge{display:inline-flex;align-items:center;gap:5px;padding:3px 8px;border-radius:999px;font-size:11.5px;font-weight:600;white-space:nowrap;line-height:1.6;}
.pcdash .badge .dot{width:7px;height:7px;border-radius:50%;display:inline-block;}
.pcdash .badge-ok{background:rgba(12,163,12,0.12);color:var(--success-text);}
.pcdash .badge-atencao{background:rgba(250,178,25,0.16);color:#8a5a00;}
.pcdash .badge-prioritario{background:rgba(236,131,90,0.16);color:#9c4420;}
.pcdash .badge-critico{background:rgba(208,59,59,0.14);color:var(--status-critical);}
.pcdash .badge-neutro{background:var(--page);color:var(--text-secondary);border:1px solid var(--border);}
@media (prefers-color-scheme:dark){ .pcdash .badge-atencao{color:#fab219;} .pcdash .badge-prioritario{color:#ec835a;} }
.pcdash .gap-card{margin-bottom:12px;}
.pcdash .gap-card summary{cursor:pointer;list-style:none;display:flex;align-items:center;gap:10px;padding:2px 0;}
.pcdash .gap-card summary::-webkit-details-marker{display:none;}
.pcdash .gap-card summary .chev{color:var(--text-muted);font-size:11px;transition:transform .15s;}
.pcdash .gap-card[open] summary .chev{transform:rotate(90deg);}
.pcdash .gap-card summary .gtitle{font-size:13.5px;font-weight:600;flex:1;}
.pcdash .gap-card .gbody{padding:12px 0 4px 20px;font-size:13px;color:var(--text-secondary);}
.pcdash .gap-card .gbody b{color:var(--text-primary);}
.pcdash .gap-card .glabel{font-size:11px;text-transform:uppercase;letter-spacing:.03em;color:var(--text-muted);margin-top:10px;margin-bottom:3px;}
.pcdash .gap-card .gbody p{margin:5px 0;}
.pcdash .axis-text{fill:var(--text-muted);font-size:11px;font-family:inherit;}
.pcdash .grid-line{stroke:var(--grid);stroke-width:1;}
.pcdash .baseline{stroke:var(--axis);stroke-width:1;}
#pc-viz-tooltip{position:fixed;pointer-events:none;z-index:9999;background:#0b0b0b;color:#f9f9f7;font-size:12px;padding:7px 10px;border-radius:7px;max-width:260px;opacity:0;transition:opacity .1s;box-shadow:0 4px 14px rgba(0,0,0,0.25);font-family:system-ui,sans-serif;}
#pc-viz-tooltip .tt-title{font-weight:600;margin-bottom:3px;}
#pc-viz-tooltip .tt-row{display:flex;justify-content:space-between;gap:10px;}
#pc-viz-tooltip .tt-val{font-weight:700;font-variant-numeric:tabular-nums;}
`;

  const MARKUP = `
<div class="pchead">
  <div class="subtitle">Consórcios BBL+CSS · ZA1004 Águas Integradas (Contagem) &amp; ZA0200 Eficiência Hídrica (Betim)</div>
  <span class="badge-pill" id="pc-asof">—</span>
</div>
<div class="filter-bar">
  <div class="filter-field"><label>Obra</label><select id="pc-f-obra"><option value="all">Todas</option></select></div>
  <div class="filter-field"><label>Período (solicitação)</label><select id="pc-f-periodo">
    <option value="all">Todo o período</option><option value="30">Últimos 30 dias</option>
    <option value="60">Últimos 60 dias</option><option value="90">Últimos 90 dias</option></select></div>
  <div class="filter-field"><label>Comprador</label><select id="pc-f-comprador"><option value="all">Todos</option></select></div>
  <div class="filter-field"><label>Grupo de insumo</label><select id="pc-f-grupo"><option value="all">Todos</option></select></div>
  <span class="filter-count" id="pc-filter-count"></span>
  <button class="filter-reset" id="pc-filter-reset" type="button">Limpar filtros</button>
</div>
<div class="tab-nav" id="pc-tab-nav">
  <button class="tab-btn active" data-tab="gerencial" type="button">📊 Visão Gerencial</button>
  <button class="tab-btn" data-tab="comprador" type="button">🧑‍💼 Mesa do Comprador</button>
  <button class="tab-btn" data-tab="sla" type="button">⏱ SLA &amp; Lead Time</button>
  <button class="tab-btn" data-tab="fornecedores" type="button">🚚 Fornecedores</button>
  <button class="tab-btn" data-tab="gaps" type="button">⚠️ Qualidade de Dados</button>
</div>
<div>
  <section class="tab-panel active" id="pc-panel-gerencial"></section>
  <section class="tab-panel" id="pc-panel-comprador"></section>
  <section class="tab-panel" id="pc-panel-sla"></section>
  <section class="tab-panel" id="pc-panel-fornecedores"></section>
  <section class="tab-panel" id="pc-panel-gaps"></section>
</div>`;

  let container = null, DATA = null, tooltipEl = null, built = false;
  const state = { obra:'all', periodo:'all', comprador:'all', grupo:'all', activeTab:'gerencial' };
  const q  = (s) => container.querySelector(s);
  const qa = (s) => container.querySelectorAll(s);

  /* ---------- formatters ---------- */
  const fmtInt = (v) => v==null ? '—' : Math.round(v).toLocaleString('pt-BR');
  const fmtNum = (v,d=1) => v==null ? '—' : v.toLocaleString('pt-BR',{minimumFractionDigits:d,maximumFractionDigits:d});
  const fmtBRL = (v) => v==null ? '—' : 'R$ ' + v.toLocaleString('pt-BR',{minimumFractionDigits:2,maximumFractionDigits:2});
  const fmtBRLCompact = (v) => {
    if (v==null) return '—';
    if (Math.abs(v)>=1000000) return 'R$ '+(v/1000000).toLocaleString('pt-BR',{maximumFractionDigits:1})+'M';
    if (Math.abs(v)>=1000) return 'R$ '+(v/1000).toLocaleString('pt-BR',{maximumFractionDigits:0})+'k';
    return fmtBRL(v);
  };
  const fmtPct = (v,d=0) => v==null ? '—' : v.toLocaleString('pt-BR',{minimumFractionDigits:d,maximumFractionDigits:d})+'%';
  const fmtDate = (iso) => { if(!iso) return '—'; const [y,m,d]=iso.split('-'); return `${d}/${m}/${y}`; };
  const fmtDays = (v) => { if(v==null) return '—'; const n=Math.round(v); return fmtInt(n)+(Math.abs(n)===1?' dia':' dias'); };
  const pct = (num,den) => den ? (100*num/den) : null;
  const truncateLabel = (s,n) => (s && s.length>n) ? s.slice(0,n-1)+'…' : s;
  function median(arr){ const a=arr.filter(v=>v!=null).slice().sort((x,y)=>x-y); if(!a.length)return null; const m=Math.floor(a.length/2); return a.length%2?a[m]:(a[m-1]+a[m])/2; }
  function sum(arr){ return arr.reduce((s,v)=>s+(v||0),0); }
  function sumInvoiceDedup(arr){ const seen=new Set(); let t=0; arr.forEach(r=>{ if(r.invoiceValue!=null&&r.invoiceNum!=null){ const k=r.invoiceNum+'|'+(r.supplier||''); if(!seen.has(k)){seen.add(k);t+=r.invoiceValue;} } }); return t; }
  function countDistinctInvoices(arr){ const s=new Set(); arr.forEach(r=>{ if(r.invoiceNum!=null&&r.invoiceValue!=null) s.add(r.invoiceNum+'|'+(r.supplier||'')); }); return s.size; }
  function weekStart(iso){ const d=new Date(iso+'T00:00:00'); const day=(d.getDay()+6)%7; d.setDate(d.getDate()-day); return d.toISOString().slice(0,10); }
  function daysAgo(iso, asOf){ return Math.round((new Date(asOf+'T00:00:00')-new Date(iso+'T00:00:00'))/86400000); }
  function escText(s){ return s==null ? '' : String(s); }
  function debounce(fn,ms){ let t; return (...a)=>{ clearTimeout(t); t=setTimeout(()=>fn(...a),ms); }; }

  /* ---------- derive (espelha build_data.py; asOf = data do export) ---------- */
  function deriveRows(D){
    const asOfD = new Date(D.meta.asOf+'T00:00:00');
    const db = (x,y)=> (x&&y)? Math.round((new Date(y+'T00:00:00')-new Date(x+'T00:00:00'))/86400000) : null;
    D.rows.forEach(r=>{
      let stage;
      if (r.itemAuthStatus==='Reprovado') stage='reprovado';
      else if (r.itemAuthStatus!=='Autorizado') stage='aguardando_autorizacao_item';
      else if (!r.orderNum) stage='pronto_para_comprar';
      else if (r.orderAuthStatus!=='Autorizado') stage='aguardando_autorizacao_pedido';
      else if (!r.siteDeliveryDate) stage='aguardando_entrega';
      else if (r.balance && r.balance>0.0001) stage='entregue_parcial';
      else if (r.paymentStatus==='Totalmente pago') stage='pago';
      else if (r.invoiceNum) stage='faturado';
      else stage='entregue_total';
      r.stage=stage;
      r.isOpenBacklog=['aguardando_autorizacao_item','pronto_para_comprar','aguardando_autorizacao_pedido','aguardando_entrega','entregue_parcial'].includes(stage);
      r.agingDays = r.reqDate ? Math.round((asOfD-new Date(r.reqDate+'T00:00:00'))/86400000) : null;
      let tier=null;
      if (r.isOpenBacklog && r.agingDays!=null){ const a=r.agingDays; tier=a<=7?'ok':a<=15?'atencao':a<=30?'prioritario':'critico'; }
      r.urgencyTier=tier;
      r.leadAuthToOrder=db(r.reqAuthDate,r.orderDate);
      r.leadReqToAuth=db(r.reqDate,r.reqAuthDate);
      r.leadOrderToOrderAuth=db(r.orderDate,r.orderAuthDate);
      r.leadOrderToDelivery=db(r.orderDate,r.siteDeliveryDate);
      r.leadDeliveryVsForecast=db(r.deliveryForecast,r.siteDeliveryDate);
      r.leadDeliveryVsNeeded=db(r.neededDate,r.siteDeliveryDate);
      const f=[];
      if (r.reqStatusRaw==='Totalmente atendida' && !r.orderNum) f.push('atendida_sem_pedido');
      if (r.reqStatusRaw==='Totalmente atendida' && !r.siteDeliveryDate) f.push('atendida_sem_entrega');
      if (r.siteDeliveryDate && r.orderDate && r.siteDeliveryDate < r.orderDate) f.push('entrega_antes_pedido');
      if (r.qtyDelivered!=null && r.qtyReq!=null && r.qtyDelivered > r.qtyReq+0.0001) f.push('entrega_maior_que_solicitado');
      if (r.itemAuthStatus==='Reprovado' && r.reqStatusRaw==='Pendente') f.push('reprovado_mas_pendente');
      if (r.invoiceNum && (r.invoiceValue==null||r.invoiceValue===0)) f.push('nf_sem_valor');
      if (r.isOpenBacklog && r.agingDays!=null && r.agingDays>60) f.push('backlog_critico_60d');
      r.flags=f;
    });
  }

  /* ---------- filter engine ---------- */
  function getFilteredRows(){
    const asOf = DATA.meta.asOf;
    let minDate = null;
    if (state.periodo!=='all'){ const d=new Date(asOf+'T00:00:00'); d.setDate(d.getDate()-parseInt(state.periodo,10)); minDate=d.toISOString().slice(0,10); }
    return DATA.rows.filter(r=>{
      if (state.obra!=='all' && r.projCode!==state.obra) return false;
      if (state.comprador!=='all' && r.buyer!==state.comprador) return false;
      if (state.grupo!=='all' && r.group!==state.grupo) return false;
      if (minDate && r.reqDate && r.reqDate < minDate) return false;
      return true;
    });
  }
  function populateFilters(){
    const obraSel=q('#pc-f-obra'); obraSel.innerHTML='<option value="all">Todas</option>';
    (DATA.meta.projetos||[]).forEach(([code,label])=>{ const o=document.createElement('option'); o.value=code; o.textContent=label; obraSel.appendChild(o); });
    const compSel=q('#pc-f-comprador'); compSel.innerHTML='<option value="all">Todos</option>';
    (DATA.meta.compradores||[]).forEach(b=>{ const o=document.createElement('option'); o.value=b; o.textContent=b; compSel.appendChild(o); });
    const grpSel=q('#pc-f-grupo'); grpSel.innerHTML='<option value="all">Todos</option>';
    (DATA.meta.grupos||[]).forEach(g=>{ const o=document.createElement('option'); o.value=g; o.textContent=g; grpSel.appendChild(o); });
    q('#pc-asof').textContent = `dados de referência: ${fmtDate(DATA.meta.asOf)} ${DATA.meta.asOfTime||''}`.trim();
  }
  function wireFilters(){
    const map={'pc-f-obra':'obra','pc-f-periodo':'periodo','pc-f-comprador':'comprador','pc-f-grupo':'grupo'};
    Object.keys(map).forEach(id=>{ q('#'+id).addEventListener('change',(e)=>{ state[map[id]]=e.target.value; renderAll(); }); });
    q('#pc-filter-reset').addEventListener('click',()=>{ state.obra='all';state.periodo='all';state.comprador='all';state.grupo='all';
      q('#pc-f-obra').value='all';q('#pc-f-periodo').value='all';q('#pc-f-comprador').value='all';q('#pc-f-grupo').value='all'; renderAll(); });
    qa('.tab-btn').forEach(btn=>btn.addEventListener('click',()=>{
      qa('.tab-btn').forEach(b=>b.classList.remove('active'));
      qa('.tab-panel').forEach(p=>p.classList.remove('active'));
      btn.classList.add('active'); state.activeTab=btn.dataset.tab;
      q('#pc-panel-'+state.activeTab).classList.add('active'); renderActiveTab();
    }));
    window.addEventListener('resize', debounce(renderAll,200));
  }

  /* ---------- tooltip ---------- */
  function showTooltip(evt,titleText,rowsArr){
    tooltipEl.innerHTML=''; const t=document.createElement('div'); t.className='tt-title'; t.textContent=titleText; tooltipEl.appendChild(t);
    rowsArr.forEach(([k,v])=>{ const row=document.createElement('div'); row.className='tt-row';
      const kEl=document.createElement('span'); kEl.textContent=k; const vEl=document.createElement('span'); vEl.className='tt-val'; vEl.textContent=v;
      row.appendChild(kEl); row.appendChild(vEl); tooltipEl.appendChild(row); });
    tooltipEl.style.opacity='1'; moveTooltip(evt);
  }
  function moveTooltip(evt){
    const pad=14; let x=evt.clientX+pad, y=evt.clientY+pad;
    const tw=tooltipEl.offsetWidth||180, th=tooltipEl.offsetHeight||60;
    if (x+tw>window.innerWidth-10) x=evt.clientX-tw-pad;
    if (y+th>window.innerHeight-10) y=evt.clientY-th-pad;
    tooltipEl.style.left=x+'px'; tooltipEl.style.top=y+'px';
  }
  function hideTooltip(){ tooltipEl.style.opacity='0'; }

  /* ---------- svg helpers ---------- */
  function svgEl(tag,attrs={}){ const el=document.createElementNS('http://www.w3.org/2000/svg',tag); for(const k in attrs) el.setAttribute(k,attrs[k]); return el; }
  function textEl(x,y,content,cls,attrs={}){ const t=svgEl('text',Object.assign({x,y,class:cls},attrs)); t.textContent=content; return t; }

  function chartCard(cont,opts){
    const card=document.createElement('div'); card.className='card chart-card';
    const head=document.createElement('div'); head.className='chead';
    const tw=document.createElement('div'); const t=document.createElement('div'); t.className='ctitle'; t.textContent=opts.title; tw.appendChild(t);
    if (opts.subtitle){ const s=document.createElement('div'); s.className='csub'; s.textContent=opts.subtitle; tw.appendChild(s); }
    head.appendChild(tw);
    const toggle=document.createElement('button'); toggle.className='table-toggle'; toggle.type='button'; toggle.textContent='Ver tabela'; head.appendChild(toggle);
    card.appendChild(head);
    const body=document.createElement('div'); body.className='chart-body'; card.appendChild(body); cont.appendChild(card);
    function draw(){
      body.innerHTML='';
      const w=Math.max(280, body.clientWidth||cont.clientWidth||560);
      const svg=opts.buildSVG(w); if(svg) body.appendChild(svg);
      if (opts.legend){ body.appendChild(opts.legend()); }
      if (opts.tableCols && opts.tableRows){
        const tbl=document.createElement('table'); tbl.className='mini-table';
        opts.tableRows.forEach(r=>{ const tr=document.createElement('tr'); r.forEach((cell,i)=>{ const td=document.createElement('td'); if(i>0) td.className='num'; td.textContent=cell; tr.appendChild(td); }); tbl.appendChild(tr); });
        body.appendChild(tbl);
      }
    }
    draw();
    toggle.addEventListener('click',()=>{ const isT=body.classList.toggle('as-table'); toggle.textContent=isT?'Ver gráfico':'Ver tabela'; });
    return { redraw:draw, bodyEl:body };
  }
  function statTile(cont,{label,value,sub,subClass}){
    const d=document.createElement('div'); d.className='card stat-tile';
    const l=document.createElement('div'); l.className='label'; l.textContent=label;
    const v=document.createElement('div'); v.className='value'; v.textContent=value;
    d.appendChild(l); d.appendChild(v);
    if (sub){ const s=document.createElement('div'); s.className='sub'+(subClass?(' '+subClass):''); s.textContent=sub; d.appendChild(s); }
    cont.appendChild(d); return d;
  }
  function seqColor(step){ return `var(--seq-${step})`; }

  function hBarList(width,items,opts={}){
    const rowH=opts.rowH||46, barH=14, topPad=6;
    const maxVal=opts.maxValue||Math.max(1,...items.map(i=>i.value||0));
    const height=topPad+items.length*rowH;
    const svg=svgEl('svg',{width,height,viewBox:`0 0 ${width} ${height}`});
    const defs=svgEl('defs'); const pat=svgEl('pattern',{id:'pcHatchND',width:6,height:6,patternUnits:'userSpaceOnUse',patternTransform:'rotate(45)'});
    pat.appendChild(svgEl('line',{x1:0,y1:0,x2:0,y2:6,style:'stroke:var(--text-muted);stroke-width:2'})); defs.appendChild(pat); svg.appendChild(defs);
    items.forEach((it,i)=>{
      const y=topPad+i*rowH; const g=svgEl('g',{});
      g.appendChild(textEl(0,y+11,it.label,'axis-text',{style:'fill:var(--text-secondary);font-size:12.5px'}));
      if (it.display!=null) g.appendChild(textEl(width,y+11,it.display,'',{style:'fill:var(--text-primary);font-size:12.5px;font-weight:600;text-anchor:end;font-variant-numeric:tabular-nums'}));
      const trackY=y+18;
      g.appendChild(svgEl('rect',{x:0,y:trackY,width:width,height:barH,rx:4,style:'fill:var(--grid)'}));
      if (it.noData){ g.appendChild(svgEl('rect',{x:0,y:trackY,width:width*0.22,height:barH,rx:4,style:'fill:url(#pcHatchND);stroke:var(--text-muted);stroke-width:1;stroke-dasharray:3,2;opacity:0.8'})); }
      else { const w=Math.max(3,width*Math.min(1,(it.value||0)/maxVal)); g.appendChild(svgEl('rect',{x:0,y:trackY,width:w,height:barH,rx:4,style:`fill:${it.color||'var(--series-1)'}`})); }
      if (it.sub) g.appendChild(textEl(0,trackY+barH+12,it.sub,'',{style:'fill:var(--text-muted);font-size:11px'}));
      const hit=svgEl('rect',{x:0,y:y,width:width,height:rowH,fill:'transparent',style:'cursor:pointer'});
      hit.addEventListener('pointermove',(e)=>{ if(it.noData) showTooltip(e,it.label,[['Situação','Sem dados neste relatório']]); else showTooltip(e,it.label,it.ttRows||[['Valor',it.display]]); });
      hit.addEventListener('pointerleave',hideTooltip); g.appendChild(hit); svg.appendChild(g);
    });
    return svg;
  }
  function columnChart(width,buckets,opts={}){
    const height=opts.height||200, padL=34,padB=28,padT=10,padR=10;
    const plotW=width-padL-padR, plotH=height-padT-padB;
    const maxVal=opts.maxValue||Math.max(1,...buckets.map(b=>b.value||0));
    const n=buckets.length, gap=10, colW=Math.min(48,(plotW-gap*(n-1))/n);
    const totalW=colW*n+gap*(n-1), offsetX=padL+(plotW-totalW)/2;
    const svg=svgEl('svg',{width,height,viewBox:`0 0 ${width} ${height}`});
    const ticks=4;
    for(let t=0;t<=ticks;t++){ const yy=padT+plotH-(plotH*t/ticks); svg.appendChild(svgEl('line',{x1:padL,x2:width-padR,y1:yy,y2:yy,class:'grid-line'})); svg.appendChild(textEl(padL-6,yy+3,fmtInt(Math.round(maxVal*t/ticks)),'axis-text',{'text-anchor':'end'})); }
    buckets.forEach((b,i)=>{
      const x=offsetX+i*(colW+gap); const h=Math.max(1,plotH*Math.min(1,(b.value||0)/maxVal)); const y=padT+plotH-h;
      svg.appendChild(svgEl('rect',{x,y,width:colW,height:h,rx:4,style:`fill:${b.color||'var(--series-1)'}`}));
      if (h>14) svg.appendChild(textEl(x+colW/2,y-6,fmtInt(b.value),'',{style:'fill:var(--text-primary);font-size:11.5px;font-weight:600;text-anchor:middle;font-variant-numeric:tabular-nums'}));
      svg.appendChild(textEl(x+colW/2,height-padB+16,b.label,'axis-text',{'text-anchor':'middle'}));
      const hit=svgEl('rect',{x,y:padT,width:colW,height:plotH,fill:'transparent',style:'cursor:pointer'});
      hit.addEventListener('pointermove',(e)=>showTooltip(e,b.label,[['Itens',fmtInt(b.value)]])); hit.addEventListener('pointerleave',hideTooltip); svg.appendChild(hit);
    });
    svg.appendChild(svgEl('line',{x1:padL,x2:width-padR,y1:padT+plotH,y2:padT+plotH,class:'baseline'}));
    return svg;
  }
  function lineChart(width,xLabels,series,opts={}){
    const height=opts.height||220, padL=36,padB=26,padT=12,padR=14;
    const plotW=width-padL-padR, plotH=height-padT-padB;
    const allVals=series.flatMap(s=>s.values).filter(v=>v!=null); const maxVal=Math.max(1,...allVals);
    const n=xLabels.length; const xAt=(i)=>padL+(n<=1?0:plotW*i/(n-1)); const yAt=(v)=>padT+plotH-plotH*Math.min(1,v/maxVal);
    const svg=svgEl('svg',{width,height,viewBox:`0 0 ${width} ${height}`}); const ticks=4;
    for(let t=0;t<=ticks;t++){ const yy=padT+plotH-(plotH*t/ticks); svg.appendChild(svgEl('line',{x1:padL,x2:width-padR,y1:yy,y2:yy,class:'grid-line'})); svg.appendChild(textEl(padL-6,yy+3,fmtInt(Math.round(maxVal*t/ticks)),'axis-text',{'text-anchor':'end'})); }
    const step=Math.ceil(n/10);
    xLabels.forEach((lb,i)=>{ if(i%step===0||i===n-1) svg.appendChild(textEl(xAt(i),height-padB+16,lb,'axis-text',{'text-anchor':'middle'})); });
    series.forEach(s=>{ let d=''; s.values.forEach((v,i)=>{ if(v==null)return; d+=(d===''?'M':'L')+xAt(i)+' '+yAt(v)+' '; });
      svg.appendChild(svgEl('path',{d,style:`fill:none;stroke:${s.color};stroke-width:2;stroke-linejoin:round;stroke-linecap:round`}));
      s.values.forEach((v,i)=>{ if(v==null)return; svg.appendChild(svgEl('circle',{cx:xAt(i),cy:yAt(v),r:3,style:`fill:${s.color};stroke:var(--surface-1);stroke-width:2`})); }); });
    svg.appendChild(svgEl('line',{x1:padL,x2:width-padR,y1:padT+plotH,y2:padT+plotH,class:'baseline'}));
    const hit=svgEl('rect',{x:padL,y:padT,width:plotW,height:plotH,fill:'transparent',style:'cursor:crosshair'});
    const cross=svgEl('line',{x1:0,x2:0,y1:padT,y2:padT+plotH,style:'stroke:var(--axis);stroke-width:1;opacity:0'}); svg.appendChild(cross);
    hit.addEventListener('pointermove',(e)=>{ const rect=svg.getBoundingClientRect(); const relX=(e.clientX-rect.left)*(width/rect.width);
      let idx=Math.round((relX-padL)/(plotW/(n-1||1))); idx=Math.max(0,Math.min(n-1,idx));
      cross.setAttribute('x1',xAt(idx)); cross.setAttribute('x2',xAt(idx)); cross.setAttribute('opacity',1);
      showTooltip(e,xLabels[idx],series.map(s=>[s.name,s.values[idx]==null?'—':fmtInt(s.values[idx])])); });
    hit.addEventListener('pointerleave',()=>{ cross.setAttribute('opacity',0); hideTooltip(); }); svg.appendChild(hit);
    return svg;
  }
  function legendRow(items){ const wrap=document.createElement('div'); wrap.className='legend';
    items.forEach(it=>{ const el=document.createElement('span'); el.className='legend-item'; const sw=document.createElement('span'); sw.className=it.type==='line'?'legend-line':'legend-swatch'; sw.style.background=it.color; const lb=document.createElement('span'); lb.textContent=it.label; el.appendChild(sw); el.appendChild(lb); wrap.appendChild(el); }); return wrap; }
  function badgeFor(tier){ const map={ok:['badge-ok','✓ Normal'],atencao:['badge-atencao','● Atenção'],prioritario:['badge-prioritario','▲ Prioritário'],critico:['badge-critico','■ Crítico']}; const [cls,txt]=map[tier]||['badge-neutro','—']; return `<span class="badge ${cls}">${txt}</span>`; }

  function buildTable(cont,{columns,rows,defaultSortKey,defaultSortDir=-1,groupKey,groupLabelFn}){
    let sortKey=defaultSortKey, sortDir=defaultSortDir;
    const wrap=document.createElement('div'); wrap.className='table-wrap';
    const table=document.createElement('table'); table.className='data-table';
    const thead=document.createElement('thead'); const htr=document.createElement('tr');
    columns.forEach(col=>{ const th=document.createElement('th'); if(col.align==='num') th.classList.add('num'); th.classList.add('sortable'); th.textContent=col.label;
      th.addEventListener('click',()=>{ if(sortKey===col.key) sortDir*=-1; else {sortKey=col.key;sortDir=1;} draw(); }); htr.appendChild(th); });
    thead.appendChild(htr); table.appendChild(thead);
    const tbody=document.createElement('tbody'); table.appendChild(tbody); wrap.appendChild(table); cont.appendChild(wrap);
    function draw(){
      columns.forEach((col,i)=>{ htr.children[i].innerHTML=col.label+(col.key===sortKey?`<span class="arrow">${sortDir>0?'▲':'▼'}</span>`:''); });
      let data=rows.slice();
      data.sort((a,b)=>{ let va=a[sortKey],vb=b[sortKey]; if(va==null)va=typeof vb==='number'?-Infinity:''; if(vb==null)vb=typeof va==='number'?-Infinity:''; if(typeof va==='string')return va.localeCompare(vb)*sortDir; return (va-vb)*sortDir; });
      tbody.innerHTML='';
      if (!data.length){ const tr=document.createElement('tr'); const td=document.createElement('td'); td.colSpan=columns.length; td.className='text-muted'; td.style.padding='16px'; td.textContent='Nenhum item para os filtros selecionados.'; tr.appendChild(td); tbody.appendChild(tr); return; }
      let lastGroup;
      data.forEach(row=>{
        if (groupKey && row[groupKey]!==lastGroup){ lastGroup=row[groupKey]; const gtr=document.createElement('tr'); gtr.className='group-row'; const gtd=document.createElement('td'); gtd.colSpan=columns.length; gtd.textContent=groupLabelFn?groupLabelFn(lastGroup,data.filter(d=>d[groupKey]===lastGroup)):String(lastGroup); gtr.appendChild(gtd); tbody.appendChild(gtr); }
        const tr=document.createElement('tr');
        columns.forEach(col=>{ const td=document.createElement('td'); if(col.align==='num') td.classList.add('num'); if(col.cellClass) td.classList.add(col.cellClass);
          const val=row[col.key]; if(col.html) td.innerHTML=col.fmt?col.fmt(val,row):escText(val); else td.textContent=col.fmt?col.fmt(val,row):escText(val); if(col.title) td.title=col.title(row); tr.appendChild(td); });
        tbody.appendChild(tr);
      });
    }
    draw(); return { redraw:draw };
  }
  function simpleTable(rowsArr,cols,limit=15){
    const holder=document.createElement('div'); const wrap=document.createElement('div'); wrap.className='table-wrap'; wrap.style.maxHeight='320px';
    const table=document.createElement('table'); table.className='data-table'; const thead=document.createElement('thead'); const htr=document.createElement('tr');
    cols.forEach(c=>{ const th=document.createElement('th'); if(c.align==='num') th.classList.add('num'); th.textContent=c.label; htr.appendChild(th); }); thead.appendChild(htr); table.appendChild(thead);
    const tbody=document.createElement('tbody');
    rowsArr.slice(0,limit).forEach(r=>{ const tr=document.createElement('tr'); cols.forEach(c=>{ const td=document.createElement('td'); if(c.align==='num') td.classList.add('num'); td.textContent=c.fmt?c.fmt(r[c.key],r):escText(r[c.key]); tr.appendChild(td); }); tbody.appendChild(tr); });
    table.appendChild(tbody); wrap.appendChild(table); holder.appendChild(wrap);
    if (rowsArr.length>limit){ const note=document.createElement('div'); note.className='text-sub'; note.style.marginTop='6px'; note.textContent=`Mostrando ${limit} de ${rowsArr.length} itens.`; holder.appendChild(note); }
    return holder;
  }
  function sectionTitle(text){ const d=document.createElement('div'); d.className='section-title'; d.textContent=text; return d; }
  function sectionIntro(text){ const d=document.createElement('div'); d.className='section-intro'; d.textContent=text; return d; }
  function emptyChartMsg(width,msg,h=120){ const svg=svgEl('svg',{width,height:h,viewBox:`0 0 ${width} ${h}`}); svg.appendChild(textEl(width/2,h/2,msg,'',{style:'fill:var(--text-muted);font-size:12.5px;text-anchor:middle'})); return svg; }
  function emptyStateCard(msg){ const d=document.createElement('div'); d.className='card'; d.style.textAlign='center'; d.style.color='var(--text-muted)'; d.style.padding='30px'; d.textContent=msg; return d; }

  /* ---------- render dispatch ---------- */
  function renderAll(){
    const rows=getFilteredRows();
    q('#pc-filter-count').textContent=`${fmtInt(rows.length)} de ${fmtInt(DATA.rows.length)} itens`;
    renderGerencial(rows); renderComprador(rows); renderSLA(rows); renderFornecedores(rows); renderGaps(rows);
  }
  function renderActiveTab(){ const rows=getFilteredRows(); ({gerencial:renderGerencial,comprador:renderComprador,sla:renderSLA,fornecedores:renderFornecedores,gaps:renderGaps}[state.activeTab]||renderGerencial)(rows); }

  function renderGerencial(rows){
    const panel=q('#pc-panel-gerencial'); panel.innerHTML='';
    const nItems=rows.length; if(!nItems){ panel.appendChild(emptyStateCard('Nenhum item corresponde aos filtros selecionados.')); return; }
    const reqIds=new Set(rows.map(r=>r.reqId));
    const open=rows.filter(r=>r.isOpenBacklog); const critico=open.filter(r=>r.urgencyTier==='critico');
    const itemsAuth=rows.filter(r=>r.itemAuthStatus==='Autorizado').length;
    const reprovado=rows.filter(r=>r.stage==='reprovado').length;
    const naoAutorizado=rows.filter(r=>r.itemAuthStatus==='Não autorizado').length;
    const withOrder=rows.filter(r=>r.orderNum).length;
    const orderAuth=rows.filter(r=>r.orderAuthStatus==='Autorizado').length;
    const entregue=rows.filter(r=>r.siteDeliveryDate).length;
    const invoiced=rows.filter(r=>r.invoiceNum); const paid=rows.filter(r=>r.paymentStatus==='Totalmente pago').length;
    const totalInvoiced=sumInvoiceDedup(rows); const nNF=countDistinctInvoices(rows);

    const kpiRow=document.createElement('div'); kpiRow.className='kpi-row'; panel.appendChild(kpiRow);
    statTile(kpiRow,{label:'Itens solicitados',value:fmtInt(nItems),sub:`${fmtInt(reqIds.size)} solicitações únicas`});
    statTile(kpiRow,{label:'Em aberto (backlog)',value:fmtInt(open.length),sub:`${fmtPct(pct(open.length,nItems))} do total de itens`});
    statTile(kpiRow,{label:'Backlog crítico (>30 dias)',value:fmtInt(critico.length),sub:open.length?`${fmtPct(pct(critico.length,open.length))} do backlog aberto`:'—',subClass:critico.length>0?'bad':''});
    statTile(kpiRow,{label:'Autorização de itens',value:fmtPct(pct(itemsAuth,nItems),1),sub:`${fmtInt(reprovado+naoAutorizado)} reprovados/não autorizados`});
    statTile(kpiRow,{label:'Autorização de pedidos',value:withOrder?fmtPct(pct(orderAuth,withOrder),1):'—',sub:withOrder?`${fmtInt(withOrder-orderAuth)} pedidos aguardando aprovação`:'nenhum pedido emitido',subClass:(withOrder&&pct(orderAuth,withOrder)<60)?'bad':''});
    statTile(kpiRow,{label:'Valor faturado (NF)',value:fmtBRLCompact(totalInvoiced),sub:`${fmtInt(nNF)} notas fiscais · ${fmtInt(invoiced.length)} itens faturados`});

    panel.appendChild(sectionTitle('Funil de suprimentos — da solicitação ao pagamento'));
    panel.appendChild(sectionIntro('Cada etapa conta itens (linhas do relatório), não números de solicitação — uma solicitação pode reunir vários itens em estágios diferentes.'));
    const funnelItems=[
      {label:'Solicitações criadas (itens)',value:nItems,color:seqColor(200)},
      {label:'Itens autorizados',value:itemsAuth,color:seqColor(300),sub:(reprovado+naoAutorizado)>0?`${fmtInt(reprovado)} reprovados + ${fmtInt(naoAutorizado)} não autorizados`:null},
      {label:'Pedido de compra emitido',value:withOrder,color:seqColor(450)},
      {label:'Pedido autorizado',value:orderAuth,color:seqColor(500),sub:withOrder>orderAuth?`${fmtInt(withOrder-orderAuth)} aguardando aprovação`:null},
      {label:'Entregue (parcial ou total)',value:entregue,color:seqColor(550)},
      {label:'Faturado (nota fiscal)',value:invoiced.length,color:seqColor(600)},
      {label:'Pago',value:paid,color:seqColor(700)},
    ];
    funnelItems.forEach(it=>{ it.display=fmtInt(it.value)+'  ·  '+fmtPct(pct(it.value,nItems),0); it.ttRows=[['Itens',fmtInt(it.value)],['% do total de itens',fmtPct(pct(it.value,nItems),1)]]; });
    const funnelGrid=document.createElement('div'); funnelGrid.className='grid-3'; panel.appendChild(funnelGrid);
    const funnelCol=document.createElement('div');
    chartCard(funnelCol,{title:'Funil solicitação → pagamento',subtitle:`Base: ${fmtInt(nItems)} itens no filtro atual`,buildSVG:(w)=>hBarList(w,funnelItems,{maxValue:nItems}),tableCols:['Etapa','Itens'],tableRows:funnelItems.map(it=>[it.label,fmtInt(it.value)+' ('+fmtPct(pct(it.value,nItems),0)+')'])});
    funnelGrid.appendChild(funnelCol);
    const conv1=pct(withOrder,itemsAuth), conv2=pct(orderAuth,withOrder);
    const calloutCol=document.createElement('div'); calloutCol.className='card';
    calloutCol.innerHTML=`<div style="font-size:13.5px;font-weight:600;margin-bottom:10px">Leitura do funil</div>
      <div class="callout-row" style="display:flex;flex-direction:column;gap:10px">
        <div class="card" style="background:var(--page);font-size:12.5px;color:var(--text-secondary)"><b>${fmtPct(conv1,0)}</b> dos itens autorizados chegam a um pedido de compra — o maior estrangulamento do processo (ver aba SLA para o tempo entre autorização e emissão).</div>
        <div class="card" style="background:var(--page);font-size:12.5px;color:var(--text-secondary)"><b>${fmtPct(conv2,0)}</b> dos pedidos emitidos já foram autorizados pela alçada responsável; o restante aguarda aprovação antes de seguir ao fornecedor.</div>
      </div>`;
    funnelGrid.appendChild(calloutCol);

    panel.appendChild(sectionTitle('Backlog em aberto e concentração da demanda'));
    const chartsGrid=document.createElement('div'); chartsGrid.className='grid-2'; panel.appendChild(chartsGrid);
    const agingBuckets=[
      {label:'0–7 d',color:'var(--status-good)',value:open.filter(r=>r.urgencyTier==='ok').length},
      {label:'8–15 d',color:'var(--status-warning)',value:open.filter(r=>r.urgencyTier==='atencao').length},
      {label:'16–30 d',color:'var(--status-serious)',value:open.filter(r=>r.urgencyTier==='prioritario').length},
      {label:'>30 d',color:'var(--status-critical)',value:open.filter(r=>r.urgencyTier==='critico').length},
    ];
    const agingCol=document.createElement('div');
    chartCard(agingCol,{title:'Idade do backlog aberto',subtitle:open.length?`${fmtInt(open.length)} itens em aberto · mediana ${fmtDays(median(open.map(r=>r.agingDays)))}`:'Sem itens em aberto no filtro atual',buildSVG:(w)=>open.length?columnChart(w,agingBuckets):emptyChartMsg(w,'Sem itens em aberto'),tableCols:['Faixa de dias em aberto','Itens'],tableRows:agingBuckets.map(b=>[b.label,fmtInt(b.value)])});
    chartsGrid.appendChild(agingCol);
    const byGroupVol={}; rows.forEach(r=>{ byGroupVol[r.group]=(byGroupVol[r.group]||0)+1; });
    const topGroups=Object.entries(byGroupVol).sort((a,b)=>b[1]-a[1]).slice(0,8);
    const groupItems=topGroups.map(([g,v])=>({label:g,value:v,display:fmtInt(v),color:'var(--series-1)',ttRows:[['Itens solicitados',fmtInt(v)],['% do total',fmtPct(pct(v,rows.length),1)]]}));
    const groupCol=document.createElement('div');
    chartCard(groupCol,{title:'Top grupos de insumo por volume de itens',subtitle:topGroups.length?`${fmtInt(topGroups.length)} de ${fmtInt(Object.keys(byGroupVol).length)} grupos · onde a demanda se concentra`:'Sem itens no filtro atual',buildSVG:(w)=>topGroups.length?hBarList(w,groupItems):emptyChartMsg(w,'Sem itens'),tableCols:['Grupo de insumo','Itens'],tableRows:topGroups.map(([g,v])=>[g,fmtInt(v)])});
    chartsGrid.appendChild(groupCol);

    panel.appendChild(sectionTitle('Tendência: entrada de solicitações × saída (entregas), por semana'));
    const weeksSet=new Set(); rows.forEach(r=>{ if(r.reqDate)weeksSet.add(weekStart(r.reqDate)); if(r.siteDeliveryDate)weeksSet.add(weekStart(r.siteDeliveryDate)); });
    const weeks=Array.from(weeksSet).sort();
    const criadas=weeks.map(w=>rows.filter(r=>r.reqDate&&weekStart(r.reqDate)===w).length);
    const entregues=weeks.map(w=>rows.filter(r=>r.siteDeliveryDate&&weekStart(r.siteDeliveryDate)===w).length);
    const trendCol=document.createElement('div');
    chartCard(trendCol,{title:'Solicitações criadas × itens entregues por semana',subtitle:'Datas no eixo = segunda-feira de início da semana',buildSVG:(w)=>weeks.length?lineChart(w,weeks.map(fmtDate),[{name:'Criadas',color:'var(--series-1)',values:criadas},{name:'Entregues',color:'var(--series-2)',values:entregues}]):emptyChartMsg(w,'Sem dados no período selecionado'),legend:()=>legendRow([{label:'Criadas',color:'var(--series-1)',type:'line'},{label:'Entregues',color:'var(--series-2)',type:'line'}]),tableCols:['Semana','Criadas','Entregues'],tableRows:weeks.map((w,i)=>[fmtDate(w),fmtInt(criadas[i]),fmtInt(entregues[i])])});
    panel.appendChild(trendCol);

    panel.appendChild(sectionTitle('Comparativo entre obras'));
    const obraStats=(DATA.meta.projetos||[]).filter(([code])=>rows.some(r=>r.projCode===code)).map(([code,label])=>{
      const rs=rows.filter(r=>r.projCode===code); const openR=rs.filter(r=>r.isOpenBacklog); const crit=openR.filter(r=>r.urgencyTier==='critico');
      return {label,n:rs.length,open:openR.length,critico:crit.length,valor:sumInvoiceDedup(rs)};
    });
    const obraDiv=document.createElement('div');
    buildTable(obraDiv,{columns:[{key:'label',label:'Obra'},{key:'n',label:'Itens',align:'num'},{key:'open',label:'Em aberto',align:'num'},{key:'critico',label:'Críticos >30d',align:'num'},{key:'valor',label:'Valor faturado',align:'num',fmt:(v)=>fmtBRL(v)}],rows:obraStats,defaultSortKey:'n'});
    panel.appendChild(obraDiv);
  }

  function renderComprador(rows){
    const panel=q('#pc-panel-comprador'); panel.innerHTML='';
    if(!rows.length){ panel.appendChild(emptyStateCard('Nenhum item corresponde aos filtros selecionados.')); return; }
    const asOf=DATA.meta.asOf;
    const BUCKETS={
      pronto_para_comprar:{order:0,label:'Pronto para comprar — emitir pedido',hint:(r)=>`Autorizado em ${fmtDate(r.reqAuthDate)}, sem pedido emitido`},
      aguardando_autorizacao_pedido:{order:1,label:'Aguardando autorização do pedido',hint:(r)=>`Pedido ${r.orderNum||'—'} emitido em ${fmtDate(r.orderDate)}, ainda não autorizado`},
      aguardando_entrega:{order:2,label:'Aguardando entrega do fornecedor',hint:(r)=>{ if(!r.deliveryForecast)return `Pedido ${r.orderNum||'—'} sem previsão de entrega informada`; const d=daysAgo(r.deliveryForecast,asOf); return `Pedido ${r.orderNum||'—'} · ${r.supplier||'fornecedor n/d'} · previsão ${fmtDate(r.deliveryForecast)}`+(d>0?` — ${fmtDays(d)} de atraso`:''); }},
      aguardando_autorizacao_item:{order:3,label:'Aguardando liberação (fora do controle do comprador)',hint:()=>'Item ainda não autorizado pelo aprovador da solicitação'},
    };
    const queue=rows.filter(r=>BUCKETS[r.stage]);
    const nPronto=rows.filter(r=>r.stage==='pronto_para_comprar').length;
    const nAutPedido=rows.filter(r=>r.stage==='aguardando_autorizacao_pedido').length;
    const nEntrega=rows.filter(r=>r.stage==='aguardando_entrega').length;
    const nCriticos=queue.filter(r=>r.urgencyTier==='critico').length;
    const semForecastVencido=rows.filter(r=>r.stage==='aguardando_entrega'&&r.deliveryForecast&&daysAgo(r.deliveryForecast,asOf)>0).length;
    const kpiRow=document.createElement('div'); kpiRow.className='kpi-row'; panel.appendChild(kpiRow);
    statTile(kpiRow,{label:'Pronto para comprar',value:fmtInt(nPronto),sub:'itens autorizados, sem pedido'});
    statTile(kpiRow,{label:'Aguardando autorização do pedido',value:fmtInt(nAutPedido),sub:'pedidos emitidos, não aprovados'});
    statTile(kpiRow,{label:'Aguardando entrega',value:fmtInt(nEntrega),sub:semForecastVencido?`${fmtInt(semForecastVencido)} já além da previsão do fornecedor`:'dentro da previsão',subClass:semForecastVencido>0?'bad':''});
    statTile(kpiRow,{label:'Itens críticos (>30 dias)',value:fmtInt(nCriticos),sub:queue.length?`${fmtPct(pct(nCriticos,queue.length))} da fila ativa`:'—',subClass:nCriticos>0?'bad':''});
    panel.appendChild(sectionTitle('Fila priorizada de compras'));
    panel.appendChild(sectionIntro('Agrupada por ação necessária; dentro de cada grupo, os itens mais antigos (maior risco de SLA) aparecem primeiro. O campo "Comprador distribuído" do SIENGE está em branco neste processo — por isso os itens não têm responsável formal atribuído até a emissão do pedido (ver aba Qualidade de Dados).'));
    const search=document.createElement('input'); search.type='text'; search.className='search-input'; search.placeholder='Buscar por item, solicitante, nº da solicitação, pedido ou fornecedor…'; panel.appendChild(search);
    const tableHost=document.createElement('div'); panel.appendChild(tableHost);
    function buildRows(ft){ let data=queue.slice(); if(ft){ const query=ft.toLowerCase(); data=data.filter(r=>[r.itemDesc,r.requester,String(r.reqId),r.supplier,r.orderNum].filter(Boolean).join(' ').toLowerCase().includes(query)); }
      data.sort((a,b)=>(b.agingDays||0)-(a.agingDays||0)); data.forEach(r=>{ r._bucketOrder=BUCKETS[r.stage].order; r._bucketLabel=BUCKETS[r.stage].label; r._hint=BUCKETS[r.stage].hint(r); }); data.sort((a,b)=>a._bucketOrder-b._bucketOrder); return data; }
    function draw(){ tableHost.innerHTML=''; const data=buildRows(search.value.trim()); if(!data.length){ tableHost.appendChild(emptyStateCard('Nenhum item ativo encontrado para a busca/filtros atuais.')); return; }
      buildTable(tableHost,{columns:[{key:'urgencyTier',label:'Urgência',html:true,fmt:(v)=>badgeFor(v)},{key:'itemDesc',label:'Item',cellClass:'wrap-cell',title:(r)=>`Solicitação nº ${r.reqId} — ${r.itemDesc}`},{key:'projCode',label:'Obra'},{key:'qtyReq',label:'Qtd',align:'num',fmt:(v,r)=>v!=null?fmtNum(v,0)+' '+(r.unit||''):'—'},{key:'requester',label:'Solicitante',cellClass:'wrap-cell'},{key:'reqDate',label:'Solicitado em',fmt:fmtDate},{key:'agingDays',label:'Dias em aberto',align:'num',fmt:fmtInt},{key:'_hint',label:'Situação / ação sugerida',cellClass:'wrap-cell'}],rows:data,groupKey:'_bucketLabel',defaultSortKey:'_bucketOrder',defaultSortDir:1,groupLabelFn:(label,g)=>`${label}  ·  ${g.length} ${g.length===1?'item':'itens'}`}); }
    draw(); search.addEventListener('input',draw);
  }

  function renderSLA(rows){
    const panel=q('#pc-panel-sla'); panel.innerHTML='';
    if(!rows.length){ panel.appendChild(emptyStateCard('Nenhum item corresponde aos filtros selecionados.')); return; }
    const open=rows.filter(r=>r.isOpenBacklog); const delivered=rows.filter(r=>r.siteDeliveryDate); const withForecast=delivered.filter(r=>r.deliveryForecast);
    const onTime=withForecast.filter(r=>r.leadDeliveryVsForecast<=0).length;
    const medAuthOrder=median(rows.map(r=>r.leadAuthToOrder)); const medOrderDeliv=median(rows.map(r=>r.leadOrderToDelivery)); const medAging=median(open.map(r=>r.agingDays));
    const kpiRow=document.createElement('div'); kpiRow.className='kpi-row'; panel.appendChild(kpiRow);
    statTile(kpiRow,{label:'Autorização → Pedido (mediana)',value:medAuthOrder!=null?fmtDays(medAuthOrder):'—',sub:'maior gargalo interno do processo',subClass:(medAuthOrder||0)>5?'bad':''});
    statTile(kpiRow,{label:'Pedido → Entrega (mediana)',value:medOrderDeliv!=null?fmtDays(medOrderDeliv):'—',sub:`${fmtInt(delivered.length)} itens já entregues`});
    statTile(kpiRow,{label:'Aderência à previsão do fornecedor',value:withForecast.length?fmtPct(pct(onTime,withForecast.length),0):'—',sub:withForecast.length?`${fmtInt(withForecast.length-onTime)} entregues após a previsão`:'sem base suficiente',subClass:withForecast.length&&pct(onTime,withForecast.length)<50?'bad':''});
    statTile(kpiRow,{label:'Idade média do backlog aberto',value:medAging!=null?fmtDays(medAging):'—',sub:`${fmtInt(open.length)} itens em aberto`});
    panel.appendChild(sectionTitle('Onde o tempo é gasto — lead time mediano por etapa'));
    panel.appendChild(sectionIntro('Dias medianos entre marcos do processo, no filtro atual. O SLA é medido pelas transições reais do fluxo (a "Data para chegada à obra" coincide com a data da solicitação na maioria dos itens — ver aba Qualidade de Dados).'));
    const stageDefs=[
      {label:'Solicitação → Autorização do item',arr:rows.map(r=>r.leadReqToAuth)},
      {label:'Autorização → Emissão do pedido',arr:rows.map(r=>r.leadAuthToOrder)},
      {label:'Pedido → Autorização do pedido',arr:rows.map(r=>r.leadOrderToOrderAuth)},
      {label:'Pedido → Entrega na obra',arr:rows.map(r=>r.leadOrderToDelivery)},
    ].map(s=>({label:s.label,value:median(s.arr),n:s.arr.filter(v=>v!=null).length}));
    const maxLead=Math.max(1,...stageDefs.map(s=>s.value||0));
    const leadItems=stageDefs.map(s=>({label:s.label,value:s.value||0,display:s.value!=null?fmtDays(s.value):'sem dados',color:'var(--series-1)',sub:`baseado em ${fmtInt(s.n)} itens com as duas datas registradas`,noData:s.value==null,ttRows:[['Mediana',s.value!=null?fmtDays(s.value):'—'],['Itens com dado',fmtInt(s.n)]]}));
    const leadCol=document.createElement('div');
    chartCard(leadCol,{title:'Lead time mediano por transição',subtitle:'Dias corridos, mediana do filtro atual',buildSVG:(w)=>hBarList(w,leadItems,{maxValue:maxLead}),tableCols:['Transição','Mediana (dias)'],tableRows:leadItems.map(it=>[it.label,it.display])});
    panel.appendChild(leadCol);
    panel.appendChild(sectionTitle('Aderência à previsão de entrega do fornecedor'));
    const grid2=document.createElement('div'); grid2.className='grid-2'; panel.appendChild(grid2);
    const bucketDefs=[{label:'≤ -4 d',test:v=>v<=-4,color:'var(--div-pole-a)'},{label:'-3 a -1 d',test:v=>v>=-3&&v<=-1,color:'var(--div-pole-a)'},{label:'0 d',test:v=>v===0,color:'var(--div-mid)'},{label:'1 a 3 d',test:v=>v>=1&&v<=3,color:'var(--div-pole-b)'},{label:'4 a 7 d',test:v=>v>=4&&v<=7,color:'var(--div-pole-b)'},{label:'> 7 d',test:v=>v>7,color:'var(--div-pole-b)'}];
    const buckets=bucketDefs.map(b=>({label:b.label,color:b.color,value:withForecast.filter(r=>b.test(r.leadDeliveryVsForecast)).length}));
    const adhCol=document.createElement('div');
    chartCard(adhCol,{title:'Entrega real vs. previsão do fornecedor',subtitle:withForecast.length?`${fmtInt(withForecast.length)} pedidos entregues com previsão registrada`:'Nenhum pedido entregue com previsão no filtro atual',buildSVG:(w)=>withForecast.length?columnChart(w,buckets):emptyChartMsg(w,'Sem dados suficientes'),legend:()=>legendRow([{label:'Adiantado',color:'var(--div-pole-a)'},{label:'No prazo',color:'var(--div-mid)'},{label:'Atrasado',color:'var(--div-pole-b)'}]),tableCols:['Faixa (dias vs. previsão)','Pedidos'],tableRows:buckets.map(b=>[b.label,fmtInt(b.value)])});
    grid2.appendChild(adhCol);
    const byGroupAging={}; open.forEach(r=>{ (byGroupAging[r.group]=byGroupAging[r.group]||[]).push(r.agingDays); });
    const groupAgingArr=Object.entries(byGroupAging).map(([g,arr])=>({g,med:median(arr),n:arr.length})).sort((a,b)=>b.med-a.med).slice(0,8);
    const maxAging=Math.max(1,...groupAgingArr.map(x=>x.med||0));
    const groupAgingItems=groupAgingArr.map(x=>({label:x.g,value:x.med,display:fmtDays(x.med),color:'var(--series-1)',sub:`${fmtInt(x.n)} itens em aberto`,ttRows:[['Mediana de dias em aberto',fmtDays(x.med)],['Itens',fmtInt(x.n)]]}));
    const groupAgingCol=document.createElement('div');
    chartCard(groupAgingCol,{title:'Grupos com backlog mais antigo',subtitle:'Mediana de dias em aberto, por grupo de insumo (top 8)',buildSVG:(w)=>groupAgingArr.length?hBarList(w,groupAgingItems,{maxValue:maxAging}):emptyChartMsg(w,'Sem itens em aberto'),tableCols:['Grupo de insumo','Mediana de dias em aberto'],tableRows:groupAgingArr.map(x=>[x.g,fmtDays(x.med)])});
    grid2.appendChild(groupAgingCol);
    panel.appendChild(sectionTitle('Itens entregues fora da previsão do fornecedor'));
    const lateRows=withForecast.filter(r=>r.leadDeliveryVsForecast>0); const lateDiv=document.createElement('div');
    if(!lateRows.length){ lateDiv.appendChild(emptyStateCard('Nenhum item entregue após a previsão do fornecedor no filtro atual.')); }
    else buildTable(lateDiv,{columns:[{key:'itemDesc',label:'Item',cellClass:'wrap-cell'},{key:'supplier',label:'Fornecedor',cellClass:'wrap-cell'},{key:'orderNum',label:'Pedido'},{key:'deliveryForecast',label:'Previsão',fmt:fmtDate},{key:'siteDeliveryDate',label:'Entregue em',fmt:fmtDate},{key:'leadDeliveryVsForecast',label:'Atraso',align:'num',fmt:(v)=>fmtDays(v)}],rows:lateRows,defaultSortKey:'leadDeliveryVsForecast',defaultSortDir:-1});
    panel.appendChild(lateDiv);
  }

  function renderFornecedores(rows){
    const panel=q('#pc-panel-fornecedores'); panel.innerHTML='';
    const withSupplier=rows.filter(r=>r.supplier);
    if(!withSupplier.length){ panel.appendChild(emptyStateCard('Nenhum pedido com fornecedor no filtro atual.')); return; }
    const bySupplier={}, seenNF={};
    withSupplier.forEach(r=>{ const s=bySupplier[r.supplier]=bySupplier[r.supplier]||{supplier:r.supplier,n:0,delivered:0,onTime:0,withForecast:0,value:0,leadArr:[]}; s.n++;
      if(r.invoiceValue!=null&&r.invoiceNum!=null){ const set=seenNF[r.supplier]=seenNF[r.supplier]||new Set(); if(!set.has(r.invoiceNum)){ set.add(r.invoiceNum); s.value+=r.invoiceValue; } }
      if(r.siteDeliveryDate){ s.delivered++; if(r.leadOrderToDelivery!=null) s.leadArr.push(r.leadOrderToDelivery); if(r.deliveryForecast){ s.withForecast++; if(r.leadDeliveryVsForecast<=0) s.onTime++; } } });
    const supArr=Object.values(bySupplier).map(s=>({...s,pctDelivered:pct(s.delivered,s.n),pctOnTime:s.withForecast?pct(s.onTime,s.withForecast):null,leadMed:median(s.leadArr)}));
    const totalValue=sum(supArr.map(s=>s.value)); const best=supArr.slice().sort((a,b)=>b.value-a.value)[0];
    const worst=supArr.filter(s=>s.withForecast>=3).sort((a,b)=>(a.pctOnTime??100)-(b.pctOnTime??100))[0];
    const kpiRow=document.createElement('div'); kpiRow.className='kpi-row'; panel.appendChild(kpiRow);
    statTile(kpiRow,{label:'Fornecedores ativos',value:fmtInt(supArr.length),sub:`${fmtInt(withSupplier.length)} itens com pedido`});
    statTile(kpiRow,{label:'Maior fornecedor (valor)',value:best&&best.value>0?fmtBRLCompact(best.value):'—',sub:best?truncateLabel(best.supplier,36):'—'});
    statTile(kpiRow,{label:'Menor aderência à previsão',value:worst&&worst.pctOnTime!=null?fmtPct(worst.pctOnTime,0):'—',sub:worst?truncateLabel(worst.supplier,30)+' (mín. 3 entregas c/ previsão)':'amostra insuficiente',subClass:worst?'bad':''});
    statTile(kpiRow,{label:'Valor total faturado (base)',value:fmtBRLCompact(totalValue),sub:`${fmtInt(supArr.filter(s=>s.value>0).length)} fornecedores com NF`});
    panel.appendChild(sectionTitle('Top fornecedores por valor faturado'));
    const topSup=supArr.filter(s=>s.value>0).sort((a,b)=>b.value-a.value).slice(0,8);
    const supItems=topSup.map(s=>({label:truncateLabel(s.supplier,44),value:s.value,display:fmtBRLCompact(s.value),color:'var(--series-1)',ttRows:[['Valor faturado',fmtBRL(s.value)],['Itens/pedidos',fmtInt(s.n)]]}));
    const chartDiv=document.createElement('div');
    chartCard(chartDiv,{title:'Fornecedores por valor faturado',subtitle:topSup.length?`Top ${fmtInt(topSup.length)} de ${fmtInt(supArr.filter(s=>s.value>0).length)} com nota fiscal emitida`:'Sem faturamento no filtro atual',buildSVG:(w)=>topSup.length?hBarList(w,supItems):emptyChartMsg(w,'Sem dados'),tableCols:['Fornecedor','Valor faturado'],tableRows:topSup.map(s=>[truncateLabel(s.supplier,50),fmtBRL(s.value)])});
    panel.appendChild(chartDiv);
    panel.appendChild(sectionTitle('Ranking completo de fornecedores'));
    panel.appendChild(sectionIntro('"Aderência à previsão" só é calculada quando há data de entrega e de previsão registradas; fornecedores ainda sem entregas aparecem como "n/d", nunca como 0%.'));
    const tblDiv=document.createElement('div');
    buildTable(tblDiv,{columns:[{key:'supplier',label:'Fornecedor',cellClass:'wrap-cell'},{key:'n',label:'Itens/pedidos',align:'num',fmt:fmtInt},{key:'delivered',label:'Entregues',align:'num',fmt:fmtInt},{key:'pctDelivered',label:'% entregue',align:'num',fmt:(v)=>v==null?'—':fmtPct(v,0)},{key:'pctOnTime',label:'Aderência à previsão',align:'num',fmt:(v)=>v==null?'n/d':fmtPct(v,0)},{key:'leadMed',label:'Lead pedido→entrega',align:'num',fmt:(v)=>v==null?'—':fmtDays(v)},{key:'value',label:'Valor faturado',align:'num',fmt:(v)=>fmtBRL(v)}],rows:supArr,defaultSortKey:'value'});
    panel.appendChild(tblDiv);
  }

  function severityBadge(sev,countOrText){ const map={warning:['badge-atencao','●'],serious:['badge-prioritario','▲'],critical:['badge-critico','■']}; const [cls,icon]=map[sev]||['badge-neutro','—']; const txt=typeof countOrText==='number'?`${fmtInt(countOrText)} ${countOrText===1?'item':'itens'}`:countOrText; return `<span class="badge ${cls}">${icon} ${txt}</span>`; }
  function gapCard(cont,{sev,title,count,openDefault,body}){ const det=document.createElement('details'); det.className='gap-card card'; if(openDefault) det.open=true;
    const s=document.createElement('summary'); const chev=document.createElement('span'); chev.className='chev'; chev.textContent='▶'; const gt=document.createElement('span'); gt.className='gtitle'; gt.textContent=title; const bh=document.createElement('span'); bh.innerHTML=severityBadge(sev,count);
    s.appendChild(chev); s.appendChild(gt); s.appendChild(bh); det.appendChild(s); const gb=document.createElement('div'); gb.className='gbody'; gb.appendChild(body); det.appendChild(gb); cont.appendChild(det); }

  function renderGaps(rows){
    const panel=q('#pc-panel-gaps'); panel.innerHTML='';
    if(!rows.length){ panel.appendChild(emptyStateCard('Nenhum item corresponde aos filtros selecionados.')); return; }
    const flagged=rows.filter(r=>r.flags&&r.flags.length);
    panel.appendChild(sectionTitle('Qualidade de dados e lacunas do relatório'));
    panel.appendChild(sectionIntro(`${fmtInt(flagged.length)} de ${fmtInt(rows.length)} itens (${fmtPct(pct(flagged.length,rows.length),1)}) apresentam ao menos uma inconsistência linha-a-linha. Todos os números respeitam o filtro ativo no topo.`));
    const withDates=rows.filter(r=>r.neededDate&&r.reqDate); const sameDay=withDates.filter(r=>r.neededDate===r.reqDate);
    const noDistBuyer=rows.filter(r=>!r.distBuyer||r.distBuyer==='Nenhum'); const semPedido=rows.filter(r=>!r.orderNum).length;
    const noApprovalReq=rows.filter(r=>!r.reqApproval).length; const withOrderRows=rows.filter(r=>r.orderNum); const noApprovalOrder=withOrderRows.filter(r=>!r.orderApproval).length;
    const entregaAntes=rows.filter(r=>r.flags.includes('entrega_antes_pedido'));
    const atSemPedido=rows.filter(r=>r.flags.includes('atendida_sem_pedido')); const atSemEntrega=rows.filter(r=>r.flags.includes('atendida_sem_entrega'));
    const atSemLastro=rows.filter(r=>r.flags.includes('atendida_sem_pedido')||r.flags.includes('atendida_sem_entrega'));
    const reprovPend=rows.filter(r=>r.flags.includes('reprovado_mas_pendente')); const entregaMaior=rows.filter(r=>r.flags.includes('entrega_maior_que_solicitado'));
    const backlog60=rows.filter(r=>r.flags.includes('backlog_critico_60d')); const invoicedCount=rows.filter(r=>r.invoiceNum).length;
    const nfLines={}; rows.forEach(r=>{ if(r.invoiceNum!=null&&r.invoiceValue!=null){ const k=r.invoiceNum+'|'+(r.supplier||''); (nfLines[k]=nfLines[k]||[]).push(r); } });
    const nfMulti=Object.entries(nfLines).filter(([k,a])=>a.length>1); const nfMultiLines=sum(nfMulti.map(([k,a])=>a.length));
    const somaLinhas=sum(rows.filter(r=>r.invoiceValue!=null).map(r=>r.invoiceValue)); const somaDedup=sumInvoiceDedup(rows); const nNFdist=countDistinctInvoices(rows);
    const buyerCounts={}; withOrderRows.forEach(r=>{ if(r.buyer) buyerCounts[r.buyer]=(buyerCounts[r.buyer]||0)+1; });
    const buyerArr=Object.entries(buyerCounts).sort((a,b)=>b[1]-a[1]); const totalWithBuyer=sum(buyerArr.map(b=>b[1])); const topBuyerShare=buyerArr.length?pct(buyerArr[0][1],totalWithBuyer):null;
    const host=document.createElement('div'); panel.appendChild(host);

    gapCard(host,{sev:'critical',openDefault:true,title:'"Valor da nota" repetido em cada item — risco de dupla contagem',count:nfMultiLines,body:(()=>{const d=document.createElement('div');
      d.innerHTML=`<p>O SIENGE preenche "Valor da nota" com o <b>total do cabeçalho da NF repetido em cada item</b>. Somar linha a linha superestima: <b>${fmtBRL(somaLinhas)}</b> somando tudo, contra <b>${fmtBRL(somaDedup)}</b> reais contando cada uma das ${fmtInt(nNFdist)} notas uma vez. Há <b>${fmtInt(nfMultiLines)}</b> linhas em ${fmtInt(nfMulti.length)} notas com valor repetido.</p>
      <div class="glabel">Como este painel trata</div><p>Todos os valores monetários (KPI de faturado, ranking de fornecedores, comparativo por obra) já contam <b>cada NF uma vez</b>.</p>`; return d;})()});
    gapCard(host,{sev:'warning',title:'Colunas do relatório estruturalmente vazias',count:'5 colunas',body:(()=>{const d=document.createElement('div');
      d.innerHTML=`<p>Categoria, Cód. Categoria, Marca, Alçada (Solicitação) e Alçada (Pedido) vêm em branco em (quase) 100% das linhas; Detalhe quase sempre. A classificação real vem só no "Grupo de insumo".</p>
      <div class="glabel">Risco</div><p>Perde-se uma camada de classificação e a rastreabilidade da alçada de aprovação.</p>`; return d;})()});
    gapCard(host,{sev:'serious',openDefault:true,title:'"Data para chegada à obra" não funciona como prazo de SLA',count:sameDay.length,body:(()=>{const d=document.createElement('div');
      d.innerHTML=`<p><b>${fmtPct(pct(sameDay.length,withDates.length||1),1)}</b> dos itens têm a "Data para chegada à obra" <b>igual</b> à data da própria solicitação — inútil como prazo-alvo.</p>
      <div class="glabel">Recomendação</div><p>Priorizar por <b>dias desde a solicitação</b> (aging), como nas abas Gerencial e Mesa do Comprador.</p>`; return d;})()});
    gapCard(host,{sev:'serious',openDefault:true,title:'Campo "Comprador distribuído" nunca é utilizado',count:noDistBuyer.length,body:(()=>{const d=document.createElement('div');
      d.innerHTML=`<p><b>${fmtPct(pct(noDistBuyer.length,rows.length),1)}</b> dos itens têm "Comprador distribuído" vazio ("Nenhum"), inclusive os <b>${fmtInt(semPedido)}</b> itens ainda sem pedido — sem responsável formal enquanto aguardam compra.</p>
      <div class="glabel">Recomendação</div><p>Ativar a distribuição automática de comprador por grupo de insumo para reduzir a espera entre autorização e pedido.</p>`; return d;})()});
    gapCard(host,{sev:'warning',title:'Alçadas de aprovação sempre em branco',count:Math.max(noApprovalReq,noApprovalOrder),body:(()=>{const d=document.createElement('div');
      d.innerHTML=`<p>Alçada vazia em <b>${fmtInt(noApprovalReq)}</b> de ${fmtInt(rows.length)} solicitações e em <b>${fmtInt(noApprovalOrder)}</b> de ${fmtInt(withOrderRows.length)} pedidos.</p>
      <div class="glabel">Risco</div><p>Não dá para auditar em qual nível de aprovação os gargalos se concentram.</p>`; return d;})()});
    gapCard(host,{sev:'critical',title:'Entrega registrada antes da emissão do pedido',count:entregaAntes.length,body:(()=>{const deliveredTotal=rows.filter(r=>r.siteDeliveryDate).length; const d=document.createElement('div');
      d.innerHTML=`<p><b>${fmtInt(entregaAntes.length)}</b> de ${fmtInt(deliveredTotal)} itens entregues têm entrega <b>anterior</b> à data do pedido — sequência impossível no fluxo formal (indício de compra emergencial formalizada depois).</p><div class="glabel">Itens afetados</div>`;
      d.appendChild(simpleTable(entregaAntes,[{key:'itemDesc',label:'Item'},{key:'orderNum',label:'Pedido'},{key:'orderDate',label:'Data do pedido',fmt:fmtDate},{key:'siteDeliveryDate',label:'Entrega',fmt:fmtDate},{key:'leadOrderToDelivery',label:'Dif.',align:'num',fmt:(v)=>fmtDays(v)}])); return d;})()});
    gapCard(host,{sev:'serious',title:'"Totalmente atendida" sem lastro de pedido ou de entrega',count:atSemLastro.length,body:(()=>{const d=document.createElement('div');
      d.innerHTML=`<p><b>${fmtInt(atSemPedido.length)}</b> itens "Totalmente atendida" nunca tiveram pedido, e <b>${fmtInt(atSemEntrega.length)}</b> sem data de entrega (possível retirada de estoque).</p><div class="glabel">Itens afetados</div>`;
      d.appendChild(simpleTable(atSemLastro,[{key:'itemDesc',label:'Item'},{key:'reqId',label:'Solicitação'},{key:'orderNum',label:'Pedido',fmt:(v)=>v||'—'},{key:'siteDeliveryDate',label:'Entrega',fmt:(v)=>v?fmtDate(v):'—'}])); return d;})()});
    gapCard(host,{sev:'warning',title:'Item reprovado, mas solicitação continua "Pendente"',count:reprovPend.length,body:(()=>{const d=document.createElement('div');
      d.innerHTML=`<p><b>${fmtInt(reprovPend.length)}</b> itens tiveram a autorização reprovada, mas a situação continua "Pendente" — infla o backlog (as abas Gerencial/Comprador já excluem itens reprovados).</p><div class="glabel">Itens afetados</div>`;
      d.appendChild(simpleTable(reprovPend,[{key:'itemDesc',label:'Item'},{key:'reqId',label:'Solicitação'},{key:'requester',label:'Solicitante'},{key:'reqDate',label:'Data',fmt:fmtDate}])); return d;})()});
    gapCard(host,{sev:'warning',title:'Quantidade entregue maior que a solicitada',count:entregaMaior.length,body:(()=>{const d=document.createElement('div');
      d.innerHTML=`<p><b>${fmtInt(entregaMaior.length)}</b> itens com entrega acima da quantidade solicitada.</p><div class="glabel">Itens afetados</div>`;
      d.appendChild(simpleTable(entregaMaior,[{key:'itemDesc',label:'Item'},{key:'qtyReq',label:'Solicitado',align:'num',fmt:(v)=>fmtNum(v,0)},{key:'qtyDelivered',label:'Entregue',align:'num',fmt:(v)=>fmtNum(v,0)}])); return d;})()});
    gapCard(host,{sev:'critical',title:'Backlog crítico não resolvido há mais de 60 dias',count:backlog60.length,body:(()=>{const d=document.createElement('div');
      d.innerHTML=`<p><b>${fmtInt(backlog60.length)}</b> itens seguem em aberto há mais de 60 dias desde a solicitação original.</p><div class="glabel">Itens afetados (10 mais antigos)</div>`;
      d.appendChild(simpleTable(backlog60.slice().sort((a,b)=>b.agingDays-a.agingDays),[{key:'itemDesc',label:'Item'},{key:'requester',label:'Solicitante'},{key:'reqDate',label:'Solicitado em',fmt:fmtDate},{key:'agingDays',label:'Dias em aberto',align:'num',fmt:fmtInt}],10)); return d;})()});
    gapCard(host,{sev:'serious',title:'Falta "Valor do Pedido" — comprometido invisível',count:'lacuna estrutural',body:(()=>{const d=document.createElement('div');
      d.innerHTML=`<p>O valor só aparece após o faturamento (<b>${fmtInt(invoicedCount)}</b> de ${fmtInt(withOrderRows.length)} pedidos). O comprometido dos <b>${fmtInt(withOrderRows.length-invoicedCount)}</b> pedidos ainda não faturados fica invisível neste relatório.</p>
      <div class="glabel">Recomendação</div><p>Complementar com o relatório/API de <b>Purchase Orders</b> (valor do pedido) do SIENGE. O <b>Mapa de Cotações</b> entra na Fase 2 do painel.</p>`; return d;})()});
    gapCard(host,{sev:'warning',title:'Concentração de pedidos em um único comprador',count:buyerArr.length?buyerArr[0][1]:0,body:(()=>{const d=document.createElement('div');
      if(!buyerArr.length){ d.textContent='Sem pedidos com comprador definido no filtro atual.'; return d; }
      d.innerHTML=`<p><b>${truncateLabel(buyerArr[0][0],40)}</b> responde por <b>${fmtPct(topBuyerShare,0)}</b> dos pedidos emitidos no filtro (${fmtInt(buyerArr[0][1])} de ${fmtInt(totalWithBuyer)}).</p>
      <div class="glabel">Risco</div><p>Dependência de uma única pessoa ("bus factor").</p>`; return d;})()});
  }

  /* ---------- build + mount ---------- */
  function build(){
    if (!document.getElementById('pcdash-css')){ const st=document.createElement('style'); st.id='pcdash-css'; st.textContent=CSS; document.head.appendChild(st); }
    container.classList.add('pcdash'); container.innerHTML=MARKUP;
    tooltipEl=document.getElementById('pc-viz-tooltip');
    if (!tooltipEl){ tooltipEl=document.createElement('div'); tooltipEl.id='pc-viz-tooltip'; document.body.appendChild(tooltipEl); }
    document.addEventListener('mousemove',(e)=>{ if(tooltipEl.style.opacity==='1') moveTooltip(e); });
    wireFilters(); built=true;
  }
  function mount(el, data){
    container=el; DATA=data; deriveRows(DATA);
    if(!built) build();
    // reset para a aba Gerencial ao remontar
    qa('.tab-btn').forEach(b=>b.classList.toggle('active',b.dataset.tab==='gerencial'));
    qa('.tab-panel').forEach(p=>p.classList.toggle('active',p.id==='pc-panel-gerencial'));
    state.activeTab='gerencial';
    populateFilters(); renderAll();
  }
  window.PainelCompras = { mount };
})();
