;;; emacs-sync-resume-check.el --- the Emacs client across a restart -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Stanislav Yaglo
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:

;; Two Emacs processes against one live daemon, as a person restarting Emacs
;; sees them.  The first attaches, puts a marker on the screen, starts a line
;; that prints while no client is attached, and goes away without a Bye, as
;; Emacs exiting does.  The second draws the stored screen before the bridge
;; has said anything, greets as the same client instance, is continued by the
;; host with a diff rather than a checkpoint, and shows what was printed
;; meanwhile.  It then ends the session.
;;
;;     emacs --batch -Q -l Tests/Platform/emacs-sync-resume-check.el \
;;         <ubiquitty-host> <state-directory> <first|second> [seconds]
;;
;; Run with UBIQUITTY_HOME set to a scratch directory, so the daemon is the
;; check's own.

;;; Code:

(require 'cl-lib)

(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (client (expand-file-name "../../Source/Platform/Emacs/ubiquitty-sync.el" here))
       (host (nth 0 command-line-args-left))
       (state (nth 1 command-line-args-left))
       (phase (nth 2 command-line-args-left))
       (seconds (string-to-number (or (nth 3 command-line-args-left) "10")))
       (failures 0))
  (unless (and host (file-executable-p host) state (member phase '("first" "second")))
    (message "usage: emacs --batch -Q -l emacs-sync-resume-check.el <ubiquitty-host> <state-directory> <first|second> [seconds]")
    (kill-emacs 2))
  (load client nil t)
  (setq ubiquitty-sync-host-program host
        ubiquitty-sync-state-directory state
        ubiquitty-sync-kill-buffer-on-exit nil)
  (cl-labels ((check (ok what)
                (message "emacs_resume_check %s: %s%s" phase (if ok "" "FAILED: ") what)
                (unless ok (cl-incf failures)))
              (screen-has (buffer text)
                (with-current-buffer buffer
                  (save-excursion
                    (goto-char (point-min))
                    (search-forward text nil t)))))
    (let ((checkpoints 0))
      (advice-add 'ubiquitty-sync--apply-checkpoint :after (lambda (&rest _) (cl-incf checkpoints)))
      ;; Whatever the bridge says is held back until the stored screen has
      ;; been looked at: the bridge's first bytes are the host's.
      (let* ((stored-instance (and (equal phase "second")
                                   (with-temp-buffer
                                     (insert-file-contents-literally (expand-file-name "client-instance" state))
                                     (string-trim (buffer-string)))))
             (before-packet nil))
        (when (equal phase "second")
          (advice-add 'ubiquitty-sync--attach :before
                      (lambda (&rest _)
                        (let ((buffer (get-buffer "*ubiquitty*")))
                          (setq before-packet
                                (list (screen-has buffer "BEFORE-THE-RESTART")
                                      (buffer-local-value 'ubiquitty-sync--generation buffer)
                                      checkpoints))))))
        (ubiquitty-sync)
        (let* ((buffer (get-buffer "*ubiquitty*"))
               (proc (buffer-local-value 'ubiquitty-sync--process buffer)))
          (cl-labels ((wait (predicate)
                        (let ((deadline (+ (float-time) seconds)))
                          (while (and (not (funcall predicate)) (< (float-time) deadline) (process-live-p proc))
                            (accept-process-output proc 0.05))
                          (funcall predicate)))
                      (type (text)
                        (with-current-buffer buffer
                          (ubiquitty-sync--send-raw (encode-coding-string text 'utf-8 t))))
                      (press-return ()
                        (with-current-buffer buffer
                          (let ((last-command-event 'return))
                            (ubiquitty-sync-send-key)))))
            (if (equal phase "first")
                (progn
                  (check (wait (lambda () (buffer-local-value 'ubiquitty-sync--generation buffer)))
                         "a checkpoint was applied")
                  (type "echo BEFORE-THE-REST''ART; (sleep 2; echo WHILE-EMACS-WAS-GO''NE) &")
                  (press-return)
                  (check (wait (lambda () (screen-has buffer "BEFORE-THE-RESTART")))
                         "the marker came back on screen")
                  (check (wait (lambda ()
                                 (with-current-buffer buffer
                                   (and (> ubiquitty-sync--input-seq 0)
                                        (= ubiquitty-sync--input-written ubiquitty-sync--input-seq)))))
                         "the host wrote every event")
                  ;; Emacs exits: the record is stored, and the bridge goes
                  ;; without a Bye, which leaves the attachment to resume.
                  (run-hooks 'kill-emacs-hook)
                  (check (file-exists-p (expand-file-name "resume.record" state)) "the record was stored")
                  (set-process-sentinel proc #'ignore)
                  (delete-process proc))
              (check (car before-packet) "the stored screen was drawn before the bridge started")
              (check (nth 1 before-packet) "the stored screen is the generation it was stored at")
              (check (wait (lambda () (buffer-local-value 'ubiquitty-sync--welcome buffer))) "the host answered")
              (let* ((welcome (buffer-local-value 'ubiquitty-sync--welcome buffer))
                     (resumed (plist-get welcome :resumed)))
                (check (and resumed (= (nth 1 (car resumed)) ubiquitty-sync--resume-outcome-diffed))
                       (format "the host continued the pane with a diff (outcomes %S)" (mapcar #'cadr resumed))))
              (check (equal stored-instance
                            (mapconcat (lambda (byte) (format "%02x" byte))
                                       (buffer-local-value 'ubiquitty-sync--client-instance buffer) ""))
                     "the Greet named the stored client instance")
              (check (wait (lambda () (screen-has buffer "WHILE-EMACS-WAS-GONE")))
                     "what was printed meanwhile came in the diff")
              (check (screen-has buffer "BEFORE-THE-RESTART") "the stored screen is kept")
              (check (= checkpoints (nth 2 before-packet))
                     (format "no checkpoint followed the resume (%d applied)" (- checkpoints (nth 2 before-packet))))
              (type "exit")
              (press-return)
              (check (wait (lambda () (buffer-local-value 'ubiquitty-sync--pane-ended buffer)))
                     "the shell's exit ended the pane")
              (check (wait (lambda () (not (process-live-p proc)))) "the bridge left")
              (check (not (file-exists-p (expand-file-name "resume.record" state)))
                     "the ended session took its record with it")
              (when (process-live-p proc)
                (delete-process proc)))))))
    (kill-emacs (if (= failures 0) 0 1))))

;;; emacs-sync-resume-check.el ends here
