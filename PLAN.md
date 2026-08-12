# PLAN - Entorno de Trading Automatizado Inteligente (100% gratis)

## PROPÓSITO
Entorno de trading automatizado completo e inteligente en la nube, 100% gratis y para
siempre, que ejecute los EAs ganadores validados (XAU + BTC multihorario) 24/7,
independiente del broker, monitoreado+orquestado por n8n, con IA que vigila, resume y
re-valida. Primero demo, luego real cent (Exness).

## ARQUITECTURA (2 capas, Oracle Cloud Free Tier)

- CAPA A - EJECUTOR (instancia AMD x86_64, 1GB):
  MetaTrader 5 nativo Linux (headless/xvfb) + EAs MQL5 multihorario compilados +
  telemetria HTTP (trades, equity, heartbeat).

- CAPA B - CEREBRO (instancia ARM Ampere, 4GB):
  n8n Community self-hosted (GRATIS) + PostgreSQL + Telegram bot + IA Groq (gratis)
  + scheduler de revalidacion walk-forward.

## EAs OPERABLES (unicos validados, PF>1.15 en 3 periodos 2 anos - grid2_final.csv)
- XAU 04-06h: BREAK24 (1.17/1.28/1.19), BREAK48 (1.23/1.34/1.45), MOMEMA (1.18/1.19/1.31)
- XAU 16-18h: EMACROSS (1.26/1.18/1.26)
- XAU 22-24h: BREAK48 (1.17/1.25/1.20)
- BTC 16-18h: RETEST48 (1.22/1.35/1.28)
- BTC 18-20h: VWAP (1.26/1.62/1.35)
- Los EAs FVG/NeurAlgo en config_backup = solo biblioteca, NO se operan.

## REGLAS INVIOLABLES
1. $0 SIEMPRE. n8n = Community self-hosted (nunca n8n Cloud). Servidor = Oracle Free Tier.
2. Alerta de presupuesto/costo Oracle activa ($0) para no recibir cargos.
3. Primero DEMO en la nube; real CENT solo tras validacion (~2-4 semanas ok).
4. Ejecucion = determinista (EA MQL5). La IA NO abre operaciones.
5. Todo en espanol.
6. Cada fase se AUDITA antes de avanzar.
7. La laptop solo desarrolla/compila; la nube opera 24/7.
8. Kill-switch humano via Telegram (pausar/reanudar EA) + limite diario de perdida ON en el EA.

## FASES
- F0: Git + respaldo + revalidar EA en Strategy Tester local (fidelidad vs Python).
- F1: Oracle Free Tier: cuenta, 2 instancias, hardening SSH, firewall, presupuesto $0.
- F2: Cerebro: Docker + n8n Community + PostgreSQL + Telegram + workflows (ingesta,
      alertas, reporte diario IA, cron revalidacion) + dashboard.
- F3: Ejecutor: MT5 Linux headless + EAs + telemetria + watchdog systemd.
- F4: Integracion ejecutor<->cerebro (VCN privada) + validacion DEMO 2-4 semanas.
- F5: Migracion a real CENT.

## ESTADO
- [x] Plan definido y anclado
- [ ] F0 Git/respaldo/fidelidad
- [ ] F1 Oracle
- [ ] F2 Cerebro (n8n+DB+Telegram+IA)
- [ ] F3 Ejecutor (MT5 headless)
- [ ] F4 Integracion + demo
- [ ] F5 Real cent