;;; ubiquitty-sync.el --- Emacs frontend for the ubiquitty-host terminal daemon -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Stanislav Yaglo
;; SPDX-License-Identifier: MIT

;; Author: Stanislav Yaglo <yaglo@me.com>
;; Maintainer: Stanislav Yaglo <yaglo@me.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: terminals, processes, unix
;; URL: https://github.com/ubiquitty/ubiquitty

;; Permission is hereby granted, free of charge, to any person obtaining a
;; copy of this software and associated documentation files (the
;; "Software"), to deal in the Software without restriction, including
;; without limitation the rights to use, copy, modify, merge, publish,
;; distribute, sublicense, and/or sell copies of the Software, and to permit
;; persons to whom the Software is furnished to do so, subject to the
;; following conditions:
;;
;; The above copyright notice and this permission notice shall be included
;; in all copies or substantial portions of the Software.
;;
;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
;; OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
;; IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
;; CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
;; TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
;; SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

;;; Commentary:

;; A thin terminal client that attaches to a running `ubiquitty-host'
;; daemon through the host's own attach bridge, speaks the Sync wire protocol,
;; renders the Sync screen plane's checkpoints and updates into an Emacs
;; buffer, and forwards keys, mouse events and pastes back as numbered Sync
;; input events on the pane's handle.  The terminal Core
;; runs in the daemon, not in Emacs: this package is purely a frontend over the
;; Sync seam.
;;
;; The client draws the screen and inline images.  Images require a graphical
;; frame.  There is no host scrollback view, consent UI,
;; or QUIC transport; the host attach bridge carries the local connection.
;;
;; Requirements: the `ubiquitty-host' daemon binary must be available.  By
;; default `ubiquitty-sync' starts it on demand (see `ubiquitty-sync-host-program'
;; and `ubiquitty-sync-auto-start'); otherwise start it yourself with
;; `ubiquitty-host --ensure-daemon'.
;;
;; Usage:  M-x ubiquitty-sync
;;
;; The window size becomes the terminal size; resizing the window sends the
;; new size in a Facts.  Keys are forwarded to the terminal; `C-c' is the escape prefix
;; for Emacs-side commands (`C-c C-q' detach, `C-c o' other-window,
;; `C-c C-c' send a literal C-c).

;;; Code:

(require 'cl-lib)
(require 'json)       ; duplicate-preserving object member lists
(require 'subr-x)     ; string-join
(require 'face-remap) ; face-remap-add-relative / -remove-relative
(require 'xt-mouse)   ; xterm-mouse-mode (TUI mouse decoding)

;; ---- protocol constants ------------------------------------------------
;;
;; The numbers this client shares with the host are in ubiquitty-sync-wire.el,
;; written from the host's headers by Scripts/gen-wire-tables.py: the wire
;; version, the frame tags and kinds, the capability and attribute bits, the
;; reasons, the key numbers.  None of them is typed here.  What follows is
;; this client's own: what it chooses, and layouts no header declares.

(require 'ubiquitty-sync-wire
         ;; Beside this file when it is loaded by path, as a test or a bare
         ;; `load-file' does; from `load-path' otherwise.
         (let* ((here (or load-file-name (bound-and-true-p byte-compile-current-file) buffer-file-name))
                (beside (and here (expand-file-name "ubiquitty-sync-wire" (file-name-directory here)))))
           (and beside (file-exists-p (concat beside ".el")) beside)))

(require 'ubiquitty-sync-effects
         (let* ((here (or load-file-name (bound-and-true-p byte-compile-current-file) buffer-file-name))
                (beside (and here (expand-file-name "ubiquitty-sync-effects" (file-name-directory here)))))
           (and beside (file-exists-p (concat beside ".el")) beside)))

(defvar-local ubiquitty-sync--client-instance nil "The exact identity sent in this attachment's Greet.")
(defvar-local ubiquitty-sync--effect-pane nil "The stable pane identity owning the effect receipt.")
(defvar-local ubiquitty-sync--effect-cursor nil "Shared complete and consumed high-water marks for the stable pane.")
(defvar-local ubiquitty-sync--effect-cursors nil "Per-handle effect batch cursors; aliases deduplicate through the stable pane.")
(defvar-local ubiquitty-sync--pane-bindings nil "Bound handles of this buffer's single stable pane.")
(defvar-local ubiquitty-sync--effect-ack-handles nil "Bound handles owing a completed effect receipt.")
(defvar-local ubiquitty-sync--effects nil "The newest eight validated typed effects, newest first.")
(defvar-local ubiquitty-sync--sample-slots nil "Exact sample identities keyed by bound handle and slot.")
(defvar-local ubiquitty-sync--sample-transfers nil "Bounded raw sample owners keyed by transfer ID.")
(defvar-local ubiquitty-sync--deferred-effects nil "Validated packets waiting for exact payload readiness, in arrival order.")
(defvar-local ubiquitty-sync--deferred-effect-bytes 0 "Encoded bytes retained by deferred effect packets.")
(defvar-local ubiquitty-sync--clipboard-transfers nil "Exact pending clipboard transfers, keyed by transfer ID.")
(defvar-local ubiquitty-sync--clipboard-pending-bytes 0 "Reserved clipboard raw and decoded payload capacity.")
(defvar-local ubiquitty-sync--effect-delivering-bytes 0 "Packet and payload capacity retained through a synchronous handler.")
(defvar-local ubiquitty-sync--clipboard-status nil "Last local write outcome: applied, disabled or refused; no clipboard contents.")

(defconst ubiquitty-sync--unsolicited-kinds
  (list ubiquitty-sync--kind-workspace-structure ubiquitty-sync--kind-pane-listed
        ubiquitty-sync--kind-pane-dirty ubiquitty-sync--kind-pane-palette
        ubiquitty-sync--kind-history-inline
        ubiquitty-sync--kind-history-head ubiquitty-sync--kind-history-reset
        ubiquitty-sync--kind-status-records)
  "The kinds a host sends that this client asked for nothing of.
It keeps no history, always shows its one pane, draws no program-status
records, lays out no workspace and lists no host, so
WorkspaceStructure, PaneListed, PaneDirty, PanePalette, the history kinds
and StatusRecords are read past by their frame length.  A shown pane's
palette arrives in its updates; PanePalette is sent only for a pane held
Dormant.  A structure too large for a frame follows as a bulk transfer
nothing here is waiting for, and its chunks are dropped when the last one
arrives.")
(defconst ubiquitty-sync--raw-piece-bytes 4096 "Typed bytes go a piece of this size at a time.")
(defconst ubiquitty-sync--virtual-keys
  '((return . return) (kp-enter . return) (tab . tab) (backspace . backspace)
    (delete . backspace) (deletechar . forward-delete) (escape . escape) (insert . insert)
    (left . left-arrow) (right . right-arrow) (up . up-arrow) (down . down-arrow)
    (home . home) (end . end) (prior . page-up) (next . page-down))
  "The named keys this client forwards, each with the `Keys::VirtualKey' it goes as.
A terminal's `delete' is the key above Return, the host's Backspace.  The
keypad's Enter goes as Return: the host's legacy key encoder writes nothing
for a keypad key that states no character, and the frontends that have one
fold it the same way.")
(defconst ubiquitty-sync--max-buffered-update-bytes (* 1024 1024)
  "Update bytes held while a checkpoint is in flight, the cap Docs/sync.md
section 7.9 states.  Past it the client asks for a fresh checkpoint instead.")

(defconst ubiquitty-sync--max-inflate-ratio 1000
  "Inflated-to-compressed ratio an IMAGE stream may claim.
A small payload cannot name a large picture, which is the half of the bound
that survives a host declaring whatever it likes about its own stream.")

(defvar ubiquitty-sync-max-image-compressed-bytes (* 1024 1024)
  "Compressed bytes of one IMAGE this client will inflate.

This is the only bound that exists.  `zlib-decompress-region' has no output
limit and Emacs offers no streaming inflate, so a stream that lies about its
size is discovered by measuring the result, which is after it is in memory.
What can be bounded is the input: a zlib stream expands at most about 1032 to
1, so a cap of N bytes here is a worst case of roughly 1032*N.

Raise it only for a host whose images are genuinely larger and whose bytes you
trust, and note what the new value multiplies out to.")
(defconst ubiquitty-sync--max-image-reassemblies 4
  "Images that may be mid-reassembly at once.
A host that opens streams and finishes none holds this many, not the whole
id space; the least recently fed goes when another starts.")
(defconst ubiquitty-sync--retained-asset-budget (* 72 1024 1024)
  "This frontend's aggregate retained image/effect allowance, not a frame size.")

(defgroup ubiquitty-sync nil
  "Minimal Emacs frontend for the ubiquitty-host Sync protocol."
  :group 'processes
  :prefix "ubiquitty-sync-")

(defcustom ubiquitty-sync-clipboard-write-function nil
  "Explicit local handler for an authorized remote clipboard write, or nil.
The function receives BUFFER, the protocol's clipboard selector, and ITEMS,
an ordered list of (MIME . UNIBYTE-DATA) pairs.  Empty ITEMS means clear.
Return t only after applying every item to that selector; nil means refusal.
No handler is installed by default, and no implicit text-only fallback runs.
The callback is synchronous and must not retain or mutate its borrowed items.
The client consumes the operation before invoking it, so reconnect cannot
replay a write whose callback has begun.  A callback error closes the carrier."
  :type '(choice (const :tag "Disabled" nil) function)
  :group 'ubiquitty-sync)
(put 'ubiquitty-sync-clipboard-write-function 'risky-local-variable t)

(defcustom ubiquitty-sync-socket nil
  "Socket leaf name handed to the attach bridge, such as \"host-0123.sock\".
When nil, the bridge attaches to the daemon of its own binary, which is
the daemon `ubiquitty-sync-host-program' starts."
  :type '(choice (const :tag "The host program's own daemon" nil) string))

(defcustom ubiquitty-sync-host-program "ubiquitty-host"
  "Name or absolute path of the ubiquitty-host daemon binary.
Looked up with `executable-find', so a bare name is resolved on PATH.
Set this to the absolute path if the binary lives in a build tree."
  :type 'string)

(defcustom ubiquitty-sync-auto-start t
  "When non-nil, run `--ensure-daemon' before attaching.
That start is a no-op when the host program's daemon is already running."
  :type 'boolean)

(defcustom ubiquitty-sync-theme nil
  "Name of the Ubiquitty theme the session is coloured with.
The host owns a session's palette and reads no configuration of its own,
so the client applies a theme after the handshake.  When nil, the `theme'
entry of ~/.config/ubiquitty/config.toml is used, and \"Noir\" without one."
  :type '(choice (const :tag "The configured theme" nil) string))

(defcustom ubiquitty-sync-theme-file
  (let ((source (or load-file-name buffer-file-name)))
    (and source
         (let ((table (expand-file-name "../../Core/Themes/builtin-themes.toml"
                                        (file-name-directory source))))
           (and (file-readable-p table) table))))
  "Path of the theme table, Ubiquitty's builtin-themes.toml.
Resolved from the source tree the package is loaded from when it is one;
without a table only the built-in Noir pair is known."
  :type '(choice (const :tag "None" nil) file))

(defcustom ubiquitty-sync-state-directory (locate-user-emacs-file "ubiquitty-sync/")
  "Directory keeping this Emacs's client instance and its resume record.
The record holds the session's screen text, so the directory is made
readable by its owner alone.  Restarted, Emacs greets the host as the same
client, draws the stored screen before the first packet and continues the
attachment with a diff."
  :type 'directory)

(defcustom ubiquitty-sync-kill-buffer-on-exit t
  "When non-nil, the terminal buffer is killed once its session ends.
When nil, the buffer remains and ends with a line saying the session ended."
  :type 'boolean)

;; ---- per-connection buffer-local state -------------------------------

(defvar-local ubiquitty-sync--process nil
  "Network process of this terminal buffer's connection to the daemon.")
(defvar-local ubiquitty-sync--columns 80
  "Last terminal column count sent to the host.")
(defvar-local ubiquitty-sync--rows 24
  "Last terminal row count sent to the host.")
(defvar-local ubiquitty-sync--application-cursor nil
  "Whether the program asked for application cursor keys (DECCKM).")
(defvar-local ubiquitty-sync--bracketed-paste nil
  "Whether the program asked for bracketed paste (mode 2004).")
(defvar-local ubiquitty-sync--mouse-tracking nil
  "Whether the program asked for any mouse reporting.")
(defvar-local ubiquitty-sync--mouse-sgr nil
  "Whether the program asked for SGR (1006) mouse coordinates.")
(defvar-local ubiquitty-sync--screen nil
  "The screen as a vector of rows, each a vector of one-cell strings.
A wide glyph's continuation cell is the empty string.")
(defvar-local ubiquitty-sync--line-attributes nil
  "Per-row DECDWL and DECDHL attribute bytes, parallel to `ubiquitty-sync--screen'.")
(defvar-local ubiquitty-sync--palette nil
  "The 259-entry colour vector the host's palette block carries.")
(defvar-local ubiquitty-sync--crt-blanked nil
  "Whether the host's CRT saver blanks the display.")
(defvar-local ubiquitty-sync--global-reverse nil
  "Whether DECSCNM reverse video is on.")
(defvar-local ubiquitty-sync--cursor '(0 0 0 nil)
  "The cursor as (ROW COLUMN SHAPE VISIBLE); SHAPE is 0 block, 1 underline, 2 bar.")
(defvar-local ubiquitty-sync--cursor-position '(0 0 0)
  "The active screen's cursor as the cursor block carries it: (ROW COLUMN SHAPE).")
(defvar-local ubiquitty-sync--cursor-visible t
  "Whether the program shows its cursor (DECTCEM).")
(defvar-local ubiquitty-sync--admission-request nil "The exact Greet selection request.")
(defvar-local ubiquitty-sync--transport-closed nil "A typed Bye permanently ended this carrier.")
(defvar-local ubiquitty-sync--pane-ended nil "The last handle of this buffer's pane was unbound.")
(defvar-local ubiquitty-sync--consent-verdict nil "The exact denied/expired verdict retained across NoConsent Bye.")
(defvar-local ubiquitty-sync--peer-metadata nil "Optional typed Bye peer build/platform, never routing authority.")
(defvar-local ubiquitty-sync--connection-generation 0 "Changes whenever this buffer starts a fresh Greet.")
(defvar-local ubiquitty-sync--pane nil
  "The Sync handle the host bound this session's pane to, or nil.")
(defvar-local ubiquitty-sync--generation nil
  "The screen generation the client holds, or nil before a checkpoint.")
(defvar-local ubiquitty-sync--dictionary-epoch 0
  "The dictionary epoch the held pens and clusters belong to.")
(defvar-local ubiquitty-sync--pens nil
  "The pen dictionary: pen id to its 20 wire bytes.")
(defvar-local ubiquitty-sync--pending-checkpoint nil
  "The checkpoint announced and not yet whole, as (GENERATION . TRANSFER).")
(defvar-local ubiquitty-sync--transfers nil
  "Bulk transfers in flight, each (TRANSFER NEXT-INDEX CHUNKS), chunks reversed.")
(defvar-local ubiquitty-sync--buffered-updates nil
  "Updates past the checkpoint in flight, newest first, applied once it lands.")
(defvar-local ubiquitty-sync--resync-outstanding nil
  "Whether a Resync is out and its checkpoint has not landed.")
(defvar-local ubiquitty-sync--ack-owed nil
  "Whether a generation was taken since the last Ack named one.")
(defvar-local ubiquitty-sync--stream-received 0
  "Sync stream bytes received on this connection.")
(defvar-local ubiquitty-sync--stream-acknowledged 0
  "Sync stream bytes the last Ack counted.")
(defvar-local ubiquitty-sync--host-time 0
  "The newest host time an update carried, echoed in the Ack.")
(defvar-local ubiquitty-sync--row-records nil
  "Both screens' rows as their RowRecords, a vector per screen, primary first.
Kept so a palette, reverse-video or text-size change lays every cell out again.")
(defvar-local ubiquitty-sync--held-blocks nil
  "The seven state blocks' bytes as they arrived, indexed by block.")
(defvar-local ubiquitty-sync--held-links nil
  "The link ring's entries as they arrived, oldest first, each (ID . BYTES).")
(defvar-local ubiquitty-sync--held-clusters nil
  "Each defined cluster's code-point list as it arrived, by cluster id.")
(defvar-local ubiquitty-sync--held-runs nil
  "The run texts as the last checkpoint carried them, count included.")
(defvar-local ubiquitty-sync--held-rich-texts nil
  "The rich text definitions as they arrived, newest first.")
(defvar-local ubiquitty-sync--held-history nil
  "The history's epoch and head the screen held names, as (EPOCH . HEAD).")
(defvar-local ubiquitty-sync--held-ground nil
  "The parser ground record the last checkpoint carried.")
(defvar-local ubiquitty-sync--held-digest nil
  "The state digest of the generation held, as its 16 wire bytes.")
(defvar-local ubiquitty-sync--program nil
  "The host program this buffer's bridge runs, which also keeps its record.")
(defvar-local ubiquitty-sync--resume-tail nil
  "What this buffer's next Greet ends with to resume its stored attachment.")
(defvar-local ubiquitty-sync--reset-generation nil
  "The generation held when the host last cleared the history, or nil.
A record keeps no picture until the screen is newer than it.")
(defvar-local ubiquitty-sync--screens nil
  "Both screens laid out, primary first, each (CELLS . LINE-ATTRIBUTES).")
(defvar-local ubiquitty-sync--screen-columns 0
  "The columns of the held screens.")
(defvar-local ubiquitty-sync--active-screen 0
  "Which held screen is shown: 0 primary, 1 alternate.")
(defvar-local ubiquitty-sync--face-caches nil
  "The face tables keyed by pen bytes, as (PLAIN . REVERSED).")
(defvar-local ubiquitty-sync--braille-renderings nil
  "At most 256 cell-sized braille images, keyed by dots, metrics and colours.")
(defvar-local ubiquitty-sync--blank-cell nil
  "The cell string past a row's extent, in the host's default colours.")
(defvar-local ubiquitty-sync--images nil
  "Decoded images by id, each (WIDTH HEIGHT FORMAT STORAGE OFFSET).
STORAGE is the immutable canonical image owner; pixels begin at OFFSET.")
(defvar-local ubiquitty-sync--image-state nil
  "The whole bound pane image record: revision, bindings, assets and placements.")
(defvar-local ubiquitty-sync--image-cache nil
  "Verified content identities to immutable decoded image owners.")
(defvar-local ubiquitty-sync--image-offers nil
  "Image identities offered by the selected pane, never another session.")
(defvar-local ubiquitty-sync--image-wants nil
  "Missing offered identities requested once while awaiting their head.")
(defvar-local ubiquitty-sync--image-transfers nil
  "At most max-image-count transfers as [ASSET OWNER RECEIVED NEXT-INDEX].
A nil OWNER is a bounded discard fence, not retained pixel data.")
(defvar-local ubiquitty-sync--image-renderings nil
  "Image data keyed by format, image id, crop and padded source dimensions.
Only the current images and placements use this bounded cache.")
(defvar-local ubiquitty-sync--image-rendering-bytes 0
  "Bytes held in `ubiquitty-sync--image-renderings'.")
(defvar-local ubiquitty-sync--image-chunks nil
  "Reassemblies in flight by image id, each a `ubiquitty-sync--reassembly'.
An id leaves when its last chunk lands, when a chunk contradicts the stream
its chunk 0 pinned, or when a newer image evicts it at the ceiling.")
(defvar-local ubiquitty-sync--image-chunk-clock 0
  "Ticks a reassembly stamps itself with, so the oldest is the one evicted.")
(defvar-local ubiquitty-sync--placements nil
  "Image placements as (ID COLUMN ROW COLUMNS ROWS OFFSET-X OFFSET-Y
SOURCE-X SOURCE-Y SOURCE-WIDTH SOURCE-HEIGHT ALTERNATE DRAWN-WIDTH
DRAWN-HEIGHT).  A nonzero drawn size is the picture's size in device
pixels; the cell box then names only the host's covered cells.")
(defvar-local ubiquitty-sync--clusters nil
  "The grapheme cluster pool: cluster id to its string.")
(defvar-local ubiquitty-sync--run-texts nil
  "The proportional run texts: run id to its string.")
(defvar-local ubiquitty-sync--proportional-specs 0
  "The live text-size specs that are proportional, bit `id - 1' per id.
A cell's cluster field names the run-text store only under one of these, and
the grapheme cluster pool under every other spec: the two id spaces overlap,
so the spec is what says which store a cell is reading.")
(defvar-local ubiquitty-sync--batch-dirty nil
  "While frames are applied in a batch, the rows owed a paint: a bool vector,
or `all' when the whole screen is.  Nil outside a batch, when each frame
paints as it lands.")
(defvar-local ubiquitty-sync--face-cookie nil
  "The default-face remap onto the host's default colours.")
(defvar-local ubiquitty-sync--default-colors nil
  "The host default colours the remap was made for, as (FOREGROUND . BACKGROUND).")

(defvar-local ubiquitty-sync--welcome nil
  "The host's Welcome as a plist, or nil before it.")
(defvar-local ubiquitty-sync--consent-phase nil
  "The own-question phase, or nil for an ordinary granted Welcome.")
(defvar-local ubiquitty-sync--paste-limits nil
  "The host's paste caps as (CHUNK-BYTES PASTE-BYTES WINDOW-BYTES), or nil when it states none.")
(defvar-local ubiquitty-sync--facts-owed nil
  "Whether a Facts waits for the Welcome: the viewport or the theme changed before it.")
(defvar-local ubiquitty-sync--focused t
  "Whether this buffer's window holds the keyboard focus, as last told to the host.")
(defvar-local ubiquitty-sync--input-seq 0
  "The number of the newest input event sent to the pane; events count from 1.")
(defvar-local ubiquitty-sync--input-written 0
  "The newest input event the host has written to the program.")
(defvar-local ubiquitty-sync--input-settled 0
  "The newest input event whose echo the host says has settled.")
(defvar-local ubiquitty-sync--input-discarded 0
  "How many of this client's events a signal character dropped unwritten.")
(defvar-local ubiquitty-sync--queued-input nil
  "Input given before the pane was bound, newest first, each (KIND . BODY).
KIND is a Sync input kind and BODY what follows the event's number; a
paste is (paste . TEXT).")
(defvar-local ubiquitty-sync--pastes nil
  "Pastes the host has not written whole, oldest first, each [SEQ TEXT SENT WRITTEN].")
(defvar-local ubiquitty-sync--pastes-aborted 0
  "How many pastes an interrupt gave up.")
(defvar-local ubiquitty-sync--echo nil
  "The pane's echo context as a plist, or nil while it is unknown.
A checkpoint makes it unknown until the next update states it.")
(defvar-local ubiquitty-sync--notifies nil
  "The host's newest notifies as (KIND . RECORD), newest first, at most eight.")
(defvar-local ubiquitty-sync--last-result nil
  "The newest Result the host sent, as (TRANSFER . TEXT).")
(defvar-local ubiquitty-sync--bye-reason nil
  "Why the host closed the screen plane, by name, or nil.")

;; ---- little-endian readers (over a unibyte string) -------------------

(defsubst ubiquitty-sync--u8 (s i) "Read the unsigned byte at offset I of string S." (aref s i))

(defsubst ubiquitty-sync--u16 (s i)
  "Read a little-endian unsigned 16-bit integer at offset I of string S."
  (logior (aref s i) (ash (aref s (1+ i)) 8)))

(defsubst ubiquitty-sync--u32 (s i)
  "Read a little-endian unsigned 32-bit integer at offset I of string S."
  (logior (aref s i)
          (ash (aref s (+ i 1)) 8)
          (ash (aref s (+ i 2)) 16)
          (ash (aref s (+ i 3)) 24)))

(defsubst ubiquitty-sync--i32 (s i)
  "Read a little-endian signed 32-bit integer at offset I of string S."
  (let ((v (ubiquitty-sync--u32 s i)))
    (if (>= v #x80000000) (- v #x100000000) v)))

(defsubst ubiquitty-sync--i16 (s i)
  "Read a little-endian signed 16-bit integer at offset I of string S."
  (let ((v (ubiquitty-sync--u16 s i)))
    (if (>= v #x8000) (- v #x10000) v)))

(defsubst ubiquitty-sync--u64 (s i)
  "Read a little-endian unsigned 64-bit integer at offset I of string S."
  (logior (ubiquitty-sync--u32 s i) (ash (ubiquitty-sync--u32 s (+ i 4)) 32)))

;; ---- little-endian writers (build unibyte strings) -------------------

(defsubst ubiquitty-sync--put-u16 (n)
  "Return N as a little-endian unsigned 16-bit unibyte string."
  (unibyte-string (logand n #xff) (logand (ash n -8) #xff)))

(defsubst ubiquitty-sync--put-u32 (n)
  "Return N as a little-endian unsigned 32-bit unibyte string."
  (unibyte-string (logand n #xff)
                  (logand (ash n -8) #xff)
                  (logand (ash n -16) #xff)
                  (logand (ash n -24) #xff)))

;; ---- frame send ------------------------------------------------------

(cl-defstruct (ubiquitty-sync--handshake-request
               (:constructor ubiquitty-sync--make-handshake-request))
  columns rows client-instance resume (target ubiquitty-sync--admission-target-session)
  (session-id 0) (workspace-id 0) (expected-daemon 0) (workspace-name "")
  (ends-when-detached nil))

(defun ubiquitty-sync--send-greet (proc cols rows)
  "Send the single first-byte Greet for one COLS by ROWS request on PROC."
  (let ((request (ubiquitty-sync--make-handshake-request
                  :columns cols :rows rows
                  ;; A buffer `ubiquitty-sync' attached is this Emacs's window;
                  ;; any other greets as a fresh client.
                  :client-instance (if ubiquitty-sync--program
                                       (ubiquitty-sync--stored-client-instance)
                                     (apply #'unibyte-string (cl-loop repeat 16 collect (random 256))))
                  :resume ubiquitty-sync--resume-tail
                  ;; A resume asks for the session its pane is, and nothing
                  ;; new: a pane's identity is its session and its daemon.
                  :session-id (if (and ubiquitty-sync--resume-tail ubiquitty-sync--effect-pane)
                                  (ubiquitty-sync--u32 ubiquitty-sync--effect-pane 0)
                                0)
                  :expected-daemon (if (and ubiquitty-sync--resume-tail ubiquitty-sync--effect-pane)
                                       (ubiquitty-sync--u64 ubiquitty-sync--effect-pane 8)
                                     0))))
    (cl-incf ubiquitty-sync--connection-generation)
    (setq ubiquitty-sync--admission-request request
          ubiquitty-sync--client-instance (ubiquitty-sync--handshake-request-client-instance request))
    (ubiquitty-sync--send-sync proc ubiquitty-sync--kind-greet 0
                                (ubiquitty-sync--greet-body request))))

;; ---- frame receive (streaming decoder) -------------------------------

(defun ubiquitty-sync--envelope-header (bytes &optional offset)
  "Return (KIND CHANNEL BODY-LENGTH HEADER-LENGTH), or nil for a partial header.
Reject unknown kinds, wrong scope and noncanonical or oversized varints before
any body is retained. OFFSET permits a borrowed walk over complete input."
  (let ((at (or offset 0)) (start (or offset 0)) (size (length bytes)))
    (catch 'partial
      (when (= at size) (throw 'partial nil))
      (let ((kind (aref bytes at)) (values nil))
        (cl-incf at)
        (unless (memq kind ubiquitty-sync--known-kinds) (error "ubiquitty-sync: unknown envelope kind %d" kind))
        (dolist (bound (list (cons 5 ubiquitty-sync--max-channel)
                            (cons 3 ubiquitty-sync--max-frame-body)))
          (let ((value 0) (index 0) (done nil))
            (while (not done)
              (when (= at size) (throw 'partial nil))
              (let ((byte (aref bytes at)))
                (cl-incf at)
                (setq value (logior value (ash (logand byte 127) (* index 7))))
                (when (or (> value (cdr bound))
                          (and (= index (1- (car bound))) (>= byte 128)))
                  (error "ubiquitty-sync: oversized envelope varint"))
                (when (< byte 128)
                  (when (and (> index 0) (= (logand byte 127) 0))
                    (error "ubiquitty-sync: nonminimal envelope varint"))
                  (setq done t))
                (cl-incf index)))
            (when (and (= (car bound) 5)
                       (not (eq (= value 0) (not (null (memq kind ubiquitty-sync--connection-kinds))))))
              (error "ubiquitty-sync: wrong envelope scope"))
            (push value values)))
        (let ((channel (cadr values)) (length (car values)))
          (unless (eq (= channel 0) (not (null (memq kind ubiquitty-sync--connection-kinds))))
            (error "ubiquitty-sync: wrong envelope scope"))
          (list kind channel length (- at start)))))))

(defun ubiquitty-sync--admit-header (header)
  "Check HEADER against this carrier's admission before retaining its body."
  (let ((kind (nth 0 header)) (length (nth 2 header)))
    (when ubiquitty-sync--transport-closed (error "ubiquitty-sync: data after Bye"))
    (when (memq kind ubiquitty-sync--client-only-kinds)
      (error "ubiquitty-sync: kind %d from the host, which only a client sends" kind))
    (unless (or ubiquitty-sync--welcome
                (memq kind (list ubiquitty-sync--kind-welcome ubiquitty-sync--kind-bye)))
      (error "ubiquitty-sync: data before Welcome"))
    (when (and ubiquitty-sync--welcome (= kind ubiquitty-sync--kind-welcome))
      (error "ubiquitty-sync: duplicate Welcome"))
    (when (and ubiquitty-sync--welcome (= kind ubiquitty-sync--kind-pane-bind)
               (>= (plist-get ubiquitty-sync--welcome :target) ubiquitty-sync--admission-target-control))
      (error "ubiquitty-sync: PaneBind on an unbound target"))
    (when (and ubiquitty-sync--consent-phase (not (equal ubiquitty-sync--consent-phase "approved")))
      (unless (memq kind (list ubiquitty-sync--kind-probe ubiquitty-sync--kind-echo
                              ubiquitty-sync--kind-bye ubiquitty-sync--kind-notify))
        (error "ubiquitty-sync: data before own consent"))
      (when (or (and (= kind ubiquitty-sync--kind-notify)
                     (or (> length ubiquitty-sync--max-consent-status-bytes)
                         (member ubiquitty-sync--consent-phase '("denied" "expired"))))
                (and (= kind ubiquitty-sync--kind-probe) (/= length 8))
                (and (= kind ubiquitty-sync--kind-echo) (/= length 12)))
        (error "ubiquitty-sync: invalid pending-consent frame")))))

(cl-defstruct (ubiquitty-sync--envelope-state (:constructor ubiquitty-sync--make-envelope-state))
  (header "") info owner (filled 0))

(defun ubiquitty-sync--feed-envelopes (pending data consume)
  "Feed unibyte DATA with bounded partial owner PENDING; CONSUME each envelope.
The at-most-nine-byte header is admitted before one exact unibyte owner is
allocated. Body fragments fill that owner in place: constant metadata and
linear copying even for a stream delivered one byte at a time."
  (when (multibyte-string-p data) (error "ubiquitty-sync: nonbinary transport data"))
  (let ((at 0) (size (length data))
        (state (if (equal pending "") (ubiquitty-sync--make-envelope-state) pending)))
    (unless (ubiquitty-sync--envelope-state-p state) (error "ubiquitty-sync: invalid reader owner"))
    (while (< at size)
      (unless (ubiquitty-sync--envelope-state-info state)
        (when (>= (length (ubiquitty-sync--envelope-state-header state)) ubiquitty-sync--max-envelope-header)
          (error "ubiquitty-sync: oversized envelope header"))
        (setf (ubiquitty-sync--envelope-state-header state)
              (concat (ubiquitty-sync--envelope-state-header state) (substring data at (1+ at))))
        (cl-incf at)
        (let ((header (ubiquitty-sync--envelope-header (ubiquitty-sync--envelope-state-header state))))
          (when header
            (ubiquitty-sync--admit-header header)
            (let ((owner (make-string (+ (nth 2 header) (nth 3 header)) 0)))
              (store-substring owner 0 (ubiquitty-sync--envelope-state-header state))
              (setf (ubiquitty-sync--envelope-state-info state) header
                    (ubiquitty-sync--envelope-state-owner state) owner
                    (ubiquitty-sync--envelope-state-filled state) (nth 3 header))))))
      (when (ubiquitty-sync--envelope-state-info state)
        (let* ((owner (ubiquitty-sync--envelope-state-owner state))
               (filled (ubiquitty-sync--envelope-state-filled state))
               (count (min (- (length owner) filled) (- size at))))
          (when (> count 0)
            (store-substring owner filled (substring data at (+ at count)))
            (cl-incf at count)
            (cl-incf filled count)
            (setf (ubiquitty-sync--envelope-state-filled state) filled))
          (when (= filled (length owner))
            ;; Release the partial-state owner before the callback can retire it.
            (setf (ubiquitty-sync--envelope-state-header state) ""
                  (ubiquitty-sync--envelope-state-info state) nil
                  (ubiquitty-sync--envelope-state-owner state) nil
                  (ubiquitty-sync--envelope-state-filled state) 0)
            (funcall consume owner)))))
    (if (equal (ubiquitty-sync--envelope-state-header state) "") "" state)))

(defun ubiquitty-sync--filter (proc data)
  "Feed PROC's canonical stream without permitting recursive owner mutation.
A malformed record or same-carrier recursive feed permanently refuses that
carrier. A callback retiring/replacing its owner prevents the old read's tail
or cleanup from changing the new owner's state."
  (unless (process-get proc 'protocol-failure)
    (let* ((buf (process-get proc 'buffer))
           (owner (and (buffer-live-p buf) (buffer-local-value 'ubiquitty-sync--process buf)))
           (generation (and (buffer-live-p buf) (buffer-local-value 'ubiquitty-sync--connection-generation buf)))
           (ticket (list 'feeding)))
      (when (and (buffer-live-p buf) (or (null owner) (eq owner proc)))
        (cl-labels ((current-owner-p ()
                      (and (buffer-live-p buf)
                           (eq (buffer-local-value 'ubiquitty-sync--process buf) owner)
                           (= (buffer-local-value 'ubiquitty-sync--connection-generation buf) generation)))
                    (refuse (failure)
                      (process-put proc 'accum "")
                      (process-put proc 'protocol-failure failure)
                      (when (current-owner-p)
                        (with-current-buffer buf (ubiquitty-sync--reset-sample-connection)))
                      (delete-process proc)))
          (if (process-get proc 'feeding)
              (refuse "ubiquitty-sync: recursive transport feed")
            (process-put proc 'feeding ticket)
            (unwind-protect
                (with-current-buffer buf
                  (setq ubiquitty-sync--batch-dirty (make-bool-vector (length (or ubiquitty-sync--screen [])) nil))
                  (condition-case err
                      (process-put proc 'accum
                                   (catch 'carrier-closed
                                     (ubiquitty-sync--feed-envelopes
                                      (or (process-get proc 'accum) "") data
                                      (lambda (envelope)
                                        (ubiquitty-sync--receive-sync proc buf envelope)
                                        (unless (and (current-owner-p) (process-live-p proc)
                                                     (not (process-get proc 'protocol-failure))
                                                     (not ubiquitty-sync--transport-closed))
                                          (throw 'carrier-closed ""))))))
                    (error (refuse (error-message-string err)))))
              (when (eq (process-get proc 'feeding) ticket) (process-put proc 'feeding nil))
              (when (current-owner-p)
                (with-current-buffer buf (ubiquitty-sync--close-batch))
                (ubiquitty-sync--send-owed-ack proc buf)))))))))

(defun ubiquitty-sync--header-line (bytes)
  "The host title in BYTES as a header line that shows the title.
A mode-line construct reads %-constructs out of the string it is given, so a
title carrying one is the buffer name or the file name of whatever Emacs is
visiting rather than what the host sent; doubling the host's percent signs is
what makes the string stand for itself.  Control bytes go with them: a header
line is one line, and the title is what occupies it."
  (replace-regexp-in-string
   "%" "%%"
   (replace-regexp-in-string "[[:cntrl:]]" "" (decode-coding-string bytes 'utf-8) t t)
   t t))

;; ---- color resolution ------------------------------------------------

(defsubst ubiquitty-sync--hex8 (r g b)
  "Return the \"#RRGGBB\" string for 8-bit channels R, G and B."
  (format "#%02x%02x%02x" r g b))

(defun ubiquitty-sync--resolve-color (index r g b palette default-slot)
  "Resolve a Pen color to a hex string.
INDEX is the wire color index; R/G/B are the direct-RGB bytes;
PALETTE is the 259-entry color vector; DEFAULT-SLOT is the palette
index of the terminal default (256 fg, 257 bg)."
  (cond
   ((= index ubiquitty-sync--color-rgb) (ubiquitty-sync--hex8 r g b))
   ((= index ubiquitty-sync--color-default) (aref palette default-slot))
   ((< index 256) (aref palette index))
   (t (aref palette default-slot))))

;; ---- the screen model ------------------------------------------------
;;
;; The client holds the screen as it last drew it: a vector of rows, each a
;; vector of one-cell strings.  A checkpoint replaces it whole; an update
;; replaces the rows it names, and only those rows are laid out and inserted
;; again -- a keystroke costs one row and one line of the buffer, not the grid.  A wide glyph's
;; continuation cell is the empty string, so a row's text is the concatenation
;; of its cells and Emacs draws the lead glyph two columns wide.

(defun ubiquitty-sync--face-table (global-reverse)
  "Return the face table for GLOBAL-REVERSE, making the pair on first use.
A face is keyed by the pen bytes that decide it, so a screen of one style
builds it once; reverse video inverts every face, so it keeps its own table."
  (unless ubiquitty-sync--face-caches
    (setq ubiquitty-sync--face-caches
          (cons (make-hash-table :test #'equal) (make-hash-table :test #'equal))))
  (if global-reverse (cdr ubiquitty-sync--face-caches) (car ubiquitty-sync--face-caches)))

(defsubst ubiquitty-sync--proportional-spec-p (spec-id)
  "Whether SPEC-ID names a live text-size spec that is proportional."
  (and (> spec-id 0)
       (/= 0 (logand ubiquitty-sync--proportional-specs (ash 1 (1- spec-id))))))

(defun ubiquitty-sync--blank-cell (palette)
  "The cell string a scroll reveals: a space in PALETTE's default colours."
  (propertize " " 'face (list :foreground (aref palette 256)
                              :background (aref palette 257))))

(defun ubiquitty-sync--row-text (row attribute graphic)
  "Lay ROW out as one line of text under its DECDWL/DECDHL ATTRIBUTE.
GRAPHIC says whether the display can scale a face.  A double-width row shows
its first half, each cell followed by a space in the cell's colours; the top
row of a double-height pair is that at twice the face height on a graphical
display, and the bottom row is blank, its height folded into the top."
  (cond
   ((= attribute 0) (mapconcat #'identity row ""))
   ((and graphic (= attribute ubiquitty-sync--line-double-height-bottom)) "")
   (t
    (let ((visible (/ (length row) 2)) (parts nil) (k 0))
      (while (< k visible)
        (let ((cell (aref row k)))
          (unless (string-empty-p cell)
            (push cell parts)
            (push (propertize " " 'face (get-text-property 0 'face cell)) parts)))
        (setq k (1+ k)))
      (let ((text (apply #'concat (nreverse parts))))
        (when (and graphic (= attribute ubiquitty-sync--line-double-height-top))
          (add-face-text-property 0 (length text) '(:height 2.0) nil text))
        text)))))

(defun ubiquitty-sync--adopt-defaults (default-fg default-bg)
  "Remap the buffer's default face onto the host's DEFAULT-FG and DEFAULT-BG.
The column Emacs reserves for the truncation glyph then blends in the way
term.el's does.  Remapped only when the host's defaults change."
  (let ((colors (cons default-fg default-bg)))
    (unless (equal colors ubiquitty-sync--default-colors)
      (when ubiquitty-sync--face-cookie
        (face-remap-remove-relative ubiquitty-sync--face-cookie))
      (setq ubiquitty-sync--face-cookie
            (face-remap-add-relative 'default
                                     :foreground default-fg
                                     :background default-bg)
            ubiquitty-sync--default-colors colors))))

(defun ubiquitty-sync--place-cursor ()
  "Put point on the host's cursor cell and shape Emacs's cursor after it."
  (pcase-let ((`(,row ,column ,shape ,visible) ubiquitty-sync--cursor))
    (goto-char (point-min))
    (forward-line row)
    (let ((attribute (if (and ubiquitty-sync--line-attributes
                              (< row (length ubiquitty-sync--line-attributes)))
                         (aref ubiquitty-sync--line-attributes row)
                       0)))
      (move-to-column (if (= attribute 0) column (* 2 column))))
    (setq-local cursor-type
                (and visible (pcase shape (1 'hbar) (2 'bar) (_ 'box))))
    (let ((win (get-buffer-window (current-buffer) t)))
      (when win (set-window-point win (point))))))

(defun ubiquitty-sync--braille-svg (pattern width height foreground background)
  "Draw PATTERN's Unicode dots in WIDTH by HEIGHT pixels in the two colours.
FOREGROUND and BACKGROUND are hexadecimal RGB strings, not SVG markup."
  (let ((dots nil)
        (radius (min (/ width 8.0) (/ height 16.0))))
    ;; Unicode numbers the first three dots down each column, then the two
    ;; bottom dots.  Geometry belongs to the terminal cell, not a fallback font.
    (dotimes (bit 8)
      (when (/= 0 (logand pattern (ash 1 bit)))
        (let ((column (if (memq bit '(0 1 2 6)) 0 1))
              (row (aref [0 1 2 0 1 2 3 3] bit)))
          (push (format "<circle cx='%s' cy='%s' r='%s'/>"
                        (* (+ column 0.5) (/ width 2.0))
                        (* (+ row 0.5) (/ height 4.0)) radius)
                dots))))
    (format "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d'><rect width='%d' height='%d' fill='%s'/><g fill='%s'>%s</g></svg>"
            width height width height background foreground (apply #'concat (nreverse dots)))))

(defun ubiquitty-sync--braille-image (pattern width height foreground background)
  "Return a bounded cached image for PATTERN and its cell metrics and colours.
WIDTH and HEIGHT are measured pixels; FOREGROUND and BACKGROUND are RGB."
  (unless ubiquitty-sync--braille-renderings
    (setq ubiquitty-sync--braille-renderings (make-hash-table :test #'equal)))
  (let ((key (list pattern width height foreground background)))
    (or (gethash key ubiquitty-sync--braille-renderings)
        (progn
          (when (>= (hash-table-count ubiquitty-sync--braille-renderings) 256)
            (maphash (lambda (_ image) (image-flush image t)) ubiquitty-sync--braille-renderings)
            (clrhash ubiquitty-sync--braille-renderings))
          (puthash key (create-image (ubiquitty-sync--braille-svg pattern width height foreground background)
                                    'svg t :scale 1.0 :ascent 'center)
                   ubiquitty-sync--braille-renderings)))))

(defun ubiquitty-sync--decorate-braille-row (start end)
  "Keep every braille character between START and END on the terminal grid.
Fallback fonts can advance farther than one cell and raise the line height.
Display properties keep the original Unicode text and cell columns intact."
  (when (and (display-graphic-p) (image-type-available-p 'svg))
    (let ((width (default-font-width)) (height (default-font-height)))
      (when (and (> width 0) (<= width 256) (> height 0) (<= height 512))
        (save-excursion
          (goto-char start)
          (while (re-search-forward "[\u2800-\u28ff]" end t)
            (let* ((at (1- (point)))
                   (face (get-text-property at 'face))
                   (foreground (or (plist-get face :foreground) (face-foreground 'default nil t)))
                   (background (or (plist-get face :background) (face-background 'default nil t)))
                   (rgb (lambda (color)
                          (apply #'format "#%02x%02x%02x"
                                 (mapcar (lambda (value) (/ value 257)) (color-values color)))))
                   (image (ubiquitty-sync--braille-image (- (char-after at) #x2800) width height
                                                       (funcall rgb foreground) (funcall rgb background))))
              ;; Equal adjacent images still need distinct display objects:
              ;; one shared property value collapses a whole run to one image.
              (put-text-property at (point) 'display (copy-sequence image)))))))))

(defun ubiquitty-sync--decorate-row (row line-start line-end)
  "Lay image slices over the cells of ROW that placements cover.
LINE-START and LINE-END bound the row's text.  Each placement covering ROW
contributes one slice of its image, as tall as the row and as wide as the
cells it claims, on a graphical display with the image decoded."
  (when (and ubiquitty-sync--placements ubiquitty-sync--images (display-graphic-p))
    (let ((cell-width (default-font-width))
          (cell-height (default-font-height))
          (png-supported (image-type-available-p 'png)))
      (dolist (placement ubiquitty-sync--placements)
        (when-let* ((is-shown (or (null (nth 11 placement)) (= (nth 11 placement) ubiquitty-sync--active-screen)))
                    (image (gethash (car placement) ubiquitty-sync--images))
                    (layout (ubiquitty-sync--image-layout image placement cell-width cell-height)))
          (pcase-let ((`(,x ,y ,columns ,rows ,crop ,padded-width ,padded-height) layout))
            (when (and (<= y row) (< row (+ y rows)))
              (goto-char line-start)
              (move-to-column x)
              (let ((start (point)))
                (move-to-column (+ x columns))
                (let ((end (min (point) line-end)))
                  (when-let* ((visible-columns (- (current-column) x))
                              (rendering (and (< start end)
                                              (ubiquitty-sync--image-rendering
                                               (car placement) image crop padded-width padded-height png-supported))))
                    (put-text-property
                     start end 'display
                     (list (list 'slice 0.0 (/ (float (- row y)) rows)
                                 (/ (float visible-columns) columns) (/ 1.0 rows))
                           (create-image (cdr rendering) (car rendering) t :scale 1.0
                                         :width (* columns cell-width)
                                         :height (* rows cell-height)
                                         :ascent 'center)))))))))))))

(defun ubiquitty-sync--paint-rows (dirty)
  "Lay out and insert again every row DIRTY marks, then place the cursor.
The buffer already holds one line per row; a row that is not dirty is left
as it stands.  On a graphical display the newline ending a double-height
bottom row carries a near-zero line height, so the pair takes two rows.
Inside a batch the rows are only noted, and painted once when it closes."
  (if ubiquitty-sync--batch-dirty
      (unless (eq ubiquitty-sync--batch-dirty 'all)
        (if (= (length ubiquitty-sync--batch-dirty) (length dirty))
            (dotimes (row (length dirty))
              (when (aref dirty row) (aset ubiquitty-sync--batch-dirty row t)))
          (setq ubiquitty-sync--batch-dirty 'all)))
    (ubiquitty-sync--paint-rows-now dirty)))

(defun ubiquitty-sync--paint-blank ()
  "Cover the held screen without changing its cells."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize
             (mapconcat (lambda (_) (make-string ubiquitty-sync--screen-columns ?\s))
                        (append ubiquitty-sync--screen nil) "\n")
             'face '(:foreground "black" :background "black" :extend t)))
    (setq-local cursor-type nil)))

(defun ubiquitty-sync--paint-rows-now (dirty)
  "Lay out and insert again every row DIRTY marks, then place the cursor."
  (if ubiquitty-sync--crt-blanked
      (ubiquitty-sync--paint-blank)
    (let* ((inhibit-read-only t)
           (screen ubiquitty-sync--screen)
           (attributes ubiquitty-sync--line-attributes)
           (rows (length screen))
           (graphic (display-graphic-p)))
      (goto-char (point-min))
      (dotimes (row rows)
        (let ((line-start (point)))
          (if (aref dirty row)
              (progn
                (delete-region line-start (line-end-position))
                (insert (ubiquitty-sync--row-text (aref screen row) (aref attributes row) graphic))
                (let ((line-end (point)))
                  (when (= (aref attributes row) 0)
                    (ubiquitty-sync--decorate-braille-row line-start line-end))
                  (ubiquitty-sync--decorate-row row line-start line-end)
                  (goto-char line-end)))
            (end-of-line)))
        (when (< row (1- rows))
          (unless (eq (char-after) ?\n) (insert "\n") (backward-char 1))
          (if (and graphic (= (aref attributes row) ubiquitty-sync--line-double-height-bottom))
              (put-text-property (point) (1+ (point)) 'line-height 0.05)
            (remove-text-properties (point) (1+ (point)) '(line-height nil)))
          (forward-char 1)))
      (ubiquitty-sync--place-cursor))))

(defun ubiquitty-sync--paint-all ()
  "Replace the buffer with the screen, or record the paint for the batch."
  (if ubiquitty-sync--batch-dirty
      (setq ubiquitty-sync--batch-dirty 'all)
    (let ((inhibit-read-only t)
          (rows (length ubiquitty-sync--screen)))
      (erase-buffer)
      (when (> rows 1) (insert (make-string (1- rows) ?\n)))
      (ubiquitty-sync--paint-rows-now (make-bool-vector rows t)))))

(defun ubiquitty-sync--close-batch ()
  "Paint what the batch noted, once."
  (let ((owed ubiquitty-sync--batch-dirty))
    (setq ubiquitty-sync--batch-dirty nil)
    (cond
     ((null ubiquitty-sync--screen) nil)
     ((eq owed 'all) (ubiquitty-sync--paint-all))
     ((and owed (> (length owed) 0))
      (when (seq-some #'identity owed)
        (ubiquitty-sync--paint-rows-now owed))))))

;; ---- Sync primitives -------------------------------------------------
;;
;; The screen arrives on the Sync screen plane (Docs/sync.md section 7):
;; direct envelopes, `kind:u8 channel:varint length:varint body'.
;; A reader is a vector [STRING OFFSET END]; every read checks the end, so a
;; body that is shorter than its fields claim signals rather than reading the
;; next frame's bytes as this one's.

(defun ubiquitty-sync--reader (s &optional start end)
  "A reader over S from START to END."
  (vector s (or start 0) (or end (length s))))

(defun ubiquitty-sync--take (r n)
  "Advance reader R past N bytes, returning the offset they start at."
  (let ((at (aref r 1)))
    (when (> (+ at n) (aref r 2))
      (error "ubiquitty-sync: a Sync body ends at %d, a field runs to %d" (aref r 2) (+ at n)))
    (aset r 1 (+ at n))
    at))

(defun ubiquitty-sync--r-u8 (r) "Read a byte from R." (aref (aref r 0) (ubiquitty-sync--take r 1)))
(defun ubiquitty-sync--r-u16 (r) "Read a u16 from R." (ubiquitty-sync--u16 (aref r 0) (ubiquitty-sync--take r 2)))
(defun ubiquitty-sync--r-u32 (r) "Read a u32 from R." (ubiquitty-sync--u32 (aref r 0) (ubiquitty-sync--take r 4)))
(defun ubiquitty-sync--r-u64 (r) "Read a u64 from R." (ubiquitty-sync--u64 (aref r 0) (ubiquitty-sync--take r 8)))

(defun ubiquitty-sync--r-varint (r)
  "Read an unsigned LEB128 of at most ten bytes from R."
  (let ((value 0) (shift 0) (more t))
    (while more
      (when (>= shift 70)
        (error "ubiquitty-sync: a varint runs past ten bytes"))
      (let ((b (ubiquitty-sync--r-u8 r)))
        (setq value (logior value (ash (logand b #x7f) shift))
              shift (+ shift 7)
              more (/= 0 (logand b #x80)))))
    value))

(defun ubiquitty-sync--r-svarint (r)
  "Read a zigzag LEB128 from R."
  (let ((v (ubiquitty-sync--r-varint r)))
    (if (= 0 (logand v 1)) (ash v -1) (- -1 (ash v -1)))))

(defun ubiquitty-sync--r-bytes (r)
  "Read a varint-length byte run from R, as a unibyte string."
  (let* ((length (ubiquitty-sync--r-varint r))
         (at (ubiquitty-sync--take r length)))
    (substring (aref r 0) at (+ at length))))

(defun ubiquitty-sync--r-end-p (r) "Whether R has read every byte." (= (aref r 1) (aref r 2)))

(defun ubiquitty-sync--read-image-asset (r)
  "Read and bound an image ASSET from R as [HASH FORMAT WIDTH HEIGHT BYTES]."
  (let* ((at (ubiquitty-sync--take r 16))
         (hash (substring (aref r 0) at (+ at 16)))
         (format (ubiquitty-sync--r-u8 r))
         (width (ubiquitty-sync--r-u32 r))
         (height (ubiquitty-sync--r-u32 r))
         (bytes (* width height (/ format 8))))
    (unless (and (memq format '(24 32)) (> width 0) (> height 0)
                 (<= width ubiquitty-sync--max-image-dimension)
                 (<= height ubiquitty-sync--max-image-dimension)
                 (<= bytes ubiquitty-sync--max-image-bytes))
      (error "ubiquitty-sync: invalid decoded image dimensions or format"))
    (vector hash format width height bytes)))

(defun ubiquitty-sync--read-image-head (body)
  "Read the whole ImageHead BODY as (ASSET . TRANSFER)."
  (let* ((r (ubiquitty-sync--reader body))
         (asset (ubiquitty-sync--read-image-asset r))
         (transfer (ubiquitty-sync--r-u32 r)))
    (unless (ubiquitty-sync--r-end-p r) (error "ubiquitty-sync: trailing ImageHead bytes"))
    (cons asset transfer)))

(defun ubiquitty-sync--read-image-placements (body)
  "Validate a whole image replacement BODY before publishing any of it."
  (let* ((r (ubiquitty-sync--reader body))
         (revision (ubiquitty-sync--r-u32 r))
         (images (make-hash-table))
         (assets (make-hash-table :test #'equal))
         (placements nil))
    (cl-labels ((count (maximum stride)
                 (let* ((start (aref r 1)) (n (ubiquitty-sync--r-varint r)))
                   (unless (and (<= n maximum) (<= (* n stride) (- (aref r 2) (aref r 1)))
                                (= (- (aref r 1) start) (if (< n 128) 1 2)))
                     (error "ubiquitty-sync: invalid image record count"))
                   n))
                (flag ()
                  (let ((value (ubiquitty-sync--r-u8 r)))
                    (when (> value 1) (error "ubiquitty-sync: unknown image flag"))
                    value)))
      (when (= revision 0) (error "ubiquitty-sync: zero image revision"))
      (dotimes (_ (count ubiquitty-sync--max-image-count ubiquitty-sync--image-binding-record-bytes))
        (let ((id (ubiquitty-sync--r-u32 r)) (start (aref r 1)))
          (ubiquitty-sync--take r 4) ; program image number
          (let ((asset (ubiquitty-sync--read-image-asset r)))
            (flag)
            (ubiquitty-sync--take r 8) ; virtual columns, rows, placement ID
            (unless (= (- (aref r 1) start) (- ubiquitty-sync--image-binding-record-bytes 4))
              (error "ubiquitty-sync: an image binding is not the host's record length"))
            (when (or (= id 0) (gethash id images)
                      (let ((previous (gethash (aref asset 0) assets)))
                        (and previous (not (equal previous asset)))))
              (error "ubiquitty-sync: inconsistent image binding"))
            (puthash id asset images)
            (puthash (aref asset 0) asset assets))))
      (dotimes (_ (count ubiquitty-sync--max-image-placements ubiquitty-sync--image-placement-record-bytes))
        (let* ((at (ubiquitty-sync--take r 16))
               (hash (substring body at (+ at 16)))
               (id (ubiquitty-sync--r-u32 r)))
          (ubiquitty-sync--take r 4) ; placement ID
          (flag)
          (let* ((x (ubiquitty-sync--r-u16 r))
                 (raw-y (ubiquitty-sync--r-u16 r))
                 (y (if (>= raw-y 32768) (- raw-y 65536) raw-y))
                 (columns (ubiquitty-sync--r-u16 r))
                 (rows (ubiquitty-sync--r-u16 r))
                 (offset-x (ubiquitty-sync--r-u16 r))
                 (offset-y (ubiquitty-sync--r-u16 r))
                 (source-x (ubiquitty-sync--r-u16 r))
                 (source-y (ubiquitty-sync--r-u16 r))
                 (source-width (ubiquitty-sync--r-u16 r))
                 (source-height (ubiquitty-sync--r-u16 r))
                 (drawn-width (ubiquitty-sync--r-u16 r))
                 (drawn-height (ubiquitty-sync--r-u16 r)))
            (ubiquitty-sync--take r 4) ; z-index
            (flag) ; cursor policy
            (let ((alternate (flag)) (asset (gethash id images)))
              (unless (= (- (aref r 1) at) ubiquitty-sync--image-placement-record-bytes)
                (error "ubiquitty-sync: an image placement is not the host's record length"))
              (unless (eq (= drawn-width 0) (= drawn-height 0))
                (error "ubiquitty-sync: a placement states half a drawn size"))
              (unless (and asset (equal (aref asset 0) hash))
                (error "ubiquitty-sync: placement names an absent image"))
              (push (list id x y columns rows offset-x offset-y source-x source-y source-width source-height
                          alternate drawn-width drawn-height)
                    placements)))))
      (unless (ubiquitty-sync--r-end-p r) (error "ubiquitty-sync: trailing ImagePlacements bytes")))
    (list :revision revision :images images :assets assets :placements (nreverse placements))))

(defun ubiquitty-sync--image-prefix (asset)
  "The 25-byte domain and canonical metadata before ASSET's decoded pixels."
  (concat "Ubiquitty.Image\0" (unibyte-string (aref asset 1))
          (ubiquitty-sync--put-u32 (aref asset 2)) (ubiquitty-sync--put-u32 (aref asset 3))))

(defun ubiquitty-sync--reset-image-connection ()
  "Retire all image state when the selected pane or attachment is replaced."
  (setq ubiquitty-sync--image-state nil
        ubiquitty-sync--image-cache (make-hash-table :test #'equal)
        ubiquitty-sync--image-offers (make-hash-table :test #'equal)
        ubiquitty-sync--image-wants (make-hash-table :test #'equal)
        ubiquitty-sync--image-transfers (make-hash-table)
        ubiquitty-sync--images nil ubiquitty-sync--placements nil
        ubiquitty-sync--image-renderings nil ubiquitty-sync--image-rendering-bytes 0))

(defun ubiquitty-sync--image-owned-bytes ()
  "Return (PENDING-CAPACITY . RETAINED-PIXELS), counting shared assets once.
Pending capacity includes sample owners and deferred effect bodies."
  (let ((pending (+ ubiquitty-sync--deferred-effect-bytes ubiquitty-sync--clipboard-pending-bytes
                    ubiquitty-sync--effect-delivering-bytes)) (pixels 0))
    (when ubiquitty-sync--sample-transfers
      (maphash (lambda (_ sample) (cl-incf pending (length (aref sample 3)))) ubiquitty-sync--sample-transfers))
    (when ubiquitty-sync--image-cache
      (maphash (lambda (_ image) (cl-incf pixels (- (length (nth 3 image)) (nth 4 image))))
               ubiquitty-sync--image-cache))
    (when ubiquitty-sync--image-transfers
      (maphash (lambda (_ transfer)
                 (when (aref transfer 1)
                   (cl-incf pending (length (aref transfer 1)))
                   (cl-incf pixels (aref (aref transfer 0) 4))))
               ubiquitty-sync--image-transfers))
    (cons pending pixels)))

(defun ubiquitty-sync--image-in-flight-p (hash)
  "Whether HASH still owns a transfer or bounded discard fence."
  (let ((found nil))
    (when ubiquitty-sync--image-transfers
      (maphash (lambda (_ transfer) (when (equal (aref (aref transfer 0) 0) hash) (setq found t)))
               ubiquitty-sync--image-transfers))
    found))

(defun ubiquitty-sync--request-missing-images (proc)
  "Request only offered, uncached pixels of this buffer's current pane on PROC."
  (when (and ubiquitty-sync--pane ubiquitty-sync--image-state)
    (maphash
     (lambda (hash asset)
       (let ((held (ubiquitty-sync--image-owned-bytes)))
         (when (and (equal asset (gethash hash (plist-get ubiquitty-sync--image-state :assets)))
                    (not (gethash hash ubiquitty-sync--image-cache))
                    (not (gethash hash ubiquitty-sync--image-wants))
                    (not (ubiquitty-sync--image-in-flight-p hash))
                    (< (+ (hash-table-count ubiquitty-sync--image-wants)
                          (hash-table-count ubiquitty-sync--image-transfers)) ubiquitty-sync--max-image-count)
                    (<= (+ (car held) 25 (aref asset 4)) ubiquitty-sync--retained-asset-budget)
                    (<= (+ (cdr held) (aref asset 4)) ubiquitty-sync--image-pixel-budget))
           (puthash hash t ubiquitty-sync--image-wants)
           (ubiquitty-sync--send-sync proc ubiquitty-sync--kind-image-want ubiquitty-sync--pane hash))))
     ubiquitty-sync--image-offers)))

(defun ubiquitty-sync--show-image-state ()
  "Bind cached content to current image IDs without copying or rehashing pixels."
  (setq ubiquitty-sync--images (make-hash-table)
        ubiquitty-sync--placements (plist-get ubiquitty-sync--image-state :placements)
        ubiquitty-sync--image-renderings nil ubiquitty-sync--image-rendering-bytes 0)
  (maphash (lambda (id asset)
             (when-let* ((image (gethash (aref asset 0) ubiquitty-sync--image-cache)))
               (puthash id image ubiquitty-sync--images)))
           (plist-get ubiquitty-sync--image-state :images))
  (when ubiquitty-sync--screen (ubiquitty-sync--paint-all)))

(defun ubiquitty-sync--take-image-placements (proc buf body)
  "Replace BUF's image metadata from BODY, requesting missing offered pixels on PROC."
  (with-current-buffer buf
    (let ((state (ubiquitty-sync--read-image-placements body)))
      (when (> (plist-get state :revision) (or (plist-get ubiquitty-sync--image-state :revision) 0))
        (let ((assets (plist-get state :assets)))
          (dolist (table (list ubiquitty-sync--image-cache ubiquitty-sync--image-offers ubiquitty-sync--image-wants))
            (let ((dead nil))
              (maphash (lambda (hash _value) (unless (gethash hash assets) (push hash dead))) table)
              (dolist (hash dead) (remhash hash table)))))
        (let ((dead nil))
          (maphash (lambda (hash image)
                     (let ((asset (gethash hash (plist-get state :assets))))
                       (unless (and (= (nth 0 image) (aref asset 2)) (= (nth 1 image) (aref asset 3))
                                    (= (nth 2 image) (aref asset 1)))
                         (push hash dead))))
                   ubiquitty-sync--image-cache)
          (dolist (hash dead) (remhash hash ubiquitty-sync--image-cache)))
        (maphash (lambda (_ transfer)
                   (let ((asset (aref transfer 0)))
                     (unless (equal asset (gethash (aref asset 0) (plist-get state :assets)))
                       (aset transfer 1 nil))))
                 ubiquitty-sync--image-transfers)
        (setq ubiquitty-sync--image-state state)
        (ubiquitty-sync--show-image-state)
        (ubiquitty-sync--request-missing-images proc)))))

(defun ubiquitty-sync--take-image-head (proc buf body)
  "Take an offer or exact-sized raw image transfer announced by BODY on PROC for BUF."
  (with-current-buffer buf
    (pcase-let* ((`(,asset . ,transfer) (ubiquitty-sync--read-image-head body))
                (hash (aref asset 0)))
      (unless (and ubiquitty-sync--image-state
                   (equal asset (gethash hash (plist-get ubiquitty-sync--image-state :assets))))
        (error "ubiquitty-sync: ImageHead names an absent asset"))
      (puthash hash asset ubiquitty-sync--image-offers)
      (if (= transfer 0)
          (ubiquitty-sync--request-missing-images proc)
        (remhash hash ubiquitty-sync--image-wants)
        (when (or (gethash transfer ubiquitty-sync--image-transfers)
                  (and ubiquitty-sync--sample-transfers (gethash transfer ubiquitty-sync--sample-transfers))
                  (and ubiquitty-sync--clipboard-transfers (gethash transfer ubiquitty-sync--clipboard-transfers))
                  (assq transfer ubiquitty-sync--transfers)
                  (and ubiquitty-sync--pending-checkpoint (= transfer (cdr ubiquitty-sync--pending-checkpoint)))
                  (>= (+ (hash-table-count ubiquitty-sync--image-transfers)
                         (hash-table-count ubiquitty-sync--image-wants)) ubiquitty-sync--max-image-count))
          (error "ubiquitty-sync: too many or repeated image transfers"))
        (let* ((held (ubiquitty-sync--image-owned-bytes))
               (owner (and (not (gethash hash ubiquitty-sync--image-cache))
                           (not (ubiquitty-sync--image-in-flight-p hash))
                           (<= (+ (car held) 25 (aref asset 4)) ubiquitty-sync--retained-asset-budget)
                           (<= (+ (cdr held) (aref asset 4)) ubiquitty-sync--image-pixel-budget)
                           (make-string (+ 25 (aref asset 4)) 0))))
          (when owner
            (when (multibyte-string-p owner) (error "ubiquitty-sync: image owner must be unibyte"))
            (store-substring owner 0 (ubiquitty-sync--image-prefix asset)))
          (puthash transfer (vector asset owner 0 0) ubiquitty-sync--image-transfers))))))

(defun ubiquitty-sync--take-image-chunk (proc transfer index last bytes sha256)
  "Take a raw image chunk, retaining its exact owner through verification.
PROC receives a missing-only request after a completed or discarded transfer.
TRANSFER, INDEX, LAST, BYTES and SHA256 are the decoded BulkChunk fields."
  (when-let* ((held (gethash transfer ubiquitty-sync--image-transfers)))
    (let* ((asset (aref held 0)) (owner (aref held 1))
           (received (aref held 2)) (after (+ received (length bytes))))
      (unless (and (= index (aref held 3)) (> (length bytes) 0) (<= after (aref asset 4))
                   (or (= last 0) (= after (aref asset 4))))
        (remhash transfer ubiquitty-sync--image-transfers)
        (error "ubiquitty-sync: invalid raw image chunk"))
      (when owner (store-substring owner (+ 25 received) bytes))
      (aset held 2 after)
      (aset held 3 (1+ index))
      (when (= last 1)
        (when owner
          (unless (and (equal (secure-hash 'sha256 owner 25 nil t) sha256)
                       (equal (substring (secure-hash 'sha256 owner nil nil t) 0 16) (aref asset 0)))
            (remhash transfer ubiquitty-sync--image-transfers)
            (error "ubiquitty-sync: image pixels fail their transfer or content digest")))
        (remhash transfer ubiquitty-sync--image-transfers)
        (when (and owner ubiquitty-sync--image-state
                   (equal asset (gethash (aref asset 0) (plist-get ubiquitty-sync--image-state :assets))))
          (puthash (aref asset 0) (list (aref asset 2) (aref asset 3) (aref asset 1) owner 25) ubiquitty-sync--image-cache)
          (ubiquitty-sync--show-image-state))
        (ubiquitty-sync--request-missing-images proc)))
    t))

(defvar-local ubiquitty-sync--pane-facts nil
  "The whole facts record of this buffer's bound pane, or nil before one arrives.")

(defun ubiquitty-sync--read-pane-facts (body)
  "Read all of PaneFacts BODY before publishing any of its title inputs.
Unused fields are checked too; text bounds come from the host's headers."
  (let ((r (ubiquitty-sync--reader body)))
    (cl-labels
        ((text (maximum)
           (let ((length (ubiquitty-sync--r-varint r)))
             (when (> length maximum) (error "ubiquitty-sync: PaneFacts text exceeds its limit"))
             (let ((at (ubiquitty-sync--take r length))) (substring body at (+ at length)))))
         (flags (known)
           (let ((value (ubiquitty-sync--r-u8 r)))
             (when (> value known) (error "ubiquitty-sync: unknown PaneFacts flag"))
             value))
         (signed32 ()
           (let ((value (ubiquitty-sync--r-svarint r)))
             (unless (<= (- (expt 2 31)) value (1- (expt 2 31)))
               (error "ubiquitty-sync: PaneFacts integer exceeds int32")))))
      (let* ((revision (ubiquitty-sync--r-u32 r))
             (title (text ubiquitty-sync--max-title-bytes))
             (directory (text ubiquitty-sync--max-directory-bytes)))
        (text ubiquitty-sync--max-home-bytes)
        (text ubiquitty-sync--max-file-url-bytes)
        (text ubiquitty-sync--max-process-chain-bytes)
        (text ubiquitty-sync--max-process-arguments-bytes)
        (dotimes (_ 3) (text ubiquitty-sync--max-process-name-bytes))
        (ubiquitty-sync--take r 4) ; rows, columns
        (flags 7) ; ended, has status, signalled
        (signed32)
        (ubiquitty-sync--take r 4) ; foreground pid
        (let ((foreground (text ubiquitty-sync--max-process-name-bytes)))
          (ubiquitty-sync--take r 4) ; foreground generation
          (let* ((pane (flags 63))
                 (progress (ubiquitty-sync--r-u8 r))
                 (percent (ubiquitty-sync--r-u8 r)))
            (when (or (> progress ubiquitty-sync--max-progress-state) (> percent 100))
              (error "ubiquitty-sync: invalid PaneFacts progress"))
            (unless (zerop (logand pane 2))
              (ubiquitty-sync--take r 3) (text ubiquitty-sync--max-indicator-bytes))
            (unless (zerop (logand pane 4)) (ubiquitty-sync--take r 3))
            (text ubiquitty-sync--max-badge-bytes)
            (let ((count (ubiquitty-sync--r-varint r)) (names nil))
              (when (> count ubiquitty-sync--max-user-variables) (error "ubiquitty-sync: too many PaneFacts variables"))
              (dotimes (_ count)
                (let ((name (text ubiquitty-sync--max-user-name-bytes)))
                  (when (or (equal name "") (member name names))
                    (error "ubiquitty-sync: duplicate or empty PaneFacts variable"))
                  (push name names)
                  (text ubiquitty-sync--max-user-value-bytes))))
            (unless (zerop (logand pane 8)) (signed32))
            (ubiquitty-sync--take r 8) ; pixel dimensions
            (let ((geometry (flags 15)))
              (unless (zerop (logand geometry 1)) (ubiquitty-sync--take r 16))
              (unless (zerop (logand geometry 8))
                (when (zerop (logand geometry 2)) (error "ubiquitty-sync: PaneFacts pin without a pin state"))
                (ubiquitty-sync--take r 16)))
            (ubiquitty-sync--take r 24) ; last output, last input, creation
            (let* ((attention (flags 3))
                   (notification-title (text ubiquitty-sync--max-attention-bytes))
                   (message (text ubiquitty-sync--max-attention-bytes)))
              (when (and (zerop (logand attention 2))
                         (or (not (equal notification-title "")) (not (equal message ""))))
                (error "ubiquitty-sync: PaneFacts notification text without a notification")))
            (unless (ubiquitty-sync--r-end-p r) (error "ubiquitty-sync: trailing PaneFacts bytes"))
            (list :revision revision :title title :directory directory :foreground foreground
                  :at-prompt (not (zerop (logand pane 1))))))))))

(defun ubiquitty-sync--put-u64 (n)
  "Return N as a little-endian unsigned 64-bit unibyte string."
  (concat (ubiquitty-sync--put-u32 (logand n #xffffffff))
          (ubiquitty-sync--put-u32 (logand (ash n -32) #xffffffff))))

(defun ubiquitty-sync--put-varint (n)
  "Return N as an unsigned LEB128 unibyte string."
  (let ((bytes nil))
    (while (>= n #x80)
      (push (logior #x80 (logand n #x7f)) bytes)
      (setq n (ash n -7)))
    (push n bytes)
    (apply #'unibyte-string (nreverse bytes))))

(defun ubiquitty-sync--send-sync (proc kind channel body)
  "Send one canonical envelope of KIND on CHANNEL carrying BODY."
  (when (> (length body) ubiquitty-sync--max-frame-body)
    (error "ubiquitty-sync: a Sync body of %d bytes, past the %d one frame carries"
           (length body) ubiquitty-sync--max-frame-body))
  (when (and (not ubiquitty-sync--transport-closed) (process-live-p proc))
    (process-send-string proc (concat (unibyte-string kind)
                                      (ubiquitty-sync--put-varint channel)
                                      (ubiquitty-sync--put-varint (length body)) body))))

(defun ubiquitty-sync--greet-body (request)
  "The Greet a human client sends for REQUEST.
The fingerprint is the wire's these tables were written at, which a host of
another build refuses; the client instance is this Emacs's, kept across
restarts; the facts
name the viewport and leave the pixel sizes unknown.
The client keeps no history, so the host sends it none."
  (let ((target (ubiquitty-sync--handshake-request-target request))
        (session (ubiquitty-sync--handshake-request-session-id request))
        (workspace (ubiquitty-sync--handshake-request-workspace-id request))
        (daemon (ubiquitty-sync--handshake-request-expected-daemon request))
        (name (ubiquitty-sync--handshake-request-workspace-name request))
        (instance (ubiquitty-sync--handshake-request-client-instance request)))
    (unless (and (integerp target) (<= 0 target ubiquitty-sync--admission-target-management)
                 (cl-every (lambda (id) (and (integerp id) (<= 0 id #xffffffff))) (list session workspace))
                 (integerp daemon) (<= 0 daemon #xffffffffffffffff)
                 (stringp instance) (= (length instance) 16) (not (multibyte-string-p instance))
                 (stringp name) (not (string-match-p "\0" name))
                 (cl-every (lambda (scalar) (and (<= scalar #x10ffff) (not (<= #xd800 scalar #xdfff)))) name)
                 (<= (string-bytes (encode-coding-string name 'utf-8 t)) ubiquitty-sync--max-workspace-name-bytes)
                 (cond ((= target ubiquitty-sync--admission-target-session) (= workspace 0))
                       ((= target ubiquitty-sync--admission-target-workspace) t)
                       (t (and (= session 0) (= workspace 0) (equal name "")
                               (not (ubiquitty-sync--handshake-request-ends-when-detached request))))))
      (error "ubiquitty-sync: invalid admission request")))
  (concat (ubiquitty-sync--put-u16 ubiquitty-sync--wire-version)
          (ubiquitty-sync--put-bytes "")         ; appVersion: not an app build
          ubiquitty-sync--wire-fingerprint
          (ubiquitty-sync--handshake-request-client-instance request)
          (unibyte-string ubiquitty-sync--client-kind-human ubiquitty-sync--role-owner)
          (unibyte-string (ubiquitty-sync--handshake-request-target request))
          (ubiquitty-sync--put-u32 (ubiquitty-sync--handshake-request-session-id request))
          (ubiquitty-sync--put-u32 (ubiquitty-sync--handshake-request-workspace-id request))
          (ubiquitty-sync--put-u64 (ubiquitty-sync--handshake-request-expected-daemon request))
          (ubiquitty-sync--put-bytes (encode-coding-string
                                    (ubiquitty-sync--handshake-request-workspace-name request) 'utf-8 t))
          (ubiquitty-sync--put-bytes "")         ; agentLabel
          (ubiquitty-sync--put-bytes "")         ; sshHost
          (unibyte-string (if (or (> (ubiquitty-sync--handshake-request-session-id request) 0)
                                 (> (ubiquitty-sync--handshake-request-workspace-id request) 0)) 1 0)
                          (if (ubiquitty-sync--handshake-request-ends-when-detached request) 1 0)
                          0 0)                 ; no clipboard service or credential
          (ubiquitty-sync--put-u16 (ubiquitty-sync--handshake-request-rows request))
          (ubiquitty-sync--put-u16 (ubiquitty-sync--handshake-request-columns request))
          (make-string 8 0)                     ; cell and text-area pixels
          (ubiquitty-sync--put-u32 0)           ; no refresh cap
          (unibyte-string 0 0 1)                ; unmetered, normal power, focused
          (ubiquitty-sync--put-u32 0)           ; no history lines kept
          (ubiquitty-sync--put-u32 0)           ; and none backfilled
          ;; The echo context, and that no consent question is shown here, so
          ;; a host asks it none.
          (ubiquitty-sync--put-varint (logior ubiquitty-sync--capability-echo-context
                                              ubiquitty-sync--capability-shows-no-questions))
          ;; The stored attachment's resume, as Core wrote it, or none.
          (or (ubiquitty-sync--handshake-request-resume request) (unibyte-string 0))))

(defun ubiquitty-sync--r-text (reader maximum)
  "Read strict UTF-8 text without NUL and at most MAXIMUM bytes."
  (let* ((before (aref reader 1)) (size (ubiquitty-sync--r-varint reader))
         (_bound (unless (and (<= size maximum)
                              (= (- (aref reader 1) before) (length (ubiquitty-sync--put-varint size))))
                   (error "ubiquitty-sync: invalid text length")))
         (at (ubiquitty-sync--take reader size))
         (bytes (substring (aref reader 0) at (+ at size)))
         (text (decode-coding-string bytes 'utf-8)))
    (unless (and (<= (length bytes) maximum) (not (string-match-p "\0" bytes))
                 (cl-every (lambda (scalar) (and (<= scalar #x10ffff) (not (<= #xd800 scalar #xdfff)))) text)
                 (equal bytes (encode-coding-string text 'utf-8 t)))
      (error "ubiquitty-sync: invalid wire text"))
    text))

(defun ubiquitty-sync--read-bye (body)
  "Read the exact canonical Bye, retaining optional peer metadata for diagnostics."
  (when (> (length body) ubiquitty-sync--max-frame-body) (error "ubiquitty-sync: oversized Bye"))
  (let* ((r (ubiquitty-sync--reader body)) (reason (ubiquitty-sync--r-u8 r))
         (detail (ubiquitty-sync--r-text r ubiquitty-sync--max-frame-body))
         (present (ubiquitty-sync--r-u8 r)) (peer nil))
    (unless (and (< reason (length ubiquitty-sync--bye-reasons)) (memq present '(0 1)))
      (error "ubiquitty-sync: invalid Bye"))
    (when (= present 1)
      (let ((version (ubiquitty-sync--r-u16 r)))
        (unless (> version 0) (error "ubiquitty-sync: invalid peer version"))
        (setq peer (list :version version
                         :app-version (ubiquitty-sync--r-text r ubiquitty-sync--max-app-version-bytes)
                         :platform (ubiquitty-sync--r-text r ubiquitty-sync--max-host-platform-bytes)))))
    (unless (ubiquitty-sync--r-end-p r) (error "ubiquitty-sync: trailing Bye bytes"))
    (list :reason (aref ubiquitty-sync--bye-reasons reason) :detail detail :peer peer)))

(defun ubiquitty-sync--r-count (reader maximum)
  "Read a bounded canonical count without retaining records first."
  (let* ((before (aref reader 1)) (count (ubiquitty-sync--r-varint reader)))
    (unless (and (<= count maximum)
                 (= (- (aref reader 1) before) (length (ubiquitty-sync--put-varint count))))
      (error "ubiquitty-sync: invalid bounded count"))
    count))

;; ---- Sync handshake tail, input and facts -------------------------------
;;
;; What a client does travels as numbered events on its pane's handle
;; (Docs/sync.md section 6.7): one count per pane, from 1, shared by every
;; input kind, which the host writes in order and reports back as
;; inputWritten.  A named key goes as Keys and a mouse event as Pointer, both
;; encoded on the host under the modes live when it writes them; a character
;; goes as Raw; a paste goes as Paste pieces, which the host brackets and
;; normalises itself.

(defun ubiquitty-sync--put-bytes (bytes)
  "BYTES behind their varint length."
  (concat (ubiquitty-sync--put-varint (length bytes)) bytes))

(defun ubiquitty-sync--read-welcome (body)
  "The current Welcome BODY as a plist, with every mandatory field checked."
  (when (> (length body) ubiquitty-sync--max-frame-body) (error "ubiquitty-sync: oversized Welcome"))
  (let* ((r (ubiquitty-sync--reader body))
         (version (ubiquitty-sync--r-u16 r))
         (app-version (ubiquitty-sync--r-text r ubiquitty-sync--max-app-version-bytes))
         (_fingerprint (ubiquitty-sync--take r 32))
         (host-instance (ubiquitty-sync--take r 16))
         (attachment (ubiquitty-sync--take r 16))
         (resume-secret (ubiquitty-sync--take r 16))
         (role (ubiquitty-sync--r-u8 r))
         (target (ubiquitty-sync--r-u8 r))
         (session-id (ubiquitty-sync--r-u32 r))
         (workspace-id (ubiquitty-sync--r-u32 r))
         (daemon (ubiquitty-sync--r-u64 r))
         (socket (ubiquitty-sync--r-text r ubiquitty-sync--max-daemon-socket-name-bytes))
         (build-flags (ubiquitty-sync--r-u8 r))
         (platform (ubiquitty-sync--r-text r ubiquitty-sync--max-host-platform-bytes))
         ;; The instance a workspace recreated from its record was restored
         ;; from: zero for a live selection.
         (restored (ubiquitty-sync--r-u64 r))
         (admission (ubiquitty-sync--r-u8 r))
         (question (ubiquitty-sync--r-u32 r))
         (session (ubiquitty-sync--r-u32 r))
         (principal (ubiquitty-sync--r-text r ubiquitty-sync--max-frame-body))
         (_max-calls (ubiquitty-sync--r-u16 r))
         (_max-bulk (ubiquitty-sync--r-u32 r))
         (_max-ranges (ubiquitty-sync--r-u16 r))
         (steps (ubiquitty-sync--r-count r ubiquitty-sync--max-probe-steps)))
    (unless (and (> version 0) (<= role ubiquitty-sync--role-agent)
                 (<= target ubiquitty-sync--admission-target-management) (> daemon 0)
                 (string-match-p "\\`[A-Za-z0-9._-]+\\'" socket)
                 (= (logand build-flags (lognot ubiquitty-sync--known-serving-build-flags)) 0)
                 (or (= restored 0)
                     (and (= target ubiquitty-sync--admission-target-workspace) (/= restored daemon)))
                 (cond ((= target ubiquitty-sync--admission-target-session) (> session-id 0))
                       ((= target ubiquitty-sync--admission-target-workspace)
                        (and (> session-id 0) (> workspace-id 0)))
                       (t (and (= session-id 0) (= workspace-id 0)))))
      (error "ubiquitty-sync: invalid Welcome selection"))
    (unless (and (memq admission (list ubiquitty-sync--attachment-admission-awaiting-consent
                                      ubiquitty-sync--attachment-admission-granted))
                 (if (= admission ubiquitty-sync--attachment-admission-awaiting-consent)
                     (and (> question 0) (> session 0) (= session session-id))
                   (and (= question 0) (= session 0))))
      (error "ubiquitty-sync: invalid Welcome admission binding"))
    (when (> steps ubiquitty-sync--max-probe-steps)
      (error "ubiquitty-sync: a Welcome with %d probe steps" steps))
    (dotimes (_step steps) (ubiquitty-sync--r-u32 r))
    (let ((welcome (list :version version :app-version app-version
                         :role role :principal principal :target target :session-id session-id
                         :workspace-id workspace-id :daemon-instance daemon :restored-from-daemon restored
                         :socket-name socket
                         :build-flags build-flags :platform platform
                         :admission admission :consent-request question :consent-session session
                         :host-instance (substring body host-instance (+ host-instance 16))
                         :attachment (substring body attachment (+ attachment 16))
                         :resume-secret (substring body resume-secret (+ resume-secret 16))
                         :host-time (ubiquitty-sync--r-u64 r)))
          (resumed nil))
      (let ((predecessor (ubiquitty-sync--r-u8 r)))
        (unless (memq predecessor '(0 1)) (error "ubiquitty-sync: invalid Welcome predecessor flag"))
        (when (= predecessor 1)
          (let ((at (ubiquitty-sync--take r 16)))
            (setq welcome (plist-put welcome :predecessor (substring body at (+ at 16)))))))
      (let ((count (ubiquitty-sync--r-count r ubiquitty-sync--max-panes-per-connection)))
        (when (> count ubiquitty-sync--max-panes-per-connection)
          (error "ubiquitty-sync: too many resumed panes"))
        (when (and (> count 0) (or (= admission ubiquitty-sync--attachment-admission-awaiting-consent)
                                   (>= target ubiquitty-sync--admission-target-control)))
          (error "ubiquitty-sync: resumed panes without bound admission"))
        (dotimes (_pane count)
          (let* ((at (ubiquitty-sync--take r 16))
                 (outcome (ubiquitty-sync--r-u8 r))
                 (present (ubiquitty-sync--r-u8 r)))
            (unless (and (<= outcome ubiquitty-sync--resume-outcome-gone) (memq present '(0 1)))
              (error "ubiquitty-sync: invalid Welcome resume outcome"))
            (push (list (substring body at (+ at 16)) outcome
                        (and (= present 1) (ubiquitty-sync--r-u64 r))) resumed))))
      (let ((present (ubiquitty-sync--r-u8 r)))
        (unless (memq present '(0 1)) (error "ubiquitty-sync: invalid Welcome paste flag"))
        (when (= present 1)
          (setq welcome (plist-put welcome :paste-limits
                                   (list (ubiquitty-sync--r-u32 r) (ubiquitty-sync--r-u32 r)
                                         (ubiquitty-sync--r-u32 r))))))
      (unless (ubiquitty-sync--r-end-p r) (error "ubiquitty-sync: trailing Welcome bytes"))
      (plist-put welcome :resumed (nreverse resumed)))))

(defconst ubiquitty-sync--consent-status-phases
  (list (cons ubiquitty-sync--consent-status-phase-pending "pending")
        (cons ubiquitty-sync--consent-status-phase-approved "approved")
        (cons ubiquitty-sync--consent-status-phase-denied "denied")
        (cons ubiquitty-sync--consent-status-phase-expired "expired"))
  "Own-consent status phases by wire number.")

(defun ubiquitty-sync--read-notify (body)
  "Split Notify BODY into (KIND . RECORD); RECORD is the rest of BODY."
  (when (> (length body) ubiquitty-sync--max-frame-body)
    (error "ubiquitty-sync: oversized Notify"))
  (let* ((r (ubiquitty-sync--reader body))
         (kind (ubiquitty-sync--r-varint r)))
    (cons kind (substring body (aref r 1)))))

(defun ubiquitty-sync--read-consent-status (body required)
  "Read BODY's own-consent status as (QUESTION SESSION PHASE).
A Notify of another kind is nil, or an error when REQUIRED: an awaiting
attachment receives nothing else."
  (when (and required (> (length body) ubiquitty-sync--max-consent-status-bytes))
    (error "ubiquitty-sync: oversized own-consent status"))
  (let ((notify (ubiquitty-sync--read-notify body)))
    (if (/= (car notify) ubiquitty-sync--notify-kind-consent-status)
        (when required (error "ubiquitty-sync: awaiting exact own-consent status"))
      (let* ((r (ubiquitty-sync--reader (cdr notify)))
             (question (ubiquitty-sync--r-u32 r))
             (session (ubiquitty-sync--r-u32 r))
             (phase (cdr (assq (ubiquitty-sync--r-u8 r) ubiquitty-sync--consent-status-phases))))
        (unless (and (ubiquitty-sync--r-end-p r) (< 0 question) (< 0 session) phase)
          (error "ubiquitty-sync: invalid own-consent status"))
        (list question session phase)))))

(defun ubiquitty-sync--receive-consent-status (status)
  "Apply only STATUS's exact, once-only transition for this Welcome."
  (pcase-let ((`(,question ,session ,phase) status))
    (unless (and ubiquitty-sync--consent-phase
                 (= question (plist-get ubiquitty-sync--welcome :consent-request))
                 (= session (plist-get ubiquitty-sync--welcome :consent-session))
                 (if (equal phase "pending")
                     (equal ubiquitty-sync--consent-phase "awaiting-status")
                   (equal ubiquitty-sync--consent-phase "pending")))
      (error "ubiquitty-sync: unsolicited or repeated own-consent status"))
    (setq ubiquitty-sync--consent-phase phase)
    (when (member phase '("denied" "expired")) (setq ubiquitty-sync--consent-verdict phase))
    (when (and (equal phase "approved") ubiquitty-sync--facts-owed)
      (setq ubiquitty-sync--facts-owed nil)
      (ubiquitty-sync--send-facts))))

(defun ubiquitty-sync--read-echo-context (r)
  "Read an update's EchoContext op from R, past its op byte, as a plist.
The modes revision and the foreground-process generation, the flags, and the
pane's live interrupt, quit and suspend characters, each present or not."
  (let* ((modes-revision (ubiquitty-sync--r-u32 r))
         (foreground-generation (ubiquitty-sync--r-u32 r))
         (flags (ubiquitty-sync--r-u8 r))
         (present (ubiquitty-sync--r-u8 r))
         (interrupt (ubiquitty-sync--r-u8 r))
         (quit (ubiquitty-sync--r-u8 r))
         (suspend (ubiquitty-sync--r-u8 r)))
    (when (or (>= flags 8) (>= present 32)
              (and (/= 0 (logand present 8)) (= 0 (logand present 16))))
      (error "ubiquitty-sync: an echo context with flags %d and presence %d" flags present))
    (list :modes-revision modes-revision
          :foreground-generation foreground-generation
          :secure-entry (/= 0 (logand flags 1))
          :foreign-input (/= 0 (logand flags 2))
          :at-prompt (/= 0 (logand flags 4))
          :interrupt (and (/= 0 (logand present 1)) interrupt)
          :quit (and (/= 0 (logand present 2)) quit)
          :suspend (and (/= 0 (logand present 4)) suspend)
          :erase (if (= 0 (logand present 16)) 127
                   (and (/= 0 (logand present 8)) (ubiquitty-sync--r-u8 r))))))

(defun ubiquitty-sync--retire-pastes ()
  "Forget the pastes the host has written whole."
  (setq ubiquitty-sync--pastes
        (seq-filter (lambda (paste)
                      (or (> (aref paste 0) ubiquitty-sync--input-written)
                          (< (aref paste 2) (length (aref paste 1)))))
                    ubiquitty-sync--pastes)))

(defun ubiquitty-sync--note-input-written (written settled)
  "Take the host's counts WRITTEN and SETTLED of this client's input.
They come in an update's header and in a Receipt."
  (when (> written ubiquitty-sync--input-written)
    (setq ubiquitty-sync--input-written written)
    (ubiquitty-sync--retire-pastes))
  (setq ubiquitty-sync--input-settled (max ubiquitty-sync--input-settled settled))
  nil)

(defun ubiquitty-sync--pump-pastes ()
  "Send the pieces of the oldest paste the host's window has room for.
From version 15 the host states a window in its Welcome and reports how much
of an unfinished paste it has written; a piece goes only while what was sent
is less than the window past that.  A program that reads nothing therefore
holds one window of the paste, and the rest stays here."
  (when (and ubiquitty-sync--pane ubiquitty-sync--paste-limits ubiquitty-sync--process)
    (pcase-let ((`(,chunk ,_total ,window) ubiquitty-sync--paste-limits))
      (let ((piece-bytes (min ubiquitty-sync--paste-piece-bytes chunk)))
        (catch 'window-full
          ;; A paste's pieces go in order, so the next paste starts only
          ;; when the one before it has none left.
          (dolist (paste ubiquitty-sync--pastes)
            (let ((text (aref paste 1)))
              (while (< (aref paste 2) (length text))
                (when (and (> window 0) (>= (- (aref paste 2) (aref paste 3)) window))
                  (throw 'window-full nil))
                (let* ((start (aref paste 2))
                       (end (min (length text) (+ start piece-bytes))))
                  (ubiquitty-sync--send-sync
                   ubiquitty-sync--process ubiquitty-sync--kind-paste ubiquitty-sync--pane
                   (concat (ubiquitty-sync--put-u64 (aref paste 0))
                           (ubiquitty-sync--put-u64 start)
                           (unibyte-string (if (= end (length text)) 1 0))
                           (ubiquitty-sync--put-bytes (substring text start end))))
                  (aset paste 2 end))))))))))

(defun ubiquitty-sync--send-event (kind body)
  "Send BODY as the pane's next input event of KIND, numbered.
Before the pane is bound the event waits, and is numbered when it goes."
  (if (and ubiquitty-sync--pane ubiquitty-sync--process)
      (ubiquitty-sync--send-sync
       ubiquitty-sync--process kind ubiquitty-sync--pane
       (concat (ubiquitty-sync--put-u64 (cl-incf ubiquitty-sync--input-seq)) body))
    (push (cons kind body) ubiquitty-sync--queued-input)))

(defun ubiquitty-sync--unfinished-paste ()
  "A paste the host has not finished writing, or nil.
One still holding pieces, or sent whole and not yet counted by inputWritten."
  (seq-find (lambda (paste) (> (aref paste 0) ubiquitty-sync--input-written))
            ubiquitty-sync--pastes))

(defun ubiquitty-sync--abort-paste (paste)
  "Give PASTE up: drop its unsent pieces and tell the host.
The abort rides the interactive lane, where it does not wait behind the
pieces it cancels."
  (setq ubiquitty-sync--pastes (delq paste ubiquitty-sync--pastes))
  (cl-incf ubiquitty-sync--pastes-aborted)
  (ubiquitty-sync--send-sync ubiquitty-sync--process ubiquitty-sync--kind-paste-abort
                              ubiquitty-sync--pane (ubiquitty-sync--put-u64 (aref paste 0))))

(defun ubiquitty-sync--interrupt-key-p (bytes)
  "Whether BYTES is one key that interrupts, quits or suspends the pane's program.
The characters are the live ones the echo context states, or a new
terminal's before it has stated any."
  (and (= (length bytes) 1)
       (memq (aref bytes 0)
             (if ubiquitty-sync--echo
                 (list (plist-get ubiquitty-sync--echo :interrupt)
                       (plist-get ubiquitty-sync--echo :quit)
                       (plist-get ubiquitty-sync--echo :suspend))
               ubiquitty-sync--default-interrupt-characters))
       t))

(defun ubiquitty-sync--send-raw (bytes)
  "Send BYTES, a unibyte string, as typed: Raw events, numbered.
An interrupt typed during an unfinished paste ends the paste first, so
Ctrl-C never waits behind megabytes of it."
  (when (> (length bytes) 0)
    (when (and ubiquitty-sync--pane (ubiquitty-sync--interrupt-key-p bytes))
      (let (paste)
        (while (setq paste (ubiquitty-sync--unfinished-paste))
          (ubiquitty-sync--abort-paste paste))))
    (let ((at 0))
      (while (< at (length bytes))
        (let ((end (min (length bytes) (+ at ubiquitty-sync--raw-piece-bytes))))
          (ubiquitty-sync--send-event ubiquitty-sync--kind-raw
                                      (ubiquitty-sync--put-bytes (substring bytes at end)))
          (setq at end))))))

(defun ubiquitty-sync--send-key-event (key modifiers)
  "Send one press of the virtual KEY with MODIFIERS as a Keys event.
The host encodes it under the modes live when it writes it, so cursor keys
follow DECCKM without this client reading it.  A named key is its own
identity and states no character."
  (ubiquitty-sync--send-event
   ubiquitty-sync--kind-keys
   (concat (ubiquitty-sync--put-varint 1)
           (ubiquitty-sync--put-u32 key)
           (ubiquitty-sync--put-u16 modifiers)
           (unibyte-string 0)                   ; a press
           (ubiquitty-sync--put-varint 0)       ; no text: the key is its identity
           (ubiquitty-sync--put-u32 0)          ; unshifted, shifted and base-layout
           (ubiquitty-sync--put-u32 0)          ; code points, which a named key
           (ubiquitty-sync--put-u32 0)          ; has none of
           (unibyte-string (if (= modifiers 0) 0 1)))))

(defun ubiquitty-sync--send-pointer-event (kind button row column)
  "Send one pointer event of KIND (0 press, 1 release) for BUTTON at ROW, COLUMN.
BUTTON is xterm's code and the cell is zero-based.  A buffer has no pixel
position, which travels as the no-pixel value."
  (ubiquitty-sync--send-event
   ubiquitty-sync--kind-pointer
   (concat (ubiquitty-sync--put-varint 1)
           (unibyte-string kind button)
           (ubiquitty-sync--put-u16 0)          ; no modifiers
           (ubiquitty-sync--put-u16 row)
           (ubiquitty-sync--put-u16 column)
           (ubiquitty-sync--put-u16 #xFFFF)
           (ubiquitty-sync--put-u16 #xFFFF))))

(defun ubiquitty-sync--paste-bytes (bytes)
  "Send BYTES, a unibyte string, as a paste; nil when the host takes none so long.
The host states the most one paste may hold, and a longer one is refused
here rather than cut."
  (cond
   ((= (length bytes) 0) t)
   ((not (and ubiquitty-sync--pane ubiquitty-sync--process))
    (push (cons 'paste bytes) ubiquitty-sync--queued-input)
    t)
   ;; A host that states no paste caps is sent no Paste: the text goes as typed.
   ((null ubiquitty-sync--paste-limits) (ubiquitty-sync--send-raw bytes) t)
   ((> (length bytes) (nth 1 ubiquitty-sync--paste-limits))
    (message "ubiquitty-sync: a paste of %d bytes, past the %d the host takes"
             (length bytes) (nth 1 ubiquitty-sync--paste-limits))
    nil)
   (t
    (setq ubiquitty-sync--pastes
          (append ubiquitty-sync--pastes
                  (list (vector (cl-incf ubiquitty-sync--input-seq) bytes 0 0))))
    (ubiquitty-sync--pump-pastes)
    t)))

(defun ubiquitty-sync--flush-queued-input ()
  "Send what was given before the pane was bound, in the order it was given."
  (let ((queued (nreverse ubiquitty-sync--queued-input)))
    (setq ubiquitty-sync--queued-input nil)
    (dolist (entry queued)
      (if (eq (car entry) 'paste)
          (ubiquitty-sync--paste-bytes (cdr entry))
        (ubiquitty-sync--send-event (car entry) (cdr entry))))))

(defvar ubiquitty-sync--seeded-ansi16)

(defun ubiquitty-sync--theme-palette (theme reference-ansi)
  "One palette of THEME on the wire, written against REFERENCE-ANSI.
The indexed colours travel as the entries that differ from the reference, a
gap-coded list; the default foreground, background and cursor follow whole,
then the indexed alphas, none of which differs, and the five special
colours, none of which a theme sets."
  (pcase-let ((`(,_name ,ansi ,fg ,bg ,cursor) theme))
    (let ((entries nil) (previous 0))
      (dotimes (index 16)
        (unless (string= (downcase (elt ansi index)) (downcase (elt reference-ansi index)))
          (push (concat (ubiquitty-sync--put-varint (- index previous))
                        (ubiquitty-sync--put-rgb16 (elt ansi index)))
                entries)
          (setq previous index)))
      (concat (ubiquitty-sync--put-varint (length entries))
              (apply #'concat (nreverse entries))
              (ubiquitty-sync--put-rgb16 fg)
              (ubiquitty-sync--put-rgb16 bg)
              (ubiquitty-sync--put-rgb16 cursor)
              (ubiquitty-sync--put-varint 0)
              (make-string (* ubiquitty-sync--palette-special 6) 0)
              (make-string ubiquitty-sync--palette-special 0)))))

(defun ubiquitty-sync--facts-body ()
  "The Facts this client sends of its own once attached.
The viewport and whether its window holds the focus, and from version 12 the
theme palette it draws in, present or not: the live palette against the
palette a terminal starts with, then the baseline a reset returns to against
the live one, which for a theme are the same colours."
  (let ((theme (ubiquitty-sync--theme (ubiquitty-sync--configured-theme-name))))
    (concat (ubiquitty-sync--put-u16 ubiquitty-sync--rows)
            (ubiquitty-sync--put-u16 ubiquitty-sync--columns)
            (make-string 8 0)                   ; cell and text-area pixels
            (ubiquitty-sync--put-u32 0)         ; no refresh cap
            (unibyte-string 0 0 (if ubiquitty-sync--focused 1 0))
            (if theme
                (concat (unibyte-string 1)
                        (ubiquitty-sync--theme-palette theme ubiquitty-sync--seeded-ansi16)
                        (ubiquitty-sync--theme-palette theme (nth 1 theme)))
              (unibyte-string 0)))))

(defun ubiquitty-sync--send-facts ()
  "Send this buffer's Facts, or owe them until the host's Welcome.
Before the Welcome the Greet's facts are still to be read."
  (when ubiquitty-sync--process
    (if (and ubiquitty-sync--welcome
             (or (null ubiquitty-sync--consent-phase) (equal ubiquitty-sync--consent-phase "approved")))
        (ubiquitty-sync--send-sync ubiquitty-sync--process ubiquitty-sync--kind-facts 0
                                    (ubiquitty-sync--facts-body))
      (setq ubiquitty-sync--facts-owed t))))

;; A size is said twice, and the two frames mean different things: the Facts
;; names the window's, and the Viewport the size this buffer shows its pane
;; at.  The buffer is the whole window, so they agree.
(defun ubiquitty-sync--send-viewport ()
  "Send the size this buffer shows its pane at, once the host has bound the pane.
The pixel sizes are zero: a buffer measures none."
  (when (and ubiquitty-sync--pane ubiquitty-sync--process)
    (ubiquitty-sync--send-sync ubiquitty-sync--process ubiquitty-sync--kind-viewport
                                ubiquitty-sync--pane
                                (concat (ubiquitty-sync--put-u16 ubiquitty-sync--rows)
                                        (ubiquitty-sync--put-u16 ubiquitty-sync--columns)
                                        (make-string 12 0)))))

(defun ubiquitty-sync--set-focus (focused)
  "Tell the host this buffer holds the keyboard focus or not, when FOCUSED changed.
The window's focus travels in a Facts and the pane's in a Focus, which the
host turns into a focus report when the program asked for them."
  (unless (eq (not focused) (not ubiquitty-sync--focused))
    (setq ubiquitty-sync--focused (and focused t))
    (ubiquitty-sync--send-facts)
    (when (and ubiquitty-sync--pane ubiquitty-sync--process)
      (ubiquitty-sync--send-sync ubiquitty-sync--process ubiquitty-sync--kind-focus
                                  ubiquitty-sync--pane (unibyte-string (if focused 1 0))))))

(defun ubiquitty-sync--note-focus (&rest _)
  "Tell each attached buffer's host whether its window holds the focus.
A buffer holds it when the selected window shows it and that window's frame
has the focus; a frame that cannot say is taken to have it."
  (let* ((window (selected-window))
         (frame-focused (frame-focus-state (window-frame window))))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when (and (derived-mode-p 'ubiquitty-sync-mode) ubiquitty-sync--process)
          (ubiquitty-sync--set-focus (and frame-focused (eq (window-buffer window) buffer))))))))

;; ---- Sync rows -----------------------------------------------------------
;;
;; A row travels as a RowRecord (Source/Core/Protocol/Sync/RowForm.h): the
;; line attribute, the wrap flag and mark, the extent past which every cell is
;; the canonical blank, the text of each unit's lead cell, and run-length and
;; gap-coded lists over units.  A unit is one cell, or a wide lead and the
;; continuation the Core writes beside it, whose continuation never travels.

(defun ubiquitty-sync--pen-face (pen palette global-reverse)
  "Build the face plist for the 20-byte PEN.
PALETTE is the 259-entry colour vector; GLOBAL-REVERSE the DECSCNM flag."
  (let* ((attrs (ubiquitty-sync--u16 pen 0))
         (fgi (ubiquitty-sync--u16 pen 2))
         (bgi (ubiquitty-sync--u16 pen 4))
         (reverse (if global-reverse
                      (= 0 (logand attrs ubiquitty-sync--attr-reverse))
                    (/= 0 (logand attrs ubiquitty-sync--attr-reverse))))
         (fg (ubiquitty-sync--resolve-color fgi (aref pen 8) (aref pen 9) (aref pen 10) palette 256))
         (bg (ubiquitty-sync--resolve-color bgi (aref pen 11) (aref pen 12) (aref pen 13) palette 257))
         (face (list :foreground (if reverse bg fg)
                     :background (if reverse fg bg))))
    (when (/= 0 (logand attrs ubiquitty-sync--attr-bold))
      (setq face (plist-put face :weight 'bold)))
    (when (/= 0 (logand attrs ubiquitty-sync--attr-italic))
      (setq face (plist-put face :slant 'italic)))
    (when (/= 0 (logand attrs ubiquitty-sync--attr-underline))
      (setq face (plist-put face :underline t)))
    (when (/= 0 (logand attrs ubiquitty-sync--attr-strike))
      (setq face (plist-put face :strike-through t)))
    (when (/= 0 (logand attrs ubiquitty-sync--attr-hidden))
      (setq face (plist-put face :foreground (plist-get face :background))))
    face))

(defsubst ubiquitty-sync--pen-spec (pen)
  "The text-size spec id PEN names: bits 1-4 of its extended attributes."
  (logand (ash (aref pen 18) -1) #xF))

(defun ubiquitty-sync--unit-text (chars pen cluster run-width)
  "The text a unit draws: CHARS, its lead cell's code points, unless CLUSTER
names a store entry.  The two stores share one id space, and PEN's text-size
spec is what says which of them the id reads: a proportional spec reads the
run-text store, whose run takes RUN-WIDTH columns, and any other the cluster
pool.  An unwritten cell, a control code and a kitty image placeholder draw as
a space."
  (let* ((run (and cluster
                   (ubiquitty-sync--proportional-spec-p (ubiquitty-sync--pen-spec pen))
                   ubiquitty-sync--run-texts
                   (gethash cluster ubiquitty-sync--run-texts)))
         (pooled (and cluster (not run) ubiquitty-sync--clusters
                      (gethash cluster ubiquitty-sync--clusters)))
         (lead (if (> (length chars) 0) (aref chars 0) 0)))
    (cond
     (run (truncate-string-to-width run run-width nil ?\s))
     (pooled pooled)
     ((or (< lead 32) (= lead #x10EEEE)) " ")
     (t chars))))

(defun ubiquitty-sync--read-runs (r)
  "Read a run list from R as a list of (UNITS . VALUE)."
  (let ((runs nil))
    (dotimes (_run (ubiquitty-sync--r-varint r))
      (let* ((units (ubiquitty-sync--r-varint r))
             (value (ubiquitty-sync--r-varint r)))
        (when (= units 0)
          (error "ubiquitty-sync: a run of no units"))
        (push (cons units value) runs)))
    (nreverse runs)))

(defun ubiquitty-sync--read-gaps (r valued)
  "Read a gap-coded list from R as a table from unit to value.
VALUED says whether each entry carries a value; one that does not maps to t."
  (let ((table (make-hash-table)) (unit 0) (first t))
    (dotimes (_entry (ubiquitty-sync--r-varint r))
      (let ((gap (ubiquitty-sync--r-varint r)))
        (when (and (not first) (= gap 0))
          (error "ubiquitty-sync: a gap list that does not ascend"))
        (setq unit (+ unit gap) first nil)
        (puthash unit (if valued (ubiquitty-sync--r-varint r) t) table)))
    table))

(defun ubiquitty-sync--decode-row (record columns)
  "Decode RECORD, one RowRecord, into (CELLS . LINE-ATTRIBUTE).
CELLS is a vector of COLUMNS cell strings in the buffer's current palette; a
continuation cell is the empty string, so the row's text is their
concatenation and Emacs draws a wide lead two columns wide."
  (let* ((r (ubiquitty-sync--reader record))
         (attribute (ubiquitty-sync--r-u8 r))
         (_flags (ubiquitty-sync--r-u8 r))
         (_mark (ubiquitty-sync--r-u8 r))
         (extent (ubiquitty-sync--r-varint r))
         (text (decode-coding-string (ubiquitty-sync--r-bytes r) 'utf-8 t))
         (runs (ubiquitty-sync--read-runs r))
         (_links (ubiquitty-sync--read-runs r))
         (clusters (ubiquitty-sync--read-gaps r t))
         (references (ubiquitty-sync--read-gaps r t))
         (kept (ubiquitty-sync--read-gaps r nil))
         (units 0)
         (entries nil)
         (column 0)
         (offset 0))
    (unless (ubiquitty-sync--r-end-p r)
      (error "ubiquitty-sync: a RowRecord with %d bytes past its lists" (- (aref r 2) (aref r 1))))
    (when (> extent columns)
      (error "ubiquitty-sync: a row of extent %d on a %d-column screen" extent columns))
    (dolist (run runs) (setq units (+ units (car run))))
    ;; Each unit's code points, pen and references, in column order.
    (let ((pending runs) (used 0))
      (dotimes (unit units)
        (let* ((count (gethash unit clusters 1))
               (chars (if (<= (+ offset count) (length text))
                          (substring text offset (+ offset count))
                        (error "ubiquitty-sync: a RowRecord's units outrun its text")))
               (pen (or (gethash (cdr (car pending)) ubiquitty-sync--pens)
                        (error "ubiquitty-sync: a run names pen %d, which is not defined"
                               (cdr (car pending)))))
               (attrs (ubiquitty-sync--u16 pen 0))
               (wide (/= 0 (logand attrs ubiquitty-sync--attr-wide)))
               (span (if (and wide (not (gethash unit kept))) 2 1)))
          (setq offset (+ offset count) used (1+ used))
          (when (= used (car (car pending)))
            (setq pending (cdr pending) used 0))
          (push (list column chars pen (gethash unit references)
                      (/= 0 (logand attrs ubiquitty-sync--attr-wide-continuation))
                      span)
                entries)
          (setq column (+ column span)))))
    (unless (and (= column extent) (= offset (length text)))
      (error "ubiquitty-sync: a RowRecord whose units fill %d of %d cells" column extent))
    (let ((cells (make-vector columns ubiquitty-sync--blank-cell))
          (table (ubiquitty-sync--face-table ubiquitty-sync--global-reverse))
          (ordered (nreverse entries)))
      (while ordered
        (pcase-let ((`(,at ,chars ,pen ,cluster ,continuation ,span) (car ordered)))
          (if continuation
              (aset cells at "")
            ;; A run claims its anchor and the continuation cells after it.
            (let ((run-width span) (rest (cdr ordered)))
              (while (and rest (nth 4 (car rest)))
                (setq run-width (1+ run-width) rest (cdr rest)))
              (aset cells at
                    (propertize (ubiquitty-sync--unit-text chars pen cluster run-width)
                                'face (or (gethash pen table)
                                          (puthash pen (ubiquitty-sync--pen-face
                                                        pen ubiquitty-sync--palette
                                                        ubiquitty-sync--global-reverse)
                                                   table))))
              ;; The continuation the Core writes beside a wide lead.
              (when (= span 2)
                (aset cells (1+ at) "")))))
        (setq ordered (cdr ordered)))
      (cons cells attribute))))

;; ---- Sync state blocks -----------------------------------------------
;;
;; A checkpoint carries seven state blocks, each a length-prefixed byte run, and
;; an update carries the ones whose bytes moved.  This client reads the leading
;; mode flags, the cursor, the palette and the text-size table, and steps over
;; the rest by the block's own length.

(defconst ubiquitty-sync--checkpoint-block-order
  (vector ubiquitty-sync--block-modes ubiquitty-sync--block-palette ubiquitty-sync--block-cursor
          ubiquitty-sync--block-screen-states ubiquitty-sync--block-text-state
          ubiquitty-sync--block-activity ubiquitty-sync--block-rich-text)
  "The StateBlock each of a checkpoint's blocks is, in wire order.
`checkpointBlockOrder' in Source/Core/Protocol/Sync/ScreenPlane.cpp.")

;; The positions, among the modes block's leading flags, of the ones this
;; client acts on (`modeFlags' in Source/Core/Protocol/Sync/ScreenPlane.cpp).
(defconst ubiquitty-sync--mode-flag-count 57 "Mode flags the modes block leads with.")
(defconst ubiquitty-sync--mode-cursor-visible 0 "Mode flag: DECTCEM.")
(defconst ubiquitty-sync--mode-application-cursor 2 "Mode flag: DECCKM.")
(defconst ubiquitty-sync--mode-bracketed-paste 4 "Mode flag: mode 2004.")
(defconst ubiquitty-sync--mode-reverse-video 16 "Mode flag: DECSCNM.")
(defconst ubiquitty-sync--mode-mouse-tracking '(24 25 27 28)
  "Mode flags that each turn mouse reporting on.
X10, button tracking, cell motion and any event, in that order.")
(defconst ubiquitty-sync--mode-mouse-sgr 26 "Mode flag: SGR (1006) mouse encoding.")

;; The palette a terminal starts with (Source/Core/TermPalette.h), which the
;; live palette travels as the difference from.
(defconst ubiquitty-sync--seeded-ansi16
  ["#000000" "#cd0000" "#00cd00" "#cdcd00" "#0000ee" "#cd00cd" "#00cdcd" "#e5e5e5"
   "#7f7f7f" "#ff0000" "#00ff00" "#ffff00" "#5c5cff" "#ff00ff" "#00ffff" "#ffffff"]
  "The ANSI colours a terminal is seeded with.")
(defconst ubiquitty-sync--seeded-defaults ["#c0c0c0" "#101014" "#c0c0c0"]
  "The default foreground, background and cursor a terminal is seeded with.")

(defun ubiquitty-sync--seeded-palette ()
  "The 259-entry palette a terminal starts with."
  (let ((palette (make-vector 259 nil)))
    (dotimes (index 16) (aset palette index (aref ubiquitty-sync--seeded-ansi16 index)))
    (cl-loop for index from 16 below 256 do (aset palette index (ubiquitty-sync--cube-rgb index)))
    (dotimes (slot 3) (aset palette (+ 256 slot) (aref ubiquitty-sync--seeded-defaults slot)))
    palette))

(defun ubiquitty-sync--r-rgb16 (r)
  "Read three u16 channels from R as \"#rrggbb\"."
  (let* ((red (ubiquitty-sync--r-u16 r))
         (green (ubiquitty-sync--r-u16 r))
         (blue (ubiquitty-sync--r-u16 r)))
    (ubiquitty-sync--hex8 (ash red -8) (ash green -8) (ash blue -8))))

(defun ubiquitty-sync--read-palette-block (bytes)
  "The live palette the palette block BYTES carries, as 259 colours.
The indexed colours travel as the entries that differ from the seeded palette;
the default foreground, background and cursor follow whole."
  (let ((r (ubiquitty-sync--reader bytes))
        (palette (ubiquitty-sync--seeded-palette))
        (index 0) (first t))
    (dotimes (_entry (ubiquitty-sync--r-varint r))
      (let ((gap (ubiquitty-sync--r-varint r)))
        (when (and (not first) (= gap 0))
          (error "ubiquitty-sync: a palette delta that does not ascend"))
        (setq index (+ index gap) first nil)
        (unless (< index 256)
          (error "ubiquitty-sync: a palette delta past entry 255"))
        (aset palette index (ubiquitty-sync--r-rgb16 r))))
    (dotimes (slot 3) (aset palette (+ 256 slot) (ubiquitty-sync--r-rgb16 r)))
    palette))

(defun ubiquitty-sync--read-modes-block (bytes)
  "The leading mode flags of the modes block BYTES, as a bool vector."
  (let ((r (ubiquitty-sync--reader bytes))
        (flags (make-bool-vector ubiquitty-sync--mode-flag-count nil)))
    (dotimes (index ubiquitty-sync--mode-flag-count)
      (let ((value (ubiquitty-sync--r-u8 r)))
        (when (> value 1) (error "ubiquitty-sync: a mode flag of %d" value))
        (aset flags index (= value 1))))
    flags))

(defun ubiquitty-sync--read-cursor-block (bytes)
  "The cursor block BYTES as (ROW COLUMN SHAPE)."
  (let* ((r (ubiquitty-sync--reader bytes))
         (column (ubiquitty-sync--r-svarint r))
         (row (ubiquitty-sync--r-svarint r))
         (_wrap (ubiquitty-sync--r-u8 r))
         (style (ubiquitty-sync--r-varint r)))
    (unless (ubiquitty-sync--r-end-p r)
      (error "ubiquitty-sync: a cursor block longer than its fields"))
    (list row column (ubiquitty-sync--cursor-shape style))))

(defun ubiquitty-sync--read-text-size-specs (bytes)
  "The proportional spec mask the text-state block BYTES carries.
The table sits after the character sets, the titles and their stacks, the
pointer-shape stack, the sixel registers, the tab stops and the user-defined
keys, so those are walked to reach it."
  (let ((r (ubiquitty-sync--reader bytes)))
    (dotimes (_field 8) (ubiquitty-sync--r-varint r))   ; G0-G3, GL, GR, single shift, link
    (dotimes (_field 22) (ubiquitty-sync--r-bytes r))   ; title, icon name, their two stacks of 10
    (dotimes (_field 39) (ubiquitty-sync--r-varint r))  ; title masks, two pointer stacks, line role, home
    (dotimes (_entry (ubiquitty-sync--r-varint r))      ; the sixel registers that moved
      (ubiquitty-sync--r-varint r) (ubiquitty-sync--r-varint r))
    (dotimes (_entry (ubiquitty-sync--r-varint r))      ; the tab stops that are set
      (ubiquitty-sync--r-varint r) (ubiquitty-sync--r-u8 r))
    (dotimes (_table 2)                              ; tab alignments and target characters
      (dotimes (_entry (ubiquitty-sync--r-varint r))
        (ubiquitty-sync--r-varint r) (ubiquitty-sync--r-varint r)))
    (dotimes (_entry (ubiquitty-sync--r-varint r))      ; line tabulation stops
      (ubiquitty-sync--r-varint r) (ubiquitty-sync--r-u8 r))
    (when (= 1 (ubiquitty-sync--r-u8 r))                ; user-defined keys
      (ubiquitty-sync--r-u8 r)
      (dotimes (_entry (ubiquitty-sync--r-varint r))
        (ubiquitty-sync--r-u16 r) (ubiquitty-sync--r-bytes r)))
    (let ((live (ubiquitty-sync--r-u16 r)) (mask 0))
      (dotimes (slot ubiquitty-sync--text-size-table-capacity)
        (let ((at (ubiquitty-sync--take r ubiquitty-sync--text-size-spec-wire-bytes)))
          (when (and (/= 0 (logand live (ash 1 slot)))
                     (/= 0 (aref bytes (+ at ubiquitty-sync--text-size-spec-proportional-offset))))
            (setq mask (logior mask (ash 1 slot))))))
      mask)))

(defun ubiquitty-sync--apply-block (index bytes)
  "Take the state block INDEX, whose bytes are BYTES.
Returns non-nil when every cell has to be laid out again: the palette and
reverse video colour every face, and the text-size table decides which store a
cell's cluster reads."
  (cond
   ((= index ubiquitty-sync--block-cursor)
    (setq ubiquitty-sync--cursor-position (ubiquitty-sync--read-cursor-block bytes))
    nil)
   ((= index ubiquitty-sync--block-modes)
    (let* ((flags (ubiquitty-sync--read-modes-block bytes))
           (reverse (aref flags ubiquitty-sync--mode-reverse-video))
           (blanked (aref bytes (- (length bytes) 4))))
      ;; Suffix: CRT blanking, key-position mode, reported and disabled modifiers.
      (unless (memq blanked '(0 1)) (error "ubiquitty-sync: invalid CRT blanking flag"))
      (setq blanked (= blanked 1))
      (setq ubiquitty-sync--cursor-visible (aref flags ubiquitty-sync--mode-cursor-visible)
            ubiquitty-sync--application-cursor (aref flags ubiquitty-sync--mode-application-cursor)
            ubiquitty-sync--bracketed-paste (aref flags ubiquitty-sync--mode-bracketed-paste)
            ubiquitty-sync--mouse-tracking
            (cl-some (lambda (flag) (aref flags flag)) ubiquitty-sync--mode-mouse-tracking)
            ubiquitty-sync--mouse-sgr (aref flags ubiquitty-sync--mode-mouse-sgr))
      (prog1 (or (not (eq reverse ubiquitty-sync--global-reverse))
                 (not (eq blanked ubiquitty-sync--crt-blanked)))
        (setq ubiquitty-sync--global-reverse reverse
              ubiquitty-sync--crt-blanked blanked))))
   ((= index ubiquitty-sync--block-palette)
    (let ((palette (ubiquitty-sync--read-palette-block bytes)))
      (prog1 (not (equal palette ubiquitty-sync--palette))
        (setq ubiquitty-sync--palette palette))))
   ((= index ubiquitty-sync--block-text-state)
    (let ((mask (ubiquitty-sync--read-text-size-specs bytes)))
      (prog1 (/= mask ubiquitty-sync--proportional-specs)
        (setq ubiquitty-sync--proportional-specs mask))))
   (t nil)))

(defun ubiquitty-sync--read-code-points (r)
  "Read a code-point list from R as a string; an unwritten point is a space."
  (let ((chars nil))
    (dotimes (_point (ubiquitty-sync--r-varint r))
      (let ((cp (ubiquitty-sync--r-varint r)))
        (push (if (and (> cp 0) (<= cp #x10FFFF)) cp ?\s) chars)))
    (apply #'string (nreverse chars))))

(defun ubiquitty-sync--skip-rich-text-definition (r)
  "Step R over one rich text block's serial and document.
This client draws the cells a block covers and not the block
\(Source/Core/Protocol/Sync/RichTextForm.h)."
  (ubiquitty-sync--r-varint r)                       ; serial
  (dotimes (_ (ubiquitty-sync--r-varint r))          ; text
    (ubiquitty-sync--r-varint r))
  (dotimes (_ (ubiquitty-sync--r-varint r))          ; runs
    (ubiquitty-sync--r-varint r)
    (ubiquitty-sync--r-u16 r)
    (ubiquitty-sync--take r 4))
  (dotimes (_ (ubiquitty-sync--r-varint r))          ; fonts
    (ubiquitty-sync--r-u8 r)
    (ubiquitty-sync--r-bytes r))
  (dotimes (_ (ubiquitty-sync--r-varint r))          ; colours
    (ubiquitty-sync--take r 4)))

;; ---- Sync screens ------------------------------------------------------

(defun ubiquitty-sync--lay-out-screens ()
  "Decode both screens' records again under the current palette and modes.
The active screen becomes `ubiquitty-sync--screen'."
  (setq ubiquitty-sync--blank-cell (ubiquitty-sync--blank-cell ubiquitty-sync--palette)
        ubiquitty-sync--face-caches nil)
  (let ((columns ubiquitty-sync--screen-columns))
    (dotimes (screen 2)
      (let* ((records (aref ubiquitty-sync--row-records screen))
             (rows (length records))
             (cells (make-vector rows nil))
             (attributes (make-vector rows 0)))
        (dotimes (row rows)
          (let ((decoded (ubiquitty-sync--decode-row (aref records row) columns)))
            (aset cells row (car decoded))
            (aset attributes row (cdr decoded))))
        (aset ubiquitty-sync--screens screen (cons cells attributes)))))
  (ubiquitty-sync--show-active-screen))

(defun ubiquitty-sync--show-active-screen ()
  "Point the painted screen at the active one of the two the client holds."
  (let ((active (aref ubiquitty-sync--screens ubiquitty-sync--active-screen)))
    (setq ubiquitty-sync--screen (car active)
          ubiquitty-sync--line-attributes (cdr active))
    (pcase-let ((`(,row ,column ,shape) ubiquitty-sync--cursor-position))
      (setq ubiquitty-sync--cursor (list row column shape (and ubiquitty-sync--cursor-visible (not ubiquitty-sync--crt-blanked)))))))

(defun ubiquitty-sync--apply-checkpoint (buf body)
  "Replace BUF's screen with the checkpoint BODY and paint it.
Signals when the body is not one whole checkpoint, before anything is kept."
  (with-current-buffer buf
    (let* ((r (ubiquitty-sync--reader body))
           (generation (ubiquitty-sync--r-u64 r))
           (epoch (ubiquitty-sync--r-u32 r))
           (rows (ubiquitty-sync--r-u16 r))
           (columns (ubiquitty-sync--r-u16 r))
           (active (ubiquitty-sync--r-u8 r))
           (blocks (make-vector 7 nil))
           (links nil)
           (held-clusters (make-hash-table))
           (rich-texts nil)
           (runs-start nil)
           (history nil)
           (ground nil)
           (digest nil)
           (pens (make-hash-table))
           (clusters (make-hash-table))
           (runs (make-hash-table))
           (records (vector (make-vector rows nil) (make-vector rows nil))))
      (when (or (= rows 0) (= columns 0) (> active 1))
        (error "ubiquitty-sync: a checkpoint of %dx%d, screen %d" rows columns active))
      (dotimes (slot 7)
        (aset blocks (aref ubiquitty-sync--checkpoint-block-order slot) (ubiquitty-sync--r-bytes r)))
      (dotimes (id (ubiquitty-sync--r-varint r))
        (puthash id (substring body (ubiquitty-sync--take r ubiquitty-sync--pen-wire)
                               (aref r 1))
                 pens))
      (dotimes (_link (ubiquitty-sync--r-varint r))   ; the link ring: id, key, URI
        (let ((at (aref r 1)) (id (ubiquitty-sync--r-u16 r)))
          (ubiquitty-sync--r-bytes r) (ubiquitty-sync--r-bytes r)
          (push (cons id (substring body at (aref r 1))) links)))
      (dotimes (index (ubiquitty-sync--r-varint r))
        (let ((at (aref r 1)))
          (puthash (1+ index) (ubiquitty-sync--read-code-points r) clusters)
          (puthash (1+ index) (substring body at (aref r 1)) held-clusters)))
      (setq runs-start (aref r 1))
      (dotimes (_run (ubiquitty-sync--r-varint r))
        (let ((id (ubiquitty-sync--r-varint r)))
          (puthash id (ubiquitty-sync--read-code-points r) runs)))
      (let ((runs-bytes (substring body runs-start (aref r 1))))
        (setq runs-start runs-bytes))
      (dotimes (_definition (ubiquitty-sync--r-varint r))
        (let ((at (aref r 1)))
          (ubiquitty-sync--skip-rich-text-definition r)
          (push (substring body at (aref r 1)) rich-texts)))
      ;; The active screen's rows, then the other's.
      (dotimes (slot 2)
        (let ((screen (if (= slot 0) active (- 1 active))))
          (dotimes (row rows)
            (aset (aref records screen) row (ubiquitty-sync--r-bytes r)))))
      ;; The history's epoch and head; its lines travel on the history plane,
      ;; and this client draws the screen and keeps no history of its own.
      (setq history (cons (ubiquitty-sync--r-u32 r) (ubiquitty-sync--r-u64 r)))
      (setq ground (ubiquitty-sync--r-bytes r))          ; the parser's ground state
      (let ((at (ubiquitty-sync--take r 16)))            ; the state digest
        (setq digest (substring body at (+ at 16))))
      (unless (ubiquitty-sync--r-end-p r)
        (error "ubiquitty-sync: a checkpoint with %d bytes past its digest" (- (aref r 2) (aref r 1))))
      (setq ubiquitty-sync--generation generation
            ubiquitty-sync--dictionary-epoch epoch
            ubiquitty-sync--pens pens
            ubiquitty-sync--clusters clusters
            ubiquitty-sync--run-texts runs
            ubiquitty-sync--row-records records
            ubiquitty-sync--held-blocks blocks
            ubiquitty-sync--held-links (nreverse links)
            ubiquitty-sync--held-clusters held-clusters
            ubiquitty-sync--held-runs runs-start
            ubiquitty-sync--held-rich-texts rich-texts
            ubiquitty-sync--held-history history
            ubiquitty-sync--held-ground ground
            ubiquitty-sync--held-digest digest
            ubiquitty-sync--screen-columns columns
            ubiquitty-sync--active-screen active
            ubiquitty-sync--screens (make-vector 2 nil)
            ;; A checkpoint replaces everything held of the pane, the echo
            ;; context with it: unknown until the next update states it.
            ubiquitty-sync--echo nil)
      (dotimes (block 7)
        (ubiquitty-sync--apply-block block (aref blocks block)))
      (ubiquitty-sync--lay-out-screens)
      (ubiquitty-sync--adopt-defaults (aref ubiquitty-sync--palette 256) (aref ubiquitty-sync--palette 257))
      (ubiquitty-sync--paint-all))))

(defun ubiquitty-sync--update-disposition (mode base generation)
  "What to do with an update of MODE from BASE to GENERATION.
Returns `apply' when the screen held builds on it, `stale' when it is not
past the screen held, and `resync' when only a checkpoint closes the gap: a
chained update names exactly the generation it builds on, a superset update
any generation at or before it."
  (cond
   ((null ubiquitty-sync--generation) 'resync)
   ((<= generation ubiquitty-sync--generation) 'stale)
   ((if (= mode 0) (= base ubiquitty-sync--generation) (<= base ubiquitty-sync--generation)) 'apply)
   (t 'resync)))

(defun ubiquitty-sync--apply-update (buf body)
  "Apply the Update BODY onto BUF's screen.
Returns `apply' when the screen took it, `stale' when it was already past it,
and `resync' when only a checkpoint can bring the screen up to date: a base
the screen does not hold, or a geometry or dictionary it does not."
  (with-current-buffer buf
    (let* ((r (ubiquitty-sync--reader body))
           (mode (ubiquitty-sync--r-u8 r))
           (base (ubiquitty-sync--r-u64 r))
           (generation (ubiquitty-sync--r-u64 r))
           (_class (ubiquitty-sync--r-u8 r))
           (host-time (ubiquitty-sync--r-u64 r))
           (_lag (ubiquitty-sync--r-varint r))
           ;; How much of this client's input the host has written to the
           ;; program and how much has settled; the counts stand whether or
           ;; not the rows apply.
           (input-written (ubiquitty-sync--r-u64 r))
           (input-settled (ubiquitty-sync--r-u64 r))
           (history-head (ubiquitty-sync--r-u64 r))
           (_effects-through (ubiquitty-sync--r-u64 r))
           (_counted (ubiquitty-sync--note-input-written input-written input-settled))
           (disposition (ubiquitty-sync--update-disposition mode base generation)))
      (if (not (eq disposition 'apply))
          disposition
        (let* ((active (ubiquitty-sync--r-u8 r))
               (rows (ubiquitty-sync--r-u16 r))
               (columns (ubiquitty-sync--r-u16 r))
               (epoch (ubiquitty-sync--r-u32 r)))
          (if (not (and (= rows (length (aref ubiquitty-sync--row-records 0)))
                        (= columns ubiquitty-sync--screen-columns)
                        (= epoch ubiquitty-sync--dictionary-epoch)
                        (<= active 1)))
              'resync
            (let ((blocks nil) (writes nil) (echo nil) (links nil) (rich-texts nil) (digest nil)
                  (pens (copy-hash-table ubiquitty-sync--pens))
                  (clusters (copy-hash-table ubiquitty-sync--clusters))
                  (held-clusters (copy-hash-table (or ubiquitty-sync--held-clusters (make-hash-table)))))
              ;; Every op is read before any is kept, so a body that fails
              ;; half way leaves the screen as it was.
              (dotimes (_op (ubiquitty-sync--r-varint r))
                (let ((op (ubiquitty-sync--r-u8 r)))
                  (pcase op
                    (1 (let* ((id (ubiquitty-sync--r-varint r))
                              (pen (substring body (ubiquitty-sync--take r ubiquitty-sync--pen-wire) (aref r 1)))
                              (held (gethash id pens)))
                         (cond (held (unless (equal held pen)
                                       (error "ubiquitty-sync: pen %d restated differently" id)))
                               ((= id (hash-table-count pens)) (puthash id pen pens))
                               (t (error "ubiquitty-sync: pen %d defined out of order" id)))))
                    (2 (let ((at (aref r 1)) (id (ubiquitty-sync--r-u16 r)))
                         (ubiquitty-sync--r-bytes r) (ubiquitty-sync--r-bytes r)
                         (push (cons id (substring body at (aref r 1))) links)))
                    (3 (let* ((id (ubiquitty-sync--r-varint r))
                              (at (aref r 1))
                              (text (ubiquitty-sync--read-code-points r)))
                         (cond ((gethash id clusters) nil)
                               ((= id (1+ (hash-table-count clusters)))
                                (puthash id text clusters)
                                (puthash id (substring body at (aref r 1)) held-clusters))
                               (t (error "ubiquitty-sync: cluster %d defined out of order" id)))))
                    ((or 4 5)
                     (let ((row (ubiquitty-sync--r-varint r)))
                       (unless (< row rows)
                         (error "ubiquitty-sync: an update row %d of %d" row rows))
                       (push (list (if (= op 4) active (- 1 active)) row (ubiquitty-sync--r-bytes r))
                             writes)))
                    (6 (let ((block (ubiquitty-sync--r-u8 r)))
                         (push (cons block (ubiquitty-sync--r-bytes r)) blocks)))
                    (8 (let ((at (aref r 1)))
                         (ubiquitty-sync--skip-rich-text-definition r)
                         (push (substring body at (aref r 1)) rich-texts)))
                    (11 (setq echo (ubiquitty-sync--read-echo-context r)))
                    ;; Ops 9 and 10, a row by its spans and a scrolled
                    ;; rectangle, go only to a client whose Greet named
                    ;; them; this one names neither.
                    (_ (error "ubiquitty-sync: update op %d" op)))))
              (let ((at (ubiquitty-sync--take r 16)))   ; the state digest
                (setq digest (substring body at (+ at 16))))
              (unless (ubiquitty-sync--r-end-p r)
                (error "ubiquitty-sync: an update with %d bytes past its digest" (- (aref r 2) (aref r 1))))
              (ubiquitty-sync--hold-update blocks (nreverse links) held-clusters rich-texts history-head digest)
              (setq ubiquitty-sync--pens pens
                    ubiquitty-sync--clusters clusters
                    ubiquitty-sync--generation generation
                    ubiquitty-sync--host-time (max ubiquitty-sync--host-time host-time))
              (when echo (setq ubiquitty-sync--echo echo))
              (let ((relayout (/= active ubiquitty-sync--active-screen))
                    (dirty (make-bool-vector rows nil)))
                (setq ubiquitty-sync--active-screen active)
                (dolist (block (nreverse blocks))
                  (when (ubiquitty-sync--apply-block (car block) (cdr block))
                    (setq relayout t)))
                (dolist (write (nreverse writes))
                  (pcase-let ((`(,screen ,row ,record) write))
                    (aset (aref ubiquitty-sync--row-records screen) row record)
                    (unless relayout
                      (let ((decoded (ubiquitty-sync--decode-row record columns))
                            (held (aref ubiquitty-sync--screens screen)))
                        (aset (car held) row (car decoded))
                        (aset (cdr held) row (cdr decoded))
                        (when (= screen active) (aset dirty row t))))))
                (if relayout
                    (progn (ubiquitty-sync--lay-out-screens)
                           (ubiquitty-sync--adopt-defaults (aref ubiquitty-sync--palette 256)
                                                           (aref ubiquitty-sync--palette 257))
                           (ubiquitty-sync--paint-all))
                  (ubiquitty-sync--show-active-screen)
                  (ubiquitty-sync--paint-rows dirty)))
              'apply)))))))

(defun ubiquitty-sync--cursor-shape (decscusr)
  "Resolve the raw DECSCUSR style to 0 block, 1 underline or 2 bar."
  (pcase decscusr ((or 3 4) 1) ((or 5 6) 2) (_ 0)))

;; ---- Sync connection ---------------------------------------------------

(defun ubiquitty-sync--request-resync (proc buf reason)
  "Ask the host on PROC for a checkpoint of BUF's pane, once per gap.
REASON is the wire's ResyncReason."
  (with-current-buffer buf
    (when (and ubiquitty-sync--pane (not ubiquitty-sync--resync-outstanding))
      (setq ubiquitty-sync--resync-outstanding t
            ubiquitty-sync--buffered-updates nil)
      (ubiquitty-sync--send-sync
       proc ubiquitty-sync--kind-resync ubiquitty-sync--pane
       (concat (unibyte-string reason)
               (ubiquitty-sync--put-u64 (or ubiquitty-sync--generation 0))
               (ubiquitty-sync--put-varint 0))))))

(defun ubiquitty-sync--take-update (proc buf body)
  "Apply the Update BODY to BUF, asking PROC's host for a checkpoint on a gap."
  (let ((disposition (condition-case err
                         (ubiquitty-sync--apply-update buf body)
                       (error
                        (message "ubiquitty-sync: %s" (error-message-string err))
                        'malformed))))
    (pcase disposition
      ('apply (with-current-buffer buf (setq ubiquitty-sync--ack-owed t)))
      ('resync (ubiquitty-sync--request-resync proc buf ubiquitty-sync--resync-base-missing))
      ('malformed (ubiquitty-sync--request-resync proc buf ubiquitty-sync--resync-decode-failed)))))

(defun ubiquitty-sync--take-chunk (proc buf body)
  "Take one BulkChunk BODY for BUF; the last chunk of a checkpoint applies it."
  (with-current-buffer buf
    (let* ((r (ubiquitty-sync--reader body))
           (transfer (ubiquitty-sync--r-u32 r))
           (index (ubiquitty-sync--r-u32 r))
           (last (ubiquitty-sync--r-u8 r))
           (bytes (ubiquitty-sync--r-bytes r))
           (sha256 (and (= last 1) (substring body (ubiquitty-sync--take r 32) (aref r 1))))
           (held (assq transfer ubiquitty-sync--transfers)))
      (unless (ubiquitty-sync--r-end-p r)
        (error "ubiquitty-sync: a BulkChunk longer than its fields"))
      (when (> last 1) (error "ubiquitty-sync: invalid BulkChunk final flag"))
      (cond
       ((and ubiquitty-sync--clipboard-transfers (gethash transfer ubiquitty-sync--clipboard-transfers))
        (ubiquitty-sync--take-clipboard-chunk transfer index last bytes sha256))
       ((and ubiquitty-sync--sample-transfers (gethash transfer ubiquitty-sync--sample-transfers))
        (ubiquitty-sync--take-sample-chunk transfer index last bytes sha256))
       ((and ubiquitty-sync--image-transfers (gethash transfer ubiquitty-sync--image-transfers))
        (ubiquitty-sync--take-image-chunk proc transfer index last bytes sha256))
       ((and ubiquitty-sync--pending-checkpoint (= (cdr ubiquitty-sync--pending-checkpoint) transfer))
        (unless (= index (if held (cadr held) 0))
          (error "ubiquitty-sync: chunk %d of transfer %d out of order" index transfer))
        (if held
            (setcdr held (list (1+ index) (cons bytes (nth 2 held))))
          (push (list transfer 1 (list bytes)) ubiquitty-sync--transfers)
          (setq held (assq transfer ubiquitty-sync--transfers)))
        (when (= last 1)
          (setq ubiquitty-sync--transfers (assq-delete-all transfer ubiquitty-sync--transfers))
          (let ((payload (apply #'concat (reverse (nth 2 held)))))
            (unless (equal (secure-hash 'sha256 payload nil nil t) sha256)
              (error "ubiquitty-sync: transfer %d fails its SHA-256" transfer))
            (setq ubiquitty-sync--pending-checkpoint nil)
            (if (condition-case err
                    (progn (ubiquitty-sync--apply-checkpoint buf payload) t)
                  (error (message "ubiquitty-sync: %s" (error-message-string err)) nil))
                (let ((buffered (reverse ubiquitty-sync--buffered-updates)))
                  (setq ubiquitty-sync--resync-outstanding nil
                        ubiquitty-sync--buffered-updates nil
                        ubiquitty-sync--ack-owed t)
                  (dolist (update buffered)
                    (ubiquitty-sync--take-update proc buf update)))
              (setq ubiquitty-sync--resync-outstanding nil)
              (ubiquitty-sync--request-resync proc buf ubiquitty-sync--resync-checkpoint-refused)))))))))

(defun ubiquitty-sync--present-effect (record)
  "Present one validated RECORD after its once-only receipt was retained."
  (let* ((role (plist-get ubiquitty-sync--welcome :role))
         (kind (plist-get record :kind))
         (post (and (memq role (list ubiquitty-sync--role-owner ubiquitty-sync--role-driver)) ubiquitty-sync--client-instance
                    (not (equal ubiquitty-sync--client-instance (make-string 16 0)))
                    (equal (plist-get record :primary) ubiquitty-sync--client-instance))))
    (unless (eql role ubiquitty-sync--role-agent)
      (setq record (plist-put record :disposition (if post 'post 'badge)))
      (push record ubiquitty-sync--effects)
      (setq ubiquitty-sync--effects (seq-take ubiquitty-sync--effects 8))
      (when post
        (cond
         ((memq kind (list ubiquitty-sync--effect-kind-bell ubiquitty-sync--effect-kind-attention)) (ding))
         ((= kind ubiquitty-sync--effect-kind-notification)
          (let ((occasion (plist-get record :occasion)))
            (when (or (= occasion ubiquitty-sync--notification-occasion-always)
                      (and (= occasion ubiquitty-sync--notification-occasion-unfocused) (not ubiquitty-sync--focused))
                      (and (= occasion ubiquitty-sync--notification-occasion-invisible) (not (get-buffer-window (current-buffer) t))))
              (message "%s: %s" (plist-get record :title) (plist-get record :body))))))))))

(defun ubiquitty-sync--reset-sample-connection ()
  "Retire sample transfers and unconsumed packets, without changing receipts."
  (setq ubiquitty-sync--sample-slots (make-hash-table :test #'equal)
        ubiquitty-sync--sample-transfers (make-hash-table)
        ubiquitty-sync--deferred-effects nil ubiquitty-sync--deferred-effect-bytes 0
        ubiquitty-sync--clipboard-transfers (make-hash-table) ubiquitty-sync--clipboard-pending-bytes 0))

(defun ubiquitty-sync--retire-sample-binding (handle)
  "Release HANDLE's exact owners and queued packets when its binding ends."
  (dolist (table (list ubiquitty-sync--sample-slots ubiquitty-sync--sample-transfers ubiquitty-sync--clipboard-transfers))
    (when table
      (let ((dead nil))
        (maphash (lambda (key sample) (when (= (aref sample 0) handle) (push key dead))) table)
        (dolist (key dead) (remhash key table)))))
  (setq ubiquitty-sync--deferred-effects
        (seq-remove (lambda (held)
                      (when (= (aref held 0) handle)
                        (cl-decf ubiquitty-sync--clipboard-pending-bytes (aref held 3))
                        (cl-decf ubiquitty-sync--deferred-effect-bytes (aref held 2)) t))
                    ubiquitty-sync--deferred-effects)))

(defun ubiquitty-sync--effect-posts-to-this-client (primary)
  "Whether PRIMARY names this authenticated human owner or driver."
  (and (memq (plist-get ubiquitty-sync--welcome :role) (list ubiquitty-sync--role-owner ubiquitty-sync--role-driver))
       ubiquitty-sync--client-instance (not (equal ubiquitty-sync--client-instance (make-string 16 0)))
       (equal primary ubiquitty-sync--client-instance)))

(defun ubiquitty-sync--check-clipboard-recipient (body)
  "Refuse a foreign clipboard BODY before decoding any payload-sized fields."
  (let ((r (ubiquitty-sync--reader body)))
    (ubiquitty-sync--take r 18)
    (unless (ubiquitty-sync--r-end-p r)
      (ubiquitty-sync--r-u64 r) (ubiquitty-sync--r-u64 r)
      (let* ((at (ubiquitty-sync--take r 16)) (primary (substring body at (+ at 16)))
             (kind (ubiquitty-sync--r-u8 r)))
        (when (and (= kind ubiquitty-sync--effect-kind-clipboard-write)
                   (not (ubiquitty-sync--effect-posts-to-this-client primary)))
          (error "ubiquitty-sync: clipboard effect has no authorized local recipient"))))))

(defun ubiquitty-sync--admit-clipboard (handle packet body-bytes)
  "Admit PACKET's exact clipboard owner for HANDLE before allocating.
BODY-BYTES accounts for the enclosing packet.  Return reserved payload bytes."
  (let* ((record (plist-get packet :record)) (payload (plist-get record :clipboard))
         (transfer (plist-get payload :transfer)))
    (if (or (not payload) (= transfer 0) (<= (plist-get record :sequence) (aref ubiquitty-sync--effect-cursor 1)))
        0
      (let* ((size (plist-get payload :encoded-bytes))
             ;; Raw reassembly and decoded MIME/data strings coexist at the
             ;; validation boundary. Reserve both before the raw allocation.
             (charge (* 2 size)))
        (when (or (gethash transfer ubiquitty-sync--clipboard-transfers)
                  (and ubiquitty-sync--sample-transfers (gethash transfer ubiquitty-sync--sample-transfers))
                  (and ubiquitty-sync--image-transfers (gethash transfer ubiquitty-sync--image-transfers))
                  (assq transfer ubiquitty-sync--transfers)
                  (and ubiquitty-sync--pending-checkpoint (= transfer (cdr ubiquitty-sync--pending-checkpoint)))
                  (> (+ (car (ubiquitty-sync--image-owned-bytes)) body-bytes charge) ubiquitty-sync--retained-asset-budget))
          (error "ubiquitty-sync: clipboard transfer capacity or identity refused"))
        (let ((owner (make-string size 0)))
          (puthash transfer (vector handle payload owner 0 0) ubiquitty-sync--clipboard-transfers))
        (cl-incf ubiquitty-sync--clipboard-pending-bytes charge)
        charge))))

(defun ubiquitty-sync--take-clipboard-chunk (transfer index last bytes digest)
  "Validate TRANSFER's ordered INDEX, LAST, BYTES and final raw DIGEST."
  (let* ((held (gethash transfer ubiquitty-sync--clipboard-transfers))
         (payload (aref held 1)) (owner (aref held 2))
         (after (+ (aref held 3) (length bytes))))
    (unless (and owner (= index (aref held 4)) (> (length bytes) 0) (<= after (length owner))
                 (if (= last 1) (= after (length owner)) (< after (length owner))))
      (error "ubiquitty-sync: invalid clipboard transfer chunk"))
    (store-substring owner (aref held 3) bytes)
    (aset held 3 after) (aset held 4 (1+ index))
    (when (= last 1)
      (unless (equal digest (secure-hash 'sha256 owner nil nil t)) (error "ubiquitty-sync: clipboard transfer digest mismatch"))
      (setf (plist-get payload :items) (ubiquitty-sync--clipboard-bundle owner ubiquitty-sync--max-effect-clipboard-write-bytes)
            (plist-get payload :ready) t)
      (aset held 2 nil)
      (ubiquitty-sync--drain-effects))))

(defun ubiquitty-sync--same-connection-owner-p (buffer process generation)
  "Whether BUFFER still belongs to PROCESS's exact GENERATION."
  (and (buffer-live-p buffer)
       (eq (buffer-local-value 'ubiquitty-sync--process buffer) process)
       (= (buffer-local-value 'ubiquitty-sync--connection-generation buffer) generation)))

(defun ubiquitty-sync--present-clipboard (payload)
  "Offer verified PAYLOAD to the explicit local handler, never to recent effects."
  (let ((buffer (current-buffer)) (process ubiquitty-sync--process)
        (generation ubiquitty-sync--connection-generation))
    (setq ubiquitty-sync--clipboard-status (if ubiquitty-sync-clipboard-write-function 'refused 'disabled))
    (let ((outcome (if (not ubiquitty-sync-clipboard-write-function) 'disabled
                     (if (eq t (condition-case nil
                                   (funcall ubiquitty-sync-clipboard-write-function
                                            (plist-get payload :buffer) (plist-get payload :items))
                                 (error (error "ubiquitty-sync: local clipboard handler failed")))) 'applied 'refused))))
      (when (ubiquitty-sync--same-connection-owner-p buffer process generation)
        (with-current-buffer buffer (setq ubiquitty-sync--clipboard-status outcome))
        (unless (eq outcome 'applied) (message "ubiquitty-sync: remote clipboard write %s" outcome))))))

(defun ubiquitty-sync--drain-effects ()
  "Consume ready per-handle prefixes.
Retain receipts and exact owners through synchronous callbacks."
  (let ((blocked nil) (buffer (current-buffer)) (process ubiquitty-sync--process)
        (generation ubiquitty-sync--connection-generation))
    (catch 'retired-effect-owner
     (dolist (held (copy-sequence ubiquitty-sync--deferred-effects))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          ;; A preceding synchronous callback may have retired this binding.
          (when (memq held ubiquitty-sync--deferred-effects)
            (let* ((handle (aref held 0)) (packet (aref held 1))
                   (cursor (cdr (assq handle ubiquitty-sync--effect-cursors)))
                   (record (plist-get packet :record)) (sound (plist-get record :sound))
                   (clipboard (plist-get record :clipboard)) (identity (plist-get sound :identity))
                   (consumed (aref ubiquitty-sync--effect-cursor 1)) (ready (not (memq handle blocked)))
                   (posts (and record (ubiquitty-sync--effect-posts-to-this-client (plist-get record :primary)))))
              (unless cursor (error "ubiquitty-sync: deferred Effect lost its bound cursor"))
              (when (and clipboard (not posts)) (error "ubiquitty-sync: clipboard recipient retired before delivery"))
              (when (and ready posts record (> (plist-get record :sequence) consumed))
                (when clipboard (setq ready (plist-get clipboard :ready)))
                (when (and identity (> (plist-get identity :frames) 0))
                  (let ((sample (and ubiquitty-sync--sample-slots
                                     (gethash (cons handle (plist-get sound :sample)) ubiquitty-sync--sample-slots))))
                    (unless (and sample (equal identity (aref sample 2))) (error "ubiquitty-sync: Effect has no exact sample owner"))
                    (setq ready (aref sample 6)))))
              (if (not ready)
                  (cl-pushnew handle blocked)
                (setq record (ubiquitty-sync--accept-effect cursor packet ubiquitty-sync--generation))
                (dotimes (index 2)
                  (aset ubiquitty-sync--effect-cursor index (max (aref cursor index) (aref ubiquitty-sync--effect-cursor index))))
                (when (= (plist-get packet :remaining) 0) (cl-pushnew handle ubiquitty-sync--effect-ack-handles))
                (setq ubiquitty-sync--deferred-effects (delq held ubiquitty-sync--deferred-effects))
                (cl-decf ubiquitty-sync--deferred-effect-bytes (aref held 2))
                (cl-decf ubiquitty-sync--clipboard-pending-bytes (aref held 3))
                (when clipboard (remhash (plist-get clipboard :transfer) ubiquitty-sync--clipboard-transfers))
                (let ((charge (+ (aref held 2) (aref held 3))))
                  (cl-incf ubiquitty-sync--effect-delivering-bytes charge)
                  (unwind-protect
                      (when (and record (> (plist-get record :sequence) consumed))
                        (if clipboard (ubiquitty-sync--present-clipboard clipboard) (ubiquitty-sync--present-effect record)))
                    ;; The old local packet remains alive through the callback,
                    ;; but it must not debit a replacement connection's counters.
                    (when (ubiquitty-sync--same-connection-owner-p buffer process generation)
                      (with-current-buffer buffer (cl-decf ubiquitty-sync--effect-delivering-bytes charge))))
                  (unless (ubiquitty-sync--same-connection-owner-p buffer process generation)
                    (throw 'retired-effect-owner nil))))))))))))

(defun ubiquitty-sync--take-sample-head (handle body)
  "Admit BODY's exact sample owner for bound HANDLE before allocation."
  (unless (memq handle ubiquitty-sync--pane-bindings) (error "ubiquitty-sync: SampleHead for an unbound pane"))
  (unless ubiquitty-sync--sample-slots (ubiquitty-sync--reset-sample-connection))
  (let* ((head (ubiquitty-sync--read-sample-head body)) (slot (plist-get head :slot))
         (identity (plist-get head :identity)) (transfer (plist-get head :transfer))
         (bytes (* 2 (plist-get identity :frames))) (key (cons handle slot))
         (old (gethash key ubiquitty-sync--sample-slots)))
    (when (and old (not (aref old 6))) (error "ubiquitty-sync: SampleHead replaced an incomplete sample"))
    (dolist (held ubiquitty-sync--deferred-effects)
      (let ((sound (plist-get (plist-get (aref held 1) :record) :sound)))
        (when (and (= handle (aref held 0)) (eql slot (plist-get sound :sample))
                   (not (equal identity (plist-get sound :identity))))
          (error "ubiquitty-sync: SampleHead replaced a queued sound"))))
    (when (> transfer 0)
      (when (or (>= (hash-table-count ubiquitty-sync--sample-transfers)
                   (* ubiquitty-sync--sample-slot-count ubiquitty-sync--max-panes-per-connection))
                (gethash transfer ubiquitty-sync--sample-transfers)
                (and ubiquitty-sync--clipboard-transfers (gethash transfer ubiquitty-sync--clipboard-transfers))
                (and ubiquitty-sync--image-transfers (gethash transfer ubiquitty-sync--image-transfers))
                (assq transfer ubiquitty-sync--transfers)
                (and ubiquitty-sync--pending-checkpoint (= transfer (cdr ubiquitty-sync--pending-checkpoint)))
                (> (+ (car (ubiquitty-sync--image-owned-bytes)) bytes) ubiquitty-sync--retained-asset-budget))
        (error "ubiquitty-sync: refused sample transfer capacity or identity")))
    (let ((sample (vector handle slot identity (and (> bytes 0) (make-string bytes 0)) 0 0 (= bytes 0))))
      (puthash key sample ubiquitty-sync--sample-slots)
      (when (> transfer 0) (puthash transfer sample ubiquitty-sync--sample-transfers)))
    (ubiquitty-sync--drain-effects)))

(defun ubiquitty-sync--take-sample-chunk (transfer index last bytes digest)
  "Verify TRANSFER's ordered INDEX, LAST marker, BYTES and exact DIGEST."
  (let* ((sample (gethash transfer ubiquitty-sync--sample-transfers))
         (owner (aref sample 3)) (after (+ (aref sample 4) (length bytes))))
    (unless (and (= index (aref sample 5)) (> (length bytes) 0) (<= after (length owner))
                 (if (= last 1) (= after (length owner)) (< after (length owner))))
      (error "ubiquitty-sync: invalid raw sample chunk"))
    (store-substring owner (aref sample 4) bytes)
    (aset sample 4 after) (aset sample 5 (1+ index))
    (when (= last 1)
      (unless (and (equal digest (secure-hash 'sha256 owner nil nil t))
                   (equal digest (plist-get (aref sample 2) :digest)))
        (error "ubiquitty-sync: sample digest mismatch"))
      ;; This reader has no PCM sink: retain only verified identity metadata.
      (aset sample 3 nil) (aset sample 6 t)
      (remhash transfer ubiquitty-sync--sample-transfers)
      (ubiquitty-sync--drain-effects))))

(defun ubiquitty-sync--receive-sync (proc buf payload)
  "Act on one exact canonical envelope PAYLOAD, for BUF on PROC."
  (with-current-buffer buf
    (setq ubiquitty-sync--stream-received (+ ubiquitty-sync--stream-received (length payload))))
  (let* ((header (or (ubiquitty-sync--envelope-header payload)
                     (error "ubiquitty-sync: incomplete envelope header")))
         (kind (nth 0 header)) (channel (nth 1 header)) (length (nth 2 header))
         (start (nth 3 header))
         (_admitted (with-current-buffer buf (ubiquitty-sync--admit-header header)))
         (_exact (unless (= (length payload) (+ start length))
                   (error "ubiquitty-sync: incomplete or trailing envelope bytes")))
         (body (substring payload start (+ start length))))
    (when (memq kind ubiquitty-sync--client-only-kinds)
      (error "ubiquitty-sync: Sync kind %d from the host, which only a client sends" kind))
    (with-current-buffer buf
      (when (and ubiquitty-sync--consent-phase (not (equal ubiquitty-sync--consent-phase "approved")))
        (when (equal ubiquitty-sync--consent-phase "closed") (error "ubiquitty-sync: data after pending-consent Bye"))
        (unless (and (= channel 0)
                     (memq kind (list ubiquitty-sync--kind-probe ubiquitty-sync--kind-echo
                                      ubiquitty-sync--kind-bye ubiquitty-sync--kind-notify)))
          (error "ubiquitty-sync: pane or connection data before own consent"))
        (when (or (and (= kind ubiquitty-sync--kind-probe) (/= length 8))
                  (and (= kind ubiquitty-sync--kind-echo) (/= length 12)))
          (error "ubiquitty-sync: invalid pending-consent transport frame"))
        (when (and (member ubiquitty-sync--consent-phase '("denied" "expired"))
                   (= kind ubiquitty-sync--kind-notify))
          (error "ubiquitty-sync: status after own consent ended"))
        (when (= kind ubiquitty-sync--kind-bye)
          (let ((closing (ubiquitty-sync--read-bye body)))
            (unless (or (not (member ubiquitty-sync--consent-phase '("denied" "expired")))
                        (equal (plist-get closing :reason) "NoConsent"))
              (error "ubiquitty-sync: invalid pending-consent Bye"))))))
    (cond
     ((= kind ubiquitty-sync--kind-welcome)
      (unless (= channel 0) (error "ubiquitty-sync: Welcome on a pane"))
      (let ((version (ubiquitty-sync--u16 body 0)))
        ;; A host at another version is refused by name, so a skew is never
        ;; an empty buffer.  The version is read before the rest: a host of
        ;; another version lays the rest out its own way.
        (unless (= version ubiquitty-sync--wire-version)
          (error "ubiquitty-sync: host speaks wire version %d, this client speaks %d"
                 version ubiquitty-sync--wire-version)))
      (with-current-buffer buf
        (when ubiquitty-sync--welcome (error "ubiquitty-sync: duplicate Welcome"))
        (let* ((welcome (ubiquitty-sync--read-welcome body))
               (request ubiquitty-sync--admission-request)
               ;; Core's isRestoredReferenceAnswer: a host that recreated the
               ;; referenced workspace from its record answers with fresh
               ;; sessions, naming the pinned instance, under the id it gave
               ;; the workspace, which need not be the one asked for.
               (restored (and request
                              (/= (plist-get welcome :restored-from-daemon) 0)
                              (= (ubiquitty-sync--handshake-request-target request)
                                 ubiquitty-sync--admission-target-workspace)
                              (= (plist-get welcome :target) ubiquitty-sync--admission-target-workspace)
                              (= (ubiquitty-sync--handshake-request-expected-daemon request)
                                 (plist-get welcome :restored-from-daemon))
                              (/= (plist-get welcome :daemon-instance) (plist-get welcome :restored-from-daemon))
                              (/= (ubiquitty-sync--handshake-request-workspace-id request) 0)
                              (/= (plist-get welcome :workspace-id) 0))))
          (unless (and request
                       (= (plist-get welcome :target)
                          (ubiquitty-sync--handshake-request-target request))
                       (or (= (plist-get welcome :restored-from-daemon) 0) restored)
                       (or restored
                           (= (ubiquitty-sync--handshake-request-session-id request) 0)
                           (= (plist-get welcome :session-id)
                              (ubiquitty-sync--handshake-request-session-id request)))
                       (or restored
                           (= (ubiquitty-sync--handshake-request-workspace-id request) 0)
                           (= (plist-get welcome :workspace-id)
                              (ubiquitty-sync--handshake-request-workspace-id request)))
                       (or restored
                           (= (ubiquitty-sync--handshake-request-expected-daemon request) 0)
                           (= (plist-get welcome :daemon-instance)
                              (ubiquitty-sync--handshake-request-expected-daemon request))))
            (error "ubiquitty-sync: Welcome changed the requested selection"))
          (setq ubiquitty-sync--welcome welcome
                ubiquitty-sync--consent-phase
                (and (= (plist-get welcome :admission) ubiquitty-sync--attachment-admission-awaiting-consent)
                     "awaiting-status")
                ubiquitty-sync--paste-limits (plist-get welcome :paste-limits))
          ;; A restored pane the host did not continue is let go of; the
          ;; record is rewritten for the fresh secret before any input goes.
          (when ubiquitty-sync--resume-tail
            (let ((resumed (assoc ubiquitty-sync--effect-pane (plist-get welcome :resumed))))
              (unless (and resumed (memq (nth 1 resumed) (list ubiquitty-sync--resume-outcome-diffed
                                                                ubiquitty-sync--resume-outcome-checkpointed)))
                (ubiquitty-sync--forget-restored)))
            (setq ubiquitty-sync--resume-tail nil))
          (if ubiquitty-sync--effect-pane
              (ubiquitty-sync--persist)
            (ubiquitty-sync--purge-record))
          ;; The theme this client draws in travels in a Facts of its own,
          ;; as does a size or a focus that changed before the Welcome.
          (when (or ubiquitty-sync--facts-owed
                    (ubiquitty-sync--theme (ubiquitty-sync--configured-theme-name)))
            (setq ubiquitty-sync--facts-owed nil)
            (ubiquitty-sync--send-facts)))))
     ((= kind ubiquitty-sync--kind-probe)
      (ubiquitty-sync--send-sync proc ubiquitty-sync--kind-echo 0
                                  (concat (substring body 0 8) (ubiquitty-sync--put-u32 0))))
     ((= kind ubiquitty-sync--kind-pane-bind)
      (with-current-buffer buf
        (setq ubiquitty-sync--pane-ended nil)
        (let* ((binding (ubiquitty-sync--reader body)) (handle (ubiquitty-sync--r-varint binding))
               (at (ubiquitty-sync--take binding 16)) (pane-id (substring body at (+ at 16))))
          (unless (and (< 0 handle ubiquitty-sync--first-listed-handle)
                       (not (equal pane-id (make-string 16 0))) (ubiquitty-sync--r-end-p binding))
            (error "ubiquitty-sync: invalid PaneBind"))
          (when (and ubiquitty-sync--effect-pane (not (equal pane-id ubiquitty-sync--effect-pane)))
            (error "ubiquitty-sync: multiple distinct panes in a single-pane client"))
          (when (or (memq handle ubiquitty-sync--pane-bindings)
                    (>= (length ubiquitty-sync--pane-bindings) ubiquitty-sync--max-panes-per-connection))
            (error "ubiquitty-sync: repeated or excessive PaneBind"))
          (unless ubiquitty-sync--effect-pane
            (ubiquitty-sync--reset-image-connection)
            (ubiquitty-sync--reset-sample-connection)
            (setq ubiquitty-sync--effect-cursor (ubiquitty-sync--effect-cursor)
                  ubiquitty-sync--pane-facts nil ubiquitty-sync--generation nil
                  ubiquitty-sync--pending-checkpoint nil ubiquitty-sync--buffered-updates nil
                  ubiquitty-sync--resync-outstanding nil))
          (push handle ubiquitty-sync--pane-bindings)
          (push (cons handle (ubiquitty-sync--effect-cursor
                              (cons (aref ubiquitty-sync--effect-cursor 0) (aref ubiquitty-sync--effect-cursor 1))))
                ubiquitty-sync--effect-cursors)
          (setq ubiquitty-sync--effect-pane pane-id ubiquitty-sync--pane handle)))
      ;; The host starts a pane Dormant, sending no screen until the client
      ;; says it shows it; this buffer is the pane, so it does at once.
      (ubiquitty-sync--send-sync proc ubiquitty-sync--kind-view
                                  (with-current-buffer buf ubiquitty-sync--pane)
                                  (unibyte-string ubiquitty-sync--view-live))
      (with-current-buffer buf
        ;; The host holds no size for a pane it has only now bound.
        (ubiquitty-sync--send-viewport)
        (unless ubiquitty-sync--focused
          (ubiquitty-sync--send-sync proc ubiquitty-sync--kind-focus ubiquitty-sync--pane
                                      (unibyte-string 0)))
        ;; A fresh attachment names its pane here: its record is stored
        ;; before the first input goes.
        (ubiquitty-sync--persist)
        (ubiquitty-sync--flush-queued-input)))
     ((= kind ubiquitty-sync--kind-pane-unbind)
      (with-current-buffer buf
        (let* ((binding (ubiquitty-sync--reader body)) (handle (ubiquitty-sync--r-varint binding)))
          (ubiquitty-sync--r-u8 binding)
          (unless (and (memq handle ubiquitty-sync--pane-bindings) (ubiquitty-sync--r-end-p binding))
            (error "ubiquitty-sync: invalid or unbound PaneUnbind"))
          (setq ubiquitty-sync--pane-bindings (delq handle ubiquitty-sync--pane-bindings)
                ubiquitty-sync--effect-cursors (assq-delete-all handle ubiquitty-sync--effect-cursors)
                ubiquitty-sync--effect-ack-handles (delq handle ubiquitty-sync--effect-ack-handles))
          (ubiquitty-sync--retire-sample-binding handle)
          (when (eql handle ubiquitty-sync--pane)
            (setq ubiquitty-sync--pane (car ubiquitty-sync--pane-bindings))
            (unless ubiquitty-sync--pane
              (setq ubiquitty-sync--pane-ended t)
              ;; The pane ended, and nothing of it is left to resume.
              (ubiquitty-sync--purge-record)
              (message "ubiquitty-sync: the bound pane ended")
              (ubiquitty-sync--reset-image-connection)
              (setq ubiquitty-sync--effect-cursor nil ubiquitty-sync--effect-pane nil
                    ubiquitty-sync--pane-facts nil ubiquitty-sync--pending-checkpoint nil))))))
     ((= kind ubiquitty-sync--kind-clipboard-request)
      (with-current-buffer buf
        (unless (and ubiquitty-sync--effect-pane (memq channel ubiquitty-sync--pane-bindings)
                     (memq (plist-get ubiquitty-sync--welcome :role)
                           (list ubiquitty-sync--role-owner ubiquitty-sync--role-driver)))
          (error "ubiquitty-sync: clipboard request without a privileged bound pane"))
        (let ((request (ubiquitty-sync--read-clipboard-request body)))
          ;; This reader does not advertise ServesClipboard. No local source
          ;; is queried, even when a remote write handler is configured.
          (ubiquitty-sync--send-sync proc ubiquitty-sync--kind-clipboard-data channel
              (concat (ubiquitty-sync--put-u32 (plist-get request :id))
                      (unibyte-string ubiquitty-sync--effect-clipboard-status-refused))))))
     ((= kind ubiquitty-sync--kind-effect)
      (with-current-buffer buf
        (unless (and (or (eql channel ubiquitty-sync--pane) (memq channel ubiquitty-sync--pane-bindings)) ubiquitty-sync--effect-pane)
          (error "ubiquitty-sync: Effect for an unbound pane"))
        (ubiquitty-sync--check-clipboard-recipient body)
        (when (or (>= (length ubiquitty-sync--deferred-effects) ubiquitty-sync--max-effect-records)
                  (> (+ ubiquitty-sync--deferred-effect-bytes (length body))
                     (* ubiquitty-sync--max-effect-records ubiquitty-sync--max-frame-body))
                  (> (+ (car (ubiquitty-sync--image-owned-bytes)) (length body)) ubiquitty-sync--retained-asset-budget))
          (error "ubiquitty-sync: too many deferred Effects"))
        (let* ((packet (ubiquitty-sync--read-effect body))
               (clipboard-charge (ubiquitty-sync--admit-clipboard channel packet (length body))))
          (setq ubiquitty-sync--deferred-effects
                (nconc ubiquitty-sync--deferred-effects (list (vector channel packet (length body) clipboard-charge))))
          (cl-incf ubiquitty-sync--deferred-effect-bytes (length body))
          (ubiquitty-sync--drain-effects))))
     ((= kind ubiquitty-sync--kind-sample-head)
      (with-current-buffer buf (ubiquitty-sync--take-sample-head channel body)))
     ((= kind ubiquitty-sync--kind-image-placements)
      (when (eql channel (with-current-buffer buf ubiquitty-sync--pane))
        (ubiquitty-sync--take-image-placements proc buf body)))
     ((= kind ubiquitty-sync--kind-image-head)
      (when (eql channel (with-current-buffer buf ubiquitty-sync--pane))
        (ubiquitty-sync--take-image-head proc buf body)))
     ((= kind ubiquitty-sync--kind-pane-facts)
      (with-current-buffer buf
        (when (eql channel ubiquitty-sync--pane)
          (let ((facts (ubiquitty-sync--read-pane-facts body)))
            (setq ubiquitty-sync--pane-facts facts
                  header-line-format (ubiquitty-sync--header-line (plist-get facts :title)))))))
     ((= kind ubiquitty-sync--kind-checkpoint-head)
      (with-current-buffer buf
        (let ((head (ubiquitty-sync--reader body)))
          (let* ((generation (ubiquitty-sync--r-u64 head))
                 (transfer (ubiquitty-sync--r-u32 head)))
            (when (and ubiquitty-sync--sample-transfers (gethash transfer ubiquitty-sync--sample-transfers))
              (error "ubiquitty-sync: checkpoint reused a sample transfer"))
            (when (and ubiquitty-sync--clipboard-transfers (gethash transfer ubiquitty-sync--clipboard-transfers))
              (error "ubiquitty-sync: checkpoint reused a clipboard transfer"))
            (setq ubiquitty-sync--pending-checkpoint (cons generation transfer)
                  ubiquitty-sync--buffered-updates
                  (seq-filter (lambda (update) (> (ubiquitty-sync--u64 update 9) generation))
                              ubiquitty-sync--buffered-updates))))))
     ((= kind ubiquitty-sync--kind-bulk-chunk)
      (ubiquitty-sync--take-chunk proc buf body))
     ((= kind ubiquitty-sync--kind-bulk-abort)
      ;; The checkpoint in flight is abandoned; a fresh one follows when the
      ;; host has one to send, and the updates chained after this one never
      ;; apply.
      (with-current-buffer buf
        (let ((transfer (ubiquitty-sync--r-u32 (ubiquitty-sync--reader body))))
          (when (and ubiquitty-sync--sample-transfers (gethash transfer ubiquitty-sync--sample-transfers))
            (error "ubiquitty-sync: required sample transfer aborted"))
          (when (and ubiquitty-sync--clipboard-transfers (gethash transfer ubiquitty-sync--clipboard-transfers))
            (error "ubiquitty-sync: required clipboard transfer aborted"))
          (setq ubiquitty-sync--transfers (assq-delete-all transfer ubiquitty-sync--transfers))
          (when ubiquitty-sync--image-transfers
            (when-let* ((image (gethash transfer ubiquitty-sync--image-transfers)))
              (let ((hash (aref (aref image 0) 0)))
                (remhash hash ubiquitty-sync--image-wants)
                ;; Do not let another completion request this asset before
                ;; the host has offered its post-abort delivery.
                (remhash hash ubiquitty-sync--image-offers)))
            (remhash transfer ubiquitty-sync--image-transfers))
          (when (and ubiquitty-sync--pending-checkpoint
                     (= (cdr ubiquitty-sync--pending-checkpoint) transfer))
            (setq ubiquitty-sync--pending-checkpoint nil
                  ubiquitty-sync--buffered-updates nil)))))
     ((= kind ubiquitty-sync--kind-update)
      (if (with-current-buffer buf ubiquitty-sync--pending-checkpoint)
          ;; An update past the checkpoint in flight builds on it, so it waits.
          (with-current-buffer buf
            (if (> (+ (length body) (apply #'+ (mapcar #'length ubiquitty-sync--buffered-updates)))
                   ubiquitty-sync--max-buffered-update-bytes)
                (ubiquitty-sync--request-resync proc buf ubiquitty-sync--resync-buffer-overflow)
              (push body ubiquitty-sync--buffered-updates)))
        (unless (with-current-buffer buf ubiquitty-sync--resync-outstanding)
          (ubiquitty-sync--take-update proc buf body))))
     ((= kind ubiquitty-sync--kind-receipt)
      ;; The host's counts when no update left to carry them.
      (let* ((receipt (ubiquitty-sync--reader body))
             (written (ubiquitty-sync--r-u64 receipt))
             (settled (ubiquitty-sync--r-u64 receipt)))
        (unless (ubiquitty-sync--r-end-p receipt)
          (error "ubiquitty-sync: a Receipt longer than its counts"))
        (with-current-buffer buf
          (ubiquitty-sync--note-input-written written settled))))
     ((= kind ubiquitty-sync--kind-paste-receipt)
      ;; How much of an unfinished paste the program has been written, which
      ;; is what opens the window for its next pieces.
      (let* ((receipt (ubiquitty-sync--reader body))
             (seq (ubiquitty-sync--r-u64 receipt))
             (written (ubiquitty-sync--r-u64 receipt)))
        (unless (ubiquitty-sync--r-end-p receipt)
          (error "ubiquitty-sync: a PasteReceipt longer than its counts"))
        (with-current-buffer buf
          (dolist (paste ubiquitty-sync--pastes)
            (when (= (aref paste 0) seq)
              (aset paste 3 (max (aref paste 3) written))))
          (ubiquitty-sync--pump-pastes))))
     ((= kind ubiquitty-sync--kind-input-discarded)
      ;; A signal character discarded the input the pane held unwritten:
      ;; every event above inputWritten and at or below throughSeq.  They
      ;; are counted, and no more of a paste among them is sent.
      (let* ((discarded (ubiquitty-sync--reader body))
             (written (ubiquitty-sync--r-u64 discarded))
             (through (ubiquitty-sync--r-u64 discarded)))
        (unless (and (ubiquitty-sync--r-end-p discarded) (> through written))
          (error "ubiquitty-sync: an InputDiscarded that names no run"))
        (with-current-buffer buf
          (cl-incf ubiquitty-sync--input-discarded
                   (max 0 (- (min through ubiquitty-sync--input-seq) written)))
          (setq ubiquitty-sync--pastes
                (seq-remove (lambda (paste) (and (> (aref paste 0) written) (<= (aref paste 0) through)))
                            ubiquitty-sync--pastes))
          (ubiquitty-sync--note-input-written through ubiquitty-sync--input-settled)
          (ubiquitty-sync--pump-pastes))))
     ((= kind ubiquitty-sync--kind-notify)
      (with-current-buffer buf
        (let ((status (ubiquitty-sync--read-consent-status
                       body (and ubiquitty-sync--consent-phase
                                 (not (equal ubiquitty-sync--consent-phase "approved"))))))
          (if status
              (progn
                (unless (= channel 0) (error "ubiquitty-sync: own consent on a pane"))
                (ubiquitty-sync--receive-consent-status status))
            ;; A kind this client does not know is skipped by the frame's
            ;; length; the rest are kept as (KIND . RECORD).
            (let ((notify (ubiquitty-sync--read-notify body)))
              (when (<= ubiquitty-sync--notify-kind-attachments (car notify)
                        ubiquitty-sync--notify-kind-paste-ready)
                (push notify ubiquitty-sync--notifies)
                (when (> (length ubiquitty-sync--notifies) 8)
                  (setq ubiquitty-sync--notifies (seq-take ubiquitty-sync--notifies 8)))))))))
     ((= kind ubiquitty-sync--kind-result)
      ;; The answer to a Call.  This client makes none; one that arrives is
      ;; kept for whoever sent a Call of their own on this connection.
      (let* ((result (ubiquitty-sync--reader body))
             (transfer (ubiquitty-sync--r-varint result)))
        (with-current-buffer buf
          (setq ubiquitty-sync--last-result
                (cons transfer (decode-coding-string (substring body (aref result 1)) 'utf-8))))))
     ((= kind ubiquitty-sync--kind-bye)
      (let* ((closing (ubiquitty-sync--read-bye body)) (reason (plist-get closing :reason)))
        (with-current-buffer buf
          (setq ubiquitty-sync--bye-reason reason ubiquitty-sync--transport-closed t
                ubiquitty-sync--peer-metadata (plist-get closing :peer))
          (when proc (process-put proc 'peer-refusal closing))
          (when (and ubiquitty-sync--consent-phase (not (equal ubiquitty-sync--consent-phase "approved")))
            (setq ubiquitty-sync--consent-phase "closed")))
        (message "ubiquitty-sync: the host closed the connection (%s): %s%s"
                 (with-current-buffer buf (or ubiquitty-sync--consent-verdict reason))
                 (plist-get closing :detail)
                 (let ((peer (plist-get closing :peer)))
                   (if peer (format " [host %s %s, wire %d]"
                                    (plist-get peer :app-version) (plist-get peer :platform)
                                    (plist-get peer :version)) "")))))
     ;; The answer to a probe; this client sends none, and one that arrives
     ;; says nothing it acts on.
     ((= kind ubiquitty-sync--kind-echo) nil)
     ;; A cleared history takes the stored record with it, inside the read
     ;; that says so: the screen before the clear is never stored again.
     ((= kind ubiquitty-sync--kind-history-reset)
      (with-current-buffer buf
        (ubiquitty-sync--purge-record)
        (setq ubiquitty-sync--reset-generation (or ubiquitty-sync--generation 0))))
     ((memq kind ubiquitty-sync--unsolicited-kinds) nil)
     (t (error "ubiquitty-sync: Sync kind %d, which no version this client speaks defines" kind)))))

(defun ubiquitty-sync--send-owed-ack (proc buf)
  "Acknowledge to PROC's host what BUF has taken since the last Ack.
Stream bytes are acknowledged whether or not they completed a generation: the
host's window retires bytes only on an Ack, so the chunks of a checkpoint
larger than the window wait on one."
  (with-current-buffer buf
    (when (and (not ubiquitty-sync--transport-closed) (process-live-p proc)
               (> ubiquitty-sync--stream-received ubiquitty-sync--stream-acknowledged))
      (setq ubiquitty-sync--stream-acknowledged ubiquitty-sync--stream-received)
      (when (and ubiquitty-sync--ack-owed ubiquitty-sync--pane)
        (cl-pushnew ubiquitty-sync--pane ubiquitty-sync--effect-ack-handles))
      (let ((panes (concat (ubiquitty-sync--put-varint (length ubiquitty-sync--effect-ack-handles))
                          (mapconcat (lambda (handle)
                                       ;; Only this handle's completed batch is acknowledged.
                                       (concat (ubiquitty-sync--put-varint handle)
                                               (ubiquitty-sync--put-u64 (or ubiquitty-sync--generation 0))
                                               (ubiquitty-sync--put-u64 0) ; no history cache
                                               (ubiquitty-sync--put-u64 (let ((cursor (cdr (assq handle ubiquitty-sync--effect-cursors))))
                                                                        (if cursor (aref cursor 0) 0)))))
                                     ubiquitty-sync--effect-ack-handles ""))))
        (setq ubiquitty-sync--ack-owed nil ubiquitty-sync--effect-ack-handles nil)
        (ubiquitty-sync--send-sync
         proc ubiquitty-sync--kind-ack 0
         (concat (ubiquitty-sync--put-u64 ubiquitty-sync--host-time)
                 (ubiquitty-sync--put-u32 0)
                 (ubiquitty-sync--put-u64 ubiquitty-sync--stream-received)
                 panes))))))

;; ---- images ------------------------------------------------------------
;;
;; A stored image arrives as zlib-compressed RGB or RGBA pixels in chunks; the
;; placements name which image draws over which cells.  On a graphical display
;; the pixels become a PNG Emacs's image support reads, and each row a
;; placement covers shows one slice of it as a display property over the
;; covered cells, so the picture moves, scrolls and disappears with the text
;; it sits on.

(defsubst ubiquitty-sync--image-bytes-per-pixel (format)
  "Bytes one pixel of FORMAT occupies: 4 for RGBA, 3 for RGB."
  (if (= format 32) 4 3))

(defun ubiquitty-sync--image-header-sound-p (width height format raw-length compressed-length
                                                   chunk-count chunk-index)
  "Whether an IMAGE header describes a picture this client will make room for.
The pixel buffer is WIDTH by HEIGHT of FORMAT and must be exactly RAW-LENGTH
bytes, so a header naming a buffer larger than its own dimensions is refused
before a byte of it is inflated.  COMPRESSED-LENGTH bounds the zlib stream the
CHUNK-COUNT chunks reassemble to and CHUNK-INDEX names one of them.

Every clause here reads a number the host declared, and a host that means harm
declares whatever it likes.  The clause that does the work is the cap on
COMPRESSED-LENGTH, because that is the one quantity the client controls the
consequences of: the inflate itself is unbounded, so the size of the input is
the only handle on the size of the output.  The declared pair is held from both sides. A stream
far longer than the buffer it claims to fill is refused on its own terms, with
an allowance because deflate expands a payload smaller than its own header — a
2x1 RGB image is six bytes of pixels and seventeen of stream. A buffer far
larger than the stream is refused by the ratio, which is what stops a small
payload naming a large picture."
  (and (> width 0) (> height 0)
       (memq format '(24 32))
       (> chunk-count 0) (< chunk-index chunk-count)
       (> raw-length 0)
       (<= raw-length ubiquitty-sync--retained-asset-budget)
       (> compressed-length 0)
       (<= compressed-length ubiquitty-sync-max-image-compressed-bytes)
       (<= compressed-length (+ raw-length 1024))
       (<= raw-length (* ubiquitty-sync--max-inflate-ratio compressed-length))
       (= raw-length (* width height (ubiquitty-sync--image-bytes-per-pixel format)))))

(defun ubiquitty-sync--image-pixels-from (compressed raw-length)
  "Return the pixels in COMPRESSED when they inflate to RAW-LENGTH bytes."
  (when (and (fboundp 'zlib-available-p) (zlib-available-p))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert compressed)
      (when (zlib-decompress-region (point-min) (point-max))
        (let ((raw (buffer-string)))
          (and (= (length raw) raw-length) raw))))))

(defconst ubiquitty-sync--png-crc-table
  (let ((table (make-vector 256 0)))
    (dotimes (n 256)
      (let ((crc n))
        (dotimes (_bit 8)
          (setq crc (logxor (ash crc -1) (if (= (logand crc 1) 0) 0 #xedb88320))))
        (aset table n crc)))
    table)
  "CRC-32 lookup table for PNG chunks, whose polynomial is #xedb88320.")

(defun ubiquitty-sync--png-crc (bytes)
  "Return the PNG CRC-32 of unibyte string BYTES."
  (let ((crc #xffffffff))
    (dotimes (n (length bytes))
      (setq crc (logxor (ash crc -8)
                       (aref ubiquitty-sync--png-crc-table (logand (logxor crc (aref bytes n)) #xff)))))
    (logxor crc #xffffffff)))

(defsubst ubiquitty-sync--png-u32 (n)
  "Encode N as four big-endian PNG bytes."
  (unibyte-string (logand (ash n -24) #xff) (logand (ash n -16) #xff)
                  (logand (ash n -8) #xff) (logand n #xff)))

(defun ubiquitty-sync--png-chunk (type bytes)
  "Encode a PNG chunk of TYPE carrying BYTES."
  (let ((body (concat (string-to-unibyte type) bytes)))
    (concat (ubiquitty-sync--png-u32 (length bytes)) body
            (ubiquitty-sync--png-u32 (ubiquitty-sync--png-crc body)))))

(defun ubiquitty-sync--png-deflate (bytes)
  "Wrap BYTES in a zlib stream of stored deflate blocks.
Emacs exposes inflate but not deflate.  Stored blocks need no external
helper, and the image's pixel budget bounds both input and output here."
  (let ((at 0) (blocks nil) (low 1) (high 0) (length (length bytes)))
    (dotimes (n length)
      (setq low (% (+ low (aref bytes n)) 65521)
            high (% (+ high low) 65521)))
    (while (< at length)
      (let* ((count (min 65535 (- length at)))
             (end (+ at count)))
        (push (concat (unibyte-string (if (= end length) 1 0))
                      (ubiquitty-sync--put-u16 count)
                      (ubiquitty-sync--put-u16 (logxor count #xffff))
                      (substring bytes at end)) blocks)
        (setq at end)))
    (concat (unibyte-string #x78 #x01)
            (if blocks (apply #'concat (nreverse blocks)) (unibyte-string 1 0 0 #xff #xff))
            (ubiquitty-sync--png-u32 (+ (ash high 16) low)))))

(defun ubiquitty-sync--image-source-sound-p (image crop padded-width padded-height)
  "Whether IMAGE's CROP and PADDED-WIDTH by PADDED-HEIGHT fit the pixel budget.
Both native encoders share this input and allocation policy."
  (pcase-let* ((`(,width ,height ,format ,pixels . ,_) image)
               (`(,x ,y ,crop-width ,crop-height ,drawn-width ,drawn-height) crop)
               (picture-width (or drawn-width crop-width))
               (picture-height (or drawn-height crop-height)))
    (and (seq-every-p #'integerp (list width height format x y crop-width crop-height
                                       picture-width picture-height padded-width padded-height))
         (> picture-width 0) (> picture-height 0)
         (> width 0) (> height 0) (memq format '(24 32))
         (stringp pixels) (not (multibyte-string-p pixels))
         (integerp (or (nth 4 image) 0)) (>= (or (nth 4 image) 0) 0)
         (= (length pixels) (+ (or (nth 4 image) 0) (* width height (/ format 8))))
         (<= (* width height (/ format 8)) ubiquitty-sync--retained-asset-budget)
         (>= x 0) (>= y 0) (> crop-width 0) (> crop-height 0)
         (<= (+ x crop-width) width) (<= (+ y crop-height) height)
         (>= padded-width picture-width) (>= padded-height picture-height)
         (<= (* (1+ (* padded-width 4)) padded-height) ubiquitty-sync--retained-asset-budget))))

(defun ubiquitty-sync--image-ppm (image crop)
  "Encode IMAGE's CROP as PPM on graphical builds without native PNG.
Only RGB is representable.  RGBA is not made opaque, and transparent
padding is not synthesized in a format that cannot carry it."
  (pcase-let ((`(,width ,_height ,format ,pixels . ,_) image)
              (`(,x ,y ,crop-width ,crop-height) crop))
    (when (and (= format 24)
               (ubiquitty-sync--image-source-sound-p image crop crop-width crop-height))
      (let ((rows nil))
        (dotimes (row crop-height)
          (let ((start (+ (or (nth 4 image) 0) (* (+ (* (+ y row) width) x) 3))))
            (push (substring pixels start (+ start (* crop-width 3))) rows)))
        (concat (string-to-unibyte (format "P6\n%d %d\n255\n" crop-width crop-height))
                (apply #'concat (nreverse rows)))))))

(defun ubiquitty-sync--image-png (image crop padded-width padded-height)
  "Encode IMAGE's CROP in a PNG of PADDED-WIDTH by PADDED-HEIGHT.
IMAGE is (WIDTH HEIGHT FORMAT STORAGE OFFSET); CROP is (X Y WIDTH HEIGHT
[DRAWN-WIDTH DRAWN-HEIGHT]).  A drawn size resamples the crop to it, nearest
texel, as a placement's device-pixel size asks.  Padding is transparent, on
the right and bottom only.  This lets a native size image claim whole buffer
cells without stretching its edge pixels.  Dimensions, raw bytes and the
padded allocation are checked before copying."
  (pcase-let ((`(,width ,_height ,format ,pixels . ,_) image)
              (`(,x ,y ,crop-width ,crop-height ,drawn-width ,drawn-height) crop))
    (if (and drawn-width (or (/= drawn-width crop-width) (/= drawn-height crop-height)))
        (ubiquitty-sync--image-png-resampled image crop padded-width padded-height)
      (when (ubiquitty-sync--image-source-sound-p image crop padded-width padded-height)
        (let* ((padding (or (/= padded-width crop-width) (/= padded-height crop-height)))
               (rgba (or (= format 32) padding))
               (output-stride (* padded-width (if rgba 4 3)))
               (input-stride (* width (/ format 8)))
               (scanlines nil))
          (dotimes (row padded-height)
            (let ((line (string-to-unibyte (make-string (1+ output-stride) 0))))
              (when (< row crop-height)
                (let ((source (+ (or (nth 4 image) 0) (* (+ y row) input-stride) (* x (/ format 8)))))
                  (if (or (= format 32) (not padding))
                      (store-substring line 1 (substring pixels source (+ source (* crop-width (/ format 8)))))
                    (dotimes (column crop-width)
                      (let ((from (+ source (* column 3))) (to (1+ (* column 4))))
                        (aset line to (aref pixels from))
                        (aset line (+ to 1) (aref pixels (+ from 1)))
                        (aset line (+ to 2) (aref pixels (+ from 2)))
                        (aset line (+ to 3) 255))))))
              (push line scanlines)))
          (concat (unibyte-string #x89 ?P ?N ?G 13 10 26 10)
                  (ubiquitty-sync--png-chunk
                   "IHDR" (concat (ubiquitty-sync--png-u32 padded-width)
                                  (ubiquitty-sync--png-u32 padded-height)
                                  (unibyte-string 8 (if rgba 6 2) 0 0 0)))
                  (ubiquitty-sync--png-chunk
                   "IDAT" (ubiquitty-sync--png-deflate (apply #'concat (nreverse scanlines))))
                  (ubiquitty-sync--png-chunk "IEND" "")))))))

(defun ubiquitty-sync--image-png-resampled (image crop padded-width padded-height)
  "Encode IMAGE's CROP resampled to its drawn size.
The canvas is PADDED-WIDTH by PADDED-HEIGHT.  CROP is
\(X Y WIDTH HEIGHT DRAWN-WIDTH DRAWN-HEIGHT).  Each drawn pixel takes the
crop texel under its centre, so a whole-number enlargement keeps its edges.
The output is RGBA; RGB sources are opaque, padding transparent."
  (pcase-let ((`(,width ,_height ,format ,pixels . ,_) image)
              (`(,x ,y ,crop-width ,crop-height ,drawn-width ,drawn-height) crop))
    (when (ubiquitty-sync--image-source-sound-p image crop padded-width padded-height)
      (let* ((bytes-per-pixel (/ format 8))
             (input-stride (* width bytes-per-pixel))
             (base (or (nth 4 image) 0))
             (source-columns (make-vector drawn-width 0))
             (scanlines nil))
        (dotimes (column drawn-width)
          (aset source-columns column
                (* (+ x (/ (* (+ (* 2 column) 1) crop-width) (* 2 drawn-width))) bytes-per-pixel)))
        (dotimes (row padded-height)
          (let ((line (string-to-unibyte (make-string (1+ (* padded-width 4)) 0))))
            (when (< row drawn-height)
              (let ((source (+ base (* (+ y (/ (* (+ (* 2 row) 1) crop-height) (* 2 drawn-height))) input-stride))))
                (dotimes (column drawn-width)
                  (let ((from (+ source (aref source-columns column))) (to (1+ (* column 4))))
                    (aset line to (aref pixels from))
                    (aset line (+ to 1) (aref pixels (+ from 1)))
                    (aset line (+ to 2) (aref pixels (+ from 2)))
                    (aset line (+ to 3) (if (= format 32) (aref pixels (+ from 3)) 255))))))
            (push line scanlines)))
        (concat (unibyte-string #x89 ?P ?N ?G 13 10 26 10)
                (ubiquitty-sync--png-chunk
                 "IHDR" (concat (ubiquitty-sync--png-u32 padded-width)
                                (ubiquitty-sync--png-u32 padded-height)
                                (unibyte-string 8 6 0 0 0)))
                (ubiquitty-sync--png-chunk
                 "IDAT" (ubiquitty-sync--png-deflate (apply #'concat (nreverse scanlines))))
                (ubiquitty-sync--png-chunk "IEND" ""))))))

(defun ubiquitty-sync--image-layout (image placement cell-width cell-height)
  "Resolve IMAGE's PLACEMENT to the row renderer's cell-aligned geometry.
The result is (COLUMN ROW COLUMNS ROWS CROP PADDED-WIDTH PADDED-HEIGHT).
Zero source extents mean the remainder, clipped at the image edge.  A drawn
size is drawn at exactly that many pixels, the crop resampled to it, and
covers whole cells as source pixels do: the host's rule, with this frame's
pixels as the device pixels and its cells as the cells, so a drawn size and a
natural one agree.  A box with neither axis set uses source pixels, padded to
whole cells.  Both axes set use the stated cell box.  Single-axis boxes
remain unsupported.  Only whole-cell components of pixel offsets can move a
text replacement; sub-cell positioning and behind-text composition need a
different renderer."
  (pcase-let ((`(,width ,height ,_format ,_pixels . ,_) image)
              (`(,_id ,x ,y ,columns ,rows ,offset-x ,offset-y
                      ,source-x ,source-y ,source-width ,source-height
                      ,_alternate ,drawn-width ,drawn-height . ,_) placement))
    (when (and (> cell-width 0) (> cell-height 0))
      (let* ((crop-width (min (- width source-x) (if (> source-width 0) source-width width)))
             (crop-height (min (- height source-y) (if (> source-height 0) source-height height)))
             (drawn (and drawn-width drawn-height (> drawn-width 0) (> drawn-height 0))))
        (when (and (> crop-width 0) (> crop-height 0)
                   (or drawn (and (> columns 0) (> rows 0)) (and (= columns 0) (= rows 0))))
          (let* ((natural (or drawn (and (= columns 0) (= rows 0))))
                 (picture-width (if drawn drawn-width crop-width))
                 (picture-height (if drawn drawn-height crop-height))
                 (columns (if natural (ceiling picture-width cell-width) columns))
                 (rows (if natural (ceiling picture-height cell-height) rows)))
            (list (+ x (/ offset-x cell-width)) (+ y (/ offset-y cell-height)) columns rows
                  (if drawn
                      (list source-x source-y crop-width crop-height drawn-width drawn-height)
                    (list source-x source-y crop-width crop-height))
                  (if natural (* columns cell-width) crop-width)
                  (if natural (* rows cell-height) crop-height))))))))

(defun ubiquitty-sync--image-rendering (id image crop padded-width padded-height png-supported)
  "Return (TYPE . BYTES) for IMAGE ID's CROP and padded dimensions.
PNG-SUPPORTED selects native PNG; otherwise only unpadded RGB uses PPM.
The cache holds at most one raw-image budget plus PNG framing.  A changed
image or placement table clears it; font metrics are part of its key."
  (unless ubiquitty-sync--image-renderings
    (setq ubiquitty-sync--image-renderings (make-hash-table :test #'equal)))
  (let* ((type (if png-supported 'png 'pbm))
         (key (list type id crop padded-width padded-height)))
    (or (gethash key ubiquitty-sync--image-renderings)
        (when-let* ((bytes (if png-supported
                              (ubiquitty-sync--image-png image crop padded-width padded-height)
                            (and (= padded-width (nth 2 crop)) (= padded-height (nth 3 crop))
                                 (null (nth 4 crop))
                                 (ubiquitty-sync--image-ppm image crop)))))
          (when (> (+ ubiquitty-sync--image-rendering-bytes (length bytes))
                   (+ ubiquitty-sync--retained-asset-budget 65536))
            (clrhash ubiquitty-sync--image-renderings)
            (setq ubiquitty-sync--image-rendering-bytes 0))
          (setq ubiquitty-sync--image-rendering-bytes (+ ubiquitty-sync--image-rendering-bytes (length bytes)))
          (puthash key (cons type bytes) ubiquitty-sync--image-renderings)))))

(defun ubiquitty-sync--start-reassembly (id stream chunk-count)
  "Open a reassembly for image ID under STREAM, holding CHUNK-COUNT chunks.
The oldest reassembly goes when the table is at its ceiling, so a host that
opens streams and finishes none holds `ubiquitty-sync--max-image-reassemblies'
of them rather than one per id it can name."
  (unless ubiquitty-sync--image-chunks
    (setq ubiquitty-sync--image-chunks (make-hash-table)))
  (remhash id ubiquitty-sync--image-chunks)
  (while (>= (hash-table-count ubiquitty-sync--image-chunks)
             ubiquitty-sync--max-image-reassemblies)
    (let ((oldest nil) (oldest-tick nil))
      (maphash (lambda (key record)
                 (when (or (null oldest-tick) (< (aref record 3) oldest-tick))
                   (setq oldest key oldest-tick (aref record 3))))
               ubiquitty-sync--image-chunks)
      (remhash oldest ubiquitty-sync--image-chunks)))
  (setq ubiquitty-sync--image-chunk-clock (1+ ubiquitty-sync--image-chunk-clock))
  (puthash id (vector (make-vector chunk-count nil) 0 stream ubiquitty-sync--image-chunk-clock)
           ubiquitty-sync--image-chunks))

(defun ubiquitty-sync--apply-image (buf p)
  "Take one IMAGE chunk P for BUF; the last chunk of an image decodes it."
  (with-current-buffer buf
    (let* ((id (ubiquitty-sync--u32 p 0))
           (width (ubiquitty-sync--u16 p 4))
           (height (ubiquitty-sync--u16 p 6))
           (format (ubiquitty-sync--u16 p 8))
           (raw-length (ubiquitty-sync--u32 p 10))
           (compressed-length (ubiquitty-sync--u32 p 14))
           (chunk-count (ubiquitty-sync--u16 p 18))
           (chunk-index (ubiquitty-sync--u16 p 20))
           (chunk-length (ubiquitty-sync--u32 p 22))
           ;; virtualPlacement(1) + virtualColumns(2) + virtualRows(2) + virtualPlacementID(4)
           (data-at 35)
           (stream (list compressed-length raw-length width height format chunk-count)))
      (unless (ubiquitty-sync--image-header-sound-p
               width height format raw-length compressed-length chunk-count chunk-index)
        (error "ubiquitty-sync: IMAGE %d declares %d pixel bytes from %d compressed, of %dx%d"
               id raw-length compressed-length width height))
      (unless (<= (+ data-at chunk-length) (length p))
        (error "ubiquitty-sync: IMAGE %d chunk %d names %d bytes the frame does not carry"
               id chunk-index chunk-length))
      (when (= chunk-index 0)
        (ubiquitty-sync--start-reassembly id stream chunk-count))
      (let ((record (and ubiquitty-sync--image-chunks
                         (gethash id ubiquitty-sync--image-chunks))))
        ;; A chunk with no open reassembly is an orphan, and one whose header
        ;; disagrees with the chunk 0 that opened the stream is a second stream
        ;; spliced into the first id. Either way the reassembly ends.
        (unless (and record (equal (aref record 2) stream))
          (when record (remhash id ubiquitty-sync--image-chunks))
          (error "ubiquitty-sync: IMAGE %d chunk %d belongs to no open stream" id chunk-index))
        ;; The running total is bounded by the stream the header declared: the
        ;; whole-stream length is checked on the last chunk alone, so without
        ;; this a host streams chunk-count minus one near-cap chunks and the
        ;; accumulator grows to their sum.
        (when (> (+ (aref record 1) chunk-length) compressed-length)
          (remhash id ubiquitty-sync--image-chunks)
          (error "ubiquitty-sync: IMAGE %d chunks exceed the %d-byte stream they declare"
                 id compressed-length))
        (aset (aref record 0) chunk-index (substring p data-at (+ data-at chunk-length)))
        (aset record 1 (+ (aref record 1) chunk-length))
        (setq ubiquitty-sync--image-chunk-clock (1+ ubiquitty-sync--image-chunk-clock))
        (aset record 3 ubiquitty-sync--image-chunk-clock)
        (when (seq-every-p #'identity (aref record 0))
          (remhash id ubiquitty-sync--image-chunks)
          (when (= (aref record 1) compressed-length)
            (when-let* ((pixels (ubiquitty-sync--image-pixels-from
                              (apply #'concat (append (aref record 0) nil))
                              raw-length)))
              (unless ubiquitty-sync--images
                (setq ubiquitty-sync--images (make-hash-table)))
              (let ((previous-image (gethash id ubiquitty-sync--images)))
                (puthash id (list width height format pixels) ubiquitty-sync--images)
                (setq ubiquitty-sync--image-renderings nil ubiquitty-sync--image-rendering-bytes 0)
                (ubiquitty-sync--repaint-placed-rows
                 (seq-filter (lambda (placement) (= (car placement) id))
                             ubiquitty-sync--placements)
                 previous-image)))))))))

(defun ubiquitty-sync--repaint-placed-rows (placements &optional previous-image)
  "Lay out again every row PLACEMENTS cover.
PREVIOUS-IMAGE is the old picture when its pixels changed: a native-size
placement may have shrunk, and its old rows must lose their display slices."
  (when (and placements ubiquitty-sync--screen)
    (let* ((rows (length ubiquitty-sync--screen))
           (dirty (make-bool-vector rows nil)))
      (dolist (placement placements)
        (dolist (image (list previous-image
                            (and ubiquitty-sync--images (gethash (car placement) ubiquitty-sync--images))))
          (when-let* ((layout (and image (ubiquitty-sync--image-layout
                                         image placement (default-font-width) (default-font-height)))))
            (let ((row (max 0 (nth 1 layout)))
                  (end (+ (nth 1 layout) (nth 3 layout))))
              (while (and (< row rows) (< row end))
                (aset dirty row t)
                (setq row (1+ row)))))))
      (ubiquitty-sync--paint-rows dirty))))

(defun ubiquitty-sync--apply-placements (buf p)
  "Take the IMAGE_PLACEMENTS body P for BUF: the placements and the live ids."
  (with-current-buffer buf
    (let ((at 0) (live nil) (placements nil))
      (let ((count (ubiquitty-sync--u16 p at)))
        (setq at (+ at 2))
        (dotimes (_image count)
          (push (ubiquitty-sync--u32 p at) live)
          (setq at (+ at 4))))
      (let ((count (ubiquitty-sync--u16 p at)))
        (setq at (+ at 2))
        (dotimes (_placement count)
          ;; imageID(4) placementID(4) hasPlacementID(1) cursorX(2) cursorY(2)
          ;; cellColumns(2) cellRows(2) pixelOffsetX(2) pixelOffsetY(2)
          ;; sourceX(2) sourceY(2) sourceWidth(2) sourceHeight(2) zIndex(4)
          ;; cursorPolicy(1): 34 bytes
          (let ((id (ubiquitty-sync--u32 p at))
                (x (ubiquitty-sync--u16 p (+ at 9)))
                (y (ubiquitty-sync--i16 p (+ at 11)))
                (columns (ubiquitty-sync--u16 p (+ at 13)))
                (height (ubiquitty-sync--u16 p (+ at 15)))
                (offset-x (ubiquitty-sync--u16 p (+ at 17)))
                (offset-y (ubiquitty-sync--u16 p (+ at 19)))
                (source-x (ubiquitty-sync--u16 p (+ at 21)))
                (source-y (ubiquitty-sync--u16 p (+ at 23)))
                (source-width (ubiquitty-sync--u16 p (+ at 25)))
                (source-height (ubiquitty-sync--u16 p (+ at 27))))
            (push (list id x y columns height offset-x offset-y
                        source-x source-y source-width source-height) placements)
            (setq at (+ at 34)))))
      (when (> at (length p))
        (error "ubiquitty-sync: IMAGE_PLACEMENTS of %d bytes ends before its tail at %d"
               (length p) at))
      (let ((previous ubiquitty-sync--placements))
        (setq ubiquitty-sync--placements (nreverse placements))
        (setq ubiquitty-sync--image-renderings nil ubiquitty-sync--image-rendering-bytes 0)
        (ubiquitty-sync--repaint-placed-rows (append previous ubiquitty-sync--placements)))
      ;; Old dimensions are still needed while clearing a removed placement.
      (when ubiquitty-sync--images
        (let ((dead nil))
          (maphash (lambda (id _image) (unless (memql id live) (push id dead)))
                   ubiquitty-sync--images)
          (dolist (id dead) (remhash id ubiquitty-sync--images)))))))

;; ---- theme -----------------------------------------------------------

(defconst ubiquitty-sync--builtin-themes
  '(("Noir"
     ("#2e323b" "#dd717a" "#98c896" "#e3be7c" "#72a3e8" "#c189d9" "#66c0c8" "#c8ccd4"
      "#5a606e" "#ea8088" "#a9d89f" "#efce8e" "#8ab5ee" "#d09fe5" "#7ccfd6" "#eaedf2")
     "#c8ccd4" "#15171c" "#e0e4ec")
    ("Noir Clair"
     ("#32363c" "#a7414c" "#416d40" "#7f5d17" "#3564a4" "#834d99" "#006e76" "#ccd2dd"
      "#8c93a2" "#93313e" "#345d2b" "#6b4f04" "#2e5587" "#6e4181" "#005d64" "#1c1f23")
     "#32363c" "#f4f5f8" "#22252b"))
  "The house theme pair: (NAME ANSI16 FG BG CURSOR), each colour \"#rrggbb\".
The same values as the tree's builtin-themes.toml, so a package installed
without the table still colours a session the way the app does by default.")

(defun ubiquitty-sync--themes-from-file (file)
  "Read the [[themes]] tables of FILE, Ubiquitty's builtin-themes.toml.
Each theme becomes (NAME ANSI16 FG BG CURSOR); a table missing a field is
left out."
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (let ((themes nil) (name nil) (ansi nil) (fg nil) (bg nil) (cursor nil))
        (cl-flet ((finish ()
                    (when (and name ansi fg bg cursor (= (length ansi) 16))
                      (push (list name ansi fg bg cursor) themes))
                    (setq name nil ansi nil fg nil bg nil cursor nil)))
          (goto-char (point-min))
          (while (not (eobp))
            (let ((line (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
              (cond
               ((string-match-p "^\\[\\[themes\\]\\]" line) (finish))
               ((string-match "^name = \"\\([^\"]*\\)\"" line) (setq name (match-string 1 line)))
               ((string-match "^ansi = \\[\\(.*\\)\\]" line)
                (let ((entries nil) (start 0) (body (match-string 1 line)))
                  (while (string-match "\"\\(#[0-9a-fA-F]\\{6\\}\\)\"" body start)
                    (push (match-string 1 body) entries)
                    (setq start (match-end 0)))
                  (setq ansi (nreverse entries))))
               ((string-match "^fg = \"\\(#[0-9a-fA-F]\\{6\\}\\)\"" line) (setq fg (match-string 1 line)))
               ((string-match "^bg = \"\\(#[0-9a-fA-F]\\{6\\}\\)\"" line) (setq bg (match-string 1 line)))
               ((string-match "^cursor = \"\\(#[0-9a-fA-F]\\{6\\}\\)\"" line) (setq cursor (match-string 1 line)))))
            (forward-line 1))
          (finish))
        (nreverse themes)))))

(defun ubiquitty-sync--configured-theme-name ()
  "Return the theme name to apply: the option, the config file's, or Noir."
  (or ubiquitty-sync-theme
      (let ((config (expand-file-name "~/.config/ubiquitty/config.toml")))
        (when (file-readable-p config)
          (with-temp-buffer
            (insert-file-contents config)
            (goto-char (point-min))
            (when (re-search-forward "^theme = \"\\([^\"]+\\)\"" nil t)
              (match-string 1)))))
      "Noir"))

(defun ubiquitty-sync--theme (name)
  "Return the theme called NAME as (NAME ANSI16 FG BG CURSOR), or nil."
  (or (assoc name (ubiquitty-sync--themes-from-file ubiquitty-sync-theme-file))
      (assoc name ubiquitty-sync--builtin-themes)))

(defun ubiquitty-sync--put-rgb16 (hex)
  "Return the wire form of colour HEX, \"#rrggbb\": three little-endian u16."
  (let ((r (string-to-number (substring hex 1 3) 16))
        (g (string-to-number (substring hex 3 5) 16))
        (b (string-to-number (substring hex 5 7) 16)))
    (concat (ubiquitty-sync--put-u16 (* r 257))
            (ubiquitty-sync--put-u16 (* g 257))
            (ubiquitty-sync--put-u16 (* b 257)))))

(defun ubiquitty-sync--cube-rgb (index)
  "Return the xterm cube or grey colour at INDEX, 16 to 255, as \"#rrggbb\"."
  (if (< index 232)
      (let* ((v (- index 16))
             (level (lambda (n) (if (zerop n) 0 (+ 55 (* n 40))))))
        (format "#%02x%02x%02x"
                (funcall level (/ v 36))
                (funcall level (% (/ v 6) 6))
                (funcall level (% v 6))))
    (let ((g (min 238 (+ 8 (* (- index 232) 10)))))
      (format "#%02x%02x%02x" g g g))))

;; ---- session end -----------------------------------------------------

(defun ubiquitty-sync--session-ended (proc buf)
  "Record that the session behind PROC ended; kill BUF unless the option keeps it.
The bridge closes after the host's EXIT, and the sentinel says nothing more
about a session that ended on its own."
  (process-put proc 'exited t)
  (when (buffer-live-p buf)
    (if ubiquitty-sync-kill-buffer-on-exit
        (let ((win (get-buffer-window buf t)))
          (if (and win (not (window-minibuffer-p win)) (not (one-window-p t (window-frame win))))
              (quit-window t win)
            (kill-buffer buf)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (goto-char (point-max))
          (insert "\n[ubiquitty-sync: session ended]")
          (setq-local cursor-type nil))))))

;; ---- input -----------------------------------------------------------

(defun ubiquitty-sync--bytes-for-event (event)
  "Translate a character EVENT into the byte string to send, or nil."
  (when (integerp event)
    (if (< event 128)
        (unibyte-string event)
      (encode-coding-string (char-to-string event) 'utf-8 t))))

(defun ubiquitty-sync--event-modifier-bits (event)
  "The key encoder's modifier bits for EVENT."
  (let ((modifiers (event-modifiers event)))
    (logior (if (memq 'shift modifiers) ubiquitty-sync--modifier-shift 0)
            (if (memq 'meta modifiers) ubiquitty-sync--modifier-alternate 0)
            (if (memq 'control modifiers) ubiquitty-sync--modifier-ctrl 0))))

(defun ubiquitty-sync--event-base (event)
  "The key the symbol EVENT names with its modifier prefixes removed.
`S-up' is `up'.  Read off the name, which is what a modified function key
is whether or not Emacs has parsed it."
  (intern (replace-regexp-in-string "\\`\\(?:[ACHMSs]-\\)+" "" (symbol-name event))))

(defun ubiquitty-sync--virtual-key (name)
  "The `Keys::VirtualKey' number the key NAME is sent as, or nil for no such key."
  (alist-get (alist-get name ubiquitty-sync--virtual-keys) ubiquitty-sync--virtual-key-numbers))

(defun ubiquitty-sync-send-key ()
  "Forward the triggering key event to the host.
A named key goes as the key it is, for the host to encode under the
program's live modes; a character goes as its bytes."
  (interactive)
  (when ubiquitty-sync--process
    (let* ((event last-command-event)
           (key (and (symbolp event)
                     (ubiquitty-sync--virtual-key (ubiquitty-sync--event-base event)))))
      (if key
          (ubiquitty-sync--send-key-event key (ubiquitty-sync--event-modifier-bits event))
        (let ((bytes (ubiquitty-sync--bytes-for-event event)))
          (when bytes (ubiquitty-sync--send-raw bytes)))))))

(defun ubiquitty-sync-send-meta ()
  "Forward the triggering Meta key as ESC plus the base byte.
For example Meta-b is sent as the two bytes ESC b.  Bound under the ESC
prefix map; see `ubiquitty-sync-mode-map'."
  (interactive)
  (let ((ev last-command-event))
    (when (and (integerp ev) ubiquitty-sync--process)
      (ubiquitty-sync--send-raw
       (concat "\e" (if (< ev 128)
                        (unibyte-string ev)
                      (encode-coding-string (char-to-string ev) 'utf-8 t)))))))

(defun ubiquitty-sync-send-escape ()
  "Forward a lone Escape key (for vi etc.)."
  (interactive)
  (when ubiquitty-sync--process
    (ubiquitty-sync--send-key-event (ubiquitty-sync--virtual-key 'escape) 0)))

(defun ubiquitty-sync--mouse-on-p ()
  "Return non-nil when the host program has any mouse tracking enabled."
  ubiquitty-sync--mouse-tracking)

(defun ubiquitty-sync--posn-cell (posn)
  "Return (COL . ROW) 1-based terminal cell for mouse POSN.
Derived from the buffer position, not window pixels, so it is immune
to the header line, scrolling, and margins: the buffer is an exact
1:1 grid where buffer line N is terminal row N."
  (let ((pt (posn-point posn)))
    (if pt
        (cons (1+ (save-excursion (goto-char pt) (current-column)))
              (line-number-at-pos pt))
      (cons 1 1))))

(defun ubiquitty-sync--send-mouse (posn button release)
  "Send a pointer event for BUTTON at POSN (RELEASE non-nil = up).
The host writes the report in the encoding the program asked for, SGR or
the legacy one, so this client states the button and the cell alone."
  (let ((cell (ubiquitty-sync--posn-cell posn)))
    (ubiquitty-sync--send-pointer-event (if release 1 0) button
                                        (1- (cdr cell)) (1- (car cell)))))

(defun ubiquitty-sync--paste-text (text)
  "Paste TEXT into the session.
The host brackets it when the program asked for bracketed paste, and it is
sent no faster than the program reads it."
  (when ubiquitty-sync--process
    (ubiquitty-sync--paste-bytes (encode-coding-string text 'utf-8 t))))

(defun ubiquitty-sync-yank ()
  "Paste the most recent kill into the terminal.
The terminal buffer is read-only: the text goes to the host as input,
which is where a paste lands in a terminal."
  (interactive)
  (ubiquitty-sync--paste-text (current-kill 0)))

(defun ubiquitty-sync-xterm-paste (event)
  "Paste the text a terminal handed Emacs as a bracketed paste EVENT."
  (interactive "e")
  (ubiquitty-sync--paste-text (nth 1 event)))

(defun ubiquitty-sync-mouse (event button release)
  "Forward EVENT as a mouse BUTTON report, else act locally.
RELEASE non-nil means a button-up; for a release that ended a drag, the
drag's end position is used.  The clicked window is selected first, so
the terminal cursor follows the click into this buffer."
  (interactive "e")
  (let* ((posn (if release (event-end event) (event-start event)))
         (win (posn-window posn)))
    (when (and (window-live-p win) (not (eq win (selected-window))))
      (select-window win))
    (cond
     ((and (ubiquitty-sync--mouse-on-p) ubiquitty-sync--process)
      (ubiquitty-sync--send-mouse posn button release))
     ;; Host has no mouse mode: keep a left-press useful locally.
     ((and (= button 0) (not release))
      (let ((pt (posn-point posn))) (when pt (goto-char pt))))
     ;; A middle click pastes the primary selection, as a terminal does.
     ((and (= button 1) release)
      (ubiquitty-sync--paste-text (or (gui-get-primary-selection) ""))))))

(defun ubiquitty-sync-wheel (event down)
  "Forward EVENT as a scroll-wheel report (DOWN non-nil) or scroll locally."
  (interactive "e")
  (if (and (ubiquitty-sync--mouse-on-p) ubiquitty-sync--process)
      (ubiquitty-sync--send-mouse (event-start event) (if down 65 64) nil)
    (ignore-errors (if down (scroll-up 3) (scroll-down 3)))))

(defun ubiquitty-sync--geometry (&optional win)
  "Return (COLS . ROWS) for WIN as a terminal size.
COLS is `window-max-chars-per-line', which already excludes the column
Emacs reserves for the continuation/truncation glyph (and any
line-number/fringe columns) — the same width term.el/vterm/eat send to
their PTYs.  Using it avoids both the trailing \"$\" markers and a
right-edge gap."
  (let ((win (or win (get-buffer-window (current-buffer) t))))
    (if win
        (cons (max 1 (window-max-chars-per-line win))
              (max 1 (window-body-height win)))
      (cons 80 24))))

(defun ubiquitty-sync-resize ()
  "Send the current window geometry to the host, in a Facts and a Viewport."
  (interactive)
  (let ((win (get-buffer-window (current-buffer) t)))
    (when (and win ubiquitty-sync--process)
      (let ((geom (ubiquitty-sync--geometry win)))
        ;; Only a change reaches the host: the size-change hook runs for
        ;; window events that leave this window's body as it was.
        (unless (and (eql (car geom) ubiquitty-sync--columns)
                     (eql (cdr geom) ubiquitty-sync--rows))
          (setq ubiquitty-sync--columns (car geom)
                ubiquitty-sync--rows (cdr geom))
          ;; The window's size travels in a Facts of the client's own, and
          ;; the pane's in its Viewport.
          (ubiquitty-sync--send-facts)
          (ubiquitty-sync--send-viewport))))))

(defun ubiquitty-sync--window-size-changed (_frame)
  "Resize the host terminal to match the new window size.
Bound buffer-locally to `window-size-change-functions'; FRAME is ignored."
  (when ubiquitty-sync--process (ubiquitty-sync-resize)))

(defun ubiquitty-sync-detach ()
  "Detach from the host and kill the buffer; the session is left running."
  (interactive)
  ;; A detach ends the attachment, so there is nothing left to resume.
  (ubiquitty-sync--purge-record)
  (when (process-live-p ubiquitty-sync--process)
    (ubiquitty-sync--send-sync ubiquitty-sync--process ubiquitty-sync--kind-bye 0
                                (concat (unibyte-string ubiquitty-sync--bye-reason-normal)
                                        (ubiquitty-sync--put-bytes "") (unibyte-string 0)))
    (delete-process ubiquitty-sync--process))
  (kill-buffer (current-buffer)))

;; ---- keymap + mode ---------------------------------------------------

(defvar ubiquitty-sync-escape-map
  (let ((m (make-sparse-keymap)))
    ;; Reached as `C-c <key>'. Emacs-side commands that the terminal never sees
    ;; to the host (so C-x, C-c, etc. themselves still reach a nested program).
    (define-key m (kbd "C-q") #'ubiquitty-sync-detach)
    (define-key m (kbd "o")   #'other-window)
    (define-key m (kbd "C-c") ; C-c C-c -> send a literal C-c (SIGINT)
                (lambda () (interactive)
                  (when ubiquitty-sync--process
                    (ubiquitty-sync--send-raw "\C-c"))))
    m)
  "Keymap reached via the `C-c' escape prefix in `ubiquitty-sync-mode'.")

(defvar ubiquitty-sync-mode-map
  ;; Built like term.el's `term-raw-map': forward every byte 0-127, but bind
  ;; ESC to a PREFIX map (not a send) so `input-decode-map' can still decode
  ;; mouse / arrow / function-key sequences instead of the raw bytes leaking
  ;; to the shell.  See the research in the commit message.
  (let ((map (make-keymap))
        (esc-map (make-keymap))
        (i 0))
    (while (< i 128)
      ;; Forward the bare byte — EXCEPT ESC (27), which becomes a prefix below.
      (unless (= i 27)
        (define-key map (vector i) #'ubiquitty-sync-send-key))
      ;; Meta forms (ESC + byte). Leave ?O (79) and ?\[ (91) UNBOUND so
      ;; "ESC O ..." / "ESC [ ..." are decoded by input-decode-map.
      (unless (or (= i ?O) (= i 91))
        (define-key esc-map (vector i) #'ubiquitty-sync-send-meta))
      (setq i (1+ i)))
    (define-key map [remap self-insert-command] #'ubiquitty-sync-send-key)
    (define-key map "\e" esc-map)                  ; ESC = Meta prefix
    (define-key map [escape] #'ubiquitty-sync-send-escape) ; lone Escape
    ;; Decoded named keys (delivered by input-decode-map / function-key-map).
    (dolist (k '(return kp-enter tab backspace delete deletechar
                 up down left right home end prior next))
      (define-key map (vector k) #'ubiquitty-sync-send-key))
    ;; Mouse: forwarded as host reports when the program wants mouse, else
    ;; handled locally.  xterm-mouse-mode decodes the raw sequences for us.
    (define-key map [down-mouse-1] (lambda (e) (interactive "e") (ubiquitty-sync-mouse e 0 nil)))
    (define-key map [mouse-1]      (lambda (e) (interactive "e") (ubiquitty-sync-mouse e 0 t)))
    (define-key map [drag-mouse-1] (lambda (e) (interactive "e") (ubiquitty-sync-mouse e 0 t)))
    (define-key map [down-mouse-2] (lambda (e) (interactive "e") (ubiquitty-sync-mouse e 1 nil)))
    (define-key map [mouse-2]      (lambda (e) (interactive "e") (ubiquitty-sync-mouse e 1 t)))
    (define-key map [down-mouse-3] (lambda (e) (interactive "e") (ubiquitty-sync-mouse e 2 nil)))
    (define-key map [mouse-3]      (lambda (e) (interactive "e") (ubiquitty-sync-mouse e 2 t)))
    (define-key map [wheel-up]     (lambda (e) (interactive "e") (ubiquitty-sync-wheel e nil)))
    (define-key map [wheel-down]   (lambda (e) (interactive "e") (ubiquitty-sync-wheel e t)))
    (define-key map [mouse-4]      (lambda (e) (interactive "e") (ubiquitty-sync-wheel e nil)))
    (define-key map [mouse-5]      (lambda (e) (interactive "e") (ubiquitty-sync-wheel e t)))
    ;; A paste is input for the host: every yank binding and a terminal's
    ;; bracketed paste event reach the session rather than the buffer.
    (define-key map [remap yank] #'ubiquitty-sync-yank)
    (define-key map [remap yank-pop] #'ubiquitty-sync-yank)
    (define-key map [remap clipboard-yank] #'ubiquitty-sync-yank)
    (define-key map [remap mouse-yank-primary] #'ubiquitty-sync-yank)
    (define-key map [xterm-paste] #'ubiquitty-sync-xterm-paste)
    ;; Escape prefix for Emacs-side commands (C-c C-q detach, C-c o other-window).
    (define-key map (kbd "C-c") ubiquitty-sync-escape-map)
    map)
  "Keymap for `ubiquitty-sync-mode'.")

(define-derived-mode ubiquitty-sync-mode special-mode "Ubiquitty"
  "Major mode for a ubiquitty-host Sync terminal buffer."
  ;; `cursor-type' is set per-frame from the host's reported cursor shape +
  ;; visibility; see `ubiquitty-sync--paint'.
  (setq-local buffer-read-only t)
  ;; A grid row is exactly the host's column count; in a window of that
  ;; same width an un-truncated line wraps to a phantom second screen
  ;; line ("skipping lines").  Truncate so each row stays one line.
  (setq-local truncate-lines t)
  (buffer-disable-undo)
  ;; In a TUI, mouse motion arrives as raw ESC[<...M byte sequences. Let
  ;; Emacs decode them into mouse events (which our keymap translates to
  ;; host reports) instead of relaying each byte to the shell as garbage.
  (unless (display-graphic-p)
    (xterm-mouse-mode 1))
  (add-hook 'window-size-change-functions
            #'ubiquitty-sync--window-size-changed nil t)
  ;; Selecting another window takes the keyboard from this buffer, and
  ;; coming back gives it again.
  (add-hook 'window-selection-change-functions
            #'ubiquitty-sync--note-focus nil t))

;; A frame gaining or losing the window system's focus moves it for the
;; buffer its selected window shows.
(add-function :after after-focus-change-function #'ubiquitty-sync--note-focus)

;; ---- the window across a restart -------------------------------------
;;
;; Core owns the resume record, its proof and its rules (Docs/sync.md §6.9);
;; this client owns only where the bytes live, a private file under
;; `ubiquitty-sync-state-directory'.  The host program reads and writes it
;; (`ubiquitty-host resume-record'): handed the picture this buffer holds as
;; the host's own wire bytes, it stores the record a Core client would, and
;; reads back the picture to draw and the tail the next Greet ends with.

(defun ubiquitty-sync--hold-update (blocks links clusters rich-texts history-head digest)
  "Keep what an applied update changed of the host's wire bytes.
BLOCKS are (BLOCK . BYTES), newest first; LINKS (ID . BYTES), oldest first;
CLUSTERS the table every defined cluster's bytes are in; RICH-TEXTS the
definitions, newest first; HISTORY-HEAD the history head the update names;
DIGEST the state digest it ends with."
  (when ubiquitty-sync--held-blocks
    (let ((held (copy-sequence ubiquitty-sync--held-blocks)))
      (dolist (block (reverse blocks))
        (when (< (car block) (length held))
          (aset held (car block) (cdr block))))
      (setq ubiquitty-sync--held-blocks held)))
  (dolist (link links)
    (setq ubiquitty-sync--held-links
          (append (cl-remove (car link) ubiquitty-sync--held-links :key #'car) (list link))))
  (setq ubiquitty-sync--held-clusters clusters
        ubiquitty-sync--held-rich-texts (append rich-texts ubiquitty-sync--held-rich-texts)
        ubiquitty-sync--held-digest digest)
  (when ubiquitty-sync--held-history
    (setq ubiquitty-sync--held-history (cons (car ubiquitty-sync--held-history) history-head))))

(defun ubiquitty-sync--held-checkpoint ()
  "The checkpoint body of the screen held, in the host's numbering, or empty.
Empty before a checkpoint, and after the host cleared the history until the
screen is newer than the generation it cleared."
  (if (not (and ubiquitty-sync--generation ubiquitty-sync--held-digest ubiquitty-sync--held-blocks
                ubiquitty-sync--row-records ubiquitty-sync--held-ground ubiquitty-sync--held-runs
                (or (null ubiquitty-sync--reset-generation)
                    (> ubiquitty-sync--generation ubiquitty-sync--reset-generation))))
      ""
    (let* ((active ubiquitty-sync--active-screen)
           (records ubiquitty-sync--row-records)
           (pens ubiquitty-sync--pens)
           (clusters ubiquitty-sync--held-clusters)
           (rich-texts (reverse ubiquitty-sync--held-rich-texts)))
      (apply #'concat
             (ubiquitty-sync--put-u64 ubiquitty-sync--generation)
             (ubiquitty-sync--put-u32 ubiquitty-sync--dictionary-epoch)
             (ubiquitty-sync--put-u16 (length (aref records 0)))
             (ubiquitty-sync--put-u16 ubiquitty-sync--screen-columns)
             (unibyte-string active)
             (append
              (cl-loop for slot below 7
                       collect (ubiquitty-sync--put-bytes
                                (aref ubiquitty-sync--held-blocks
                                      (aref ubiquitty-sync--checkpoint-block-order slot))))
              (list (ubiquitty-sync--put-varint (hash-table-count pens)))
              (cl-loop for id below (hash-table-count pens) collect (gethash id pens))
              (list (ubiquitty-sync--put-varint (length ubiquitty-sync--held-links)))
              (mapcar #'cdr ubiquitty-sync--held-links)
              (list (ubiquitty-sync--put-varint (hash-table-count clusters)))
              (cl-loop for id from 1 to (hash-table-count clusters) collect (gethash id clusters))
              (list ubiquitty-sync--held-runs
                    (ubiquitty-sync--put-varint (length rich-texts)))
              rich-texts
              (mapcar #'ubiquitty-sync--put-bytes (aref records active))
              (mapcar #'ubiquitty-sync--put-bytes (aref records (- 1 active)))
              (list (ubiquitty-sync--put-u32 (car ubiquitty-sync--held-history))
                    (ubiquitty-sync--put-u64 (cdr ubiquitty-sync--held-history))
                    (ubiquitty-sync--put-bytes ubiquitty-sync--held-ground)
                    ubiquitty-sync--held-digest))))))

(defun ubiquitty-sync--state-file (name)
  "The file NAME in the state directory, made private to its owner first."
  (let ((directory (file-name-as-directory (expand-file-name ubiquitty-sync-state-directory))))
    (unless (file-directory-p directory)
      (with-file-modes #o700 (make-directory directory t)))
    (set-file-modes directory #o700)
    (expand-file-name name directory)))

(defun ubiquitty-sync--stored-client-instance ()
  "This Emacs's client instance as its 16 wire bytes, kept across restarts."
  (let* ((file (ubiquitty-sync--state-file "client-instance"))
         (stored (and (file-readable-p file)
                      (with-temp-buffer
                        (insert-file-contents-literally file)
                        (string-trim (buffer-string))))))
    (if (and stored (string-match-p "\\`[0-9a-f]\\{32\\}\\'" stored)
             (not (string-match-p "\\`0+\\'" stored)))
        (apply #'unibyte-string
               (cl-loop for index below 16
                        collect (string-to-number (substring stored (* 2 index) (+ 2 (* 2 index))) 16)))
      (let ((instance (apply #'unibyte-string (cl-loop repeat 16 collect (random 256)))))
        (with-file-modes #o600
          (with-temp-file file
            (insert (mapconcat (lambda (byte) (format "%02x" byte)) instance "") "\n")))
        instance))))

(defun ubiquitty-sync--record-tool (verb &optional input)
  "Run the host program's resume-record VERB on this Emacs's record.
INPUT is written to its standard input.  Returns (STATUS . OUTPUT), or nil
in a buffer no `ubiquitty-sync' attached, which keeps no record."
  (when-let* ((program ubiquitty-sync--program)
              (file (ubiquitty-sync--state-file "resume.record")))
    (let ((coding-system-for-read 'binary)
          (coding-system-for-write 'binary))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (let ((status (if input
                          (call-process-region input nil program nil t nil "resume-record" verb file)
                        (call-process program nil t nil "resume-record" verb file))))
          (cons status (buffer-string)))))))

(defun ubiquitty-sync--persist ()
  "Store this buffer's resume record: the attachment and the screen held.
Only once a Welcome named the attachment; the bytes are Core's to check."
  (let ((welcome ubiquitty-sync--welcome))
    (when (and welcome ubiquitty-sync--effect-pane ubiquitty-sync--client-instance
               (plist-get welcome :attachment)
               (or (null ubiquitty-sync--consent-phase) (equal ubiquitty-sync--consent-phase "approved")))
      (let ((picture (ubiquitty-sync--held-checkpoint))
            (cursor (or ubiquitty-sync--effect-cursor (vector 0 0))))
        (ubiquitty-sync--record-tool
         "write"
         (concat (plist-get welcome :host-instance) ubiquitty-sync--client-instance
                 (plist-get welcome :attachment) (plist-get welcome :resume-secret)
                 ubiquitty-sync--effect-pane
                 (ubiquitty-sync--put-u64 ubiquitty-sync--input-seq)
                 (unibyte-string #xff)
                 (ubiquitty-sync--put-u64 (aref cursor 0))
                 (ubiquitty-sync--put-u64 (aref cursor 1))
                 (ubiquitty-sync--put-u32 (length picture))
                 picture))))))

(defun ubiquitty-sync--purge-record ()
  "Remove this Emacs's resume record."
  (ubiquitty-sync--record-tool "purge"))

(defun ubiquitty-sync--read-record (instance)
  "The stored record of client INSTANCE, as a plist, or nil.
A record of another instance is purged rather than drawn."
  (let ((answer (ubiquitty-sync--record-tool "read")))
    (when (eql (car answer) 0)
      (condition-case nil
          (let* ((bytes (cdr answer))
                 (r (ubiquitty-sync--reader bytes))
                 (at (ubiquitty-sync--take r 16))
                 (stored (substring bytes at (+ at 16)))
                 (tail-length (ubiquitty-sync--r-u32 r))
                 (tail-at (ubiquitty-sync--take r tail-length))
                 (tail (substring bytes tail-at (+ tail-at tail-length)))
                 (panes nil))
            (dotimes (_ (ubiquitty-sync--r-u16 r))
              (let* ((pane-at (ubiquitty-sync--take r 16))
                     (seq (ubiquitty-sync--r-u64 r))
                     (acknowledged (ubiquitty-sync--r-u64 r))
                     (consumed (ubiquitty-sync--r-u64 r))
                     (picture-length (ubiquitty-sync--r-u32 r))
                     (picture-at (ubiquitty-sync--take r picture-length)))
                (push (list (substring bytes pane-at (+ pane-at 16)) seq acknowledged consumed
                            (substring bytes picture-at (+ picture-at picture-length)))
                      panes)))
            (cond ((not (ubiquitty-sync--r-end-p r)) nil)
                  ((not (equal stored instance)) (ubiquitty-sync--purge-record) nil)
                  (t (list :tail tail :panes (nreverse panes)))))
        (error nil)))))

(defun ubiquitty-sync--restore (buf record)
  "Draw RECORD's stored screen into BUF and arrange for the Greet to resume it.
Nothing is sent: the picture is the one held when the record was written,
and the host's diff brings it up to date once the Greet is answered."
  (with-current-buffer buf
    (let ((pane (car (plist-get record :panes))))
      (when pane
        (pcase-let ((`(,id ,seq ,acknowledged ,consumed ,picture) pane))
          (condition-case nil
              (progn
                ;; The pane's bind finds its pane already named and keeps the
                ;; picture, so the connection state a bind starts is started here.
                (ubiquitty-sync--reset-image-connection)
                (ubiquitty-sync--reset-sample-connection)
                (unless (string-empty-p picture)
                  (ubiquitty-sync--apply-checkpoint buf picture))
                (setq ubiquitty-sync--effect-pane id
                      ubiquitty-sync--effect-cursor (ubiquitty-sync--effect-cursor (cons acknowledged consumed))
                      ubiquitty-sync--input-seq seq
                      ubiquitty-sync--resume-tail (plist-get record :tail))
                (message "ubiquitty-sync: showing the stored screen; reconnecting"))
            (error (ubiquitty-sync--forget-restored))))))))

(defun ubiquitty-sync--forget-restored ()
  "Let go of a restored attachment the host did not continue.
The pane the host binds next starts from its own checkpoint."
  (setq ubiquitty-sync--effect-pane nil ubiquitty-sync--effect-cursor nil
        ubiquitty-sync--generation nil ubiquitty-sync--input-seq 0
        ubiquitty-sync--resume-tail nil))

(defun ubiquitty-sync--persist-every-buffer ()
  "Store the record of every attached buffer, as Emacs exits."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (derived-mode-p 'ubiquitty-sync-mode) (process-live-p ubiquitty-sync--process))
        (ignore-errors (ubiquitty-sync--persist))))))

(add-hook 'kill-emacs-hook #'ubiquitty-sync--persist-every-buffer)

;; ---- connect ---------------------------------------------------------

(defun ubiquitty-sync--host-program ()
  "Return the absolute path of the host program, or signal a user error."
  (or (executable-find ubiquitty-sync-host-program)
      (user-error "No ubiquitty-host program; set `ubiquitty-sync-host-program'")))

(defun ubiquitty-sync--ensure-daemon (program)
  "Start PROGRAM's daemon with `--ensure-daemon'; a running daemon is left alone."
  (call-process program nil nil nil "--ensure-daemon"))

(defun ubiquitty-sync--attach (program)
  "Return a process running PROGRAM's attach bridge for this Emacs.
The bridge relays Sync frames between its stdio and the daemon socket, and
the daemon reads the bridge's binary as its own, which is what admits a
tokenless local client.  The bridge's stderr stays out of the frame stream."
  (make-process
   :name "ubiquitty-sync"
   :buffer nil
   :command (append (list program "--attach")
                    (and ubiquitty-sync-socket (list "--socket" ubiquitty-sync-socket)))
   :coding 'binary
   :connection-type 'pipe
   :noquery t
   :filter #'ubiquitty-sync--filter
   :sentinel #'ubiquitty-sync--sentinel
   :stderr (get-buffer-create " *ubiquitty-sync stderr*")))

(defun ubiquitty-sync--sentinel (proc _event)
  "Process sentinel for PROC: note the disconnect in its buffer.
EVENT is ignored.  The bridge's last stderr line names a refusal the frame
stream never carries, such as a missing daemon."
  (unless (or (process-live-p proc) (process-get proc 'exited))
    (let ((buf (process-get proc 'buffer)))
      (when (buffer-live-p buf)
        (with-current-buffer buf (ignore-errors (ubiquitty-sync--persist)))))
    (let ((buf (process-get proc 'buffer))
          (stderr (get-buffer " *ubiquitty-sync stderr*")))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (let ((inhibit-read-only t)
                (last-line (and stderr
                                (with-current-buffer stderr
                                  (string-trim (buffer-substring-no-properties
                                                (line-beginning-position 0) (point-max)))))))
            (goto-char (point-max))
            (insert (if (and last-line (not (string-empty-p last-line)))
                        (format "\n[ubiquitty-sync: disconnected: %s]" last-line)
                      "\n[ubiquitty-sync: disconnected]"))))))))

;;;###autoload
(defun ubiquitty-sync ()
  "Attach to the ubiquitty-host daemon and open a terminal buffer."
  (interactive)
  (let ((program (ubiquitty-sync--host-program)))
    (when ubiquitty-sync-auto-start
      (ubiquitty-sync--ensure-daemon program))
    (let ((buf (get-buffer-create "*ubiquitty*")))
      (with-current-buffer buf
        (ubiquitty-sync-mode)
        (when-let* ((stderr (get-buffer " *ubiquitty-sync stderr*")))
          (with-current-buffer stderr (erase-buffer))))
      ;; Displayed first: the handshake names the window's real size, so the
      ;; session starts at it rather than at a guess a resize has to correct.
      (pop-to-buffer buf)
      ;; The stored screen is drawn before the bridge starts, so before any
      ;; packet can arrive.
      (with-current-buffer buf
        (setq ubiquitty-sync--program program)
        (when-let* ((record (ubiquitty-sync--read-record (ubiquitty-sync--stored-client-instance))))
          (ubiquitty-sync--restore buf record)))
      (with-current-buffer buf
        (let* ((geom (ubiquitty-sync--geometry (get-buffer-window buf t)))
               (cols (car geom))
               (rows (cdr geom))
               (proc (ubiquitty-sync--attach program)))
          (process-put proc 'buffer buf)
          (process-put proc 'accum "")
          (setq ubiquitty-sync--process proc
                ubiquitty-sync--columns cols
                ubiquitty-sync--rows rows)
          (ubiquitty-sync--send-greet proc cols rows))))))

(provide 'ubiquitty-sync)
;;; ubiquitty-sync.el ends here
