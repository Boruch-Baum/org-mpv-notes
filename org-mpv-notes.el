;;; org-mpv-notes.el --- Take notes in org mode while watching videos in mpv -*- lexical-binding: t -*-

;; IMPORTANT: This file is Boruch Baum's fork of the package referred
;; to below, which has now (2023-11-29) diverged by 53 commits from
;; the upstream. The URL of this fork is
;; https://github.com/boruch-baum/org-mpv-notes

;; Copyright (C) 2021-2022 Bibek Panthi

;; Author: Bibek Panthi <bpanthi977@gmail.com>
;; Maintainer: Bibek Panthi <bpanthi977@gmail.com>
;; URL: https://github.com/bpanthi977/org-mpv-notes
;; Version: 0.0.1
;; Package-Requires: ((emacs "27.1"))
;; Kewords: mpv, org

;; This file in not part of GNU Emacs

;;; SPDX-License-Identifier: MIT

;;; Commentary:

;; org-mpv-notes allows you to control mpv and take notes from videos
;; playing in mpv.  You can control mpv (play, pause, seek, ...) while
;; in org buffer and insert heading or notes with timestamps to the
;; current playing position.  Later you can revist the notes and seek
;; to the inserted timestamp with a few keystrokes.  Also, it can
;; insert screenshots as org link, run ocr (if ocr program is
;; installed) and insert the ocr-ed text to the org buffer.

;;; Code:
(require 'cl-lib) ; for cl-find
(let ((a (require 'mpv nil 'noerror))   ; option 1 for mpv control backend
      (b (require 'empv nil 'noerror))) ; option 2 for mpv control backend
  (unless (or a b)
    (error "Error: At least one of packages mpv.el, empv.el must be installed.")))
(require 'org-attach)  ; for org-attach-attach
(require 'org-element) ; for org-element-{context,property}

;;;;;
;;; MPV and EMPV Compatibility Layer
;;;;;

(defgroup org-mpv-notes nil
  "Options concerning mpv links in Org mode."
  :group 'org-link
  :prefix "org-mpv-notes-")

(defcustom org-mpv-notes-empv-wait-interval 0.1
  "How many seconds to wait for mpv to settle.
This may be necessary because much of the empv library runs
asynchronously."
  :type '(float
          :validate
          (lambda (w)
            (when (> 0 (floor (widget-value w)))
              (widget-put w :error "Must be a positive number")
              w))))


(defcustom org-mpv-notes-mpv-args '("--no-terminal"
                                    "--idle"
                                    "--no-focus-on-open"
                                    "--volume=40"
                                    "--sub-delay=-1"
                                    "--ontop=yes"
                                    "--geometry=100%:100%"
                                    "--autofit=35%"
                                    "--autofit-larger=50%")
  "Args used while starting mpv.
This will over-ride the settings of your chosen mpv
backend (variable `mpv-default-options' for mpv.el, or variable
`empv-mpv-args' for empv.el) for just this use-case. See man(1)
mpv for details."
  :type '(repeat
          (string
           :validate
           (lambda (w)
             (let ((val (widget-value w)))
               (when (or (not (stringp val))
                         (not (string-match "^--" val)))
                 (widget-put w :error "All elements must be command line option strings, eg. --foo")
                 w))))))

(defun org-mpv-notes---cmd (mpv-cmd empv-cmd error-msg)
  "Run a backend command.
MPV-CMD and EMPV-CMD are lists in the form (CMD ARGS). ERROR-MSG
is a string."
  (or (and (cl-find 'mpv features)
           (mpv-live-p)
           (progn (apply mpv-cmd)
                  t))
      (and (cl-find 'empv features)
           (empv--running?)
           (progn (apply empv-cmd)
                  t))
      (error error-msg)))

(defun org-mpv-notes--cmd (cmd &rest args)
  "Send mpv command via backend."
  (org-mpv-notes---cmd
    (list #'mpv-run-command cmd args)
    (list #'empv--send-command-sync (list cmd args))
    (error "Please open a audio/video in either mpv or empv library")))

(defun org-mpv-notes--get-property (property)
  (org-mpv-notes---cmd
    (list 'mpv-get-property property)
    (list 'with-timeout '(1 nil) 'empv--send-command-sync (list "get_property" property))
    (error "Please open a audio/video in either mpv or empv library")))

(defun org-mpv-notes--set-property (property value)
  (org-mpv-notes--cmd "set_property" property value))

(defun org-mpv-notes-pause ()
  "Toggle pause/run of the mpv instance."
  (interactive)
  (org-mpv-notes---cmd '(mpv-pause) '(empv-toggle) "Error: no mpv instance detected."))

(defun org-mpv-notes-kill ()
  "Close the mpv instance."
  (interactive)
  (org-mpv-notes---cmd '(mpv-kill) '(empv-exit) "Error: no mpv instance detected."))


;;;;;
;;; Opening Link & Interface with org link
;;;;;

;; from https://github.com/kljohann/mpv.el/wiki
;;  To create a mpv: link type that is completely analogous to file: links but opens using mpv-play instead,
(defun org-mpv-notes-complete-link (&optional arg)
  "Provide completion to mpv: link in `org-mode'.
ARG is passed to `org-link-complete-file'."
  (replace-regexp-in-string
   "file:" "mpv:"
   (org-link-complete-file arg)
   t t))

(org-link-set-parameters "mpv"
                         :complete #'org-mpv-notes-complete-link
                         :follow #'org-mpv-notes-open
                         :export #'org-mpv-notes-export)

;; adapted from https://bitspook.in/blog/extending-org-mode-to-handle-youtube-links/
(defun org-mpv-notes-export (path desc backend)
  (when (and (eq backend 'html)
             (string-search "youtube.com/" path))
    (let* ((link (org-mpv-notes--parse-link path))
           (path (car link))
           (secs (cadr link))
           video-id
           url)
      (cond ((or (not desc) (string-equal desc ""))
              (setq video-id (cadar (url-parse-query-string path)))
              (setq url (when (string-empty-p video-id) path
                          (format "//youtube.com/embed/%s" video-id)))
              (format "<p style=\"text-align:center; width:100%%\"><iframe width=\"560\" height=\"315\" src=\"https://www.youtube-nocookie.com/embed/lJIrF4YjHfQ\" title=\"%s\" frameborder=\"0\" allow=\"accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share\" allowfullscreen></iframe></p>"
                       url desc)))
            (secs
             (format "<a href=\"%s&t=%ds\">%s</a>" path secs (substring-no-properties desc))))))

(defun org-mpv-notes--parse-link (path)
  (let* ((split (split-string path "::" nil "\\(^\\[\\[mpv:\\)\\|\\(\\]\\[.*$\\)"))
         (secs (cadr split)))
    (if (null secs)
      (setq split (append split '(0)))
     (setf (cadr split)
       (cond ((string-match "^[0-9]+:[0-9]+:[0-9]+$" secs)
              (let* ((hms-list (split-string secs ":"))
                     (h (string-to-number (nth 0 hms-list)))
            	     (m (string-to-number (nth 1 hms-list)))
            	     (s (string-to-number (nth 2 hms-list))))
                (* (+ s (* 60 (+ m (* 60 h)))))))
             ((string-match "^\\([0-9]+\\)$" secs)
              (string-to-number search-option))
             (t (error "Error: Failed to parse link timestamp: %s" secs)))))
    split))

(defun org-mpv-notes-open (path &optional arg)
  "Open the mpv `PATH'.
`ARG' is required by org-follow-link but is ignored here."
  (interactive "fSelect file to open: ")
  (org-mpv-notes-mode t)
  (let* ((link (org-mpv-notes--parse-link path))
         (path (car link))
         (secs (or (cadr link) 0))
         (backend (or (cl-find 'mpv features)
                      (cl-find 'empv features)
                      (error "Please load either mpv or empv library")))
         (mpv-default-option (format " %s" org-mpv-notes-mpv-args))
         (empv-mpv-args (when (boundp 'empv-mpv-args)
                          (append empv-mpv-args org-mpv-notes-mpv-args)))
         (alive (if (eq backend 'mpv)
                  (mpv-live-p)
                 (empv--running?)))
         (start (lambda (path)
                  (if (eq backend 'mpv)
                    (mpv-start path)
                   (if path (empv-play path)
                     (call-interactively 'empv-play-file))))))
    (cond ((not alive)
           (funcall start path))
          ((not (string-equal (org-mpv-notes--get-property "path") path))
           (if (eq backend 'mpv)
             (mpv-kill)
            (empv-exit)))
           (sleep-for org-mpv-notes-empv-wait-interval)
           (funcall start path))
    (sleep-for org-mpv-notes-empv-wait-interval)
    (if (eq backend 'mpv)
      (mpv-seek secs)
     (empv-seek secs '("absolute")))))

;;;;;
;;; Screenshot
;;;;;

(defun org-mpv-notes-save-as-attach (file)
  "Save image FILE to org file using `org-attach'."
  ;; attach it
  (let ((org-attach-method 'mv)
        (org-attach-store-link-p 'file))
    (sleep-for org-mpv-notes-empv-wait-interval)
    (org-attach-attach file)
    (sleep-for org-mpv-notes-empv-wait-interval)
    ;; insert the link
    (org-insert-link "hello" file)
    (insert "  " "[[attachment:" (file-name-base file) "." (file-name-extension file) "]]")))

(defcustom org-mpv-notes-save-image-function
  #'org-mpv-notes-save-as-attach
  "Function that saves screenshot image file to org buffer.
Filename is passed as first argument.  The function has to copy
the file to proper location and insert a link to that file."
  :type '(function)
  :options '(#'org-mpv-notes-save-as-attach
             #'org-download-image))

;; save screenshot as attachment
(defun org-mpv-notes-save-screenshot ()
  "Save screenshot of current frame as attachment."
  (interactive)
  (let ((filename (format "%s.png" (make-temp-file "mpv-screenshot"))))
    ;; take screenshot
    (org-mpv-notes--cmd "screenshot-to-file"
                        filename
                        "video")
    (funcall org-mpv-notes-save-image-function filename)
    (org-display-inline-images)))

;;;;;
;;; OCR on screenshot
;;;;;

(defcustom org-mpv-notes-ocr-command "tesseract"
  "OCR program to extract text from mpv screenshot."
  :type '(string))

(defcustom org-mpv-notes-ocr-command-args "-"
  "Extra arguments to pass to ocr-command after the input image file."
  :type '(string))

(defun org-mpv-notes--ocr-on-file (file)
  "Run tesseract OCR on the screenshot FILE."
  (unless (executable-find org-mpv-notes-ocr-command)
    (user-error "OCR program %S not found" org-mpv-notes-ocr-command))
  (with-temp-buffer
    (if (zerop (call-process org-mpv-notes-ocr-command nil t nil
                             (file-truename file) org-mpv-notes-ocr-command-args))
        (remove ? (buffer-string))
      (error "OCR command failed: %S" (buffer-string)))))

(defun org-mpv-notes-screenshot-ocr ()
  "Take screenshot, run OCR on it and insert the text to org buffer."
  (interactive)
  (let ((filename (format "%s.png" (make-temp-file "mpv-screenshot"))))
    ;; take screenshot
    (org-mpv-notes--cmd "screenshot-to-file"
                        filename
                        "video")
    (let ((string (org-mpv-notes--ocr-on-file filename)))
      (insert "\n"
              string
              "\n"))))
;;;;;
;;; Motion (jump to next, previous, ... link)
;;;;;

(defcustom org-mpv-narrow-timestamp-navigation nil
  "Restrict timestamp navigation to within the current heading.
This affects functions `org-mpv-notes-next-timestamp' and
`org-mpv-notes-previous-timestamp'."
  :type 'boolean)

(defun org-mpv-notes--timestamp-p ()
  "Return non-NIL if POINT is on a timestamp."
 (string-match "mpv" (or (org-element-property :type (org-element-context)) "")))

(defun org-mpv-notes-next-timestamp (&optional reverse)
  "Seek to next timestamp in the notes file."
  (interactive)
  (let ((p (point))
        success
        context)
    (save-excursion
      (when org-mpv-narrow-timestamp-navigation
        (org-narrow-to-subtree))
      (while (and (not success)
                  (org-next-link reverse)
                  (not (eq p (point))))
        (when (and (org-mpv-notes--timestamp-p)
                   (not (eq p (point))))
          (setq success t))
        (setq p (point)))
     (when org-mpv-narrow-timestamp-navigation
       (widen)))
    (if (not success)
      (error "Error: No %s link" (if reverse "prior" "next"))
     (goto-char p)
     (org-mpv-notes-open
       (org-element-property :path (setq context (org-element-context))))
     (org-show-entry)
     (recenter)
     (goto-char (org-element-property :contents-end context))
     (search-forward org-mpv-notes-link-suffix nil t))))

(defun org-mpv-notes-previous-timestamp ()
  "Seek to previous timestamp in the notes file."
  (interactive)
  (org-mpv-notes-next-timestamp t))

(defun org-mpv-notes-this-timestamp ()
  "Seek to the timestamp at POINT or previous.
If there is no timestamp at POINT, consider the previous one as
'this' one."
  (interactive)
  (cond
   ((org-mpv-notes--timestamp-p)
     (org-mpv-notes-open (org-element-property :path (org-element-context)))
     (org-show-entry)
     (recenter))
   (t
     (save-excursion (org-mpv-notes-previous-timestamp)))))

;;; Creating Links
;;;;;

(defcustom org-mpv-notes-link-prefix "\n\n("
  "String to precede timestamp links."
  :type 'string)

(defcustom org-mpv-notes-link-suffix "): "
  "String to follow timestamp links."
  :type 'string)

(defcustom org-mpv-notes-pause-on-link-create nil
  "Whether to automatically pause mpv when creating a link or note."
  :type 'boolean)

(defun org-mpv-notes-toggle-pause-on-link-create ()
  "Toggle whether to automatically pause mpv when creating a link or note."
  (interactive)
  (setq org-mpv-notes-pause-on-link-create (not org-mpv-notes-pause-on-link-create))
  (message "mpv will now %spause when creating an org-mpv link/note"
    (if org-mpv-notes-pause-on-link-create "" "NOT ")))

(defcustom org-mpv-notes-timestamp-lag 0
  "Number of seconds to subtract when setting timestamp.

This variable acknowledges that many of us may sometimes be slow
to create a note or link."
  :type '(integer
          :validate (lambda (w)
                      (let ((val (widget-value w)))
                        (when (> 0 val)
                          (widget-put w :error "Must be a positive integer")
                          w)))))

(defun org-mpv-notes-timestamp-lag-modify (seconds)
  "Change the timestanp lag."
  (interactive "nlag seconds: ")
  (if (> 0 seconds)
    (error "Error: positive integer required"))
   (setq org-mpv-notes-timestamp-lag seconds))

(defun org-mpv-toggle-pause-on-link-create ()
  "Toggle whether to automatically pause mpv when creating a link or note."
  (interactive)
  (setq org-mpv-notes-pause-on-link-create (not org-mpv-notes-pause-on-link-create))
  (message "mpv will now %spause when creating an org-mpv link/note"
    (if org-mpv-notes-pause-on-link-create "" "NOT ")))

(defun org-mpv-notes--create-link (&optional read-description)
  "Create a link with timestamp to insert in org file.
If `READ-DESCRIPTION' is true, ask for a link description from user."
  (let* ((mpv-backend (or (and (cl-find 'mpv features) (mpv-live-p))
                          (if (cl-find 'empv features)
                             nil
                            (error "Please load either mpv or empv library"))))
         (alive (if mpv-backend
                   (mpv-live-p)
                  (empv--running?)))
         (path (progn
                 (when (not alive)
                   (call-interactively 'org-mpv-notes-open)
                   (sleep-for org-mpv-notes-empv-wait-interval))
                 (org-link-escape
                   (or (if mpv-backend
                         (mpv-get-property "path")
                        (with-timeout (1 nil)
                          (empv--send-command-sync (list "get_property" 'path))))
                       (org-mpv-notes-open "")
                       ""))))
         (time (if alive
                 (or (if mpv-backend
                       (mpv-get-playback-position)
                      (with-timeout (1 nil)
                        (empv--send-command-sync (list "get_property" 'time-pos))))
                     (error "Error: mpv time-pos not found"))
                0))
         (time (max 0 (- time org-mpv-notes-timestamp-lag)))
         (timestamp (org-mpv-notes--secs-to-hhmmss time))
         (description ""))
    (when org-mpv-notes-pause-on-link-create
      (if mpv-backend
        (mpv-pause))
       (empv-pause))
    (when read-description
      (setq description (read-string "Description: " timestamp)))
    (when (string-equal description "")
      (setf description timestamp))
    (concat "[[mpv:" path "::" timestamp "][" description "]]")))

(defcustom org-mpv-notes-note-name-prune-regex "\\( \\\\\\[[^]]+\\\\]\\)\\|\\(\\.[^.]*$\\)"
  "What not to include in a default note heading.
When variable `org-mpv-notes-insert-link-prompt-for-description'
is NIL, a note's filename will be used as the basis for the
created org heading text. This regex is used to remove filename
parts from that. The default value removes filename extensions
and youtube-style media ID hashes."
  :type 'regexp)

(defun org-mpv-notes-insert-note (&optional prompt-for-description)
  "Insert a heading with link & timestamp.
With PREFIX-ARG, over-ride the setting of variable
`org-mpv-notes-insert-link-prompt-for-description'."
  (interactive "P")
  (let ((link
          (org-mpv-notes--create-link
            (if prompt-for-description
               (not org-mpv-notes-insert-link-prompt-for-description)
              org-mpv-notes-insert-link-prompt-for-description))))
    (when link
      (org-insert-heading)
      (insert (replace-regexp-in-string
                org-mpv-notes-note-name-prune-regex
                ""
                (file-name-nondirectory (car (org-mpv-notes--parse-link link))))
              org-mpv-notes-link-prefix
              link
              org-mpv-notes-link-suffix))))

(defcustom org-mpv-notes-insert-link-prompt-for-description nil
  "Prompt the user for a custom link descrption.
NIL means use the timestamp in conjunction with variables
`org-mpv-notes-link-prefix' and `org-mpv-notes-link-suffix'. This
value can be over-ridden on a per-use basis at run-time by
calling function `org-mpv-notes-insert-link' with a prefix
argument."
  :type 'boolean)

(defun org-mpv-notes-insert-link (&optional prompt-for-description)
  "Insert link with timestamp.
With PREFIX-ARG, over-ride the setting of variable
`org-mpv-notes-insert-link-prompt-for-description'."
  (interactive "P")
  (insert org-mpv-notes-link-prefix
          (org-mpv-notes--create-link
            (if prompt-for-description
               (not org-mpv-notes-insert-link-prompt-for-description)
              org-mpv-notes-insert-link-prompt-for-description))
          org-mpv-notes-link-suffix))

(defun org-mpv-notes-replace-timestamp-with-link (begin end link)
  "Convert hh:mm:ss text within region to link with timestamp.
`LINK' is the media url/path."
  (interactive "r\nsLink:")
  (let ((p (point))
        timestamp)
    (setq link (org-link-escape link))
    (goto-char end)
    (while (re-search-backward "[^0-9]\\([0-9]+:[0-9]+:[0-9]+\\)" begin t)
      (setq timestamp (match-string 1))
      (replace-region-contents (match-beginning 1) (match-end 1)
        (lambda () (concat org-mpv-notes-link-prefix
                           "[[mpv:" link "::" timestamp "][" timestamp "]]"
                           org-mpv-notes-link-suffix)))
      (search-backward "[[" begin t))))

(defun org-mpv-notes-change-link-reference (all-occurences)
  "Change a link to reflect a moved or renamed media file.
With a PREFIX-ARG, apply the change to all similar references
within the current buffer."
  (interactive "P")
  (unless (org-mpv-notes--timestamp-p)
    ;; We could always look to the timestamp link prior to POINT, but
    ;; this is a decent trade-off between convenience and preventing
    ;; accidental changes.
    (error "Error: POINT is not within a timestamp link."))
  (let* ((target (org-link-escape
                   (read-file-name "Correct target path?: " nil nil t)))
         (context (org-element-context))
         (old-link-path (split-string
                          (or (org-element-property :path context)
                              (error "Error: Failed to extract old path-name."))
                          "::"))
         (old-path (if (/= 2 (length old-link-path))
                     (error "Error: Failed to parse the old link.")
                    (org-link-escape (car old-link-path))))
         (p (point))
         here
         (replace-it
           (lambda ()
             (setq context (org-element-context))
             (replace-string-in-region old-path target
                                       (org-element-property :begin context)
                                       (org-element-property :end context)))))
    (org-toggle-link-display)
    (cond
     (all-occurences
      (goto-char (point-min))
      (setq here (point))
      (while (and (org-next-link)
                  (> (point) here))
        (when (org-mpv-notes--timestamp-p)
          (funcall replace-it))
        (setq here (point)))
      (goto-char p))
     (t ; ie. (not all-occurences)
       (funcall replace-it)))
     (org-toggle-link-display)))

;;;;;
;;; Minor Mode and Keymap
;;;;;


;;;###autoload
(define-minor-mode org-mpv-notes-mode
  "Org minor mode for Note taking alongside audio and video.
Uses mpv.el to control mpv process"
  :keymap `((,(kbd "M-n i")       . org-mpv-notes-insert-link)
            (,(kbd "M-n M-i")     . org-mpv-notes-insert-note)
            (,(kbd "M-n =")       . org-mpv-notes-this-timestamp)
            (,(kbd "M-n <left>")  . org-mpv-notes-previous-timestamp)
            (,(kbd "M-n <right>") . org-mpv-notes-next-timestamp)
            (,(kbd "M-n s")       . org-mpv-notes-save-screenshot)
            (,(kbd "M-n M-s")     . org-mpv-notes-screenshot-ocr)
            (,(kbd "M-n SPC")     . org-mpv-notes-pause)
            (,(kbd "M-n k")       . org-mpv-notes-kill)))



(defun org-mpv-notes--secs-to-hhmmss (secs)
  "Convert integer seconds to hh:mm:ss string"
  (format "%02d:%02d:%02d"
          (floor (/ secs 3600))          ;; hours
          (floor (/ (mod secs 3600) 60)) ;; minutes
          (floor (mod secs 60))))        ;; seconds

(defun org-mpv-notes--subtitles-insert-srv1 ()
  "Edit srv1 formatted subtitle file for import.
This function is meant to be called by function
`org-mpv-notes-subtitles-insert'."
  ;; 1: Prune header
  (goto-char (point-min))
  (search-forward "<transcript>")
  (delete-region (point-min) (point))
  ;; 2: Extract timestamps from <text> elements
  (goto-char (point-min))
  (let (secs)
    (while (re-search-forward "<text start=\"\\([0-9]+\\)[^>]*>" nil t)
      (setq secs (string-to-number (match-string 1)))
      (replace-match (concat "\n\n" (org-mpv-notes--secs-to-hhmmss secs) " "))))
  ;; 3: Remove cruft html from body
  (goto-char (point-min))
  (while (re-search-forward "</text>" nil t)
    (replace-match ""))
  ;; 4: Remove cruft html from end of tile
  (delete-region (- (point-max) 13) (point-max)))

(defun org-mpv-notes--subtitles-insert-srv2 ()
  "Edit srv2 formatted subtitle file for import.
This function is meant to be called by function
`org-mpv-notes-subtitles-insert'."
  ;; 1: Prune header
  (goto-char (point-min))
  (search-forward "<timedtext>")
  (delete-region (point-min) (point))
  ;; 2: Extract timestamps from <text> elements
  (goto-char (point-min))
  (let (secs)
    (while (re-search-forward "<text t=\"\\([0-9]+\\)[^>]*>" nil t)
      (setq secs (string-to-number (substring (match-string 1) 0 -3)))
      (replace-match (concat "\n\n" (org-mpv-notes--secs-to-hhmmss secs) " "))))
  ;; 3: Remove cruft html from body
  (goto-char (point-min))
  (while (re-search-forward "</text>" nil t)
    (replace-match ""))
  ;; 4: Remove cruft html from end of tile
  (delete-region (- (point-max) 12) (point-max)))

(defun org-mpv-notes--subtitles-insert-srv3 ()
  "Edit srv3 formatted subtitle file for import.
This function is meant to be called by function
`org-mpv-notes-subtitles-insert'."
  ;; 1: Prune header
  (goto-char (point-min))
  (forward-line 2)
  (delete-region (point-min) (point))
  ;; 2: Extract timestamps from <p> elements
  (goto-char (point-min))
  (let (secs)
    (while (re-search-forward "<p t=\"\\([0-9]+\\)[^>]*>" nil t)
      (setq secs (string-to-number (substring (match-string 1) 0 -3)))
      (replace-match (concat "\n" (org-mpv-notes--secs-to-hhmmss secs) " "))))
  ;; 3: Remove cruft html from body
  (goto-char (point-min))
  (while (re-search-forward "</p>" nil t)
    (replace-match ""))
  ;; 4: Remove cruft html from end of tile
  (goto-char (point-max))
  (forward-line -2)
  (delete-region (point) (point-max)))

(defun org-mpv-notes--subtitles-insert-ttml ()
  "Edit ttml formatted subtitle file for import.
This function is meant to be called by function
`org-mpv-notes-subtitles-insert'."
  ;; 1: Prune header
  (goto-char (point-min))
  (search-forward "<p")
  (delete-region (point-min) (match-beginning 0))
  ;; 2: Extract timestamps from <p> elements
  (goto-char (point-min))
  (while (re-search-forward "<p begin=\"\\([0-9][0-9]:[0-9][0-9]:[0-9][0-9]\\)\\.[0-9][0-9][0-9][^>]*>" nil t)
    (replace-match "\n\\1 "))
  ;; 3: Remove cruft html from body
  (goto-char (point-min))
  (while (re-search-forward "\\(</p>\\)\\|\\(<br />\\)" nil t)
    (replace-match ""))
  ;; 4: Remove cruft html from end of tile
  (goto-char (point-max))
  (forward-line -3)
  (delete-region (point) (point-max)))

(defun org-mpv-notes--subtitles-insert-vtt ()
  "Edit vtt formatted subtitle file for import.
This function is meant to be called by function
`org-mpv-notes-subtitles-insert'."
  ;; 1: Prune header
  (goto-char (point-min))
  (forward-line 3)
  (delete-region (point-min) (point))
  ;; 2: Convert timestamp format lines to hh:mm:ss
  (while (re-search-forward "\\([0-9][0-9]:[0-9][0-9]:[0-9][0-9]\\)\\.[0-9][0-9][0-9] --> [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\\.[0-9][0-9][0-9]\n" nil t)
    (replace-match "\n\\1 "))
  ;; 3: Combine text lines
  (goto-char (point-min))
  (while (re-search-forward "\\([^0-9:]\\{8\\}\n\\)\n" nil t)
    (replace-match "\\1 "))
  (delete-trailing-whitespace))

(defun org-mpv-notes-subtitles-insert (file &optional link)
  "Insert and modify a subtitle file for org-mode notes."
  (interactive "f")
  (let ((target-buffer (current-buffer))
        (format (file-name-extension file)))
    (when (and (not (or executing-kbd-macro noninteractive))
               (y-or-n-p "Create tiemstamp links?"))
      (setq link (read-file-name "Media file for this subtitle file: " nil nil t)))
    (with-temp-buffer
      (setq temp-buffer (current-buffer))
      (insert-file-contents file)
      (cond
        ((string= "json3" format) (error "Error: Unsupported format"))
        ((string= "srt" format)   (error "Error: Unsupported format"))
        ((string= "srv1" format)  (org-mpv-notes--subtitles-insert-srv1))
        ((string= "srv2" format)  (org-mpv-notes--subtitles-insert-srv2))
        ((string= "srv3" format)  (org-mpv-notes--subtitles-insert-srv3))
        ((string= "ttml" format)  (org-mpv-notes--subtitles-insert-ttml))
        ((string= "vtt" format)   (org-mpv-notes--subtitles-insert-vtt))
        (t (error "Error: Unrecognized subtitle format")))
      ;; Remove timestamps from within paragraphs
      (goto-char (point-min))
      (while (re-search-forward "\\([^!:\\.\"…”] *\n\\)\n[0-9:]\\{8\\} " nil t)
        (replace-match "\\1"))
      (fill-region (point-min) (point-max))
      (when link
        (org-mpv-notes-replace-timestamp-with-link (point-min) (point-max) link)
        (goto-char (point-min))
        (while (re-search-forward "\n\n\n+" nil t)
          (replace-match "\n\n")))
      (insert-into-buffer target-buffer))))

(provide 'org-mpv-notes)

;;; org-mpv-notes.el ends here
