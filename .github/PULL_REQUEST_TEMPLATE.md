<!-- Leia CONTRIBUTING.md antes de abrir o PR. Lembre: merge no main = produção. -->

## O que muda
<!-- Descreva o quê e por quê, em 1–3 linhas. -->

## Como testei
<!-- App real (celular/desktop), telas afetadas, console limpo, etc. -->

## Checklist
- [ ] `coleta-vN` incrementado em `public/sw.js` (e `CAD_VER` no `index.html` se mexeu no Cadastro técnico)
- [ ] `node --check` passou em `index.html` e `sw.js`
- [ ] Sem segredos no frontend; RLS/grants corretos em RPCs novas
- [ ] PR pequeno e focado (evita conflito no `index.html`)
- [ ] **Documentação atualizada neste PR** (`docs/MODULOS.md` — seção do módulo/"cuidados" — e `CLAUDE.md` se o panorama mudou)
