;;; emacs-sync-admission-test.el --- Exact own-consent admission -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Stanislav Yaglo
;; SPDX-License-Identifier: Apache-2.0

(require 'ert)
(add-to-list 'load-path (expand-file-name "../../Source/Platform/Emacs" (file-name-directory load-file-name)))
;; Admission fixtures must not read user configuration or a theme table.
(defvar ubiquitty-sync-theme)
(defvar ubiquitty-sync-theme-file)
(setq ubiquitty-sync-theme "__admission_test_no_theme__"
      ubiquitty-sync-theme-file nil)
(require 'ubiquitty-sync)

(defun ubiquitty-admission-test--welcome (admission question session &optional tail selection)
  "Build the current Welcome for ADMISSION, QUESTION and SESSION with TAIL."
  (concat (ubiquitty-sync--put-u16 ubiquitty-sync--wire-version)
          (ubiquitty-sync--put-bytes "")
          (make-string 32 0) (make-string 16 ?h) (make-string 16 ?a) (make-string 16 0)
          (unibyte-string ubiquitty-sync--role-owner (or (plist-get selection :target) ubiquitty-sync--admission-target-session))
          (ubiquitty-sync--put-u32 (or (plist-get selection :session) 9))
          (ubiquitty-sync--put-u32 (or (plist-get selection :workspace) 0))
          (ubiquitty-sync--put-u64 (or (plist-get selection :daemon) 1))
          (ubiquitty-sync--put-bytes "fixture.sock") (unibyte-string 0)
          (ubiquitty-sync--put-bytes "")
          (ubiquitty-sync--put-u64 (or (plist-get selection :restored) 0))
          (unibyte-string admission)
          (ubiquitty-sync--put-u32 question) (ubiquitty-sync--put-u32 session)
          (ubiquitty-sync--put-bytes "fixture")
          (ubiquitty-sync--put-u16 8) (ubiquitty-sync--put-u32 (* 16 1024 1024))
          (ubiquitty-sync--put-u16 8) (unibyte-string 0) (ubiquitty-sync--put-u64 42)
          (or tail (unibyte-string 0 0 0))))

(defun ubiquitty-admission-test--notify (kind record)
  "Build a Notify body of KIND with RECORD."
  (concat (ubiquitty-sync--put-varint kind) record))

(defun ubiquitty-admission-test--status (phase &optional question session)
  "Build PHASE's own status for QUESTION and SESSION, defaulting to 7 and 9.
An unknown PHASE word is written as the first number past the known ones."
  (ubiquitty-admission-test--notify
   ubiquitty-sync--notify-kind-consent-status
   (concat (ubiquitty-sync--put-u32 (or question 7)) (ubiquitty-sync--put-u32 (or session 9))
           (unibyte-string (or (car (rassoc phase ubiquitty-sync--consent-status-phases)) 4)))))

(defconst ubiquitty-admission-test--attachments
  (ubiquitty-admission-test--notify ubiquitty-sync--notify-kind-attachments
                                    (concat (ubiquitty-sync--put-u64 4) (unibyte-string 0)))
  "An empty attachments list, a Notify of another kind than own status.")

(defun ubiquitty-admission-test--receive (kind body &optional channel)
  "Deliver KIND and BODY on CHANNEL to the current in-memory buffer."
  (unless ubiquitty-sync--admission-request
    (setq ubiquitty-sync--admission-request (ubiquitty-sync--make-handshake-request
                                            :columns 80 :rows 24 :client-instance (make-string 16 ?c))))
  (ubiquitty-sync--receive-sync
   nil (current-buffer)
   (concat (unibyte-string kind) (ubiquitty-sync--put-varint (or channel 0))
           (ubiquitty-sync--put-bytes body))))

(defun ubiquitty-admission-test--begin ()
  "Deliver the exact pending Welcome without opening a process or socket."
  (ubiquitty-admission-test--receive
   ubiquitty-sync--kind-welcome
   (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-awaiting-consent 7 9)))

(ert-deftest ubiquitty-admission-welcome-is-mandatory-and-exact ()
  (let ((body (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-granted 0 0)))
    (should (= (plist-get (ubiquitty-sync--read-welcome body) :admission) ubiquitty-sync--attachment-admission-granted))
    (dotimes (cut (length body)) (should-error (ubiquitty-sync--read-welcome (substring body 0 cut))))
    (should-error (ubiquitty-sync--read-welcome (concat body "x")))
    (dolist (tail (list (unibyte-string 2 0 0) (unibyte-string 0 0 2) (unibyte-string 0 0 1)))
      (should-error (ubiquitty-sync--read-welcome
                     (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-granted 0 0 tail)))))
  (dolist (binding (list (list ubiquitty-sync--attachment-admission-awaiting-consent 0 9)
                         (list ubiquitty-sync--attachment-admission-awaiting-consent 7 0)
                         (list ubiquitty-sync--attachment-admission-granted 7 0)
                         (list ubiquitty-sync--attachment-admission-granted 0 9)
                         '(2 7 9)))
    (should-error (ubiquitty-sync--read-welcome (apply #'ubiquitty-admission-test--welcome binding))))
  (let ((tail (concat (unibyte-string 0 1) (make-string 16 ?p)
                      (unibyte-string ubiquitty-sync--resume-outcome-checkpointed 0 0))))
    (should (= (length (plist-get (ubiquitty-sync--read-welcome
                                  (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-granted 0 0 tail))
                                 :resumed)) 1))
    (should-error (ubiquitty-sync--read-welcome
                   (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-awaiting-consent 7 9 tail)))))

(ert-deftest ubiquitty-admission-pending-welcome-withholds-data-and-facts ()
  (dolist (kind (list ubiquitty-sync--kind-pane-bind ubiquitty-sync--kind-pane-listed
                     ubiquitty-sync--kind-workspace-structure ubiquitty-sync--kind-checkpoint-head
                     ubiquitty-sync--kind-update ubiquitty-sync--kind-effect ubiquitty-sync--kind-result))
    (with-temp-buffer
      (let ((sent nil))
        (cl-letf (((symbol-function 'ubiquitty-sync--send-sync) (lambda (&rest arguments) (push arguments sent))))
          (setq ubiquitty-sync--process 'memory ubiquitty-sync--facts-owed t)
          (ubiquitty-admission-test--begin)
          (should (equal ubiquitty-sync--consent-phase "awaiting-status"))
          (should-not sent)
          (should-error (ubiquitty-admission-test--receive kind ""))
          (should-not ubiquitty-sync--pane)
          (should-not sent))))))

(ert-deftest ubiquitty-admission-exact-pending-then-approved-enables-once ()
  (with-temp-buffer
    (let ((sent nil))
      (cl-letf (((symbol-function 'ubiquitty-sync--send-sync) (lambda (&rest arguments) (push arguments sent))))
        (setq ubiquitty-sync--process 'memory ubiquitty-sync--facts-owed t)
        (ubiquitty-admission-test--begin)
        (ubiquitty-admission-test--receive ubiquitty-sync--kind-notify (ubiquitty-admission-test--status "pending"))
        (should (equal ubiquitty-sync--consent-phase "pending"))
        (should-not sent)
        (ubiquitty-admission-test--receive ubiquitty-sync--kind-notify (ubiquitty-admission-test--status "approved"))
        (should (equal ubiquitty-sync--consent-phase "approved"))
        (should (= (length sent) 1))
        (should-not ubiquitty-sync--facts-owed)
        (should-not ubiquitty-sync--notifies)
        (ubiquitty-admission-test--receive ubiquitty-sync--kind-pane-bind (concat (unibyte-string 1) (make-string 16 ?p)))
        (should (= ubiquitty-sync--pane 1))
        (let ((before (length sent)))
          (should-error (ubiquitty-admission-test--receive ubiquitty-sync--kind-notify (ubiquitty-admission-test--status "approved")))
          (should (= (length sent) before)))))))

(ert-deftest ubiquitty-admission-status-rejects-mismatch-replay-and-malformed-records ()
  (dolist (body (list (ubiquitty-admission-test--status "approved")
                     (ubiquitty-admission-test--status "pending" 8 9)
                     (ubiquitty-admission-test--status "pending" 7 10)
                     (ubiquitty-admission-test--status "pending" 0 9)
                     (ubiquitty-admission-test--status "unknown")
                     ubiquitty-admission-test--attachments
                     (ubiquitty-admission-test--notify 127 "")
                     (substring (ubiquitty-admission-test--status "pending") 0 -1)
                     (concat (ubiquitty-admission-test--status "pending") (unibyte-string 0))
                     (make-string (1+ ubiquitty-sync--max-consent-status-bytes) ?x)))
    (with-temp-buffer
      (ubiquitty-admission-test--begin)
      (should-error (ubiquitty-admission-test--receive ubiquitty-sync--kind-notify body))
      (should (equal ubiquitty-sync--consent-phase "awaiting-status"))
      (should-not ubiquitty-sync--pane)))
  (with-temp-buffer
    (ubiquitty-admission-test--begin)
    (should-error (ubiquitty-admission-test--receive ubiquitty-sync--kind-notify (ubiquitty-admission-test--status "pending") 1))
    (ubiquitty-admission-test--receive ubiquitty-sync--kind-notify (ubiquitty-admission-test--status "pending"))
    (should-error (ubiquitty-admission-test--receive ubiquitty-sync--kind-notify (ubiquitty-admission-test--status "pending")))))

(ert-deftest ubiquitty-admission-denial-and-expiry-never-grant-a-pane ()
  (dolist (phase '("denied" "expired"))
    (with-temp-buffer
      (ubiquitty-admission-test--begin)
      (ubiquitty-admission-test--receive ubiquitty-sync--kind-notify (ubiquitty-admission-test--status "pending"))
      (ubiquitty-admission-test--receive ubiquitty-sync--kind-notify (ubiquitty-admission-test--status phase))
      (should (equal ubiquitty-sync--consent-phase phase))
      (should-error (ubiquitty-admission-test--receive ubiquitty-sync--kind-pane-bind ""))
      (should-error (ubiquitty-admission-test--receive ubiquitty-sync--kind-notify (ubiquitty-admission-test--status "approved")))
      (should-error (ubiquitty-admission-test--receive ubiquitty-sync--kind-bye (unibyte-string 0 0 0)))
      (let ((reason (cl-position "NoConsent" ubiquitty-sync--bye-reasons :test #'equal)))
        (ubiquitty-admission-test--receive ubiquitty-sync--kind-bye (unibyte-string reason 0 0)))
      (should (equal ubiquitty-sync--bye-reason "NoConsent"))
      (should (equal ubiquitty-sync--consent-verdict phase))
      (should-error (ubiquitty-admission-test--receive ubiquitty-sync--kind-notify (ubiquitty-admission-test--status "approved")))
      (should-not ubiquitty-sync--pane))))

(ert-deftest ubiquitty-admission-granted-rejects-an-unsolicited-own-status ()
  (with-temp-buffer
    (ubiquitty-admission-test--receive
     ubiquitty-sync--kind-welcome
     (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-granted 0 0))
    (should-error (ubiquitty-admission-test--receive ubiquitty-sync--kind-notify (ubiquitty-admission-test--status "pending")))
    (should-error (ubiquitty-admission-test--receive
                   ubiquitty-sync--kind-welcome
                   (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-granted 0 0))))
  (dolist (body (list
                (ubiquitty-admission-test--status "unknown")
                (substring (ubiquitty-admission-test--status "pending") 0 -1)
                (concat (ubiquitty-admission-test--status "pending") (unibyte-string 0))
                (unibyte-string #x80)))
    (with-temp-buffer
      (ubiquitty-admission-test--receive
       ubiquitty-sync--kind-welcome
       (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-granted 0 0))
      (should-error (ubiquitty-admission-test--receive ubiquitty-sync--kind-notify body))
      (should-not ubiquitty-sync--notifies)
      (should-not ubiquitty-sync--consent-phase)
      (should-not ubiquitty-sync--pane)))
  (with-temp-buffer
    (ubiquitty-admission-test--receive
     ubiquitty-sync--kind-welcome
     (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-granted 0 0))
    ;; A kind this client does not know is skipped by its length.
    (ubiquitty-admission-test--receive ubiquitty-sync--kind-notify (ubiquitty-admission-test--notify 127 "opaque"))
    (should-not ubiquitty-sync--notifies)
    (ubiquitty-admission-test--receive ubiquitty-sync--kind-notify ubiquitty-admission-test--attachments)
    (should (= (length ubiquitty-sync--notifies) 1))
    (should (= (caar ubiquitty-sync--notifies) ubiquitty-sync--notify-kind-attachments))
    (should-not ubiquitty-sync--consent-phase)))

(ert-deftest ubiquitty-admission-greet-is-the-only-first-byte-request ()
  (with-temp-buffer
    (let ((sent nil))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'process-send-string) (lambda (_ bytes) (push bytes sent))))
        (ubiquitty-sync--send-greet 'memory 137 43))
      (should (= (length sent) 1))
      (let* ((body (concat (ubiquitty-sync--put-u16 ubiquitty-sync--wire-version) (unibyte-string 0)
                           ubiquitty-sync--wire-fingerprint ubiquitty-sync--client-instance
                           (unibyte-string ubiquitty-sync--client-kind-human ubiquitty-sync--role-owner
                                           ubiquitty-sync--admission-target-session)
                           (make-string 23 0)
                           (ubiquitty-sync--put-u16 43) (ubiquitty-sync--put-u16 137)
                           (make-string 14 0) (unibyte-string 1) (make-string 8 0)
                           (ubiquitty-sync--put-varint (logior ubiquitty-sync--capability-echo-context ubiquitty-sync--capability-shows-no-questions))
                           (unibyte-string 0)))
             (expected (concat (unibyte-string ubiquitty-sync--kind-greet 0) (ubiquitty-sync--put-bytes body))))
        (should (equal (car sent) expected))
        (should (equal (ubiquitty-sync--handshake-request-client-instance ubiquitty-sync--admission-request)
                       ubiquitty-sync--client-instance)))))
  (let ((request (ubiquitty-sync--make-handshake-request :columns 80 :rows 24 :client-instance (make-string 16 ?c)
                                                       :session-id 9)))
    (let* ((body (ubiquitty-sync--greet-body request)) (r (ubiquitty-sync--reader body)))
      (ubiquitty-sync--take r 2)
      (ubiquitty-sync--r-bytes r)
      (ubiquitty-sync--take r 51) ; fingerprint, exact instance, kind, role, target
      (should (= (ubiquitty-sync--r-u32 r) 9))
      (ubiquitty-sync--take r 12)
      (dotimes (_ 3) (should (equal (ubiquitty-sync--r-bytes r) "")))
      (should (= (ubiquitty-sync--r-u8 r) 1))) ; saved numeric IDs never create
    (setf (ubiquitty-sync--handshake-request-session-id request) #x100000000)
    (should-error (ubiquitty-sync--greet-body request))))

(ert-deftest ubiquitty-admission-selection-must-answer-the-exact-request ()
  (dolist (mismatch '(session workspace daemon target))
    (with-temp-buffer
      (setq ubiquitty-sync--admission-request
            (ubiquitty-sync--make-handshake-request :columns 80 :rows 24 :client-instance (make-string 16 ?c)))
      (pcase mismatch
        ('session (setf (ubiquitty-sync--handshake-request-session-id ubiquitty-sync--admission-request) 8))
        ('workspace (setf (ubiquitty-sync--handshake-request-target ubiquitty-sync--admission-request)
                         ubiquitty-sync--admission-target-workspace
                         (ubiquitty-sync--handshake-request-workspace-id ubiquitty-sync--admission-request) 8))
        ('daemon (setf (ubiquitty-sync--handshake-request-expected-daemon ubiquitty-sync--admission-request) 2))
        ('target (setf (ubiquitty-sync--handshake-request-target ubiquitty-sync--admission-request)
                       ubiquitty-sync--admission-target-workspace)))
      (should-error (ubiquitty-admission-test--receive
                     ubiquitty-sync--kind-welcome
                     (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-granted 0 0 nil
                       (and (eq mismatch 'workspace) (list :target ubiquitty-sync--admission-target-workspace :workspace 7)))))
      (should-not ubiquitty-sync--welcome)
      (should-not ubiquitty-sync--pane)))
  (with-temp-buffer
    (setq ubiquitty-sync--admission-request
          (ubiquitty-sync--make-handshake-request :columns 80 :rows 24 :client-instance (make-string 16 ?c)
                                                 :session-id 9 :expected-daemon 1))
    (ubiquitty-admission-test--receive ubiquitty-sync--kind-welcome
                                     (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-granted 0 0))
    (should (= (plist-get ubiquitty-sync--welcome :session-id) 9))))

(ert-deftest ubiquitty-admission-unbound-targets-have-no-pane-or-resumed-authority ()
  (dolist (target (list ubiquitty-sync--admission-target-control ubiquitty-sync--admission-target-management))
    (let ((selection (list :target target :session 0))
          (tail (concat (unibyte-string 0 1) (make-string 16 ?p)
                        (unibyte-string ubiquitty-sync--resume-outcome-checkpointed 0 0))))
      (should-error (ubiquitty-sync--read-welcome
                     (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-granted 0 0 tail selection)))
      (with-temp-buffer
        (setq ubiquitty-sync--admission-request
              (ubiquitty-sync--make-handshake-request :columns 80 :rows 24 :client-instance (make-string 16 ?c) :target target))
        (ubiquitty-admission-test--receive ubiquitty-sync--kind-welcome
          (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-granted 0 0 nil selection))
        (should (= (plist-get ubiquitty-sync--welcome :target) target))
        (should-error (ubiquitty-admission-test--receive ubiquitty-sync--kind-pane-bind ""))
        (should-not ubiquitty-sync--pane)))))

(ert-deftest ubiquitty-admission-bye-has-an-exact-mandatory-peer-tail ()
  (let* ((body (concat (unibyte-string ubiquitty-sync--bye-reason-version-mismatch)
                       (ubiquitty-sync--put-bytes "update host") (unibyte-string 1)
                       (ubiquitty-sync--put-u16 99)
                       (ubiquitty-sync--put-bytes "fixture") (ubiquitty-sync--put-bytes "linux")))
         (closing (ubiquitty-sync--read-bye body)))
    (should (equal (plist-get closing :reason) "VersionMismatch"))
    (should (equal (plist-get closing :detail) "update host"))
    (should (= (plist-get (plist-get closing :peer) :version) 99))
    (should (equal (plist-get (plist-get closing :peer) :platform) "linux"))
    (dotimes (cut (length body)) (should-error (ubiquitty-sync--read-bye (substring body 0 cut))))
    (should-error (ubiquitty-sync--read-bye (concat body "x")))
    (with-temp-buffer
      (ubiquitty-admission-test--receive ubiquitty-sync--kind-bye body)
      (should ubiquitty-sync--transport-closed)
      (should-not ubiquitty-sync--welcome)
      (should-error (ubiquitty-admission-test--receive
                     ubiquitty-sync--kind-welcome
                     (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-granted 0 0)))))
  (dolist (body (list (unibyte-string 0 0) (unibyte-string 0 0 2) (unibyte-string 255 0 0)
                     (unibyte-string 0 1 255 0) (unibyte-string 0 1 0 0)))
    (should-error (ubiquitty-sync--read-bye body))))

(ert-deftest ubiquitty-admission-coalesced-approval-opens-only-after-both-statuses ()
  (let ((parts (list (list ubiquitty-sync--kind-welcome
                           (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-awaiting-consent 7 9))
                    (list ubiquitty-sync--kind-notify (ubiquitty-admission-test--status "pending"))
                    (list ubiquitty-sync--kind-notify (ubiquitty-admission-test--status "approved"))
                    (list ubiquitty-sync--kind-pane-bind (concat (unibyte-string 1) (make-string 16 ?p))))))
    (with-temp-buffer
      (let ((sent nil))
        (cl-letf (((symbol-function 'ubiquitty-sync--send-sync) (lambda (&rest values) (push values sent)))
                  ((symbol-function 'ubiquitty-sync--send-viewport) #'ignore))
          (setq ubiquitty-sync--admission-request
                (ubiquitty-sync--make-handshake-request :columns 80 :rows 24 :client-instance (make-string 16 ?c)))
          (let ((wire (mapconcat (lambda (part)
                                   (concat (unibyte-string (car part) 0) (ubiquitty-sync--put-bytes (cadr part)))) parts "")))
            (should (equal (ubiquitty-sync--feed-envelopes
                            "" wire (lambda (frame) (ubiquitty-sync--receive-sync nil (current-buffer) frame))) "")))
          (should (equal ubiquitty-sync--consent-phase "approved"))
          (should (= ubiquitty-sync--pane 1)))))))

;;; emacs-sync-admission-test.el ends here

(ert-deftest ubiquitty-admission-restored-workspace-answers-only-its-pinned-reference ()
  "Core's isRestoredReferenceAnswer: the recreated workspace, under the pinned instance."
  (let ((restored (list :target ubiquitty-sync--admission-target-workspace :session 5 :workspace 7 :daemon 2 :restored 1)))
    (should-error (ubiquitty-sync--read-welcome
                   (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-granted 0 0 nil
                                                      (list :restored 1 :daemon 2))))
    (should-error (ubiquitty-sync--read-welcome
                   (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-granted 0 0 nil
                                                      (list :target ubiquitty-sync--admission-target-workspace
                                                            :session 5 :workspace 7 :daemon 1 :restored 1))))
    (with-temp-buffer
      (setq ubiquitty-sync--admission-request
            (ubiquitty-sync--make-handshake-request
             :columns 80 :rows 24 :client-instance (make-string 16 ?c)
             :target ubiquitty-sync--admission-target-workspace :session-id 9 :workspace-id 7 :expected-daemon 1))
      (ubiquitty-admission-test--receive
       ubiquitty-sync--kind-welcome
       (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-granted 0 0 nil restored))
      (should (= (plist-get ubiquitty-sync--welcome :session-id) 5)))
    ;; The restoring host lists the workspace under an id of its own when the
    ;; one asked for is another workspace's there; only a restore may move it.
    (dolist (restored-from '(1 0))
      (with-temp-buffer
        (setq ubiquitty-sync--admission-request
              (ubiquitty-sync--make-handshake-request
               :columns 80 :rows 24 :client-instance (make-string 16 ?c)
               :target ubiquitty-sync--admission-target-workspace :session-id 9 :workspace-id 7 :expected-daemon 1))
        (let ((welcome (ubiquitty-admission-test--welcome
                        ubiquitty-sync--attachment-admission-granted 0 0 nil
                        (list :target ubiquitty-sync--admission-target-workspace
                              :session (if (= restored-from 0) 9 5) :workspace 8
                              :daemon (if (= restored-from 0) 1 2) :restored restored-from))))
          (if (= restored-from 0)
              (should-error (ubiquitty-admission-test--receive ubiquitty-sync--kind-welcome welcome))
            (ubiquitty-admission-test--receive ubiquitty-sync--kind-welcome welcome)
            (should (= (plist-get ubiquitty-sync--welcome :workspace-id) 8))))))
    (with-temp-buffer
      (setq ubiquitty-sync--admission-request
            (ubiquitty-sync--make-handshake-request
             :columns 80 :rows 24 :client-instance (make-string 16 ?c)
             :target ubiquitty-sync--admission-target-workspace :workspace-id 7))
      (should-error (ubiquitty-admission-test--receive
                     ubiquitty-sync--kind-welcome
                     (ubiquitty-admission-test--welcome ubiquitty-sync--attachment-admission-granted 0 0 nil restored))))))

