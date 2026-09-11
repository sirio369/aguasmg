## Card "📐 Modelo (previsto)" na tela de pressão

Card novo logo **acima do grid Mínima/Média/Mediana/Máxima** — comparação rápida e fácil entre o valor de projeto/simulação e o que o logger de fato mediu.

- Usa `instalacao_logger_calibracao.pressao`, já exposto como `p.pressao_modelo` por `app_loggers_listar` — **sem RPC nem coluna nova**, é frontend puro.
- Borda tracejada (em vez da borda sólida dos cards de dado medido), pra deixar claro que é uma previsão, não uma leitura.
- Só aparece quando o ponto tem valor de modelo cadastrado **e** há amostra de pressão real para comparar.
- Aparece nos dois lugares onde a caixa de pressão já existe (`lgPressaoBox`/`lgCarregarPressao`, sem duplicar código): **logger concluído** e o **preview de finalização** — útil já na hora de decidir se conclui o ponto.

## Escopo
Só frontend (o dado já existia no objeto do ponto). `node --check` ok em `index.html` e `sw.js`. `sw`: v111 → v112.

## Doc
`docs/MODULOS.md` §2.2 + `CLAUDE.md` (Loggers).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
