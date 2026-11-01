# Guia d'estil i terminologia — traducció Hermex al català

Registre: **tuteig**, català estàndard general, natural i sense formalitat excessiva. Estil de les interfícies d'Apple en català.

## Regles bàsiques

1. **Tuteig**: sempre «tu» («la teva ubicació», «comprova que…», «has iniciat sessió»). Mai «vostè/vostra» (els glossaris de Softcatala sovint duen formes de «vós»: converteix-les a «tu»).
2. **Botons i accions**: imperatiu de 2a persona singular: «Afegeix», «Elimina», «Desa», «Cancel·la», «Reintenta», «Obre».
3. **Majúscules**: mai Title Case anglès; només la primera paraula i noms propis: «Back to Chat» → «Torna al xat», «Remove Server» → «Elimina el servidor».
4. **Estats en curs** amb el·lipsi: «S'està desant…», «S'està reconnectant…», «S'està resumint…».
5. **Puntuació**: mantén punts finals, «…», «·», comes i cometes tipogràfiques (« ” ’) tal com apareguin a la font. Català normal per a interrogatius i exclamatius.
6. **Res millorat**: mantén el mateix to i nivell de detall de la font; no afegeixis ni ometis informació.

## Placeholders (regles dures)

- Conserva **exactament** els tokens: `%@`, `%1$@`…`%11$@`, `%lld`, `%1$lld`…, `%%`, `%arg`, `${applicationName}`, `${profile}`. Mateixa multiplicitat i mateix token; la posició pot canviar per la gramàtica.
- No tradueixis mai el contingut que un placeholder substitueix (noms, fitxers, URLs, text del servidor).
- En plurals: `%arg` es manté tal qual dins de cada branca.

## Plurals

Per a entrades estructurades, la traducció és un diccionari amb **exactament** les mateixes cases que la font (normalment `one`/`other`): `one` = singular català (1), `other` = plural (0, 2, 3…). Cada branca és la frase completa amb `%arg` al lloc del nombre.

## Termes protegits (NO es tradueixen)

Hermex, Hermes, hermes-webui, hermex-push, Dispatcher, Siri, VoiceOver, Tailscale, NetBird, Cloudflare, tailnet, Kanban, MCP, ID, URL, API, HTTPS, HTTP, PDF, CLI, JSON, Git (com a producte), App Store, cron.

## Termes d'Apple (forma oficial catalana)

- Live Activity → **activitat en directe**
- Dynamic Island → **Illa dinàmica**
- app Shortcuts → **app Dreceres** («obre-ho a Dreceres»)
- Keychain → **Cadena de claus**
- Siri, VoiceOver, iPhone, App Store → sense canvis

## Terminologia fixa del producte

| Anglès | Català |
|---|---|
| chat | xat |
| new chat | xat nou |
| voice chat | xat de veu |
| session | sessió |
| turn | torn |
| server | servidor |
| host | amfitrió |
| bot | bot |
| profile | perfil |
| provider | proveïdor |
| model | model |
| task (tasca programada del cron) | tasca |
| background task | tasca en segon pla |
| card (Kanban) | targeta |
| board | tauler |
| attachment | adjunt |
| workspace | espai de treball |
| stream / streaming | transmissió / transmissió en directe |
| inbox | safata d'entrada |
| notification | notificació |
| sign in (v) | iniciar la sessió |
| sign out (v) | tancar la sessió |
| saved sign-in | sessió desada |
| draft | esborrany |
| pin / pinned / unpin | fixar / fixat / deixa de fixar |
| archive / unarchive | arxiva / desarxiva |
| folder | carpeta |
| cache | memòria cau |
| copy (v) / (n) | copia / còpia |
| move | mou |
| reconnect | reconnectar |
| sync | sincronitzar |
| relay (component) | relé |
| tunnel | túnel |
| tunnel address | adreça del túnel |
| self-hosted | autoallotjat |
| prompt (IA) | prompt (en text explicatiu es pot dir «instruccions») |
| clarification | aclariment |
| skill | habilitat |
| tool / tool call | eina / crida d'eina |
| thinking | raonament |
| approval | aprovació |
| context compaction | compactació del context |
| token (ús d'IA) | token(s) |
| access token (auth) | testimoni d'accés |
| queue (v/n) | posa a la cua / cua |
| regenerate | regenera |
| discard | descarta |
| retry | reintenta |
| allow / always allow / deny | permet / permet sempre / denega |
| approve / reject | aprova / rebutja |
| settings | configuració («Obre Configuració», com a app) |
| goal | objectiu |
| memory (funció) | memòria |
| search / filter / sort | cerca / filtre / ordena |
| just now / yesterday | ara mateix / ahir |
| needs you | et necessita |
| copy link | copia l'enllaç |
| pull request | pull request (sense traduir, minúscula al mig de frase) |
| Web UI | interfície web (l'identificador «hermes-webui» mai) |
| voice note | nota de veu |
| voice input | entrada de veu |
| share extension | extensió de compartició |
| push (notificacions) | push («notificacions push») |
| side question | pregunta paral·lela |

## Decisions de context

- «Chat» com a funcionalitat/tab: «Xat». Com a conversa concreta: «xat».
- «Open» com a estat d'una pull request: «Obert»; «Merged» → «Fusionat»; «Closed» → «Tancat».
- «-» (empty state) → «—» o frase natural segons context; mai deixis buit.
- Frases d'error llargues: mantén el matís condicional («pot ser que», «no ha respost») amb tuteig.
- Si un terme no és aquí ni als glossaris: tria el terme estàndard del Recull de Softcatala i anota-ho a l'informe.

## Consulta de glossaris

- `/Users/vernau/Downloads/Hermex/catalan-discovery/tots-glossary.txt` (UI general) i `sc-glossary.txt` (Softcatala), format `origen,traducció` per línia. Per dubtes: `grep -i '^terme,' tots-glossary.txt`. Són referència: adapta-ho al tuteig i al context.

## Decisions de la revisió (31/10)

- move (nom) → **trasllat** (mai «moviment»); path → **ruta**; media → **contingut multimèdia**; claim (Kanban) → **reserva**.
- bloquejat/bloqueja (mai «blocat»); commit (verb): **comet**, participi **comès**; «darrer/darrera» (no «últim»).
- Botons dins de frases: entre «cometes baixes» («Permet durant la sessió», «Reprèn»).
- Reasoning: Mínim / Baix / Mitjà / Alt / Molt alt / Màx.
