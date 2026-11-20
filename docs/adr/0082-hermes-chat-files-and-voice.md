# 0082. Hermes chat files and voice

Area: networking-hermes

## Fetch remote MEDIA documents without server credentials

`ChatView.hermesFilePreviewData` is the capped preview download behind `hermesFilePreviewItem`. A sent chip and a MEDIA document's host path download from this chat's attach, as the card's export does, so a result that lands after a reattach is dropped (#1030). A remote MEDIA document is a public, cookie-less fetch with neither server's credentials. The whole file, past the cap included, exports from the card's own download button.

Lives in: `HermesMobile/Features/Chat/ChatView.swift`

## Confirm Hermes file chips with `complete.path` per candidate

`ChatViewModel.listedFileReferences` reports which wanted files the source lists in a directory and which it answered for at all. A webui folder is listed once, through the cache the `@` panel fills, so it answers all of them or throws. A Hermes chat asks `complete.path` for each candidate's own path: the host lists the folder's entries that start with the name, so a folder past its 30-row cap still confirms one. One candidate's failed lookup leaves only that candidate unanswered; its siblings keep their answers.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Speak Listen text past one host chunk on device

`ServerTTSPolicy.maximumHermesTextLength` is a Hermes host's ceiling (#1072). The host splits longer text into its provider's chunks (Edge 5000, OpenAI 4096, others 4000) and plays only the first without ffmpeg to join them, so Hermex sends one chunk's worth and speaks longer replies on device. The length is counted in Unicode scalars, as the host's Python `len` counts them.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`
