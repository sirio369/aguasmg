# Coleta Águas MG — PWA de campo

Aplicativo web progressivo (PWA) de coleta de campo para o programa de redução de perdas
(Consórcios Águas Integradas e Eficiência Hídrica — COPASA / RMBH).

## Módulos
- **Mapeamento de pressão** — leitura de manômetro + foto + GPS.
- **Loggers temporários** — instalação/remoção/finalização com ciclo de vida.
- **Pesquisa** — registro de trechos retos + ocorrências + tela de produtividade (km, velocidade, vaz./km).
- **Cadastro técnico** — visualização das camadas do PostGIS (rede, ligações, unidades, VRPs) com busca.
- **Captação de clientes** — cadastro de novo cliente durante o recadastramento (mockup).

## Stack
- HTML/CSS/JS puro (sem build), Leaflet (mapa), supabase-js (via esm.sh).
- Backend: Supabase (PostGIS + Auth + Storage + RPCs). Offline-first via Service Worker + IndexedDB.

## Publicação
Site estático — servir a raiz desta pasta. Sem etapa de build.
Requer HTTPS (Service Worker + geolocalização).
