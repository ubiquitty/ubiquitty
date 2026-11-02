;;; ubiquitty-sync-effects.el --- Typed effect receipts -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Stanislav Yaglo
;; SPDX-License-Identifier: MIT

;;; Commentary:
;; Bounded typed records and once-only receipt cursors.  The caller supplies the
;; authenticated pane binding and applied generation; wire fields grant neither.

;;; Code:

(defun ubiquitty-sync--effect-text (reader maximum)
  "Read strict UTF-8 from READER, bounded by MAXIMUM bytes before copying."
  (let* ((start (aref reader 1)) (size (ubiquitty-sync--r-varint reader)))
    (unless (and (<= size maximum)
                 (= (- (aref reader 1) start) (length (ubiquitty-sync--put-varint size))))
      (error "ubiquitty-sync: invalid Effect text length"))
    (let* ((at (ubiquitty-sync--take reader size))
           (text (decode-coding-string (substring (aref reader 0) at (+ at size)) 'utf-8)))
      (unless (cl-every (lambda (scalar) (and (<= scalar #x10ffff) (not (<= #xd800 scalar #xdfff)))) text)
        (error "ubiquitty-sync: invalid Effect UTF-8"))
      text)))

(defun ubiquitty-sync--read-clipboard-request (bytes)
  "Validate bounded ClipboardRequest BYTES without reading any local clipboard."
  (when (> (length bytes) ubiquitty-sync--max-frame-body)
    (error "ubiquitty-sync: oversized clipboard request"))
  (let* ((r (ubiquitty-sync--reader bytes)) (id (ubiquitty-sync--r-u32 r))
         (selector (ubiquitty-sync--r-u8 r)) (kind (ubiquitty-sync--r-u8 r))
         (mime (ubiquitty-sync--effect-text r ubiquitty-sync--max-effect-clipboard-mime-bytes)))
    (unless (and (> id 0) (< selector ubiquitty-sync--clipboard-buffer-count)
                 (memq kind (list ubiquitty-sync--effect-clipboard-request-types ubiquitty-sync--effect-clipboard-request-item))
                 (eq (= kind ubiquitty-sync--effect-clipboard-request-types) (equal mime ""))
                 (not (string-match-p "\0" mime)) (ubiquitty-sync--r-end-p r))
      (error "ubiquitty-sync: invalid clipboard request"))
    (list :id id :buffer selector :kind kind :mime mime)))

(defun ubiquitty-sync--sample-identity (r)
  "Read a bounded exact PCM identity from R without retaining PCM."
  (let* ((serial (ubiquitty-sync--r-u32 r)) (frames (ubiquitty-sync--r-u32 r))
         (at (ubiquitty-sync--take r 32)) (digest (substring (aref r 0) at (+ at 32))))
    (unless (and (<= frames ubiquitty-sync--sample-max-frames)
                 (or (> frames 0) (equal digest (make-string 32 0))))
      (error "ubiquitty-sync: invalid sample identity"))
    (list :serial serial :frames frames :digest digest)))

(defun ubiquitty-sync--clipboard-bundle (bytes maximum)
  "Validate complete binary BYTES within MAXIMUM data bytes, preserving MIME items."
  (let* ((metadata (+ 1 (* ubiquitty-sync--max-effect-clipboard-items
                           (+ 3 ubiquitty-sync--max-effect-clipboard-mime-bytes 4))))
         (r (ubiquitty-sync--reader bytes)) (items nil) (seen nil) (total 0))
    (when (or (> maximum ubiquitty-sync--max-effect-clipboard-read-bytes)
              (> (length bytes) (+ metadata maximum)))
      (error "ubiquitty-sync: oversized clipboard bundle"))
    (let ((start (aref r 1)) (count (ubiquitty-sync--r-varint r)))
      (unless (and (<= count ubiquitty-sync--max-effect-clipboard-items)
                   (= (- (aref r 1) start) (length (ubiquitty-sync--put-varint count))))
        (error "ubiquitty-sync: invalid clipboard item count"))
      (dotimes (_ count)
        (let* ((mime (ubiquitty-sync--effect-text r ubiquitty-sync--max-effect-clipboard-mime-bytes))
               (at (aref r 1)) (size (ubiquitty-sync--r-varint r)))
          (unless (and (> (length mime) 0) (not (string-match-p "\0" mime)) (not (member mime seen))
                       (<= size (- maximum total))
                       (= (- (aref r 1) at) (length (ubiquitty-sync--put-varint size))))
            (error "ubiquitty-sync: invalid clipboard MIME inventory or data size"))
          (push mime seen) (cl-incf total size)
          (let ((offset (ubiquitty-sync--take r size)))
            (push (cons mime (substring bytes offset (+ offset size))) items)))))
    (unless (ubiquitty-sync--r-end-p r) (error "ubiquitty-sync: trailing clipboard bundle"))
    (nreverse items)))

(defun ubiquitty-sync--clipboard-payload (r maximum)
  "Read R's exact inline or transferred clipboard descriptor within MAXIMUM."
  (let* ((transfer (ubiquitty-sync--r-u32 r)) (size (ubiquitty-sync--r-u32 r))
         (metadata (+ 1 (* ubiquitty-sync--max-effect-clipboard-items
                           (+ 3 ubiquitty-sync--max-effect-clipboard-mime-bytes 4))))
         (value (list :transfer transfer :encoded-bytes size :ready nil :items nil)))
    (unless (<= 1 size (+ metadata maximum)) (error "ubiquitty-sync: invalid clipboard descriptor"))
    (when (= transfer 0)
      (let ((at (ubiquitty-sync--take r size)))
        (setf (plist-get value :ready) t
              (plist-get value :items)
              (ubiquitty-sync--clipboard-bundle (substring (aref r 0) at (+ at size)) maximum))))
    value))

(defun ubiquitty-sync--read-sample-head (bytes)
  "Validate exact bounded SampleHead BYTES without allocating its PCM."
  (unless (= (length bytes) ubiquitty-sync--sample-head-bytes)
    (error "ubiquitty-sync: invalid SampleHead length"))
  (let* ((r (ubiquitty-sync--reader bytes)) (slot (ubiquitty-sync--r-u8 r))
         (identity (ubiquitty-sync--sample-identity r)) (transfer (ubiquitty-sync--r-u32 r)))
    (unless (and (<= 1 slot ubiquitty-sync--sample-slot-count)
                 (eq (= (plist-get identity :frames) 0) (= transfer 0)))
      (error "ubiquitty-sync: invalid SampleHead"))
    (list :slot slot :identity identity :transfer transfer)))

(defun ubiquitty-sync--effect-sound (r)
  "Read and validate a complete DECPS request from R without playing it."
  (let* ((volume (ubiquitty-sync--r-u8 r)) (wave (ubiquitty-sync--r-u8 r))
         (channel (ubiquitty-sync--r-u8 r)) (attack (ubiquitty-sync--r-u16 r))
         (release (ubiquitty-sync--r-u16 r)) (semitones (ubiquitty-sync--r-u8 r))
         (duration (ubiquitty-sync--r-u32 r)) (gap (ubiquitty-sync--r-u32 r))
         (sample (ubiquitty-sync--r-u8 r)) (decay (ubiquitty-sync--r-u16 r))
         (sustain (ubiquitty-sync--r-u8 r)) (reverb (ubiquitty-sync--r-u8 r))
         (grid (ubiquitty-sync--r-u8 r)) (lowpass (ubiquitty-sync--r-u16 r))
         (highpass (ubiquitty-sync--r-u16 r)) (pan (ubiquitty-sync--r-u8 r))
         (repeat-count (ubiquitty-sync--r-u8 r)) (count (ubiquitty-sync--r-u8 r)) (notes nil) (identity nil))
    (unless (and (<= volume ubiquitty-sync--max-tone-volume) (<= wave ubiquitty-sync--max-tone-wave)
                 (< channel ubiquitty-sync--tone-channel-count)
                 (or (= attack ubiquitty-sync--tone-default-envelope) (<= attack ubiquitty-sync--max-tone-envelope-milliseconds))
                 (or (= release ubiquitty-sync--tone-default-envelope) (<= release ubiquitty-sync--max-tone-envelope-milliseconds))
                 (<= semitones ubiquitty-sync--max-tone-semitones-down)
                 (<= duration (/ (* ubiquitty-sync--max-tone-duration-units 1000) 32)) (<= gap duration)
                 (<= sample ubiquitty-sync--sample-slot-count) (<= decay ubiquitty-sync--max-tone-envelope-milliseconds)
                 (<= sustain ubiquitty-sync--max-tone-volume) (<= reverb ubiquitty-sync--max-tone-volume)
                 (<= lowpass ubiquitty-sync--max-tone-cutoff-hertz) (<= highpass ubiquitty-sync--max-tone-cutoff-hertz)
                 (<= pan ubiquitty-sync--max-tone-pan) (<= count ubiquitty-sync--max-tone-notes))
      (error "ubiquitty-sync: invalid sound Effect"))
    (dotimes (_ count)
      (let ((frequency (ubiquitty-sync--r-u32 r)) (loudness (ubiquitty-sync--r-u8 r))
            (effect (ubiquitty-sync--r-u8 r)) (parameter (ubiquitty-sync--r-u8 r)))
        (unless (and (<= loudness ubiquitty-sync--max-tone-volume) (<= effect ubiquitty-sync--max-tone-effect))
          (error "ubiquitty-sync: invalid sound note"))
        (push (list frequency loudness effect parameter) notes)))
    (when (= wave 6)
      (setq identity (ubiquitty-sync--sample-identity r))
      (when (and (= sample 0) (> (plist-get identity :frames) 0))
        (error "ubiquitty-sync: sampled sound has no slot")))
    (list :volume volume :wave wave :channel channel :attack attack :release release :semitones semitones
          :duration duration :gap gap :sample sample :decay decay :sustain sustain :reverb reverb :grid grid
          :lowpass lowpass :highpass highpass :pan pan :repeat repeat-count :notes (nreverse notes) :identity identity)))

(defun ubiquitty-sync--read-effect (bytes)
  "Validate whole Effect packet BYTES without changing receipts or presentation."
  (when (> (length bytes) ubiquitty-sync--max-frame-body) (error "ubiquitty-sync: oversized Effect"))
  (let* ((r (ubiquitty-sync--reader bytes))
         (generation (ubiquitty-sync--r-u64 r)) (through (ubiquitty-sync--r-u64 r))
         (remaining (ubiquitty-sync--r-u16 r)) (record nil))
    (unless (and (> through 0) (< remaining ubiquitty-sync--max-effect-records))
      (error "ubiquitty-sync: invalid Effect batch"))
    (unless (ubiquitty-sync--r-end-p r)
      (let* ((record-generation (ubiquitty-sync--r-u64 r)) (sequence (ubiquitty-sync--r-u64 r))
             (primary-at (ubiquitty-sync--take r 16)) (primary (substring bytes primary-at (+ primary-at 16)))
             (kind (ubiquitty-sync--r-u8 r)) (count (ubiquitty-sync--r-u32 r)))
        (unless (and (> sequence 0) (> count 0) (<= record-generation generation) (<= (+ sequence remaining) through))
          (error "ubiquitty-sync: invalid Effect identity"))
        (setq record (list :generation record-generation :sequence sequence :primary primary :kind kind :count count))
        (cond
         ((= kind ubiquitty-sync--effect-kind-notification)
          (let* ((title (ubiquitty-sync--effect-text r ubiquitty-sync--max-attention-bytes))
                 (body (ubiquitty-sync--effect-text r ubiquitty-sync--max-attention-bytes))
                 (identifier (ubiquitty-sync--effect-text r ubiquitty-sync--max-notification-identifier-bytes))
                 (occasion (ubiquitty-sync--r-u8 r)))
            (when (> occasion ubiquitty-sync--notification-occasion-invisible) (error "ubiquitty-sync: invalid notification occasion"))
            (setq record (append record (list :title title :body body :identifier identifier :occasion occasion)))))
         ((= kind ubiquitty-sync--effect-kind-command-finished)
          (let* ((at (aref r 1)) (status (ubiquitty-sync--r-svarint r))
                 (encoded (ubiquitty-sync--put-varint (if (< status 0) (1- (* -2 status)) (* 2 status)))))
            (unless (and (<= (- (expt 2 31)) status (1- (expt 2 31))) (= (length encoded) (- (aref r 1) at)))
              (error "ubiquitty-sync: invalid command exit status"))
            (setq record (append record (list :exit-status status :duration (ubiquitty-sync--r-u64 r)
                                             :directory (ubiquitty-sync--effect-text r ubiquitty-sync--max-directory-bytes)
                                             :command (ubiquitty-sync--effect-text r ubiquitty-sync--max-command-line-bytes))))))
         ((= kind ubiquitty-sync--effect-kind-sound)
          (setq record (append record (list :sound (ubiquitty-sync--effect-sound r)))))
         ((= kind ubiquitty-sync--effect-kind-clipboard-write)
          (let ((buffer (ubiquitty-sync--r-u8 r)))
            (when (>= buffer ubiquitty-sync--clipboard-buffer-count) (error "ubiquitty-sync: invalid clipboard selector"))
            (setq record (append record (list :clipboard
                               (append (list :buffer buffer)
                                       (ubiquitty-sync--clipboard-payload r ubiquitty-sync--max-effect-clipboard-write-bytes)))))))
         ((not (memq kind (list ubiquitty-sync--effect-kind-bell ubiquitty-sync--effect-kind-attention)))
          (error "ubiquitty-sync: unsupported Effect body")))))
    (unless (and (ubiquitty-sync--r-end-p r) (or record (= remaining 0)))
      (error "ubiquitty-sync: trailing or unfinished Effect"))
    (list :generation generation :through through :remaining remaining :record record)))

(defun ubiquitty-sync--effect-cursor (&optional receipt)
  "Restore local RECEIPT for the same authenticated host/pane, or create one.
RECEIPT holds acknowledged and consumed cursors, never host-supplied values."
  (let ((acknowledged (or (car receipt) 0)) (consumed (or (cdr receipt) 0)))
    (unless (and (integerp acknowledged) (integerp consumed) (<= 0 acknowledged consumed #xffffffffffffffff))
      (error "ubiquitty-sync: invalid effect receipt"))
    (vector acknowledged consumed nil nil nil nil)))

(defun ubiquitty-sync--accept-effect (cursor packet applied-generation)
  "Consume PACKET against CURSOR and APPLIED-GENERATION before any callback.
Return its new record, or nil for a duplicate/empty completion.  Only a final
packet advances ACK; refusal leaves all six cursor fields unchanged."
  (let* ((through (plist-get packet :through)) (generation (plist-get packet :generation))
         (remaining (plist-get packet :remaining)) (record (plist-get packet :record))
         (sequence (and record (plist-get record :sequence))))
    (unless (and (<= generation (or applied-generation 0)) (>= through (aref cursor 1))
                 (or (not (aref cursor 2))
                     (and record (= through (aref cursor 2)) (= generation (aref cursor 3))
                          (= remaining (aref cursor 4)) (> sequence (aref cursor 5)))))
      (error "ubiquitty-sync: Effect outside its batch or picture boundary"))
    (let ((deliver (and record (> sequence (aref cursor 1)))))
      (when deliver (aset cursor 1 sequence))
      (if (> remaining 0)
          (progn (aset cursor 2 through) (aset cursor 3 generation)
                 (aset cursor 4 (1- remaining)) (aset cursor 5 sequence))
        (aset cursor 0 through) (aset cursor 1 through)
        (dotimes (index 4) (aset cursor (+ index 2) nil)))
      (and deliver record))))

(provide 'ubiquitty-sync-effects)
;;; ubiquitty-sync-effects.el ends here
