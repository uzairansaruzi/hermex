# 0025. Composer sends and attachments

Area: chat-composer

## Refuse sends while /clear is in flight

`ChatViewModel.isClearingConversation` is set while webui `POST /api/session/clear` is in flight, and a send or a second `/clear` refuses while it is set. Otherwise the clear response could wipe a message the user started inside that window (#389).

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Mark Hermes submissions unresolved until the host answers

In `ChatViewModel.submitHermesPrompt` (#508), from just before a prompt goes out until the host answers, the draft and its files stay on disk with the submission marked unresolved through `ChatDraftStore.setBotSubmissionUncertain`. A lost answer keeps all three and holds Send while the chat reattaches; that attach clears only the mark, and nothing is sent again, so a prompt is never sent twice.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Load the draft before setting its submission mark

Before `drafts.setBotSubmissionUncertain(true, for:)`, `ChatViewModel.submitHermesPrompt` awaits `drafts.draft(for: key)` and discards the result. Loading first means the unresolved mark never stands in for the saved draft, so the seemingly unused load must stay.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Chain-drain the queue only after a successful send

`ChatViewModel` calls `drainQueuedSlashMessageIfIdle` after a queued send only when that send succeeded. A failed send requeues the message and waits for the next natural trigger: a queue append, stream completion, or an explicit user send. Re-draining immediately turned a persistently failing send into a tight retry loop hammering the network and CPU (#202).

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Resolve rollback checkpoints from the list before diffing

A Hermes host answers a checkpoint hash it does not hold with an empty diff rather than an error. For `/rollback` diff, `ChatViewModel.rollbackFromSlashCommand` reads the host's checkpoint list and resolves the reference with `HermesCheckpoint.named` before calling `checkpointDiff(hash)`.

Lives in: `HermesMobile/Features/Chat/ChatViewModel.swift`

## Hold the old paste copy until the edit's save lands

`ChatAttachmentCoordinator.replaceStagedPaste` puts the old draft file back into `attachmentLease.files` before flushing the draft. Once the record points at the new copy nothing else references the old one, and an import freeing space could delete it before the save decides whether the edit stands; the failure path restores the original.

Lives in: `HermesMobile/Features/Chat/ChatAttachmentCoordinator.swift`

## Detach the camera preview layer on the session queue

Detaching a preview layer makes `AVCaptureSession` rebuild its graph and wait for it to finish, which takes seconds on device. `CameraPickerView`'s `detachPreviewLayer` sets `layer.session = nil` on `sessionQueue`, so the main thread never blocks on it.

Lives in: `HermesMobile/Features/Chat/CameraPickerView.swift`
