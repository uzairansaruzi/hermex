# 0019. Composer attachments

Area: chat-composer

## Forward scene environment into the attachment picker overlay host

The attachment picker's overlay is a sibling `UIHostingController` that does not inherit SwiftUI's scene environment. `CustomAttachmentPicker` forwards it so camera and media work starts and stops with its owner, and sets the root font the host would otherwise miss.

Lives in: `HermesMobile/Features/Chat/CustomAttachmentPicker.swift`

## Install the attachment picker overlay beside the hosting root view

A `UIHostingController`'s root view does not support UIKit subviews. `CustomAttachmentPicker` installs its overlay beside the root view in their common container instead.

Lives in: `HermesMobile/Features/Chat/CustomAttachmentPicker.swift`

## Detach the camera preview off the main thread

Detaching the preview layer makes `AVCaptureSession` rebuild its graph and wait for it; on device that held the main thread for about 9 s after leaving the camera (#809). `HermexAttachmentCameraController.detachPreviewLayer` sets the layer's `session` to nil on its session queue, off the main thread.

Lives in: `HermesMobile/Features/Chat/CameraPickerView.swift`, `HermesMobileTests/ChatComposerSendGateTests.swift`

## Synthesize text for attachment-only sends

The server requires non-empty message text. An attachment-only send synthesizes the message the web UI sends (`static/messages.js`).

Lives in: `HermesMobile/Models/UploadResponse.swift`

## Keep queued canonical sends' photo chips client-side

A canonical send carries its photos as `attachments` (#1644), but the host's `pending` lists text only; a dashboard prompt names its photos in `text` instead. `HermesChatTurnCoordinator` keeps the chips of each queued canonical send's photos, by admission, in memory only, until its turn starts or a Stop withdraws it. The queued bubble and the row its turn opens with take their chips from there.

Lives in: `HermesMobile/Features/Chat/HermesChatTurnCoordinator.swift`
