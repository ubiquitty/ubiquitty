;;; emacs-live-check.el --- the Emacs client against a live daemon -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Stanislav Yaglo
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:

;; Attaches through the host's attach bridge, waits for the first checkpoint,
;; and then sends what the client sends against the host that reads it: a
;; character as Raw and Return as a key the host encodes, a paste as Paste
;; pieces, its theme and a new size in a Facts.  Each is seen to come back,
;; and the host's count of input written to reach the count sent.  The shell
;; is told to exit at the end, which ends the session and with it a daemon
;; this check started.
;;
;;     emacs --batch -Q -l Tests/Platform/emacs-live-check.el <ubiquitty-host> [seconds]

;;; Code:

(require 'cl-lib)

(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (client (expand-file-name "../../Source/Platform/Emacs/ubiquitty-sync.el" here))
       (host (car command-line-args-left))
       (seconds (string-to-number (or (nth 1 command-line-args-left) "5")))
       (failures 0))
  (unless (and host (file-executable-p host))
    (message "usage: emacs --batch -Q -l emacs-live-check.el <ubiquitty-host> [seconds]")
    (kill-emacs 2))
  (load client nil t)
  (setq ubiquitty-sync-host-program host
        ;; The client instance and resume record go to a scratch directory.
        ubiquitty-sync-state-directory (make-temp-file "ubiquitty-live-state" t)
        ubiquitty-sync-theme "Noir"
        ubiquitty-sync-kill-buffer-on-exit nil)
  (ubiquitty-sync)
  (let* ((buffer (get-buffer "*ubiquitty*"))
         (proc (buffer-local-value 'ubiquitty-sync--process buffer)))
    (cl-labels ((wait (predicate)
                  (let ((deadline (+ (float-time) seconds)))
                    (while (and (not (funcall predicate)) (< (float-time) deadline) (process-live-p proc))
                      (accept-process-output proc 0.05))
                    (funcall predicate)))
                (on-screen (text)
                  (wait (lambda ()
                          (with-current-buffer buffer
                            (save-excursion
                              (goto-char (point-min))
                              (search-forward text nil t))))))
                (check (ok what)
                  (message "emacs_live_check: %s%s" (if ok "" "FAILED: ") what)
                  (unless ok (cl-incf failures)))
                (type (text)
                  (with-current-buffer buffer
                    (ubiquitty-sync--send-raw (encode-coding-string text 'utf-8 t))))
                (press (event)
                  (with-current-buffer buffer
                    (let ((last-command-event event))
                      (ubiquitty-sync-send-key)))))
      (check (wait (lambda () (buffer-local-value 'ubiquitty-sync--generation buffer)))
             "a checkpoint was applied")
      ;; A marker the typed line itself does not contain, run by Return sent
      ;; as a key for the host to encode.
      (type "echo UBIQUITTY-EM''ACS-LIVE")
      (press 'return)
      (check (on-screen "UBIQUITTY-EMACS-LIVE") "typed input, run by a Return key event, came back on screen")
      ;; A paste: the host brackets it if the shell asked.
      (with-current-buffer buffer
        (ubiquitty-sync--paste-text "echo UBIQUITTY-EM''ACS-PASTE"))
      (press 'return)
      (check (on-screen "UBIQUITTY-EMACS-PASTE") "a paste came back on screen")
      ;; The theme went in a Facts after the Welcome, and the host's palette
      ;; came back as the theme's: Noir's background.
      (check (wait (lambda ()
                     (let ((palette (buffer-local-value 'ubiquitty-sync--palette buffer)))
                       (and palette (equal (aref palette 257) "#15171c")))))
             "the theme stated in a Facts is the palette the host sent back")
      ;; A new size, in a Facts.
      (with-current-buffer buffer
        (setq ubiquitty-sync--columns 53 ubiquitty-sync--rows 17)
        (ubiquitty-sync--send-facts))
      (type "echo SIZE-$(stty size | tr ' ' x)-END")
      (press 'return)
      (check (on-screen "SIZE-17x53-END") "the new size reached the shell")
      (check (wait (lambda ()
                     (with-current-buffer buffer
                       (and (> ubiquitty-sync--input-seq 0)
                            (= ubiquitty-sync--input-written ubiquitty-sync--input-seq)))))
             (with-current-buffer buffer
               (format "the host counted every event written (sent %d, written %d, discarded %d)"
                       ubiquitty-sync--input-seq ubiquitty-sync--input-written ubiquitty-sync--input-discarded)))
      ;; The echo context can arrive after the output the checks above wait
      ;; for, so it is waited for like them.
      (check (wait (lambda () (buffer-local-value 'ubiquitty-sync--echo buffer))) "the echo context arrived")
      (check (plist-get (buffer-local-value 'ubiquitty-sync--welcome buffer) :paste-limits)
             "the Welcome stated paste caps")
      ;; The shell exits, the session ends, and the bridge leaves.
      (type "exit")
      (press 'return)
      (check (wait (lambda () (not (process-live-p proc)))) "the session ended and the bridge left")
      (when (process-live-p proc)
        (delete-process proc))))
  (kill-emacs (if (= failures 0) 0 1)))

;;; emacs-live-check.el ends here
