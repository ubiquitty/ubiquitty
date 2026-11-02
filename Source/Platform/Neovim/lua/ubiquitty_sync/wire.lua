-- Copyright (C) 2026 Stanislav Yaglo
-- SPDX-License-Identifier: Apache-2.0

-- The numbers ubiquitty_sync shares with the host, as the host's headers
-- declare them. Written by Scripts/gen-wire-tables.py from:
--
--   Source/Core/Protocol/Sync/Admission.h
--   Source/Core/Protocol/Sync/Envelope.h
--   Source/Core/Protocol/Sync/Envelope.cpp
--   Source/Core/Protocol/Sync/Messages.h
--   Source/Core/Protocol/Sync/ScreenPlane.h
--   Source/Core/Protocol/Sync/RowForm.h
--   Source/Core/Protocol/Sync/Connection.h
--   Source/Core/Keys/KeyTranslation.h
--   Source/Core/Keys/Keymap.h
--   Source/Core/VT/Constants.h
--   Source/Core/Color.h
--   Source/Core/RowMeta.h
--   Source/Core/TextSizeTable.h
--   Source/Core/TermPalette.h
--   Source/Core/Protocol/Sync/Records.h
--   Source/Core/Terminal.h
--   Source/Core/OSC/TabStatus.h
--   Source/Core/OSC/ProgressIndicator.h
--   Source/Core/Image/TerminalImage.h
--   Source/Core/Protocol/Sync/Images.h
--   Source/Core/Protocol/Sync/Effects.h
--   Source/Core/Protocol/Sync/Roles.h
--   Source/Core/Protocol/Sync/EffectCodec.h
--   Source/Core/OSC/KittyNotification.h
--   Source/Core/VT/DECPSSynth.h
--   Source/Core/VT/Sound.h
--   Source/Core/Protocol/Sync/Samples.h
--   Source/PAL/PAL.h
--   Source/PAL/TerminalClients.h
--   Source/Core/Protocol/Sync/ConsentStatus.h
--   Source/Core/Session/NameLimits.h
--
-- Do not edit: change the header and run the script.
-- Scripts/check-wire-tables.py fails when this file is not what the headers
-- produce.

local M = {}

-- Own-consent status Notify body bytes
M.max_consent_status_bytes = 10
-- Maximum bound pane handles on one connection.
M.max_panes_per_connection = 256
-- First host-listing handle; bound panes use lower nonzero handles.
M.first_listed_handle = 1073741824
-- Maximum effects in one delivery batch.
M.max_effect_records = 256
-- Maximum MIME items in one clipboard operation.
M.max_effect_clipboard_items = 32
-- Maximum bytes in one clipboard MIME name.
M.max_effect_clipboard_mime_bytes = 65535
-- Maximum clipboard-write data bytes.
M.max_effect_clipboard_write_bytes = 1048576
-- Maximum clipboard-read data bytes.
M.max_effect_clipboard_read_bytes = 4194304
-- Maximum notification replacement identifier bytes.
M.max_notification_identifier_bytes = 32
-- Maximum command-finished command line bytes.
M.max_command_line_bytes = 8192
-- Maximum notes in one sound effect.
M.max_tone_notes = 16
-- Sound envelope sentinel for the selected voice.
M.tone_default_envelope = 65535
-- Number of sound channels, including the terminal speaker.
M.tone_channel_count = 9
-- Highest admitted sound wave.
M.max_tone_wave = 6
-- Maximum volume and sustain level.
M.max_tone_volume = 7
-- Maximum sound envelope duration.
M.max_tone_envelope_milliseconds = 5000
-- Maximum sound pitch offset.
M.max_tone_semitones_down = 48
-- Maximum sound duration in thirty-seconds of a second.
M.max_tone_duration_units = 255
-- Maximum sound note effect number.
M.max_tone_effect = 15
-- Maximum sound filter cutoff.
M.max_tone_cutoff_hertz = 20000
-- Maximum sound stereo position.
M.max_tone_pan = 64
-- Number of downloadable sound sample slots.
M.sample_slot_count = 25
-- Maximum frames in one sound sample.
M.sample_max_frames = 441000
-- Sound sample frames per second.
M.sample_rate_hertz = 44100
-- Exact encoded sound sample identity size.
M.sample_identity_bytes = 40
-- Exact encoded sample announcement size.
M.sample_head_bytes = 45
-- Highest pane progress state.
M.max_progress_state = 4
-- Maximum pane title bytes.
M.max_title_bytes = 4096
-- Maximum pane directory bytes.
M.max_directory_bytes = 4096
-- Maximum pane file URL bytes.
M.max_file_url_bytes = 4096
-- Maximum host home directory bytes.
M.max_home_bytes = 1024
-- Maximum process chain bytes.
M.max_process_chain_bytes = 1024
-- Maximum process chain with arguments bytes.
M.max_process_arguments_bytes = 2048
-- Maximum process or host name bytes.
M.max_process_name_bytes = 255
-- Maximum indicator label bytes.
M.max_indicator_bytes = 48
-- Maximum badge bytes.
M.max_badge_bytes = 256
-- Maximum notification field bytes.
M.max_attention_bytes = 255
-- Maximum pane user variables.
M.max_user_variables = 32
-- Maximum user variable name bytes.
M.max_user_name_bytes = 128
-- Maximum user variable value bytes.
M.max_user_value_bytes = 1024
-- The Sync wire version these tables were written at.
M.wire_version = 2
-- Maximum canonical envelope header bytes.
M.max_envelope_header = 9
-- Maximum canonical pane handle.
M.max_channel = 4294967295
-- Maximum app version bytes.
M.max_app_version_bytes = 32
-- Maximum credential bytes.
M.max_credential_bytes = 256
-- Maximum presented claimed label bytes.
M.max_agent_label_bytes = 256
-- Maximum workspace name bytes.
M.max_workspace_name_bytes = 4096
-- Maximum host platform bytes.
M.max_host_platform_bytes = 64
-- Maximum daemon socket basename bytes.
M.max_daemon_socket_name_bytes = 65535
-- Known serving-build flag bits.
M.known_serving_build_flags = 3
-- The longest body one Sync frame carries.
M.max_frame_body = 65535
-- Maximum image bindings in one pane.
M.max_image_count = 32
-- Maximum image placements in one pane.
M.max_image_placements = 128
-- Bytes of one ImageBinding in an ImagePlacements body.
M.image_binding_record_bytes = 42
-- Bytes of one ImagePlacement in an ImagePlacements body.
M.image_placement_record_bytes = 55
-- Maximum decoded pixel bytes in one image.
M.max_image_bytes = 67108864
-- Maximum width or height of a decoded image.
M.max_image_dimension = 16384
-- Default retained image-pixel budget of one terminal.
M.image_pixel_budget = 268435456
-- The most of a paste a client hands its transport at once.
M.paste_piece_bytes = 8192
-- The most steps a Welcome's probe schedule names.
M.max_probe_steps = 8
-- Bytes a Sync pen occupies.
M.pen_wire = 20
-- The state blocks a checkpoint carries.
M.state_block_count = 7
-- Slots a text-size table always carries.
M.text_size_table_capacity = 15
-- Bytes one text-size slot occupies in the text-state block.
M.text_size_spec_wire_bytes = 12
-- Where a text-size slot's proportional flag sits within it.
M.text_size_spec_proportional_offset = 6
-- Special palette colours per table.
M.palette_special = 5
-- Pen colour index meaning the terminal default.
M.color_default = 0x100
-- Pen colour index meaning the direct RGB bytes.
M.color_rgb = 0x101
-- Row attribute: DECDWL double width.
M.line_double_width = 1
-- Row attribute: DECDHL top half.
M.line_double_height_top = 2
-- Row attribute: DECDHL bottom half.
M.line_double_height_bottom = 3
-- The Sync wire fingerprint these tables were written at, sent in every Greet.
M.wire_fingerprint = "\106\061\215\022\099\058\244\199\000\046\119\191\057\010\224\217\197\232\233\141\112\054\086\169\203\023\133\106\218\037\128\017"

-- Role.
M.role = {
    owner = 0,
    driver = 1,
    viewer = 2,
    agent = 3,
}

-- ClientKind.
M.client_kind = {
    human = 0,
    agent = 1,
    viewer = 2,
}

-- AttachmentAdmission.
M.attachment_admission = {
    awaiting_consent = 0,
    granted = 1,
}

-- ResumeOutcome.
M.resume_outcome = {
    diffed = 0,
    checkpointed = 1,
    gone = 2,
}

-- ByeReason.
M.bye_reason = {
    normal = 0,
    version_mismatch = 1,
    malformed = 2,
    oversize = 3,
    unknown_kind = 4,
    unbound_handle = 5,
    transfer_refused = 6,
    superseded = 7,
    resume_in_progress = 8,
    suspending = 9,
    handing_over = 10,
    token_missing = 11,
    token_invalid = 12,
    token_expired = 13,
    token_revoked = 14,
    outside_scope = 15,
    duplicate_handshake = 16,
    no_consent = 17,
    remote_host_refused = 18,
    session_gone = 19,
    host_full = 20,
    output_backlog = 21,
    silent = 22,
}

-- EffectKind.
M.effect_kind = {
    bell = 0,
    notification = 1,
    command_finished = 2,
    sound = 3,
    attention = 4,
    clipboard_write = 5,
}

-- NotificationOccasion.
M.notification_occasion = {
    always = 0,
    unfocused = 1,
    invisible = 2,
}

-- ClipboardBuffer.
M.clipboard_buffer = {
    clipboard = 0,
    primary = 1,
    secondary = 2,
    select = 3,
    cut0 = 4,
    cut1 = 5,
    cut2 = 6,
    cut3 = 7,
    cut4 = 8,
    cut5 = 9,
    cut6 = 10,
    cut7 = 11,
    count = 12,
}

-- EffectClipboardRequestKind.
M.effect_clipboard_request = {
    types = 0,
    item = 1,
}

-- EffectClipboardStatus.
M.effect_clipboard_status = {
    ok = 0,
    empty = 1,
    refused = 2,
    too_large = 3,
}

-- AdmissionTarget.
M.admission_target = {
    session = 0,
    workspace = 1,
    control = 2,
    management = 3,
}

-- FrameKind.
M.kind = {
    greet = 1,
    welcome = 2,
    facts = 3,
    ack = 4,
    probe = 5,
    echo = 6,
    pane_bind = 7,
    pane_unbind = 8,
    bulk_chunk = 9,
    bye = 10,
    typography_facts = 11,
    bulk_abort = 12,
    call = 13,
    result = 14,
    notify = 15,
    workspace_structure = 16,
    pane_listed = 17,
    proportional_faces = 18,
    pane_palette = 19,
    checkpoint_head = 32,
    update = 33,
    resync = 34,
    view = 36,
    pane_dirty = 37,
    history_inline = 40,
    history_head = 41,
    history_reset = 42,
    history_want = 43,
    pane_facts = 48,
    status_records = 49,
    effect = 50,
    clipboard_request = 51,
    image_head = 52,
    image_placements = 53,
    sample_head = 54,
    rich_text_measure = 55,
    native_drag_command = 56,
    receipt = 64,
    keys = 65,
    pointer = 66,
    paste = 67,
    paste_abort = 68,
    raw = 69,
    focus = 70,
    paste_receipt = 71,
    input_discarded = 72,
    viewport = 73,
    clipboard_data = 74,
    image_want = 75,
    rich_text_measured = 76,
    native_drag_event = 77,
}

-- NotifyKind.
M.notify_kind = {
    attachments = 1,
    events = 2,
    consent_status = 3,
    consent_question = 4,
    structure_consent = 5,
    consent_resolved = 6,
    paste_ready = 7,
}

-- ConsentStatusPhase.
M.consent_status_phase = {
    pending = 0,
    approved = 1,
    denied = 2,
    expired = 3,
}

-- ClientCapability.
M.capability = {
    deflate_checkpoints = 1,
    span_ops = 2,
    scroll_rect_ops = 4,
    echo_context = 8,
    native_drag = 16,
    asks_about_host_effects = 32,
    shows_no_questions = 64,
    deflate_images = 128,
    publishes_faces = 256,
}

-- ViewState.
M.view_state = {
    live = 0,
    dormant = 1,
    records_only = 2,
}

-- ResyncReason.
M.resync_reason = {
    digest_mismatch = 0,
    base_missing = 1,
    decode_failed = 2,
    checkpoint_refused = 3,
    buffer_overflow = 4,
}

-- PasteState.
M.paste_state = {
    more = 0,
    final = 1,
}

-- StateBlock.
M.block = {
    cursor = 0,
    modes = 1,
    palette = 2,
    screen_states = 3,
    text_state = 4,
    activity = 5,
    rich_text = 6,
}

-- Attribute.
M.attribute = {
    bold = 0x01,
    dim = 0x02,
    italic = 0x04,
    underline = 0x08,
    blink = 0x10,
    reverse = 0x20,
    hidden = 0x40,
    strike = 0x80,
    wide = 0x100,
    wide_continuation = 0x200,
    force_emoji_presentation = 0x400,
    emoji = 0x800,
    protected = 0x1000,
    overline = 0x2000,
    framed = 0x4000,
    encircled = 0x8000,
}

-- Bye reasons by wire number.
M.bye_reasons = {
    [0] = "Normal",
    [1] = "VersionMismatch",
    [2] = "Malformed",
    [3] = "Oversize",
    [4] = "UnknownKind",
    [5] = "UnboundHandle",
    [6] = "TransferRefused",
    [7] = "Superseded",
    [8] = "ResumeInProgress",
    [9] = "Suspending",
    [10] = "HandingOver",
    [11] = "TokenMissing",
    [12] = "TokenInvalid",
    [13] = "TokenExpired",
    [14] = "TokenRevoked",
    [15] = "OutsideScope",
    [16] = "DuplicateHandshake",
    [17] = "NoConsent",
    [18] = "RemoteHostRefused",
    [19] = "SessionGone",
    [20] = "HostFull",
    [21] = "OutputBacklog",
    [22] = "Silent",
}

-- The kinds only a client sends (Envelope.cpp's directionOf).
M.client_only_kind = {
    [1] = true, -- Greet
    [3] = true, -- Facts
    [4] = true, -- Ack
    [11] = true, -- TypographyFacts
    [13] = true, -- Call
    [18] = true, -- ProportionalFaces
    [34] = true, -- Resync
    [36] = true, -- View
    [43] = true, -- HistoryWant
    [65] = true, -- Keys
    [66] = true, -- Pointer
    [67] = true, -- Paste
    [68] = true, -- PasteAbort
    [69] = true, -- Raw
    [70] = true, -- Focus
    [73] = true, -- Viewport
    [74] = true, -- ClipboardData
    [75] = true, -- ImageWant
    [76] = true, -- RichTextMeasured
    [77] = true, -- NativeDragEvent
}

-- Key encoder modifier bits.
M.modifier = {
    shift = 1,
    alternate = 2,
    ctrl = 4,
    super = 8,
    hyper = 16,
    meta = 32,
    caps_lock = 64,
    num_lock = 128,
}

-- Keys::VirtualKey numbers by name.
M.virtual_key = {
    none = 0,
    ["return"] = 1,
    keypad_enter = 2,
    tab = 3,
    backspace = 4,
    forward_delete = 5,
    escape = 6,
    insert = 7,
    left_arrow = 8,
    right_arrow = 9,
    up_arrow = 10,
    down_arrow = 11,
    home = 12,
    ["end"] = 13,
    page_up = 14,
    page_down = 15,
    f1 = 16,
    f2 = 17,
    f3 = 18,
    f4 = 19,
    f5 = 20,
    f6 = 21,
    f7 = 22,
    f8 = 23,
    f9 = 24,
    f10 = 25,
    f11 = 26,
    f12 = 27,
    keypad0 = 28,
    keypad1 = 29,
    keypad2 = 30,
    keypad3 = 31,
    keypad4 = 32,
    keypad5 = 33,
    keypad6 = 34,
    keypad7 = 35,
    keypad8 = 36,
    keypad9 = 37,
    keypad_decimal = 38,
    keypad_divide = 39,
    keypad_multiply = 40,
    keypad_subtract = 41,
    keypad_add = 42,
    keypad_equal = 43,
    left_shift = 44,
    right_shift = 45,
    left_control = 46,
    right_control = 47,
    left_alternate = 48,
    right_alternate = 49,
    left_super = 50,
    right_super = 51,
    key_a = 260,
    key_b = 261,
    key_c = 262,
    key_d = 263,
    key_e = 264,
    key_f = 265,
    key_g = 266,
    key_h = 267,
    key_i = 268,
    key_j = 269,
    key_k = 270,
    key_l = 271,
    key_m = 272,
    key_n = 273,
    key_o = 274,
    key_p = 275,
    key_q = 276,
    key_r = 277,
    key_s = 278,
    key_t = 279,
    key_u = 280,
    key_v = 281,
    key_w = 282,
    key_x = 283,
    key_y = 284,
    key_z = 285,
    digit1 = 286,
    digit2 = 287,
    digit3 = 288,
    digit4 = 289,
    digit5 = 290,
    digit6 = 291,
    digit7 = 292,
    digit8 = 293,
    digit9 = 294,
    digit0 = 295,
    space = 300,
    minus = 301,
    equal = 302,
    left_bracket = 303,
    right_bracket = 304,
    backslash = 305,
    international_hash = 306,
    semicolon = 307,
    quote = 308,
    grave = 309,
    comma = 310,
    period = 311,
    slash = 312,
    caps_lock = 313,
    international_backslash = 356,
}

-- The interrupt, quit and suspend characters of a pane nobody has described.
M.default_interrupt_characters = { interrupt = 0x03, quit = 0x1c, suspend = 0x1a }

-- Kinds requiring canonical channel zero.
M.connection_kind = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true, [9] = true, [10] = true, [12] = true, [13] = true, [14] = true, [15] = true, [16] = true, [17] = true, [18] = true }

return M
