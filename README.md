# Claude Notch

Notch animato per macOS che mostra quanto resta dei limiti di Claude: sessione 5h, settimana e token usati oggi.

- **Hover** sul notch → si espande (anelli animati, countdown al reset, grafico orario di oggi)
- **Clic destro** → Impostazioni, avvio al login, controlla aggiornamenti, esci
- **Monitor di sistema** (opzionale) → anelli CPU, RAM e spazio disco in tempo reale
- **Aggiornamenti automatici** da GitHub Releases ogni 30 minuti

Dati: endpoint usage di Anthropic (lo stesso di `/usage` in Claude Code) usando il login di Claude Code nel Portachiavi, più i transcript locali in `~/.claude/projects` per i token di oggi.

## Installazione (utenti)

1. Scarica `ClaudeNotch-x.y.dmg`, aprilo, trascina l'app in **Applications**.
2. Primo avvio: Impostazioni di Sistema → Privacy e sicurezza → **Apri comunque** (l'app non è notarizzata).
3. Serve Claude Code con login effettuato. macOS 14+.

## Build (sviluppatori)

```bash
./build.sh --run          # build universale + avvio
scripts/make-dmg.sh       # crea dist/ClaudeNotch-<versione>.dmg
```

Distribuzione senza avvisi Gatekeeper (serve Apple Developer ID):

```bash
SIGN_IDENTITY="Developer ID Application: Nome (TEAMID)" NOTARY_PROFILE=notary scripts/make-dmg.sh
```

`CLAUDE_NOTCH_PIN_OPEN=1` tiene il notch aperto (debug/screenshot).

## Pubblicare una nuova versione

1. Aumenta il numero in `VERSION` (es. `1.3`).
2. Push su `main`.

La GitHub Action `.github/workflows/release.yml` crea il DMG e la release `v1.3`.
Le app installate la trovano entro 30 minuti, la scaricano, sostituiscono se stesse e si riavviano.
Repo controllata dall'updater: `Updater.repo` in `Sources/ClaudeNotch/Updater.swift` (deve essere pubblica).
