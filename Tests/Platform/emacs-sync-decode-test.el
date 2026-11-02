;;; emacs-sync-decode-test.el --- the Emacs client decodes a real Sync stream -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Stanislav Yaglo
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:

;; Feeds the client the bytes a host connection sent a client that attached
;; (Tests/Platform/sync_stream_fixture.cpp writes them) and asserts what the
;; buffer shows and what the client answers.  A field count is not what fails
;; here: a decoder that walks one field wrong still paints something, so the
;; assertions are values chosen at capture time — a cursor at row 4 column 8,
;; a first row that reads UBIQUITTY-SYNC-OK — and a version skew is an error
;; rather than an empty buffer.
;;
;; Then the client's own half: what it sends for a key, a pointer event, a
;; paste, an interrupt, a focus change, a resize and its theme, against the
;; frames a host sends back about its input (the fixture's third file).
;; Everything it sent is written to the fourth path, for the fixture's
;; --verify to read with the host's decoders.

;;; Code:

(require 'cl-lib)

(defvar ubiquitty-test--failures 0)

(defun ubiquitty-test--check (ok what)
  "Record WHAT as passed when OK, and as a failure otherwise."
  (unless ok
    (setq ubiquitty-test--failures (1+ ubiquitty-test--failures))
    (message "FAIL %s" what)))

(defun ubiquitty-test--read (path)
  "The bytes of PATH as a unibyte string, or a failure when it is unreadable."
  (if (and path (file-readable-p path))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally path)
        (buffer-string))
    (message "FAIL the fixture was not readable: %s" path)
    (kill-emacs 1)))

(defun ubiquitty-test--sync-frame (kind channel body)
  "One direct canonical envelope of KIND on CHANNEL with BODY."
  (concat (unibyte-string kind) (ubiquitty-sync--put-varint channel)
          (ubiquitty-sync--put-bytes body)))

(defun ubiquitty-test--sync-frames (stream)
  "The direct envelopes in STREAM, as (KIND CHANNEL BODY)."
  (let ((at 0) (frames nil))
    (while (< at (length stream))
      (let* ((header (or (ubiquitty-sync--envelope-header stream at) (error "partial fixture header")))
             (start (+ at (nth 3 header))) (end (+ start (nth 2 header))))
        (when (> end (length stream)) (error "partial fixture body"))
        (push (list (nth 0 header) (nth 1 header) (substring stream start end)) frames)
        (setq at end)))
    (nreverse frames)))

(defvar ubiquitty-test--sent nil "The canonical envelopes sent, newest first, as (KIND CHANNEL BODY).")

(defun ubiquitty-test--sent-sync (kind)
  "The bodies of KIND sent by the client, oldest first."
  (mapcar (lambda (frame) (nth 2 frame))
          (seq-filter (lambda (frame) (= (car frame) kind)) (reverse ubiquitty-test--sent))))

(defun ubiquitty-test--lines (buffer)
  "BUFFER's text as a list of lines."
  (with-current-buffer buffer
    (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n")))

(defun ubiquitty-test--cursor (buffer)
  "Where the client left point in BUFFER, as (ROW . COLUMN)."
  (with-current-buffer buffer
    (cons (1- (line-number-at-pos)) (current-column))))

(defun ubiquitty-test--picture-checks (stream)
  "Decode STREAM, a host's attach of a pane holding two pictures.
The ImagePlacements body is the host's own, so a client walking another
record layout reads wrong fields or refuses the frame, and this fails."
  (let* ((buffer (generate-new-buffer "*ubiquitty-picture-test*"))
         (proc (make-pipe-process :name "ubiquitty-picture-test" :noquery t)))
    (process-put proc 'buffer buffer)
    (process-put proc 'accum "")
    (with-current-buffer buffer
      (setq ubiquitty-sync--admission-request (ubiquitty-wire-fixture--request)))
    (ubiquitty-test--feed proc stream 97)
    (let* ((placements (with-current-buffer buffer ubiquitty-sync--placements))
           (iterm (seq-find (lambda (placement) (> (or (nth 12 placement) 0) 0)) placements))
           (kitty (seq-find (lambda (placement) (eql (nth 12 placement) 0)) placements)))
      (ubiquitty-test--check (= (length placements) 2)
                             (format "the picture pane decoded %d placements, not 2" (length placements)))
      ;; OSC 1337 width=24px;height=24px at row 0, column 11: drawn at 24x24
      ;; device pixels, covering 3x2 of the host's fallback 8x16 cells.
      (ubiquitty-test--check (and iterm (equal (seq-take iterm 5) (list (car iterm) 11 0 3 2))
                                  (equal (seq-drop iterm 12) '(24 24)))
                             (format "the OSC 1337 placement decoded as %S" iterm))
      ;; kitty natural size at row 3, column 16: no cell box, no drawn size.
      (ubiquitty-test--check (and kitty (equal (seq-take kitty 5) (list (car kitty) 16 3 0 0))
                                  (equal (seq-drop kitty 7) '(0 0 0 0 0 0 0)))
                             (format "the kitty placement decoded as %S" kitty)))
    (delete-process proc)
    (kill-buffer buffer)))

(defun ubiquitty-test--feed (proc stream piece)
  "Hand STREAM to PROC's filter PIECE bytes at a time, as reads arrive."
  (let ((at 0))
    (while (< at (length stream))
      (ubiquitty-sync--filter proc (substring stream at (min (length stream) (+ at piece))))
      (setq at (+ at piece)))))

(defun ubiquitty-test--content-image-checks ()
  "Check real image-frame dispatch, verified owners and missing-only reuse."
  (with-temp-buffer
    (ubiquitty-sync--reset-image-connection)
    ;; Pane frames are admitted only after a Welcome.
    (setq ubiquitty-sync--welcome (ubiquitty-sync--read-welcome (ubiquitty-wire-fixture--welcome)))
    (setq ubiquitty-sync--pane 1)
    (setq ubiquitty-sync--pane-bindings (list 1))
    (let* ((pixels (unibyte-string 255 0 0 127 0 255 0 255 0 0 255 0 255 255 255 255))
           (hash (unibyte-string #xd5 #xe7 #x34 #x7a #x4b #x32 #x1d #xf4 #x39 #x17 #xc8 #x6a #x75 #xdc #x22 #x32))
           (asset (vector hash 32 2 2 16))
           (asset-bytes (concat hash (unibyte-string 32) (ubiquitty-sync--put-u32 2) (ubiquitty-sync--put-u32 2)))
           (sent nil))
      (cl-letf (((symbol-function 'ubiquitty-sync--send-sync)
                 (lambda (_proc kind channel body) (push (list kind channel body) sent))))
        (cl-labels ((receive (kind channel body)
                      (ubiquitty-sync--receive-sync nil (current-buffer)
                                                   (ubiquitty-test--sync-frame kind channel body)))
                    (state (revision &optional id)
                      (concat (ubiquitty-sync--put-u32 revision)
                              (if id (concat (unibyte-string 1) (ubiquitty-sync--put-u32 id)
                                             (ubiquitty-sync--put-u32 0) asset-bytes (make-string 9 0))
                                (unibyte-string 0))
                              (unibyte-string 0)))
                    (head (transfer)
                      (receive ubiquitty-sync--kind-image-head 1 (concat asset-bytes (ubiquitty-sync--put-u32 transfer))))
                    (chunk (transfer index last bytes &optional bad-hash)
                      (receive ubiquitty-sync--kind-bulk-chunk 0
                               (concat (ubiquitty-sync--put-u32 transfer) (ubiquitty-sync--put-u32 index)
                                       (unibyte-string (if last 1 0)) (ubiquitty-sync--put-varint (length bytes)) bytes
                                       (if last (if bad-hash (make-string 32 0) (secure-hash 'sha256 pixels nil nil t)) ""))))
                    (wants () (cl-count ubiquitty-sync--kind-image-want sent :key #'car))
                    (refused (function body)
                      (condition-case nil (progn (funcall function body) nil) (error t))))
          (ubiquitty-test--check (equal (substring (secure-hash 'sha256 (concat (ubiquitty-sync--image-prefix asset) pixels) nil nil t) 0 16) hash)
                                 "the Emacs image identity disagrees with the Core SHA-256 vector")
          (let ((body (state 1 7)) (head-body (concat asset-bytes (ubiquitty-sync--put-u32 100))))
            (dotimes (length (length body))
              (ubiquitty-test--check (refused #'ubiquitty-sync--read-image-placements (substring body 0 length))
                                     (format "truncated ImagePlacements accepted at %d" length)))
            (dotimes (length (length head-body))
              (ubiquitty-test--check (refused #'ubiquitty-sync--read-image-head (substring head-body 0 length))
                                     (format "truncated ImageHead accepted at %d" length)))
            (ubiquitty-test--check (refused #'ubiquitty-sync--read-image-placements (concat body "x")) "trailing ImagePlacements bytes accepted")
            (receive ubiquitty-sync--kind-image-placements 2 body)
            (ubiquitty-test--check (null ubiquitty-sync--image-state) "another pane installed image metadata")
            (receive ubiquitty-sync--kind-image-placements 1 body))
          (head 100)
          (ubiquitty-test--check (equal (ubiquitty-sync--image-owned-bytes) '(41 . 16))
                                 "image admission did not charge its exact canonical owner before chunks")
          (chunk 100 0 nil (substring pixels 0 9))
          (ubiquitty-test--check (null (gethash 7 ubiquitty-sync--images)) "partial image pixels became visible")
          (chunk 100 1 t (substring pixels 9))
          (let* ((image (gethash 7 ubiquitty-sync--images)) (owner (nth 3 image)))
            (ubiquitty-test--check (and image (equal (substring owner (nth 4 image)) pixels)) "verified RGBA pixels or alpha were changed")
            (ubiquitty-test--check (equal (ubiquitty-sync--image-owned-bytes) '(0 . 16)) "completed owner did not transfer into the cache")
            (ubiquitty-test--check (equal (ubiquitty-sync--image-png image '(1 0 1 2) 1 2)
                                        (ubiquitty-sync--image-png (list 2 2 32 pixels) '(1 0 1 2) 1 2))
                                   "canonical-prefix storage changed cropped alpha PNG pixels")
            (cl-letf (((symbol-function 'secure-hash) (lambda (&rest _) (error "placement metadata rehashed immutable pixels"))))
              (receive ubiquitty-sync--kind-image-placements 1 (state 2 9))
              (head 0))
            (ubiquitty-test--check (eq owner (nth 3 (gethash 9 ubiquitty-sync--images))) "re-ID copied or replaced cached pixel ownership")
            (ubiquitty-test--check (= (wants) 0) "unchanged cached pixels were requested again"))
          (receive ubiquitty-sync--kind-image-placements 1 (state 3))
          (ubiquitty-test--check (= (hash-table-count ubiquitty-sync--image-cache) 0) "deletion retained an unreferenced image asset")
          (receive ubiquitty-sync--kind-image-placements 1 (state 4 7))
          (head 0)
          (head 0)
          (ubiquitty-test--check (= (wants) 1) "a missing reintroduced image was not requested exactly once")
          (head 101)
          (ubiquitty-test--check (condition-case nil (progn (chunk 101 0 t pixels t) nil) (error t)) "bad image SHA-256 was accepted")
          (ubiquitty-test--check (and (= (hash-table-count ubiquitty-sync--image-cache) 0)
                                    (= (car (ubiquitty-sync--image-owned-bytes)) 0)) "failed image verification left pixels cached or retained")
          (head 110)
          (receive ubiquitty-sync--kind-bulk-abort 0 (ubiquitty-sync--put-u32 110))
          (ubiquitty-sync--request-missing-images nil)
          (ubiquitty-test--check (= (wants) 1) "an aborted image was requested before its new offer")
          (head 0)
          (ubiquitty-test--check (= (wants) 2) "a newly offered aborted image was not requested")
          (let ((ubiquitty-sync--retained-asset-budget 24))
            (head 102)
            (ubiquitty-test--check (= (car (ubiquitty-sync--image-owned-bytes)) 0) "refused image allocated before admission")
            (chunk 102 0 nil (substring pixels 0 8))
            (chunk 102 1 t (substring pixels 8))
            (ubiquitty-test--check (= (hash-table-count ubiquitty-sync--image-transfers) 0) "discarded final image left its fence behind"))
          (head 103)
          (chunk 103 0 nil (substring pixels 0 8))
          (receive ubiquitty-sync--kind-image-placements 1 (state 5))
          (ubiquitty-test--check (= (car (ubiquitty-sync--image-owned-bytes)) 0) "deletion did not free a partial image owner")
          (chunk 103 1 t (substring pixels 8))
          (ubiquitty-test--check (= (hash-table-count ubiquitty-sync--image-cache) 0) "late deleted pixels resurrected an image")
          (receive ubiquitty-sync--kind-image-placements 1 (state 6 7))
          (head 104)
          (receive ubiquitty-sync--kind-pane-unbind 0 (unibyte-string 1 0))
          (chunk 104 0 t pixels)
          (ubiquitty-test--check (and (= (car (ubiquitty-sync--image-owned-bytes)) 0) (null ubiquitty-sync--transfers))
                                 "unbound image entered the generic bulk accumulator"))))))

(defun ubiquitty-test--image-checks (buffer)
  "Assert what BUFFER's client makes of IMAGE frames, sound and hostile alike."
  (cl-labels ((adler32 (bytes)
                (let ((low 1) (high 0))
                  (dotimes (k (length bytes))
                    (setq low (% (+ low (aref bytes k)) 65521))
                    (setq high (% (+ high low) 65521)))
                  (unibyte-string (ash high -8) (logand high #xff)
                                  (ash low -8) (logand low #xff))))
              ;; Emacs compresses nothing, so a stream the client can really
              ;; inflate is one stored deflate block.
              (stored (bytes)
                (let ((length (length bytes)))
                  (concat (unibyte-string #x78 #x01 #x01
                                          (logand length #xff) (ash length -8)
                                          (logxor (logand length #xff) #xff)
                                          (logxor (ash length -8) #xff))
                          bytes (adler32 bytes))))
              (image-body (id width height format raw-length compressed-length
                              chunk-count chunk-index chunk)
                (concat (ubiquitty-sync--put-u32 id)
                        (ubiquitty-sync--put-u16 width)
                        (ubiquitty-sync--put-u16 height)
                        (ubiquitty-sync--put-u16 format)
                        (ubiquitty-sync--put-u32 raw-length)
                        (ubiquitty-sync--put-u32 compressed-length)
                        (ubiquitty-sync--put-u16 chunk-count)
                        (ubiquitty-sync--put-u16 chunk-index)
                        (ubiquitty-sync--put-u32 (length chunk))
                        (unibyte-string 0)          ; virtualPlacement
                        (ubiquitty-sync--put-u16 0) ; virtualColumns
                        (ubiquitty-sync--put-u16 0) ; virtualRows
                        (ubiquitty-sync--put-u32 0) ; virtualPlacementID
                        chunk))
              (refused (body)
                (condition-case nil
                    (progn (ubiquitty-sync--apply-image buffer body) nil)
                  (error t))))
    (with-current-buffer buffer
      (setq ubiquitty-sync--images nil
            ubiquitty-sync--image-chunks nil))
    ;; A 2x1 RGB image, its six pixel bytes split across two chunks.
    (let* ((pixels (unibyte-string 1 2 3 4 5 6))
           (stream (stored pixels))
           (half (/ (length stream) 2)))
      (ubiquitty-sync--apply-image
       buffer (image-body 7 2 1 24 6 (length stream) 2 0 (substring stream 0 half)))
      (with-current-buffer buffer
        (ubiquitty-test--check (= (hash-table-count ubiquitty-sync--image-chunks) 1)
                               "the first chunk did not open a reassembly"))
      (ubiquitty-sync--apply-image
       buffer (image-body 7 2 1 24 6 (length stream) 2 1 (substring stream half)))
      (with-current-buffer buffer
        (ubiquitty-test--check (= (hash-table-count ubiquitty-sync--image-chunks) 0)
                               "the finished reassembly stayed in the table")
        (if (and (fboundp 'zlib-available-p) (zlib-available-p))
            (ubiquitty-test--check
             (equal (gethash 7 ubiquitty-sync--images)
                    (list 2 1 24 pixels))
             (format "the two-chunk image decoded as: %S" (gethash 7 ubiquitty-sync--images)))
          (message "note: this Emacs has no zlib, so the inflate itself is unchecked"))))
    (let* ((pixels (unibyte-string 255 0 0 128 0 255 0 0))
           (stream (stored pixels)))
      (ubiquitty-sync--apply-image buffer (image-body 70 2 1 32 8 (length stream) 1 0 stream))
      (when (and (fboundp 'zlib-available-p) (zlib-available-p))
        (with-current-buffer buffer
          (ubiquitty-test--check (equal (gethash 70 ubiquitty-sync--images) (list 2 1 32 pixels))
                                 "RGBA image reassembly discarded alpha"))))
    ;; A pixel buffer larger than the dimensions account for, and one a tiny
    ;; stream claims to hold: both are refused on the header.
    (let ((stream (stored (unibyte-string 0))))
      (ubiquitty-test--check
       (refused (image-body 8 2 1 24 4096 (length stream) 1 0 stream))
       "an image whose pixel length contradicts its dimensions is taken")
      (ubiquitty-test--check
       (refused (image-body 8 1 1 16 3 (length stream) 1 0 stream))
       "an image with an unknown pixel format is taken")
      (ubiquitty-test--check
       (refused (image-body 9 2048 2048 24 12582912 64 1 0
                            (substring stream 0 (min 64 (length stream)))))
       "an image claiming to inflate past the ratio cap is taken"))
    ;; The running reassembly is bounded by the stream its header declares.
    (let ((chunk (make-string 64 ?x)))
      (ubiquitty-sync--apply-image buffer (image-body 10 2 1 24 6 100 4 0 chunk))
      (ubiquitty-test--check
       (refused (image-body 10 2 1 24 6 100 4 1 chunk))
       "chunks summing past the declared stream are taken"))
    ;; A host that opens images and finishes none holds the ceiling.
    (let ((chunk (unibyte-string 0)))
      (dotimes (k (* 4 ubiquitty-sync--max-image-reassemblies))
        (ubiquitty-sync--apply-image buffer (image-body (+ 100 k) 2 1 24 6 64 2 0 chunk)))
      (with-current-buffer buffer
        (ubiquitty-test--check
         (= (hash-table-count ubiquitty-sync--image-chunks)
            ubiquitty-sync--max-image-reassemblies)
         (format "%d reassemblies are in flight, the ceiling is %d"
                 (hash-table-count ubiquitty-sync--image-chunks)
                 ubiquitty-sync--max-image-reassemblies)))))
  (ubiquitty-test--image-rendering-checks)
  (ubiquitty-test--content-image-checks))

(defun ubiquitty-test--image-rendering-checks ()
  "Check PNG framing, pixels, crop and the row renderer's placement geometry."
  (cl-labels ((big-u32 (bytes at)
                (+ (ash (aref bytes at) 24) (ash (aref bytes (+ at 1)) 16)
                   (ash (aref bytes (+ at 2)) 8) (aref bytes (+ at 3))))
              (slow-crc (bytes)
                ;; Independent bit-at-a-time reference for the table encoder.
                (let ((crc #xffffffff))
                  (dotimes (n (length bytes))
                    (setq crc (logxor crc (aref bytes n)))
                    (dotimes (_bit 8)
                      (setq crc (if (= (logand crc 1) 1)
                                    (logxor (ash crc -1) #xedb88320)
                                  (ash crc -1)))))
                  (logxor crc #xffffffff)))
              (png-pixels (png width height color-type)
                (ubiquitty-test--check
                 (and png (not (multibyte-string-p png))
                      (equal (substring png 0 8) (unibyte-string #x89 ?P ?N ?G 13 10 26 10)))
                 "the image encoder did not produce binary PNG data")
                (let ((at 8) (types nil) (compressed nil))
                  (while (< at (length png))
                    (let* ((length (big-u32 png at))
                           (type (substring png (+ at 4) (+ at 8)))
                           (end (+ at 8 length)))
                      (ubiquitty-test--check
                       (= (big-u32 png end) (slow-crc (substring png (+ at 4) end)))
                       (format "bad PNG CRC for %s" type))
                      (push type types)
                      (cond
                       ((equal type "IHDR")
                        (ubiquitty-test--check
                         (and (= length 13) (= (big-u32 png (+ at 8)) width)
                              (= (big-u32 png (+ at 12)) height)
                              (= (aref png (+ at 16)) 8) (= (aref png (+ at 17)) color-type))
                         "PNG dimensions or RGB/RGBA type changed"))
                       ((equal type "IDAT") (setq compressed (substring png (+ at 8) end))))
                      (setq at (+ end 4))))
                  (ubiquitty-test--check (equal (nreverse types) '("IHDR" "IDAT" "IEND"))
                                         "PNG chunks are missing or out of order")
                  (when (and (fboundp 'zlib-available-p) (zlib-available-p))
                    (with-temp-buffer
                      (set-buffer-multibyte nil)
                      (insert compressed)
                      (ubiquitty-test--check (zlib-decompress-region (point-min) (point-max))
                                             "PNG IDAT did not inflate")
                      (buffer-string))))))
    (ubiquitty-test--check (= (ubiquitty-sync--png-crc "123456789") #xcbf43926)
                           "PNG CRC disagrees with the standard check value")
    (let* ((pixels (unibyte-string 255 0 0 128 0 255 0 0 0 0 255 255 1 2 3 64))
           (image (list 2 2 32 pixels))
           (crop '(1 0 1 2))
           (png (ubiquitty-sync--image-png image crop 1 2))
           (decoded (png-pixels png 1 2 6)))
      (when decoded
        (ubiquitty-test--check (equal decoded (unibyte-string 0 0 255 0 0 0 1 2 3 64))
                               "source cropping discarded transparent or partial-alpha pixels"))
      (dolist (bad (list (list 2 2 32 (substring pixels 1))
                        (list 2 2 16 pixels) (list 0 2 32 pixels)))
        (ubiquitty-test--check (null (ubiquitty-sync--image-png bad crop 1 2))
                               "PNG input with invalid dimensions, format or length was taken"))
      (dolist (bad-crop '((-1 0 1 1) (0 0 0 1) (1 1 2 2) (0 2 1 1)))
        (ubiquitty-test--check (null (ubiquitty-sync--image-png image bad-crop 2 2))
                               "PNG crop outside the image was taken"))
      (ubiquitty-test--check (null (ubiquitty-sync--image-png image crop 0 2))
                             "PNG crop larger than its canvas was taken")
      (let ((ubiquitty-sync--retained-asset-budget 16))
        (ubiquitty-test--check (null (ubiquitty-sync--image-png image crop 2 2))
                               "PNG padded scanlines exceeded the allocation budget"))
      (ubiquitty-test--check
       (equal (ubiquitty-sync--image-layout image '(7 3 -1 2 3 16 32 1 0 0 0) 8 16)
              '(5 1 2 3 (1 0 1 2) 1 2))
       "whole-cell pixel offsets or zero-extent source crop were lost")
      (ubiquitty-test--check
       (equal (ubiquitty-sync--image-layout image '(7 0 0 0 0 0 0 0 0 0 0) 8 16)
              '(0 0 1 1 (0 0 2 2) 8 16))
       "natural image size was not padded to a cell-aligned canvas")
      (ubiquitty-test--check
       (null (ubiquitty-sync--image-layout image '(7 0 0 1 1 0 0 2 0 0 0) 8 16))
       "a crop beyond the source was given visible geometry"))
    (let* ((image (list 1 1 24 (unibyte-string 11 22 33)))
           (decoded (png-pixels (ubiquitty-sync--image-png image '(0 0 1 1) 2 2) 2 2 6)))
      (when decoded
        (ubiquitty-test--check
         (equal decoded (unibyte-string 0 11 22 33 255 0 0 0 0
                                       0 0 0 0 0 0 0 0 0))
         "natural-size RGB image padding was not transparent RGBA")))
    ;; A drawn size resamples the crop to it, nearest texel, and pads the rest:
    ;; a 2x1 RGB crop drawn at 4x2 doubles each texel on both axes.
    (let* ((image (list 2 1 24 (unibyte-string 10 20 30 40 50 60)))
           (decoded (png-pixels (ubiquitty-sync--image-png image '(0 0 2 1 4 2) 5 2) 5 2 6))
           (row (concat (unibyte-string 0) (unibyte-string 10 20 30 255 10 20 30 255 40 50 60 255 40 50 60 255 0 0 0 0))))
      (when decoded
        (ubiquitty-test--check (equal decoded (concat row row))
                               "a drawn size was not resampled nearest-texel into its padded canvas")))
    (let ((image (list 24 24 32 (string-to-unibyte (make-string (* 24 24 4) 0)))))
      (ubiquitty-test--check
       (equal (ubiquitty-sync--image-layout image '(7 11 0 3 2 0 0 0 0 0 0 0 24 24) 8 16)
              '(11 0 3 2 (0 0 24 24 24 24) 24 32))
       "a drawn size did not cover whole cells at this frame's cell size")
      (ubiquitty-test--check
       (equal (ubiquitty-sync--image-layout image '(7 11 0 3 2 0 0 0 0 0 0 0 12 12) 8 16)
              '(11 0 2 1 (0 0 24 24 12 12) 16 16))
       "a drawn size smaller than the source was not the picture's size"))
    (let ((pixels (string-to-unibyte (make-string (* 256 90 3) 0))))
      ;; Fill raw bytes, rather than trying to convert Unicode U+00BF to a byte.
      (fillarray pixels 191)
      (ubiquitty-test--check
       (and (not (multibyte-string-p pixels)) (= (length pixels) 69120)
            (= (aref pixels 0) 191) (= (aref pixels (1- (length pixels))) 191))
       "the multi-block PNG fixture was not a high-bit byte string")
      (let ((decoded (png-pixels
                      (ubiquitty-sync--image-png (list 256 90 24 pixels) '(0 0 256 90) 256 90)
                      256 90 2)))
        (when decoded
          (ubiquitty-test--check
           (equal decoded (apply #'concat (make-list 90 (concat (unibyte-string 0) (substring pixels 0 768)))))
           "PNG stored deflate blocks failed across the 65535-byte boundary"))))
    (with-temp-buffer
      (let ((dirty nil))
        (let ((rgb (list 2 1 24 (unibyte-string 1 2 3 4 5 6))))
          (ubiquitty-test--check
           (equal (ubiquitty-sync--image-rendering 7 rgb '(1 0 1 1) 1 1 nil)
                  (cons 'pbm (concat (string-to-unibyte "P6\n1 1\n255\n") (unibyte-string 4 5 6))))
           "a graphical build without PNG lost opaque RGB cropping")
          (ubiquitty-test--check
           (null (ubiquitty-sync--image-rendering 7 rgb '(1 0 1 1) 2 2 nil))
           "PPM pretended to preserve transparent padding")
          (ubiquitty-test--check
           (null (ubiquitty-sync--image-ppm (list 1 1 32 (unibyte-string 1 2 3 0)) '(0 0 1 1)))
           "PPM silently discarded an RGBA image's alpha")
          (ubiquitty-test--check (null (ubiquitty-sync--image-ppm rgb '(1 0 2 1)))
                                 "PPM bypassed shared source-crop validation"))
        (setq ubiquitty-sync--screen (make-vector 10 nil)
              ubiquitty-sync--images (make-hash-table))
        (puthash 7 (list 2 2 32 (unibyte-string 1 2 3 255 4 5 6 0 7 8 9 128 10 11 12 255))
                 ubiquitty-sync--images)
        (cl-letf (((symbol-function 'default-font-width) (lambda (&optional _frame) 8))
                  ((symbol-function 'default-font-height) (lambda (&optional _frame) 16))
                  ((symbol-function 'ubiquitty-sync--paint-rows) (lambda (rows) (setq dirty rows))))
          (ubiquitty-sync--apply-placements
           (current-buffer)
           (concat (ubiquitty-sync--put-u16 1) (ubiquitty-sync--put-u32 7)
                   (ubiquitty-sync--put-u16 1) (ubiquitty-sync--put-u32 7)
                   (ubiquitty-sync--put-u32 8) (unibyte-string 1)
                   (ubiquitty-sync--put-u16 3) (ubiquitty-sync--put-u16 #xffff)
                   (ubiquitty-sync--put-u16 2) (ubiquitty-sync--put-u16 3)
                   (ubiquitty-sync--put-u16 16) (ubiquitty-sync--put-u16 32)
                   (ubiquitty-sync--put-u16 1) (ubiquitty-sync--put-u16 0)
                   (ubiquitty-sync--put-u16 0) (ubiquitty-sync--put-u16 0)
                   (ubiquitty-sync--put-u32 0) (unibyte-string 0)))
          (ubiquitty-test--check (equal ubiquitty-sync--placements '((7 3 -1 2 3 16 32 1 0 0 0)))
                                 "placement decoder discarded source crop or pixel offsets")
          (ubiquitty-test--check (equal dirty (bool-vector nil t t t nil nil nil nil nil nil))
                                 "shifted placement did not repaint its visible rows")
          (ubiquitty-sync--apply-placements (current-buffer) (unibyte-string 0 0 0 0))
          (ubiquitty-test--check (and (equal dirty (bool-vector nil t t t nil nil nil nil nil nil))
                                     (= (hash-table-count ubiquitty-sync--images) 0))
                                 "eviction forgot old placement geometry before clearing its slices")
          (puthash 7 (list 1 1 24 (unibyte-string 1 2 3)) ubiquitty-sync--images)
          (ubiquitty-sync--repaint-placed-rows
           '((7 0 0 0 0 0 0 0 0 0 0))
           (list 1 32 24 (string-to-unibyte (make-string 96 0))))
          (ubiquitty-test--check (equal dirty (bool-vector t t nil nil nil nil nil nil nil nil))
                                 "a smaller replacement image left its old lower slice visible"))))))

(defun ubiquitty-test--upstream-checks (attach update control upstream-path)
  "Assert what the client sends, and write it to UPSTREAM-PATH.
ATTACH and UPDATE are the host's streams and CONTROL the frames it sends
about a client's input and on the control channel."
  (let* ((sent nil)
         (ubiquitty-sync-theme "Noir")
         (buffer (generate-new-buffer "*ubiquitty-upstream-test*"))
         (proc (make-pipe-process :name "ubiquitty-upstream-test" :noquery t))
         (control-frames (ubiquitty-test--sync-frames control)))
    (process-put proc 'buffer buffer)
    (process-put proc 'accum "")
    (cl-letf (((symbol-function 'ubiquitty-sync--send-sync)
               (lambda (_proc kind channel body) (push (list kind channel body) sent))))
      (cl-labels ((sync (kind)
                    (mapcar (lambda (frame) (nth 2 frame))
                            (seq-filter (lambda (frame) (= (car frame) kind)) (reverse sent))))
                  (host-says (kind)
                    (let ((frame (seq-find (lambda (candidate) (= (car candidate) kind)) control-frames)))
                      (ubiquitty-test--check frame (format "the control fixture carries no frame of kind %d" kind))
                      (when frame
                        (ubiquitty-sync--filter proc (ubiquitty-test--sync-frame (nth 0 frame) (nth 1 frame) (nth 2 frame))))))
                  (host-sends (kind channel body)
                    (ubiquitty-sync--filter proc (ubiquitty-test--sync-frame kind channel body)))
                  (key (event)
                    (let ((last-command-event event))
                      (ubiquitty-sync-send-key)))
                  (u64 (n) (ubiquitty-sync--put-u64 n)))
        (with-current-buffer buffer
          (setq ubiquitty-sync--process proc
                ubiquitty-sync--columns 80
                ubiquitty-sync--rows 24)

          ;; Typed before the pane is bound: held, and sent in order once it is.
          (key ?l)
          (ubiquitty-test--check (null sent) "input typed before the pane was bound was sent somewhere")
          ;; A single Greet owns identity, selection and viewport together.
          (let ((request-frames nil))
            (cl-letf (((symbol-function 'ubiquitty-sync--send-sync)
                       (lambda (_proc kind channel body) (push (list kind channel body) request-frames))))
              (ubiquitty-sync--send-greet proc 137 43))
            (ubiquitty-test--check (= (length request-frames) 1) "one request sent more than one greeting")
            (let* ((frame (car request-frames)) (body (nth 2 frame)) (r (ubiquitty-sync--reader body)))
              (ubiquitty-test--check (and (= (car frame) ubiquitty-sync--kind-greet) (= (nth 1 frame) 0))
                                     "Greet was not the first control envelope")
              (ubiquitty-test--check (and (= (ubiquitty-sync--r-u16 r) ubiquitty-sync--wire-version)
                                         (equal (ubiquitty-sync--r-bytes r) "")) "Greet build prefix changed")
              (ubiquitty-sync--take r 32)
              (let ((at (ubiquitty-sync--take r 16)))
                (ubiquitty-test--check (equal (substring body at (+ at 16)) ubiquitty-sync--client-instance)
                                       "the explicit client identity differs from Greet"))
              (ubiquitty-test--check
               (and (= (ubiquitty-sync--r-u8 r) ubiquitty-sync--client-kind-human)
                    (= (ubiquitty-sync--r-u8 r) ubiquitty-sync--role-owner)
                    (= (ubiquitty-sync--r-u8 r) ubiquitty-sync--admission-target-session)
                    (= (ubiquitty-sync--r-u32 r) 0) (= (ubiquitty-sync--r-u32 r) 0) (= (ubiquitty-sync--r-u64 r) 0)
                    (equal (ubiquitty-sync--r-bytes r) "") (equal (ubiquitty-sync--r-bytes r) "")
                    (equal (ubiquitty-sync--r-bytes r) "")
                    (= (ubiquitty-sync--r-u32 r) 0)
                    (= (ubiquitty-sync--r-u16 r) 43) (= (ubiquitty-sync--r-u16 r) 137))
               "Greet selection, credential presence or viewport changed")
              (ubiquitty-sync--take r 8)
              (ubiquitty-test--check
               (and (= (ubiquitty-sync--r-u32 r) 0) (= (ubiquitty-sync--r-u8 r) 0)
                    (= (ubiquitty-sync--r-u8 r) 0) (= (ubiquitty-sync--r-u8 r) 1)
                    (= (ubiquitty-sync--r-u32 r) 0) (= (ubiquitty-sync--r-u32 r) 0)
                    (= (ubiquitty-sync--r-varint r) (logior ubiquitty-sync--capability-echo-context ubiquitty-sync--capability-shows-no-questions))
                    (= (ubiquitty-sync--r-u8 r) 0) (ubiquitty-sync--r-end-p r))
               "Greet Facts or mandatory resume tail changed")))
          (ubiquitty-sync--send-greet proc 80 24)
          (ubiquitty-test--feed proc attach 4096)
          (ubiquitty-test--feed proc update 4096)

          ;; The Welcome is read whole: the host's version, what it grants,
          ;; and every trailing field.
          (let ((welcome ubiquitty-sync--welcome))
            (ubiquitty-test--check (eql (plist-get welcome :version) ubiquitty-sync--wire-version)
                                   "the Welcome's version was not read")
            (ubiquitty-test--check (equal (plist-get welcome :principal) "fixture")
                                   (format "the Welcome's principal reads %S" (plist-get welcome :principal)))
            (ubiquitty-test--check (and (null (plist-get welcome :predecessor)) (null (plist-get welcome :resumed)))
                                   "a fresh attach read a resume out of its Welcome")
            (ubiquitty-test--check (equal (plist-get welcome :paste-limits) (list (* 32 1024) (* 16 1024 1024) (* 256 1024)))
                                   (format "the Welcome's paste caps and window read %S" (plist-get welcome :paste-limits))))
          (let* ((body (nth 2 (seq-find (lambda (frame) (= (car frame) ubiquitty-sync--kind-welcome))
                                        (ubiquitty-test--sync-frames attach))))
                 (tail 15) ; no predecessor, no resumed pane, present paste caps
                 (absent (ubiquitty-sync--read-welcome (concat (substring body 0 (- (length body) 13)) (unibyte-string 0))))
                 (resumed (ubiquitty-sync--read-welcome
                           (concat (substring body 0 (- (length body) tail))
                                   (unibyte-string 1) (make-string 16 9)
                                   (unibyte-string 1) (make-string 16 7) (unibyte-string 1 1) (u64 42)
                                   (unibyte-string 1) (substring body (- (length body) 12))))))
            (dotimes (cut (length body))
              (ubiquitty-test--check
               (condition-case nil (progn (ubiquitty-sync--read-welcome (substring body 0 cut)) nil) (error t))
               "a truncated current Welcome was accepted"))
            (ubiquitty-test--check
             (condition-case nil (progn (ubiquitty-sync--read-welcome (concat body (unibyte-string 1 2 3))) nil) (error t))
             "trailing Welcome bytes were accepted")
            (ubiquitty-test--check (null (plist-get absent :paste-limits)) "an explicit absent paste flag was misread")
            (ubiquitty-test--check (and (equal (plist-get resumed :predecessor) (make-string 16 9))
                                        (equal (plist-get resumed :resumed) (list (list (make-string 16 7) 1 42)))
                                        (equal (plist-get resumed :paste-limits) (plist-get ubiquitty-sync--welcome :paste-limits)))
                                   "a Welcome's resume tail was not read in order"))

          ;; The update carried the pane's echo context, which the Greet asked
          ;; for: a pane nobody has described has a new terminal's characters.
          (ubiquitty-test--check (and ubiquitty-sync--echo
                                      (eql (plist-get ubiquitty-sync--echo :interrupt) 3)
                                      (eql (plist-get ubiquitty-sync--echo :quit) 28)
                                      (eql (plist-get ubiquitty-sync--echo :suspend) 26)
                                      (not (plist-get ubiquitty-sync--echo :secure-entry)))
                                 (format "the update's echo context reads %S" ubiquitty-sync--echo))
          (ubiquitty-test--check
           (condition-case nil
               (progn (ubiquitty-sync--read-echo-context
                       (ubiquitty-sync--reader (concat (make-string 8 0) (unibyte-string 8 0 0 0 0))))
                      nil)
             (error t))
           "an echo context with an undefined flag was read")
          (let ((context (ubiquitty-sync--read-echo-context
                          (ubiquitty-sync--reader (concat (unibyte-string 5 0 0 0 9 0 0 0 5 2 3 28 26))))))
            (ubiquitty-test--check (and (= (plist-get context :modes-revision) 5)
                                        (= (plist-get context :foreground-generation) 9)
                                        (plist-get context :secure-entry)
                                        (plist-get context :at-prompt)
                                        (not (plist-get context :foreign-input))
                                        (null (plist-get context :interrupt))
                                        (eql (plist-get context :quit) 28)
                                        (null (plist-get context :suspend)))
                                   (format "an echo context read as %S" context)))
          (dolist (erase '(0 8 127 255))
            (let* ((r (ubiquitty-sync--reader
                       (concat (make-string 9 0) (unibyte-string 24 0 0 0 erase))))
                   (context (ubiquitty-sync--read-echo-context r)))
              (ubiquitty-test--check (and (eql (plist-get context :erase) erase)
                                          (ubiquitty-sync--r-end-p r))
                                     "the PTY erase character or its boundary was misread")))
          (let ((context (ubiquitty-sync--read-echo-context
                          (ubiquitty-sync--reader
                           (concat (make-string 9 0) (unibyte-string 16 0 0 0))))))
            (ubiquitty-test--check (null (plist-get context :erase)) "disabled erase became DEL"))
          (dolist (presence '(8 32 255))
            (ubiquitty-test--check
             (condition-case nil
                 (progn (ubiquitty-sync--read-echo-context
                         (ubiquitty-sync--reader
                          (concat (make-string 9 0) (unibyte-string presence 0 0 0))))
                        nil)
               (error t))
             "invalid erase presence was read"))

          ;; The theme this client draws in went in a Facts after the Welcome:
          ;; the live palette as the entries that differ from a new
          ;; terminal's, and the baseline as no entry that differs from it.
          (let* ((facts (sync ubiquitty-sync--kind-facts))
                 (theme (ubiquitty-sync--theme "Noir"))
                 (differing (cl-count-if-not #'identity
                                             (cl-mapcar (lambda (a b) (string= (downcase a) (downcase b)))
                                                        (nth 1 theme) (append ubiquitty-sync--seeded-ansi16 nil))))
                 (rest (+ 18 1 30 5)))
            (ubiquitty-test--check (= (length facts) 1) "the theme was not stated in a Facts after the Welcome")
            (ubiquitty-test--check (and facts (= (length (car facts)) (+ 20 1 (* 7 differing) rest 1 rest)))
                                   (format "the theme's Facts is %d bytes, not the two palettes in their short form"
                                           (length (or (car facts) "")))))

          ;; A character goes as its bytes; a named key as the key it is.
          (key ?s)
          (let ((raws (sync ubiquitty-sync--kind-raw)))
            (ubiquitty-test--check (and (= (length raws) 2)
                                        (equal (nth 0 raws) (concat (u64 1) (unibyte-string 1 ?l)))
                                        (equal (nth 1 raws) (concat (u64 2) (unibyte-string 1 ?s))))
                                   "typed characters did not go as Raw numbered from 1"))
          (dolist (event '(return up deletechar backspace delete tab home end prior next kp-enter left right down))
            (key event))
          (key (event-convert-list '(shift up)))
          (ubiquitty-sync-send-escape)
          (let ((keys (sync ubiquitty-sync--kind-keys)))
            (ubiquitty-test--check (= (length keys) 16) (format "%d named keys went as Keys, expected 16" (length keys)))
            (ubiquitty-test--check (and keys (= (ubiquitty-sync--u64 (car keys) 0) 3)
                                        (= (ubiquitty-sync--u32 (car keys) 9) 1))
                                   "Return did not go as the key numbered after the characters")
            (ubiquitty-test--check (and (nth 14 keys)
                                        (= (ubiquitty-sync--u32 (nth 14 keys) 9) 10)
                                        (= (ubiquitty-sync--u16 (nth 14 keys) 13) 1))
                                   "Shift-Up did not go as Up with the Shift bit"))
          (let ((last-command-event ?b))
            (ubiquitty-sync-send-meta))
          (ubiquitty-test--check (equal (car (last (sync ubiquitty-sync--kind-raw)))
                                        (concat (u64 19) (unibyte-string 2 27 ?b)))
                                 "Meta-b did not go as ESC b")

          ;; A mouse event goes as the button and the zero-based cell.
          (cl-letf (((symbol-function 'ubiquitty-sync--posn-cell) (lambda (_posn) (cons 6 3))))
            (ubiquitty-sync--send-mouse nil 0 nil)
            (ubiquitty-sync--send-mouse nil 0 t)
            (ubiquitty-sync--send-mouse nil 65 nil))
          (let ((pointers (sync ubiquitty-sync--kind-pointer)))
            (ubiquitty-test--check (and (= (length pointers) 3)
                                        (equal (substring (nth 0 pointers) 8)
                                               (concat (unibyte-string 1 0 0 0 0) (ubiquitty-sync--put-u16 2) (ubiquitty-sync--put-u16 5)
                                                       (unibyte-string 255 255 255 255)))
                                        (= (aref (nth 1 pointers) 9) 1)
                                        (= (aref (nth 2 pointers) 10) 65))
                                   "a press, a release and a wheel step did not go as Pointer events"))

          ;; A paste goes as pieces; with a window of two pieces the third
          ;; waits for the host's receipt, and a key typed meanwhile is
          ;; numbered after the paste and sent at once.
          (setq ubiquitty-sync--paste-limits (list (* 32 1024) (* 16 1024 1024) 16384))
          (ubiquitty-sync--paste-text (make-string 20000 ?p))
          (key ?x)
          (let ((pieces (sync ubiquitty-sync--kind-paste)))
            (ubiquitty-test--check (= (length pieces) 2)
                                   (format "%d pieces of a 20000-byte paste went into a 16384-byte window, expected 2" (length pieces)))
            (ubiquitty-test--check (and pieces (= (ubiquitty-sync--u64 (car pieces) 0) 23)
                                        (= (ubiquitty-sync--u64 (car pieces) 8) 0)
                                        (= (aref (car pieces) 16) 0)
                                        (= (ubiquitty-sync--u64 (nth 1 pieces) 8) 8192))
                                   "the pieces are not numbered 23 from offset 0 with more to come")
            (ubiquitty-test--check (equal (car (last (sync ubiquitty-sync--kind-raw))) (concat (u64 24) (unibyte-string 1 ?x)))
                                   "the key typed after the paste was not numbered after it"))
          (host-says ubiquitty-sync--kind-receipt)
          (ubiquitty-test--check (and (= ubiquitty-sync--input-written 1) (= ubiquitty-sync--input-settled 1)
                                      (= (length (sync ubiquitty-sync--kind-paste)) 2))
                                 "the Receipt's counts were not taken, or it opened the paste's window")
          ;; The fixture's PasteReceipt names paste 2, which is not this one.
          (host-says ubiquitty-sync--kind-paste-receipt)
          (ubiquitty-test--check (= (length (sync ubiquitty-sync--kind-paste)) 2)
                                 "a receipt for another paste opened this one's window")
          (host-sends ubiquitty-sync--kind-paste-receipt ubiquitty-sync--pane (concat (u64 23) (u64 8192)))
          (let ((pieces (sync ubiquitty-sync--kind-paste)))
            (ubiquitty-test--check (and (= (length pieces) 3)
                                        (= (ubiquitty-sync--u64 (nth 2 pieces) 8) 16384)
                                        (= (aref (nth 2 pieces) 16) 1))
                                   "the receipt did not release the paste's final piece")
            (ubiquitty-test--check
             (= 20000 (apply #'+ (mapcar (lambda (piece)
                                           (let ((r (ubiquitty-sync--reader piece 17)))
                                             (length (ubiquitty-sync--r-bytes r))))
                                         pieces)))
             "the pieces do not carry the whole paste"))
          ;; Text outside ASCII travels as its UTF-8 bytes.
          (ubiquitty-sync--paste-text "é")
          (ubiquitty-test--check (equal (car (last (sync ubiquitty-sync--kind-paste)))
                                        (concat (u64 25) (u64 0) (unibyte-string 1 2 #xC3 #xA9)))
                                 "a pasted é did not go as its two UTF-8 bytes in one final piece")

          ;; A signal character discarded what the pane held: the events are
          ;; counted, and no more of a paste among them is sent.
          (ubiquitty-sync--paste-text (make-string 30000 ?q))
          (key ?y)
          (ubiquitty-test--check (and (= (length (sync ubiquitty-sync--kind-paste)) 6) (= ubiquitty-sync--input-seq 27))
                                 "the second paste did not fill its window")
          (host-sends ubiquitty-sync--kind-input-discarded ubiquitty-sync--pane (concat (u64 25) (u64 27)))
          (ubiquitty-test--check (= ubiquitty-sync--input-discarded 2)
                                 (format "%d events were counted as discarded, expected 2" ubiquitty-sync--input-discarded))
          (ubiquitty-test--check (and (null ubiquitty-sync--pastes) (= ubiquitty-sync--input-written 27))
                                 "a discarded paste is still held, or the count did not pass it")
          (host-sends ubiquitty-sync--kind-paste-receipt ubiquitty-sync--pane (concat (u64 26) (u64 16384)))
          (ubiquitty-test--check (= (length (sync ubiquitty-sync--kind-paste)) 6) "a piece of a discarded paste was sent")
          ;; The fixture's InputDiscarded names a run behind this client's count.
          (host-says ubiquitty-sync--kind-input-discarded)
          (ubiquitty-test--check (= ubiquitty-sync--input-written 27) "an InputDiscarded behind the count moved it")

          ;; An interrupt typed during an unfinished paste gives the paste up
          ;; first, on the interactive lane, and then goes itself.
          (ubiquitty-sync--paste-text (make-string 20000 ?r))
          (key 3)
          (let ((aborts (sync ubiquitty-sync--kind-paste-abort)))
            (ubiquitty-test--check (and (= (length aborts) 1) (= (ubiquitty-sync--u64 (car aborts) 0) 28))
                                   "the interrupt did not abort the unfinished paste by its number")
            (ubiquitty-test--check (and (equal (nth 0 sent)
                                               (list ubiquitty-sync--kind-raw ubiquitty-sync--pane
                                                     (concat (u64 29) (unibyte-string 1 3))))
                                        (= (car (nth 1 sent)) ubiquitty-sync--kind-paste-abort))
                                   "the abort did not go ahead of the interrupt")
            (ubiquitty-test--check (null ubiquitty-sync--pastes) "an aborted paste is still held"))
          ;; The pane's own interrupt character, once its echo context states
          ;; one, is what aborts; Ctrl-C then is a key like any other.
          (setq ubiquitty-sync--echo (list :interrupt 7 :quit nil :suspend nil))
          (ubiquitty-sync--paste-text (make-string 20000 ?s))
          (key 3)
          (ubiquitty-test--check (= (length (sync ubiquitty-sync--kind-paste-abort)) 1)
                                 "a key that is not the pane's interrupt character aborted a paste")
          ;; Bytes that only begin with it are not that key.
          (ubiquitty-sync--send-raw (unibyte-string 7 ?x))
          (ubiquitty-test--check (= (length (sync ubiquitty-sync--kind-paste-abort)) 1)
                                 "bytes beginning with the interrupt character aborted a paste")
          (key 7)
          (ubiquitty-test--check (= (length (sync ubiquitty-sync--kind-paste-abort)) 2)
                                 "the pane's own interrupt character did not abort the paste")
          (key 7)
          (ubiquitty-test--check (= (length (sync ubiquitty-sync--kind-paste-abort)) 2)
                                 "an interrupt with no paste unfinished sent an abort")
          ;; A paste past what the host takes is refused whole, not cut.
          (setq ubiquitty-sync--paste-limits (list (* 32 1024) 1000 16384))
          (let ((before (length (sync ubiquitty-sync--kind-paste))))
            (ubiquitty-test--check (and (null (ubiquitty-sync--paste-text (make-string 1001 ?t)))
                                        (= before (length (sync ubiquitty-sync--kind-paste))))
                                   "a paste past the host's cap was sent"))
          (setq ubiquitty-sync--paste-limits (list (* 32 1024) (* 16 1024 1024) 16384))

          ;; Losing the focus says so twice: the window's in a Facts, the
          ;; pane's in a Focus.  A new size says so twice as well: the window's
          ;; in a Facts, the pane's in a Viewport.  A client with no theme
          ;; states no palette.
          (ubiquitty-sync--set-focus nil)
          (ubiquitty-sync--set-focus nil)
          (setq ubiquitty-sync--columns 100 ubiquitty-sync--rows 30)
          (ubiquitty-sync--send-facts)
          (ubiquitty-sync--send-viewport)
          (let ((viewports (sync ubiquitty-sync--kind-viewport)))
            (ubiquitty-test--check (and (= (length viewports) 2)
                                        (= (length (nth 0 viewports)) 16)
                                        (= (ubiquitty-sync--u16 (nth 0 viewports) 0) 24)
                                        (= (ubiquitty-sync--u16 (nth 0 viewports) 2) 80)
                                        (= (ubiquitty-sync--u16 (nth 1 viewports) 0) 30)
                                        (= (ubiquitty-sync--u16 (nth 1 viewports) 2) 100)
                                        (equal (substring (nth 1 viewports) 4) (make-string 12 0)))
                                   "the pane's Viewport was not sent at its bind and again at the new size"))
          (let ((ubiquitty-sync-theme "No Such Theme"))
            (ubiquitty-sync--send-facts))
          (let ((facts (sync ubiquitty-sync--kind-facts))
                (focus (sync ubiquitty-sync--kind-focus)))
            (ubiquitty-test--check (and (= (length facts) 4)
                                        (= (aref (nth 1 facts) 18) 0)
                                        (= (aref (nth 1 facts) 19) 1)
                                        (= (ubiquitty-sync--u16 (nth 2 facts) 0) 30)
                                        (= (ubiquitty-sync--u16 (nth 2 facts) 2) 100)
                                        (= (length (nth 3 facts)) 20)
                                        (= (aref (nth 3 facts) 19) 0))
                                   "the Facts after a focus change, a resize and without a theme are not the three expected")
            (ubiquitty-test--check (equal focus (list (unibyte-string 0)))
                                   "the pane was not told once that it lost the focus"))

          ;; The control channel: a notification is kept and a result is kept.
          (host-says ubiquitty-sync--kind-notify)
          (ubiquitty-test--check (and (= (length ubiquitty-sync--notifies) 1)
                                      (= (caar ubiquitty-sync--notifies) ubiquitty-sync--notify-kind-attachments))
                                 "the host's notification was not kept")
          (host-says ubiquitty-sync--kind-result)
          (ubiquitty-test--check (and ubiquitty-sync--last-result
                                      (= (car ubiquitty-sync--last-result) 0)
                                      (string-match-p "\"id\":7" (cdr ubiquitty-sync--last-result)))
                                 "the host's result was not read")
          ;; A Call is a client's to send: one from the host is refused by
          ;; name and answered with nothing, since the host closes on a
          ;; client's Result.
          (let* ((call (seq-find (lambda (frame) (= (car frame) ubiquitty-sync--kind-call)) control-frames))
                 (refusal (condition-case err
                              (progn (ubiquitty-sync--receive-sync
                                      proc buffer (ubiquitty-test--sync-frame (nth 0 call) (nth 1 call) (nth 2 call)))
                                     nil)
                            (error (error-message-string err)))))
            (ubiquitty-test--check (and refusal (string-match-p "only a client sends" refusal)
                                        (null (sync ubiquitty-sync--kind-result)))
                                   "a Call from the host was not refused, or was answered"))
          ;; Each Bye permanently ends its own carrier, not the transcript's
          ;; still-active input connection.
          (dolist (reason '("Superseded" "HandingOver"))
            (with-temp-buffer
              (ubiquitty-wire-fixture--admit)
              (let ((code (cl-position reason ubiquitty-sync--bye-reasons :test #'equal)))
                (ubiquitty-sync--receive-sync
                 nil (current-buffer)
                 (ubiquitty-test--sync-frame ubiquitty-sync--kind-bye 0 (unibyte-string code 0 0))))
              (ubiquitty-test--check (and (equal ubiquitty-sync--bye-reason reason) ubiquitty-sync--transport-closed)
                                     "the typed Bye did not permanently close its own carrier")))

          ;; Typed bytes past one piece go as several events, each numbered.
          (let ((before (length (sync ubiquitty-sync--kind-raw))))
            (ubiquitty-sync--send-raw (make-string 5000 ?z))
            (let ((raws (sync ubiquitty-sync--kind-raw)))
              (ubiquitty-test--check (and (= (length raws) (+ before 2))
                                          (= (length (car (last raws 2))) (+ 8 2 4096))
                                          (= (ubiquitty-sync--u64 (car (last raws)) 0) ubiquitty-sync--input-seq))
                                     "5000 typed bytes did not go as two numbered pieces")))

          ;; An update's header carries the host's counts of this client's input.
          (let* ((carried (seq-find (lambda (frame) (= (car frame) ubiquitty-sync--kind-update))
                                    (ubiquitty-test--sync-frames update)))
                 (body (nth 2 carried))
                 (lag (ubiquitty-sync--reader body 26))
                 (_lag (ubiquitty-sync--r-varint lag))
                 (at (aref lag 1)))
            (host-sends ubiquitty-sync--kind-update (nth 1 carried)
                        (concat (substring body 0 at) (u64 ubiquitty-sync--input-seq) (u64 5) (substring body (+ at 16))))
            (ubiquitty-test--check (and (= ubiquitty-sync--input-written ubiquitty-sync--input-seq) (= ubiquitty-sync--input-settled 5))
                                   (format "an update's input counts read %d written and %d settled"
                                           ubiquitty-sync--input-written ubiquitty-sync--input-settled)))

          ;; A kind only a client sends, arriving from the host, is refused and
          ;; named; so is a kind byte no version defines.  A kind this client
          ;; asked nothing of is stepped over.
          (cl-flet ((refused (kind channel body)
                      (condition-case err
                          (progn (ubiquitty-sync--receive-sync
                                  proc buffer (ubiquitty-test--sync-frame kind channel body))
                                 nil)
                        (error (error-message-string err)))))
            (ubiquitty-test--check (string-match-p "only a client sends" (or (refused ubiquitty-sync--kind-raw ubiquitty-sync--pane (make-string 9 0)) ""))
                                   "a client-only kind from the host was taken")
            (ubiquitty-test--check (string-match-p "kind 200" (or (refused 200 0 "") ""))
                                   "a kind byte no version defines was taken")
            (ubiquitty-test--check (null (refused 37 ubiquitty-sync--pane ""))
                                   "a PaneDirty this client asked nothing of was refused")
            (ubiquitty-test--check (null (refused 42 ubiquitty-sync--pane (make-string 20 0)))
                                   "a HistoryReset this client asked nothing of was refused")
            ;; PaneFacts supplies the title, so malformed records must fail
            ;; without publishing even a successfully decoded title prefix.
            (let ((facts-before (copy-tree ubiquitty-sync--pane-facts))
                  (title-before (copy-tree header-line-format)))
              (ubiquitty-test--check
               (stringp (refused ubiquitty-sync--kind-pane-facts ubiquitty-sync--pane (make-string 40 0)))
               "a truncated PaneFacts record was taken")
              (ubiquitty-test--check
               (and (equal ubiquitty-sync--pane-facts facts-before)
                    (equal header-line-format title-before))
               "a refused PaneFacts record changed the title or facts"))
            (ubiquitty-test--check (null (refused ubiquitty-sync--kind-status-records ubiquitty-sync--pane (make-string 10 0)))
                                   "a StatusRecords this client draws nothing from was refused")
            (ubiquitty-test--check (string-match-p "names no run" (or (refused ubiquitty-sync--kind-input-discarded ubiquitty-sync--pane (make-string 16 0)) ""))
                                   "an InputDiscarded naming no run was taken")))))
    ;; A checkpoint replaces everything held of the pane, the echo context
    ;; with it: unknown again until an update states it.  What this attach
    ;; sends is not part of the recorded stream.
    (let ((recorded sent))
      (cl-letf (((symbol-function 'ubiquitty-sync--send-sync) #'ignore))
        (with-current-buffer buffer
          (setq ubiquitty-sync--echo (list :interrupt 3)))
        ;; A checkpoint replaces the picture without rebinding an already
        ;; bound handle on the same carrier.
        (dolist (frame (ubiquitty-test--sync-frames attach))
          (when (memq (car frame) (list ubiquitty-sync--kind-checkpoint-head ubiquitty-sync--kind-bulk-chunk))
            (ubiquitty-test--feed proc (apply #'ubiquitty-test--sync-frame frame) 4096)))
        (ubiquitty-test--check (null (buffer-local-value 'ubiquitty-sync--echo buffer))
                               "a checkpoint left the echo context of the screen before it"))
      (setq sent recorded))
    (delete-process proc)
    (when upstream-path
      (let ((coding-system-for-write 'binary))
        (with-temp-file upstream-path
          (set-buffer-multibyte nil)
          (dolist (frame (reverse sent))
            (insert (apply #'ubiquitty-test--sync-frame frame))))))))

(defun ubiquitty-test--envelope-split-sweeps ()
  "Compare exact envelopes under exhaustive cuts and seeded partitions."
  (let ((ubiquitty-sync--welcome '(:target 0))
        (ubiquitty-sync--transport-closed nil)
        (ubiquitty-sync--consent-phase nil))
    (dolist (size '(1 127 128 1023 1024 1025 16383 16384 65535))
      (let* ((body (make-string size 0))
             (stream nil)
             (expected nil)
             (cuts nil))
        (dotimes (index size) (aset body index (% (+ (* index 37) (/ index 251)) 256)))
        (setq expected (list (ubiquitty-test--sync-frame ubiquitty-sync--kind-result 0 body)
                             (ubiquitty-test--sync-frame ubiquitty-sync--kind-probe 0 "abcdefgh"))
              stream (apply #'concat expected)
              cuts (list 0 (length stream)))
        (if (<= size 128)
            (dotimes (cut (length stream)) (push cut cuts))
          (let ((quantum 1))
            (while (<= quantum (length stream))
              (dolist (cut (list (1- quantum) quantum (1+ quantum)))
                (when (<= cut (length stream))
                  (push cut cuts)
                  (push (- (length stream) cut) cuts)))
              (setq quantum (* quantum 2)))))
        (cl-labels
            ((replay (ends label)
               (let ((pending "") (at 0) (received nil))
                 (dolist (end ends)
                   (setq pending
                         (ubiquitty-sync--feed-envelopes
                          pending (substring stream at end)
                          (lambda (frame) (push frame received)))
                         at end))
                 (let ((matches (and (equal pending "") (equal (nreverse received) expected))))
                   (ubiquitty-test--check matches
                                          (format "envelope split sweep size=%d %s" size label))
                   matches))))
          (catch 'differed
            (unless (replay (list (length stream)) "whole") (throw 'differed nil))
            (dolist (cut (sort (delete-dups cuts) #'<))
              (unless (replay (list cut (length stream)) (format "split=%d" cut))
                (throw 'differed nil)))
            (when (<= size 128)
              (unless (replay (number-sequence 1 (length stream)) "byte-at-a-time")
                (throw 'differed nil)))
            (dotimes (seed-index 32)
              (let ((state (1+ seed-index)) (end 0) (ends nil)
                    (maximum (if (= (% seed-index 2) 0) 17 4096)))
                (while (< end (length stream))
                  (setq state (% (* state 48271) 2147483647)
                        end (min (length stream) (+ end 1 (% state maximum))))
                  (push end ends))
                (unless (replay (nreverse ends) (format "seed=%d" (1+ seed-index)))
                  (throw 'differed nil))))))))))

(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (client (expand-file-name "../../Source/Platform/Emacs/ubiquitty-sync.el" here)))
  (load client nil t)
  (load (expand-file-name "editor-wire-fixture.el" here) nil t)
  (ubiquitty-test--envelope-split-sweeps)

  (dolist (function '(ubiquitty-sync--image-layout ubiquitty-sync--image-rendering
                      ubiquitty-sync--start-reassembly ubiquitty-sync--apply-image
                      ubiquitty-sync--apply-placements))
    (ubiquitty-test--check (fboundp function)
                           (format "%S was not defined when the client loaded" function)))

  (let* ((attach (ubiquitty-test--read (car command-line-args-left)))
         (update (ubiquitty-test--read (nth 1 command-line-args-left)))
         (buffer (generate-new-buffer "*ubiquitty-decode-test*"))
         (proc (make-pipe-process :name "ubiquitty-decode-test" :noquery t)))
    (process-put proc 'buffer buffer)
    (process-put proc 'accum "")
    (cl-letf (((symbol-function 'ubiquitty-sync--send-sync)
               (lambda (_proc kind channel body) (push (list kind channel body) ubiquitty-test--sent))))
      (with-current-buffer buffer
        (setq ubiquitty-sync--admission-request (ubiquitty-wire-fixture--request)))

      ;; The attach, in reads smaller than its frames: the checkpoint crosses
      ;; several BulkChunks, and each of those several reads.
      (ubiquitty-test--feed proc attach 97)
      (let ((lines (ubiquitty-test--lines buffer)))
        (ubiquitty-test--check (string-prefix-p "UBIQUITTY-SYNC-OK" (nth 0 lines))
                               (format "the first row reads back: %S" (nth 0 lines)))
        (ubiquitty-test--check (string-prefix-p "RED plain" (or (nth 1 lines) ""))
                               (format "the second row reads back: %S" (nth 1 lines)))
        ;; Two wide glyphs, a sized cell carrying a grapheme cluster, then a
        ;; proportional run. The cluster and the run are both id 1, so a
        ;; decoder that reads the id without the cell's text-size spec shows
        ;; the run's text where the cluster belongs.
        (ubiquitty-test--check (string-prefix-p "日本👨‍👩PROP" (or (nth 3 lines) ""))
                               (format "the sized, clustered and proportional row reads back: %S" (nth 3 lines)))
        ;; A wide glyph in the last two columns keeps both halves.
        (ubiquitty-test--check (string-suffix-p "世" (or (nth 3 lines) ""))
                               (format "the row's last wide glyph reads back: %S" (nth 3 lines))))
      (ubiquitty-test--check (equal (ubiquitty-test--cursor buffer) '(4 . 8))
                             (format "the cursor decoded at %S, expected (4 . 8)" (ubiquitty-test--cursor buffer)))
      (with-current-buffer buffer
        (save-excursion
        (goto-char (point-min))
        (forward-line 1)
        (ubiquitty-test--check
         (equal (plist-get (get-text-property (point) 'face) :foreground) "#cd0000")
         (format "the red run is drawn in palette red, not %S"
                 (plist-get (get-text-property (point) 'face) :foreground)))))
      (with-current-buffer buffer
        (ubiquitty-test--check (and ubiquitty-sync--mouse-tracking ubiquitty-sync--mouse-sgr)
                               "mouse tracking in the SGR encoding was not read from the modes block")
        (ubiquitty-test--check ubiquitty-sync--bracketed-paste
                               "bracketed paste was not read from the modes block"))

      ;; The checkpoint is acknowledged: its generation on the pane's handle,
      ;; and every stream byte the attach carried, so the host's window moves.
      (let* ((acks (ubiquitty-test--sent-sync ubiquitty-sync--kind-ack))
             (stream-bytes (length attach))
             (last (car (last acks)))
             (checkpoint-generation (with-current-buffer buffer ubiquitty-sync--generation)))
        (ubiquitty-test--check (and checkpoint-generation (> checkpoint-generation 0))
                               "no checkpoint generation is held")
        (ubiquitty-test--check
         (and last (= (ubiquitty-sync--u64 last 12) stream-bytes))
         (format "the last Ack counts %S stream bytes, the attach carried %d"
                 (and last (ubiquitty-sync--u64 last 12)) stream-bytes))
        (ubiquitty-test--check
         (cl-some (lambda (ack)
                    (let ((r (ubiquitty-sync--reader ack 20)))
                      (and (= (ubiquitty-sync--r-varint r) 1)
                           (= (ubiquitty-sync--r-varint r) (with-current-buffer buffer ubiquitty-sync--pane))
                           (= (ubiquitty-sync--r-u64 r) checkpoint-generation))))
                  acks)
         "no Ack names the checkpoint's generation on the pane's handle")

      ;; The pane is shown as soon as it is bound: the host sends a pane's
      ;; screen only once the client says so.
      (let ((views (ubiquitty-test--sent-sync ubiquitty-sync--kind-view)))
        (ubiquitty-test--check (and views (equal (car views) (unibyte-string 0)))
                               (format "the bound pane was not set Live: %S" views)))

      ;; The C++ encoder supplies the whole record, including every optional
      ;; branch. A complete title prefix cannot make a truncated record live.
      (let* ((control (ubiquitty-test--read (nth 2 command-line-args-left)))
             (records (cl-remove-if-not (lambda (frame) (= (car frame) ubiquitty-sync--kind-pane-facts))
                                        (ubiquitty-test--sync-frames control)))
             (pane (with-current-buffer buffer ubiquitty-sync--pane)))
        (ubiquitty-test--check (= (length records) 2) "the fixture carries full and empty PaneFacts")
        (when (= (length records) 2)
          (let* ((body (nth 2 (car records)))
                 (facts (ubiquitty-sync--read-pane-facts body)))
            (ubiquitty-test--check
             (and (equal (plist-get facts :title) "recorded-title")
                  (equal (plist-get facts :directory) "/srv/project")
                  (equal (plist-get facts :foreground) "less")
                  (not (plist-get facts :at-prompt))) "PaneFacts title inputs decode whole")
            (dotimes (length (length body))
              (ubiquitty-test--check
               (condition-case nil (progn (ubiquitty-sync--read-pane-facts (substring body 0 length)) nil) (error t))
               (format "truncated PaneFacts accepted at %d" length)))
            (ubiquitty-test--check
             (condition-case nil (progn (ubiquitty-sync--read-pane-facts (concat body "x")) nil) (error t))
             "PaneFacts accepted trailing bytes")
            (ubiquitty-test--feed proc (ubiquitty-test--sync-frame ubiquitty-sync--kind-pane-facts (1+ pane) body) 4096)
            (ubiquitty-test--check
             (not (equal (with-current-buffer buffer header-line-format) "recorded-title"))
             "another pane's facts retitled this buffer")
            (ubiquitty-test--feed proc (ubiquitty-test--sync-frame ubiquitty-sync--kind-pane-facts pane body) 4096)
            (ubiquitty-test--check (equal (with-current-buffer buffer header-line-format) "recorded-title")
                                   "PaneFacts alone did not retitle the buffer")
            (ubiquitty-test--feed proc
                                  (ubiquitty-test--sync-frame ubiquitty-sync--kind-pane-facts pane (nth 2 (cadr records))) 4096)
            (ubiquitty-test--check
             (with-current-buffer buffer
               (and (equal header-line-format "")
                    (equal (plist-get ubiquitty-sync--pane-facts :directory) "")
                    (plist-get ubiquitty-sync--pane-facts :at-prompt)))
             "an empty whole record did not clear title inputs"))))

        ;; An update that does not decode asks for a checkpoint and leaves the
        ;; screen as it was.
        (let* ((carried (car (cl-remove-if-not (lambda (frame) (= (car frame) ubiquitty-sync--kind-update))
                                               (ubiquitty-test--sync-frames update))))
               (channel (nth 1 carried))
               (body (nth 2 carried)))
          (ubiquitty-test--check carried "the update fixture carries no Update")
          (ubiquitty-sync--filter proc (ubiquitty-test--sync-frame
                                        ubiquitty-sync--kind-update channel
                                        (substring body 0 (- (length body) 20))))
          (let ((resyncs (ubiquitty-test--sent-sync ubiquitty-sync--kind-resync)))
            (ubiquitty-test--check (and resyncs (= (aref (car (last resyncs)) 0)
                                                   ubiquitty-sync--resync-decode-failed))
                                   "a truncated update did not ask for a checkpoint"))
          (ubiquitty-test--check (not (string-prefix-p "update-row-six" (or (nth 5 (ubiquitty-test--lines buffer)) "")))
                                 "a truncated update changed the screen")
          ;; The checkpoint that Resync asks for is the attach again.
          (with-current-buffer buffer (setq ubiquitty-sync--resync-outstanding nil))

          ;; The update itself: a row written, the cursor moved, bracketed
          ;; paste turned off.
          (ubiquitty-test--feed proc update 4096)
          (let ((lines (ubiquitty-test--lines buffer)))
            (ubiquitty-test--check (string-prefix-p "update-row-six" (or (nth 5 lines) ""))
                                   (format "the updated row reads back: %S" (nth 5 lines)))
            (ubiquitty-test--check (string-prefix-p "UBIQUITTY-SYNC-OK" (nth 0 lines))
                                   "an update naming one row disturbed another"))
          (ubiquitty-test--check (equal (ubiquitty-test--cursor buffer) '(5 . 14))
                                 (format "the update's cursor decoded at %S, expected (5 . 14)"
                                         (ubiquitty-test--cursor buffer)))
          (with-current-buffer buffer
            (ubiquitty-test--check (not ubiquitty-sync--bracketed-paste)
                                   "the update's modes block did not turn bracketed paste off")
            (ubiquitty-test--check (> ubiquitty-sync--generation checkpoint-generation)
                                   "the update's generation is not held"))

          ;; The same update again is behind the screen and asks for nothing.
          (let ((before (length (ubiquitty-test--sent-sync ubiquitty-sync--kind-resync))))
            (ubiquitty-sync--filter proc (ubiquitty-test--sync-frame ubiquitty-sync--kind-update channel body))
            (ubiquitty-test--check (= before (length (ubiquitty-test--sent-sync ubiquitty-sync--kind-resync)))
                                   "an update the screen is already past asked for a checkpoint"))

          ;; An update onto a generation the screen does not hold is a gap
          ;; only a checkpoint closes.
          (with-current-buffer buffer (setq ubiquitty-sync--generation 0))
          (let ((before (length (ubiquitty-test--sent-sync ubiquitty-sync--kind-resync))))
            (ubiquitty-sync--filter proc (ubiquitty-test--sync-frame ubiquitty-sync--kind-update channel body))
            (let ((resyncs (ubiquitty-test--sent-sync ubiquitty-sync--kind-resync)))
              (ubiquitty-test--check (and (= (length resyncs) (1+ before))
                                          (= (aref (car (last resyncs)) 0)
                                             ubiquitty-sync--resync-base-missing))
                                     "an update onto a generation not held did not ask for a checkpoint")))))

      ;; A host at another version says so rather than leave a blank buffer.
      (ubiquitty-test--check
       (condition-case err
           (progn (with-temp-buffer
                    (ubiquitty-sync--receive-sync
                   nil (current-buffer)
                   (ubiquitty-test--sync-frame ubiquitty-sync--kind-welcome 0
                                                           (concat (ubiquitty-sync--put-u16 99)
                                                                   (make-string 38 0)))))
                  nil)
         (error (string-match-p "wire version 99" (error-message-string err))))
       "a Welcome at another wire version does not raise an error naming it"))

    ;; Header bounds are checked before a hostile body is retained.
    (ubiquitty-test--check (null (ubiquitty-sync--envelope-header
                                  (unibyte-string ubiquitty-sync--kind-welcome 0 #x80)))
                           "a partial canonical header did not await its length")
    (dolist (header (list (unibyte-string #xff) (unibyte-string #x23)
                          (unibyte-string ubiquitty-sync--kind-welcome 1)
                          (unibyte-string ubiquitty-sync--kind-welcome 0 #x80 #x80 4)))
      (ubiquitty-test--check (condition-case nil (progn (ubiquitty-sync--envelope-header header) nil) (error t))
                             "an invalid canonical header was accepted"))

    ;; The host's title is text, not a mode-line construct.
    (let ((line (ubiquitty-sync--header-line
                 (encode-coding-string "100% [%b]\nsecond" 'utf-8 t))))
      (ubiquitty-test--check
       (equal line "100%% [%%b]second")
       (format "the host title is installed as: %S" line)))

    (ubiquitty-test--image-checks buffer)
    (delete-process proc)
    (ubiquitty-test--picture-checks (ubiquitty-test--read (nth 4 command-line-args-left)))
    (ubiquitty-test--upstream-checks attach update
                                     (ubiquitty-test--read (nth 2 command-line-args-left))
                                     (nth 3 command-line-args-left))

    (if (= ubiquitty-test--failures 0)
        (progn (message "emacs_sync_decode: all passed") (kill-emacs 0))
      (kill-emacs 1))))

;;; emacs-sync-decode-test.el ends here
