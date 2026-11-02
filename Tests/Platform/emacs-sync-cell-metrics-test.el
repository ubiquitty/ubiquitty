;;; emacs-sync-cell-metrics-test.el --- terminal cell geometry -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Stanislav Yaglo
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:

;; Run in a separate Emacs process with -Q -l.  Batch mode runs the data
;; tests; graphical mode also measures the actual redisplayed cell positions.
;; The graphical fixture never attaches to a host or opens a user buffer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(load (expand-file-name "../../Source/Platform/Emacs/ubiquitty-sync.el"
                        (file-name-directory (or load-file-name buffer-file-name))) nil t)

(ert-deftest ubiquitty-braille-svg-preserves-unicode-dot-order ()
  (let ((centres '((2 . 2) (2 . 6) (2 . 10) (6 . 2)
                   (6 . 6) (6 . 10) (2 . 14) (6 . 14))))
    (dotimes (bit 8)
      (let ((svg (ubiquitty-sync--braille-svg (ash 1 bit) 8 16 "#aabbcc" "#102030"))
            (centre (nth bit centres)))
        (should (= 1 (cl-count ?< svg :start (string-match "<circle" svg)
                               :end (string-match "</g>" svg))))
        (should (string-match-p
                 (regexp-quote (format "<circle cx='%s.0' cy='%s.0' r='1.0'/>"
                                       (car centre) (cdr centre))) svg)))))
  (let ((blank (ubiquitty-sync--braille-svg 0 8 16 "#aabbcc" "#102030")))
    (should (string-match-p "width='8' height='16'" blank))
    (should (string-match-p "fill='#102030'" blank))
    (should-not (string-match-p "<circle" blank))))

(ert-deftest ubiquitty-braille-image-cache-is-bounded-and-metric-specific ()
  (with-temp-buffer
    (let ((created 0) (flushed 0))
      (cl-letf (((symbol-function 'create-image)
                 (lambda (data &rest _) (cl-incf created) (list 'image :data data)))
                ((symbol-function 'image-flush)
                 (lambda (_image all-frames) (should all-frames) (cl-incf flushed))))
        (let ((first (ubiquitty-sync--braille-image 1 8 16 "#ffffff" "#000000")))
          (should (eq first (ubiquitty-sync--braille-image 1 8 16 "#ffffff" "#000000")))
          (should-not (eq first (ubiquitty-sync--braille-image 1 9 16 "#ffffff" "#000000")))
          (should-not (eq first (ubiquitty-sync--braille-image 1 8 16 "#ff0000" "#000000"))))
        (dotimes (pattern 256)
          (ubiquitty-sync--braille-image pattern 8 16 "#ffffff" "#000000")
          (should (<= (hash-table-count ubiquitty-sync--braille-renderings) 256)))
        (should (= flushed 256))
        (should (= created 258))))))

(ert-deftest ubiquitty-braille-decoration-preserves-text-and-distinct-cells ()
  (with-temp-buffer
    (insert (propertize "⣿⣿x" 'face '(:foreground "#aabbcc" :background "#102030")))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'image-type-available-p) (lambda (_) t))
              ((symbol-function 'default-font-width) (lambda () 8))
              ((symbol-function 'default-font-height) (lambda () 16))
              ((symbol-function 'color-values)
               (lambda (color) (if (equal color "#aabbcc") '(43690 48059 52428) '(4112 8224 12336))))
              ((symbol-function 'create-image) (lambda (data &rest _) (list 'image :data data))))
      (ubiquitty-sync--decorate-braille-row (point-min) (point-max))
      (should (equal (buffer-substring-no-properties (point-min) (point-max)) "⣿⣿x"))
      (let ((first (get-text-property 1 'display)) (second (get-text-property 2 'display)))
        (should first)
        (should (equal first second))
        (should-not (eq first second))
        (should (string-match-p "fill='#aabbcc'" (plist-get (cdr first) :data))))
      (should-not (get-text-property 3 'display)))))

(ert-deftest ubiquitty-braille-decoration-refuses-unsupported-metrics ()
  (with-temp-buffer
    (insert "⣿")
    (dolist (settings '((nil t 8 16) (t nil 8 16) (t t 0 16)
                        (t t 257 16) (t t 8 0) (t t 8 513)))
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) (nth 0 settings)))
                ((symbol-function 'image-type-available-p) (lambda (_) (nth 1 settings)))
                ((symbol-function 'default-font-width) (lambda () (nth 2 settings)))
                ((symbol-function 'default-font-height) (lambda () (nth 3 settings)))
                ((symbol-function 'create-image) (lambda (&rest _) (ert-fail "unexpected image allocation"))))
        (ubiquitty-sync--decorate-braille-row (point-min) (point-max))
        (should-not (get-text-property 1 'display))
        (should (equal (buffer-string) "⣿"))))))

(ert-deftest ubiquitty-braille-keeps-the-terminal-pixel-grid ()
  (skip-unless (display-graphic-p))
  (let ((original-font (frame-parameter nil 'font))
        (original-buffer (window-buffer))
        (buffer (generate-new-buffer " *ubiquitty cell geometry*")))
    (unwind-protect
        (progn
          (when (find-font (font-spec :family "Menlo"))
            (set-frame-font "Menlo-14" t))
          (set-frame-size nil 120 24)
          (set-window-buffer nil buffer)
          (with-current-buffer buffer
            (ubiquitty-sync-mode)
            (setq ubiquitty-sync--screen
                  (vconcat
                   (mapcar
                    (lambda (specification)
                      (let* ((text (concat (make-string 80 (car specification)) "|"))
                             (face (append '(:foreground "#aacc88" :background "#101014")
                                           (and (cdr specification) '(:weight bold)))))
                        (vconcat (mapcar (lambda (character) (propertize (string character) 'face face)) text))))
                    '((?x) (#x28ff) (#x28ff . t) (#x2800) (#x2801) (#x2880))))
                  ubiquitty-sync--line-attributes [0 0 0 0 0 0]
                  ubiquitty-sync--cursor '(0 0 0 nil))
            (ubiquitty-sync--paint-all)
            (redisplay t)
            (let ((width (default-font-width))
                  (height (default-font-height)))
              (dotimes (row 6)
                (goto-char (point-min))
                (forward-line row)
                (let* ((start (point))
                       (first (posn-x-y (posn-at-point start)))
                       (second (posn-x-y (posn-at-point (1+ start))))
                       (last (posn-x-y (posn-at-point (+ start 80)))))
                  (should (= (car second) width))
                  (should (= (car last) (* 80 width)))
                  (should (= (cdr first) (* row height)))
                  (should (= (string-width (buffer-substring-no-properties start (+ start 80))) 80)))))))
      (set-window-buffer nil original-buffer)
      (set-frame-font original-font t)
      (kill-buffer buffer))))

(ert-deftest ubiquitty-crt-saving-covers-and-restores-held-cells ()
  (with-temp-buffer
    (setq ubiquitty-sync--screen [ ["A" "B" "C"] ]
          ubiquitty-sync--screen-columns 3
          ubiquitty-sync--line-attributes [0]
          ubiquitty-sync--cursor '(0 0 bar t))
    (let ((modes (make-string 63 0)))
      (aset modes 0 1)
      (aset modes 59 1)
      (should (ubiquitty-sync--apply-block ubiquitty-sync--block-modes modes))
      (ubiquitty-sync--paint-all)
      (should (equal (buffer-substring-no-properties (point-min) (point-max)) "   "))
      (should-not cursor-type)
      (should (equal (aref ubiquitty-sync--screen 0) ["A" "B" "C"]))
      (should (equal (plist-get (get-text-property 1 'face) :background) "black"))
      (aset modes 59 0)
      (should (ubiquitty-sync--apply-block ubiquitty-sync--block-modes modes))
      (ubiquitty-sync--paint-all)
      (should (equal (buffer-substring-no-properties (point-min) (point-max)) "ABC")))))

(if noninteractive
    (ert-run-tests-batch-and-exit)
  (run-at-time
   0.5 nil
   (lambda ()
     (let ((stats (ert-run-tests-batch)))
       (when-let ((report (getenv "UBQ_EMACS_TEST_REPORT")))
         (with-temp-file report
           (insert (with-current-buffer "*Messages*" (buffer-string)))))
       (kill-emacs (if (zerop (ert-stats-completed-unexpected stats)) 0 1))))))

;;; emacs-sync-cell-metrics-test.el ends here
