;;; editor-wire-fixture.el --- Memory-only canonical wire setup -*- lexical-binding: t; -*-
;; Copyright (C) 2026 Stanislav Yaglo
;; SPDX-License-Identifier: Apache-2.0

(require 'ubiquitty-sync)

(defun ubiquitty-wire-fixture--welcome (&optional role admission question session tail)
  "Build a complete current Welcome for the fixture's session 9 on daemon 1."
  (concat (ubiquitty-sync--put-u16 ubiquitty-sync--wire-version) (unibyte-string 0)
          (make-string 32 0) (make-string 16 ?h) (make-string 16 ?a) (make-string 16 ?s)
          (unibyte-string (or role ubiquitty-sync--role-owner) ubiquitty-sync--admission-target-session)
          (ubiquitty-sync--put-u32 9) (ubiquitty-sync--put-u32 0) (ubiquitty-sync--put-u64 1)
          (ubiquitty-sync--put-bytes "fixture.sock") (unibyte-string 0 0) (ubiquitty-sync--put-u64 0)
          (unibyte-string (or admission ubiquitty-sync--attachment-admission-granted))
          (ubiquitty-sync--put-u32 (or question 0)) (ubiquitty-sync--put-u32 (or session 0))
          (ubiquitty-sync--put-bytes "fixture")
          (ubiquitty-sync--put-u16 8) (ubiquitty-sync--put-u32 (* 16 1024 1024))
          (ubiquitty-sync--put-u16 8) (unibyte-string 0) (ubiquitty-sync--put-u64 42)
          (or tail (unibyte-string 0 0 0))))

(defun ubiquitty-wire-fixture--request ()
  "The explicit fresh request that the fixture's Welcome answers."
  (ubiquitty-sync--make-handshake-request :columns 80 :rows 24 :client-instance (make-string 16 ?c)))

(defun ubiquitty-wire-fixture--admit (&optional role)
  "Seed an already admitted unit-test state through the actual Welcome reader.
No process, bridge, socket, clipboard or host is created. Admission transition
tests deliver the same body through the actual stream reader instead."
  (setq ubiquitty-sync--admission-request (ubiquitty-wire-fixture--request)
        ubiquitty-sync--welcome (ubiquitty-sync--read-welcome (ubiquitty-wire-fixture--welcome role))))

(provide 'editor-wire-fixture)
