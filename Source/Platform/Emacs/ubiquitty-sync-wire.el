;;; ubiquitty-sync-wire.el --- Wire numbers for ubiquitty-sync  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Stanislav Yaglo
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; The numbers `ubiquitty-sync' shares with the host, as the host's headers
;; declare them.  Written by Scripts/gen-wire-tables.py from:
;;
;;   Source/Core/Protocol/Sync/Admission.h
;;   Source/Core/Protocol/Sync/Envelope.h
;;   Source/Core/Protocol/Sync/Envelope.cpp
;;   Source/Core/Protocol/Sync/Messages.h
;;   Source/Core/Protocol/Sync/ScreenPlane.h
;;   Source/Core/Protocol/Sync/RowForm.h
;;   Source/Core/Protocol/Sync/Connection.h
;;   Source/Core/Keys/KeyTranslation.h
;;   Source/Core/Keys/Keymap.h
;;   Source/Core/VT/Constants.h
;;   Source/Core/Color.h
;;   Source/Core/RowMeta.h
;;   Source/Core/TextSizeTable.h
;;   Source/Core/TermPalette.h
;;   Source/Core/Protocol/Sync/Records.h
;;   Source/Core/Terminal.h
;;   Source/Core/OSC/TabStatus.h
;;   Source/Core/OSC/ProgressIndicator.h
;;   Source/Core/Image/TerminalImage.h
;;   Source/Core/Protocol/Sync/Images.h
;;   Source/Core/Protocol/Sync/Effects.h
;;   Source/Core/Protocol/Sync/Roles.h
;;   Source/Core/Protocol/Sync/EffectCodec.h
;;   Source/Core/OSC/KittyNotification.h
;;   Source/Core/VT/DECPSSynth.h
;;   Source/Core/VT/Sound.h
;;   Source/Core/Protocol/Sync/Samples.h
;;   Source/PAL/PAL.h
;;   Source/PAL/TerminalClients.h
;;   Source/Core/Protocol/Sync/ConsentStatus.h
;;   Source/Core/Session/NameLimits.h
;;
;; Do not edit: change the header and run the script.
;; Scripts/check-wire-tables.py fails when this file is not what the headers
;; produce.

;;; Code:

(defconst ubiquitty-sync--max-consent-status-bytes 10
  "Own-consent status Notify body bytes")
(defconst ubiquitty-sync--max-panes-per-connection 256
  "Maximum bound pane handles on one connection.")
(defconst ubiquitty-sync--first-listed-handle 1073741824
  "First host-listing handle; bound panes use lower nonzero handles.")
(defconst ubiquitty-sync--max-effect-records 256
  "Maximum effects in one delivery batch.")
(defconst ubiquitty-sync--max-effect-clipboard-items 32
  "Maximum MIME items in one clipboard operation.")
(defconst ubiquitty-sync--max-effect-clipboard-mime-bytes 65535
  "Maximum bytes in one clipboard MIME name.")
(defconst ubiquitty-sync--max-effect-clipboard-write-bytes 1048576
  "Maximum clipboard-write data bytes.")
(defconst ubiquitty-sync--max-effect-clipboard-read-bytes 4194304
  "Maximum clipboard-read data bytes.")
(defconst ubiquitty-sync--max-notification-identifier-bytes 32
  "Maximum notification replacement identifier bytes.")
(defconst ubiquitty-sync--max-command-line-bytes 8192
  "Maximum command-finished command line bytes.")
(defconst ubiquitty-sync--max-tone-notes 16
  "Maximum notes in one sound effect.")
(defconst ubiquitty-sync--tone-default-envelope 65535
  "Sound envelope sentinel for the selected voice.")
(defconst ubiquitty-sync--tone-channel-count 9
  "Number of sound channels, including the terminal speaker.")
(defconst ubiquitty-sync--max-tone-wave 6
  "Highest admitted sound wave.")
(defconst ubiquitty-sync--max-tone-volume 7
  "Maximum volume and sustain level.")
(defconst ubiquitty-sync--max-tone-envelope-milliseconds 5000
  "Maximum sound envelope duration.")
(defconst ubiquitty-sync--max-tone-semitones-down 48
  "Maximum sound pitch offset.")
(defconst ubiquitty-sync--max-tone-duration-units 255
  "Maximum sound duration in thirty-seconds of a second.")
(defconst ubiquitty-sync--max-tone-effect 15
  "Maximum sound note effect number.")
(defconst ubiquitty-sync--max-tone-cutoff-hertz 20000
  "Maximum sound filter cutoff.")
(defconst ubiquitty-sync--max-tone-pan 64
  "Maximum sound stereo position.")
(defconst ubiquitty-sync--sample-slot-count 25
  "Number of downloadable sound sample slots.")
(defconst ubiquitty-sync--sample-max-frames 441000
  "Maximum frames in one sound sample.")
(defconst ubiquitty-sync--sample-rate-hertz 44100
  "Sound sample frames per second.")
(defconst ubiquitty-sync--sample-identity-bytes 40
  "Exact encoded sound sample identity size.")
(defconst ubiquitty-sync--sample-head-bytes 45
  "Exact encoded sample announcement size.")
(defconst ubiquitty-sync--max-progress-state 4
  "Highest pane progress state.")
(defconst ubiquitty-sync--max-title-bytes 4096
  "Maximum pane title bytes.")
(defconst ubiquitty-sync--max-directory-bytes 4096
  "Maximum pane directory bytes.")
(defconst ubiquitty-sync--max-file-url-bytes 4096
  "Maximum pane file URL bytes.")
(defconst ubiquitty-sync--max-home-bytes 1024
  "Maximum host home directory bytes.")
(defconst ubiquitty-sync--max-process-chain-bytes 1024
  "Maximum process chain bytes.")
(defconst ubiquitty-sync--max-process-arguments-bytes 2048
  "Maximum process chain with arguments bytes.")
(defconst ubiquitty-sync--max-process-name-bytes 255
  "Maximum process or host name bytes.")
(defconst ubiquitty-sync--max-indicator-bytes 48
  "Maximum indicator label bytes.")
(defconst ubiquitty-sync--max-badge-bytes 256
  "Maximum badge bytes.")
(defconst ubiquitty-sync--max-attention-bytes 255
  "Maximum notification field bytes.")
(defconst ubiquitty-sync--max-user-variables 32
  "Maximum pane user variables.")
(defconst ubiquitty-sync--max-user-name-bytes 128
  "Maximum user variable name bytes.")
(defconst ubiquitty-sync--max-user-value-bytes 1024
  "Maximum user variable value bytes.")
(defconst ubiquitty-sync--wire-version 2
  "The Sync wire version these tables were written at.")
(defconst ubiquitty-sync--max-envelope-header 9
  "Maximum canonical envelope header bytes.")
(defconst ubiquitty-sync--max-channel 4294967295
  "Maximum canonical pane handle.")
(defconst ubiquitty-sync--max-app-version-bytes 32
  "Maximum app version bytes.")
(defconst ubiquitty-sync--max-credential-bytes 256
  "Maximum credential bytes.")
(defconst ubiquitty-sync--max-agent-label-bytes 256
  "Maximum presented claimed label bytes.")
(defconst ubiquitty-sync--max-workspace-name-bytes 4096
  "Maximum workspace name bytes.")
(defconst ubiquitty-sync--max-host-platform-bytes 64
  "Maximum host platform bytes.")
(defconst ubiquitty-sync--max-daemon-socket-name-bytes 65535
  "Maximum daemon socket basename bytes.")
(defconst ubiquitty-sync--known-serving-build-flags 3
  "Known serving-build flag bits.")
(defconst ubiquitty-sync--max-frame-body 65535
  "The longest body one Sync frame carries.")
(defconst ubiquitty-sync--max-image-count 32
  "Maximum image bindings in one pane.")
(defconst ubiquitty-sync--max-image-placements 128
  "Maximum image placements in one pane.")
(defconst ubiquitty-sync--image-binding-record-bytes 42
  "Bytes of one ImageBinding in an ImagePlacements body.")
(defconst ubiquitty-sync--image-placement-record-bytes 55
  "Bytes of one ImagePlacement in an ImagePlacements body.")
(defconst ubiquitty-sync--max-image-bytes 67108864
  "Maximum decoded pixel bytes in one image.")
(defconst ubiquitty-sync--max-image-dimension 16384
  "Maximum width or height of a decoded image.")
(defconst ubiquitty-sync--image-pixel-budget 268435456
  "Default retained image-pixel budget of one terminal.")
(defconst ubiquitty-sync--paste-piece-bytes 8192
  "The most of a paste a client hands its transport at once.")
(defconst ubiquitty-sync--max-probe-steps 8
  "The most steps a Welcome's probe schedule names.")
(defconst ubiquitty-sync--pen-wire 20
  "Bytes a Sync pen occupies.")
(defconst ubiquitty-sync--state-block-count 7
  "The state blocks a checkpoint carries.")
(defconst ubiquitty-sync--text-size-table-capacity 15
  "Slots a text-size table always carries.")
(defconst ubiquitty-sync--text-size-spec-wire-bytes 12
  "Bytes one text-size slot occupies in the text-state block.")
(defconst ubiquitty-sync--text-size-spec-proportional-offset 6
  "Where a text-size slot's proportional flag sits within it.")
(defconst ubiquitty-sync--palette-special 5
  "Special palette colours per table.")
(defconst ubiquitty-sync--color-default #x100
  "Pen colour index meaning the terminal default.")
(defconst ubiquitty-sync--color-rgb #x101
  "Pen colour index meaning the direct RGB bytes.")
(defconst ubiquitty-sync--line-double-width 1
  "Row attribute: DECDWL double width.")
(defconst ubiquitty-sync--line-double-height-top 2
  "Row attribute: DECDHL top half.")
(defconst ubiquitty-sync--line-double-height-bottom 3
  "Row attribute: DECDHL bottom half.")
(defconst ubiquitty-sync--wire-fingerprint
  (unibyte-string 106 61 215 22 99 58 244 199 0 46 119 191 57 10 224 217 197 232 233 141 112 54 86 169 203 23
   133 106 218 37 128 17)
  "The Sync wire fingerprint these tables were written at, sent in every Greet.")

;; Role.
(defconst ubiquitty-sync--role-owner 0 "Granted connection role: Owner.")
(defconst ubiquitty-sync--role-driver 1 "Granted connection role: Driver.")
(defconst ubiquitty-sync--role-viewer 2 "Granted connection role: Viewer.")
(defconst ubiquitty-sync--role-agent 3 "Granted connection role: Agent.")

;; ClientKind.
(defconst ubiquitty-sync--client-kind-human 0 "Verified client kind: Human.")
(defconst ubiquitty-sync--client-kind-agent 1 "Verified client kind: Agent.")
(defconst ubiquitty-sync--client-kind-viewer 2 "Verified client kind: Viewer.")

;; AttachmentAdmission.
(defconst ubiquitty-sync--attachment-admission-awaiting-consent 0 "Welcome consent admission: AwaitingConsent.")
(defconst ubiquitty-sync--attachment-admission-granted 1 "Welcome consent admission: Granted.")

;; ResumeOutcome.
(defconst ubiquitty-sync--resume-outcome-diffed 0 "A resumed pane's outcome: Diffed.")
(defconst ubiquitty-sync--resume-outcome-checkpointed 1 "A resumed pane's outcome: Checkpointed.")
(defconst ubiquitty-sync--resume-outcome-gone 2 "A resumed pane's outcome: Gone.")

;; ByeReason.
(defconst ubiquitty-sync--bye-reason-normal 0 "Canonical connection close reason: Normal.")
(defconst ubiquitty-sync--bye-reason-version-mismatch 1 "Canonical connection close reason: VersionMismatch.")
(defconst ubiquitty-sync--bye-reason-malformed 2 "Canonical connection close reason: Malformed.")
(defconst ubiquitty-sync--bye-reason-oversize 3 "Canonical connection close reason: Oversize.")
(defconst ubiquitty-sync--bye-reason-unknown-kind 4 "Canonical connection close reason: UnknownKind.")
(defconst ubiquitty-sync--bye-reason-unbound-handle 5 "Canonical connection close reason: UnboundHandle.")
(defconst ubiquitty-sync--bye-reason-transfer-refused 6 "Canonical connection close reason: TransferRefused.")
(defconst ubiquitty-sync--bye-reason-superseded 7 "Canonical connection close reason: Superseded.")
(defconst ubiquitty-sync--bye-reason-resume-in-progress 8 "Canonical connection close reason: ResumeInProgress.")
(defconst ubiquitty-sync--bye-reason-suspending 9 "Canonical connection close reason: Suspending.")
(defconst ubiquitty-sync--bye-reason-handing-over 10 "Canonical connection close reason: HandingOver.")
(defconst ubiquitty-sync--bye-reason-token-missing 11 "Canonical connection close reason: TokenMissing.")
(defconst ubiquitty-sync--bye-reason-token-invalid 12 "Canonical connection close reason: TokenInvalid.")
(defconst ubiquitty-sync--bye-reason-token-expired 13 "Canonical connection close reason: TokenExpired.")
(defconst ubiquitty-sync--bye-reason-token-revoked 14 "Canonical connection close reason: TokenRevoked.")
(defconst ubiquitty-sync--bye-reason-outside-scope 15 "Canonical connection close reason: OutsideScope.")
(defconst ubiquitty-sync--bye-reason-duplicate-handshake 16 "Canonical connection close reason: DuplicateHandshake.")
(defconst ubiquitty-sync--bye-reason-no-consent 17 "Canonical connection close reason: NoConsent.")
(defconst ubiquitty-sync--bye-reason-remote-host-refused 18 "Canonical connection close reason: RemoteHostRefused.")
(defconst ubiquitty-sync--bye-reason-session-gone 19 "Canonical connection close reason: SessionGone.")
(defconst ubiquitty-sync--bye-reason-host-full 20 "Canonical connection close reason: HostFull.")
(defconst ubiquitty-sync--bye-reason-output-backlog 21 "Canonical connection close reason: OutputBacklog.")
(defconst ubiquitty-sync--bye-reason-silent 22 "Canonical connection close reason: Silent.")

;; EffectKind.
(defconst ubiquitty-sync--effect-kind-bell 0 "Effect kind: Bell.")
(defconst ubiquitty-sync--effect-kind-notification 1 "Effect kind: Notification.")
(defconst ubiquitty-sync--effect-kind-command-finished 2 "Effect kind: CommandFinished.")
(defconst ubiquitty-sync--effect-kind-sound 3 "Effect kind: Sound.")
(defconst ubiquitty-sync--effect-kind-attention 4 "Effect kind: Attention.")
(defconst ubiquitty-sync--effect-kind-clipboard-write 5 "Effect kind: ClipboardWrite.")

;; NotificationOccasion.
(defconst ubiquitty-sync--notification-occasion-always 0 "Notification presentation condition: Always.")
(defconst ubiquitty-sync--notification-occasion-unfocused 1 "Notification presentation condition: Unfocused.")
(defconst ubiquitty-sync--notification-occasion-invisible 2 "Notification presentation condition: Invisible.")

;; ClipboardBuffer.
(defconst ubiquitty-sync--clipboard-buffer-clipboard 0 "Clipboard selector: Clipboard.")
(defconst ubiquitty-sync--clipboard-buffer-primary 1 "Clipboard selector: Primary.")
(defconst ubiquitty-sync--clipboard-buffer-secondary 2 "Clipboard selector: Secondary.")
(defconst ubiquitty-sync--clipboard-buffer-select 3 "Clipboard selector: Select.")
(defconst ubiquitty-sync--clipboard-buffer-cut0 4 "Clipboard selector: Cut0.")
(defconst ubiquitty-sync--clipboard-buffer-cut1 5 "Clipboard selector: Cut1.")
(defconst ubiquitty-sync--clipboard-buffer-cut2 6 "Clipboard selector: Cut2.")
(defconst ubiquitty-sync--clipboard-buffer-cut3 7 "Clipboard selector: Cut3.")
(defconst ubiquitty-sync--clipboard-buffer-cut4 8 "Clipboard selector: Cut4.")
(defconst ubiquitty-sync--clipboard-buffer-cut5 9 "Clipboard selector: Cut5.")
(defconst ubiquitty-sync--clipboard-buffer-cut6 10 "Clipboard selector: Cut6.")
(defconst ubiquitty-sync--clipboard-buffer-cut7 11 "Clipboard selector: Cut7.")
(defconst ubiquitty-sync--clipboard-buffer-count 12 "Clipboard selector: Count.")

;; EffectClipboardRequestKind.
(defconst ubiquitty-sync--effect-clipboard-request-types 0 "Clipboard request kind: Types.")
(defconst ubiquitty-sync--effect-clipboard-request-item 1 "Clipboard request kind: Item.")

;; EffectClipboardStatus.
(defconst ubiquitty-sync--effect-clipboard-status-ok 0 "Clipboard response status: OK.")
(defconst ubiquitty-sync--effect-clipboard-status-empty 1 "Clipboard response status: Empty.")
(defconst ubiquitty-sync--effect-clipboard-status-refused 2 "Clipboard response status: Refused.")
(defconst ubiquitty-sync--effect-clipboard-status-too-large 3 "Clipboard response status: TooLarge.")

;; AdmissionTarget.
(defconst ubiquitty-sync--admission-target-session 0 "Canonical admission target: Session.")
(defconst ubiquitty-sync--admission-target-workspace 1 "Canonical admission target: Workspace.")
(defconst ubiquitty-sync--admission-target-control 2 "Canonical admission target: Control.")
(defconst ubiquitty-sync--admission-target-management 3 "Canonical admission target: Management.")

;; FrameKind.
(defconst ubiquitty-sync--kind-greet 1 "Sync frame kind: Greet.")
(defconst ubiquitty-sync--kind-welcome 2 "Sync frame kind: Welcome.")
(defconst ubiquitty-sync--kind-facts 3 "Sync frame kind: Facts.")
(defconst ubiquitty-sync--kind-ack 4 "Sync frame kind: Ack.")
(defconst ubiquitty-sync--kind-probe 5 "Sync frame kind: Probe.")
(defconst ubiquitty-sync--kind-echo 6 "Sync frame kind: Echo.")
(defconst ubiquitty-sync--kind-pane-bind 7 "Sync frame kind: PaneBind.")
(defconst ubiquitty-sync--kind-pane-unbind 8 "Sync frame kind: PaneUnbind.")
(defconst ubiquitty-sync--kind-bulk-chunk 9 "Sync frame kind: BulkChunk.")
(defconst ubiquitty-sync--kind-bye 10 "Sync frame kind: Bye.")
(defconst ubiquitty-sync--kind-typography-facts 11 "Sync frame kind: TypographyFacts.")
(defconst ubiquitty-sync--kind-bulk-abort 12 "Sync frame kind: BulkAbort.")
(defconst ubiquitty-sync--kind-call 13 "Sync frame kind: Call.")
(defconst ubiquitty-sync--kind-result 14 "Sync frame kind: Result.")
(defconst ubiquitty-sync--kind-notify 15 "Sync frame kind: Notify.")
(defconst ubiquitty-sync--kind-workspace-structure 16 "Sync frame kind: WorkspaceStructure.")
(defconst ubiquitty-sync--kind-pane-listed 17 "Sync frame kind: PaneListed.")
(defconst ubiquitty-sync--kind-proportional-faces 18 "Sync frame kind: ProportionalFaces.")
(defconst ubiquitty-sync--kind-pane-palette 19 "Sync frame kind: PanePalette.")
(defconst ubiquitty-sync--kind-checkpoint-head 32 "Sync frame kind: CheckpointHead.")
(defconst ubiquitty-sync--kind-update 33 "Sync frame kind: Update.")
(defconst ubiquitty-sync--kind-resync 34 "Sync frame kind: Resync.")
(defconst ubiquitty-sync--kind-view 36 "Sync frame kind: View.")
(defconst ubiquitty-sync--kind-pane-dirty 37 "Sync frame kind: PaneDirty.")
(defconst ubiquitty-sync--kind-history-inline 40 "Sync frame kind: HistoryInline.")
(defconst ubiquitty-sync--kind-history-head 41 "Sync frame kind: HistoryHead.")
(defconst ubiquitty-sync--kind-history-reset 42 "Sync frame kind: HistoryReset.")
(defconst ubiquitty-sync--kind-history-want 43 "Sync frame kind: HistoryWant.")
(defconst ubiquitty-sync--kind-pane-facts 48 "Sync frame kind: PaneFacts.")
(defconst ubiquitty-sync--kind-status-records 49 "Sync frame kind: StatusRecords.")
(defconst ubiquitty-sync--kind-effect 50 "Sync frame kind: Effect.")
(defconst ubiquitty-sync--kind-clipboard-request 51 "Sync frame kind: ClipboardRequest.")
(defconst ubiquitty-sync--kind-image-head 52 "Sync frame kind: ImageHead.")
(defconst ubiquitty-sync--kind-image-placements 53 "Sync frame kind: ImagePlacements.")
(defconst ubiquitty-sync--kind-sample-head 54 "Sync frame kind: SampleHead.")
(defconst ubiquitty-sync--kind-rich-text-measure 55 "Sync frame kind: RichTextMeasure.")
(defconst ubiquitty-sync--kind-native-drag-command 56 "Sync frame kind: NativeDragCommand.")
(defconst ubiquitty-sync--kind-receipt 64 "Sync frame kind: Receipt.")
(defconst ubiquitty-sync--kind-keys 65 "Sync frame kind: Keys.")
(defconst ubiquitty-sync--kind-pointer 66 "Sync frame kind: Pointer.")
(defconst ubiquitty-sync--kind-paste 67 "Sync frame kind: Paste.")
(defconst ubiquitty-sync--kind-paste-abort 68 "Sync frame kind: PasteAbort.")
(defconst ubiquitty-sync--kind-raw 69 "Sync frame kind: Raw.")
(defconst ubiquitty-sync--kind-focus 70 "Sync frame kind: Focus.")
(defconst ubiquitty-sync--kind-paste-receipt 71 "Sync frame kind: PasteReceipt.")
(defconst ubiquitty-sync--kind-input-discarded 72 "Sync frame kind: InputDiscarded.")
(defconst ubiquitty-sync--kind-viewport 73 "Sync frame kind: Viewport.")
(defconst ubiquitty-sync--kind-clipboard-data 74 "Sync frame kind: ClipboardData.")
(defconst ubiquitty-sync--kind-image-want 75 "Sync frame kind: ImageWant.")
(defconst ubiquitty-sync--kind-rich-text-measured 76 "Sync frame kind: RichTextMeasured.")
(defconst ubiquitty-sync--kind-native-drag-event 77 "Sync frame kind: NativeDragEvent.")

;; NotifyKind.
(defconst ubiquitty-sync--notify-kind-attachments 1 "Notify kind: Attachments.")
(defconst ubiquitty-sync--notify-kind-events 2 "Notify kind: Events.")
(defconst ubiquitty-sync--notify-kind-consent-status 3 "Notify kind: ConsentStatus.")
(defconst ubiquitty-sync--notify-kind-consent-question 4 "Notify kind: ConsentQuestion.")
(defconst ubiquitty-sync--notify-kind-structure-consent 5 "Notify kind: StructureConsent.")
(defconst ubiquitty-sync--notify-kind-consent-resolved 6 "Notify kind: ConsentResolved.")
(defconst ubiquitty-sync--notify-kind-paste-ready 7 "Notify kind: PasteReady.")

;; ConsentStatusPhase.
(defconst ubiquitty-sync--consent-status-phase-pending 0 "Own-consent status phase: Pending.")
(defconst ubiquitty-sync--consent-status-phase-approved 1 "Own-consent status phase: Approved.")
(defconst ubiquitty-sync--consent-status-phase-denied 2 "Own-consent status phase: Denied.")
(defconst ubiquitty-sync--consent-status-phase-expired 3 "Own-consent status phase: Expired.")

;; ClientCapability.
(defconst ubiquitty-sync--capability-deflate-checkpoints 1 "Greet capability bit: DeflateCheckpoints.")
(defconst ubiquitty-sync--capability-span-ops 2 "Greet capability bit: SpanOps.")
(defconst ubiquitty-sync--capability-scroll-rect-ops 4 "Greet capability bit: ScrollRectOps.")
(defconst ubiquitty-sync--capability-echo-context 8 "Greet capability bit: EchoContext.")
(defconst ubiquitty-sync--capability-native-drag 16 "Greet capability bit: NativeDrag.")
(defconst ubiquitty-sync--capability-asks-about-host-effects 32 "Greet capability bit: AsksAboutHostEffects.")
(defconst ubiquitty-sync--capability-shows-no-questions 64 "Greet capability bit: ShowsNoQuestions.")
(defconst ubiquitty-sync--capability-deflate-images 128 "Greet capability bit: DeflateImages.")
(defconst ubiquitty-sync--capability-publishes-faces 256 "Greet capability bit: PublishesFaces.")

;; ViewState.
(defconst ubiquitty-sync--view-live 0 "View state: Live.")
(defconst ubiquitty-sync--view-dormant 1 "View state: Dormant.")
(defconst ubiquitty-sync--view-records-only 2 "View state: RecordsOnly.")

;; ResyncReason.
(defconst ubiquitty-sync--resync-digest-mismatch 0 "Resync reason: DigestMismatch.")
(defconst ubiquitty-sync--resync-base-missing 1 "Resync reason: BaseMissing.")
(defconst ubiquitty-sync--resync-decode-failed 2 "Resync reason: DecodeFailed.")
(defconst ubiquitty-sync--resync-checkpoint-refused 3 "Resync reason: CheckpointRefused.")
(defconst ubiquitty-sync--resync-buffer-overflow 4 "Resync reason: BufferOverflow.")

;; PasteState.
(defconst ubiquitty-sync--paste-state-more 0 "Paste piece state: More.")
(defconst ubiquitty-sync--paste-state-final 1 "Paste piece state: Final.")

;; StateBlock.
(defconst ubiquitty-sync--block-cursor 0 "State block: Cursor.")
(defconst ubiquitty-sync--block-modes 1 "State block: Modes.")
(defconst ubiquitty-sync--block-palette 2 "State block: Palette.")
(defconst ubiquitty-sync--block-screen-states 3 "State block: ScreenStates.")
(defconst ubiquitty-sync--block-text-state 4 "State block: TextState.")
(defconst ubiquitty-sync--block-activity 5 "State block: Activity.")
(defconst ubiquitty-sync--block-rich-text 6 "State block: RichText.")

;; Attribute.
(defconst ubiquitty-sync--attr-bold #x01 "Cell attribute bit: Bold.")
(defconst ubiquitty-sync--attr-dim #x02 "Cell attribute bit: Dim.")
(defconst ubiquitty-sync--attr-italic #x04 "Cell attribute bit: Italic.")
(defconst ubiquitty-sync--attr-underline #x08 "Cell attribute bit: Underline.")
(defconst ubiquitty-sync--attr-blink #x10 "Cell attribute bit: Blink.")
(defconst ubiquitty-sync--attr-reverse #x20 "Cell attribute bit: Reverse.")
(defconst ubiquitty-sync--attr-hidden #x40 "Cell attribute bit: Hidden.")
(defconst ubiquitty-sync--attr-strike #x80 "Cell attribute bit: Strike.")
(defconst ubiquitty-sync--attr-wide #x100 "Cell attribute bit: Wide.")
(defconst ubiquitty-sync--attr-wide-continuation #x200 "Cell attribute bit: WideContinuation.")
(defconst ubiquitty-sync--attr-force-emoji-presentation #x400 "Cell attribute bit: ForceEmojiPresentation.")
(defconst ubiquitty-sync--attr-emoji #x800 "Cell attribute bit: Emoji.")
(defconst ubiquitty-sync--attr-protected #x1000 "Cell attribute bit: Protected.")
(defconst ubiquitty-sync--attr-overline #x2000 "Cell attribute bit: Overline.")
(defconst ubiquitty-sync--attr-framed #x4000 "Cell attribute bit: Framed.")
(defconst ubiquitty-sync--attr-encircled #x8000 "Cell attribute bit: Encircled.")

(defconst ubiquitty-sync--bye-reasons
  ["Normal" "VersionMismatch" "Malformed" "Oversize" "UnknownKind" "UnboundHandle"
   "TransferRefused" "Superseded" "ResumeInProgress" "Suspending" "HandingOver" "TokenMissing"
   "TokenInvalid" "TokenExpired" "TokenRevoked" "OutsideScope" "DuplicateHandshake" "NoConsent"
   "RemoteHostRefused" "SessionGone" "HostFull" "OutputBacklog" "Silent"]
  "Bye reasons by wire number.")

(defconst ubiquitty-sync--client-only-kinds
  '(1 3 4 11 13 18 34 36 43 65 66 67 68 69 70 73 74 75 76 77)
  "The kinds only a client sends (Envelope.cpp's directionOf):
Greet, Facts, Ack, TypographyFacts, Call, ProportionalFaces, Resync, View,
HistoryWant, Keys, Pointer, Paste, PasteAbort, Raw, Focus, Viewport, ClipboardData, ImageWant, RichTextMeasured, NativeDragEvent.")

;; Key encoder modifier bits.
(defconst ubiquitty-sync--modifier-shift 1 "Key encoder modifier bit: Shift.")
(defconst ubiquitty-sync--modifier-alternate 2 "Key encoder modifier bit: Alternate.")
(defconst ubiquitty-sync--modifier-ctrl 4 "Key encoder modifier bit: Ctrl.")
(defconst ubiquitty-sync--modifier-super 8 "Key encoder modifier bit: Super.")
(defconst ubiquitty-sync--modifier-hyper 16 "Key encoder modifier bit: Hyper.")
(defconst ubiquitty-sync--modifier-meta 32 "Key encoder modifier bit: Meta.")
(defconst ubiquitty-sync--modifier-caps-lock 64 "Key encoder modifier bit: CapsLock.")
(defconst ubiquitty-sync--modifier-num-lock 128 "Key encoder modifier bit: NumLock.")

(defconst ubiquitty-sync--virtual-key-numbers
  '((none . 0) (return . 1) (keypad-enter . 2) (tab . 3) (backspace . 4) (forward-delete . 5)
    (escape . 6) (insert . 7) (left-arrow . 8) (right-arrow . 9) (up-arrow . 10)
    (down-arrow . 11) (home . 12) (end . 13) (page-up . 14) (page-down . 15) (f1 . 16) (f2 . 17)
    (f3 . 18) (f4 . 19) (f5 . 20) (f6 . 21) (f7 . 22) (f8 . 23) (f9 . 24) (f10 . 25) (f11 . 26)
    (f12 . 27) (keypad0 . 28) (keypad1 . 29) (keypad2 . 30) (keypad3 . 31) (keypad4 . 32)
    (keypad5 . 33) (keypad6 . 34) (keypad7 . 35) (keypad8 . 36) (keypad9 . 37)
    (keypad-decimal . 38) (keypad-divide . 39) (keypad-multiply . 40) (keypad-subtract . 41)
    (keypad-add . 42) (keypad-equal . 43) (left-shift . 44) (right-shift . 45)
    (left-control . 46) (right-control . 47) (left-alternate . 48) (right-alternate . 49)
    (left-super . 50) (right-super . 51) (key-a . 260) (key-b . 261) (key-c . 262) (key-d . 263)
    (key-e . 264) (key-f . 265) (key-g . 266) (key-h . 267) (key-i . 268) (key-j . 269)
    (key-k . 270) (key-l . 271) (key-m . 272) (key-n . 273) (key-o . 274) (key-p . 275)
    (key-q . 276) (key-r . 277) (key-s . 278) (key-t . 279) (key-u . 280) (key-v . 281)
    (key-w . 282) (key-x . 283) (key-y . 284) (key-z . 285) (digit1 . 286) (digit2 . 287)
    (digit3 . 288) (digit4 . 289) (digit5 . 290) (digit6 . 291) (digit7 . 292) (digit8 . 293)
    (digit9 . 294) (digit0 . 295) (space . 300) (minus . 301) (equal . 302) (left-bracket . 303)
    (right-bracket . 304) (backslash . 305) (international-hash . 306) (semicolon . 307)
    (quote . 308) (grave . 309) (comma . 310) (period . 311) (slash . 312) (caps-lock . 313)
    (international-backslash . 356))
  "`Keys::VirtualKey' numbers by name.")

(defconst ubiquitty-sync--default-interrupt-characters '(3 28 26)
  "The interrupt, quit and suspend characters of a pane nobody has described.")

(defconst ubiquitty-sync--known-kinds '(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 32 33 34 36 37 40 41 42 43 48 49 50 51 52 53 54 55 56 64 65 66 67 68 69 70 71 72 73 74 75 76 77)
  "Current canonical envelope kinds.")
(defconst ubiquitty-sync--connection-kinds '(1 2 3 4 5 6 7 8 9 10 12 13 14 15 16 17 18)
  "Kinds requiring canonical channel zero.")

(provide 'ubiquitty-sync-wire)

;;; ubiquitty-sync-wire.el ends here
