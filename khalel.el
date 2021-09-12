;;; khalel.el --- description -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2021 Hanno Perrey
;;
;; Author: Hanno Perrey <http://gitlab.com/hperrey>
;; Maintainer: Hanno Perrey <hanno@hoowl.se>
;; Created: september 10, 2021
;; Modified: september 10, 2021
;; Version: 0.0.1
;; Keywords: event, calendar, ics, khal
;; Homepage: https://gitlab.com/hperrey/khalel
;; Package-Requires: ((emacs 27.1) (cl-lib "0.5") (org 9.5))
;;
;; This file is not part of GNU Emacs.
;;
;;    This program is free software: you can redistribute it and/or modify
;;    it under the terms of the GNU General Public License as published by
;;    the Free Software Foundation, either version 3 of the License, or
;;    (at your option) any later version.
;;
;;    This program is distributed in the hope that it will be useful,
;;    but WITHOUT ANY WARRANTY; without even the implied warranty of
;;    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;    GNU General Public License for more details.
;;
;;    You should have received a copy of the GNU General Public License
;;    along with this program.  If not, see <https://www.gnu.org/licenses/>.
;;
;;; Commentary:
;;
;;  khalel provides helper routines to import upcoming events from a local
;;  calendar through khal and to capture new events that are exported to
;;  khal.
;;
;;  The local calendar can be synced with other external tools such as vdirsyncer.
;;
;;  First steps/quick start:
;;  - install and configure khal
;;  - customize the values for default calendar, capture file and import file for khalel
;;  - call `khalel-add-capture-template' to set up a capture template
;;  - consider adding the import org file to your org agenda to show upcoming events there
;;  - import upcoming events through `khalel-import-upcoming-events' or create new ones through `org-capture'
;;
;;; Code:

;;;; Requirements

(require 'org)

;;;; Customization

(defgroup khalel nil
  "Calendar import functions using khal."
  :group 'Calendar)

(defcustom khalel-khal-command "~/.local/bin/khal"
  "The command to run when executing khal.

When set to nil then it will be guessed."
  :group 'khalel
  :type 'string)

(defcustom khalel-default-calendar "privat"
  "The khal calendar to import into by default.

The calendar for a new event can be modified during the capture
process. Set to nil to use the default calendar configured for
khal instead."
  :group 'khalel
  :type 'string)

(defcustom khalel-default-alarm "10"
  "The default alarm before events to use for new events."
  :group 'khalel
  :type 'string)

(defcustom khalel-capture-key "e"
  "The key to use when registering an `org-capture' template via `khalel-add-capture-template'."
  :group 'khalel
  :type 'string)

(defcustom khalel-import-org-file (concat org-directory "calendar.org")
  "The file to import khal calendar entries into.

CAUTION: the file will be overwritten with each import! The
prompt for overwriting the file can be disabled by setting
`khalel-import-org-file-confirm-overwrite' to nil."
  :group 'khalel
  :type 'string)

(defcustom khalel-import-org-file-confirm-overwrite 't
  "When nil, always overwrite the org file into which events are imported.
Otherwise, ask for confirmation."
  :group 'khalel
  :type 'string)

(defcustom khalel-import-time-delta "30d"
  "How many hours, days, or months in the future to consider when import.
Used as DELTA argument to the khal date range."
  :group 'khalel
  :type 'string)


;;;; Commands

(defun khalel-import-upcoming-events ()
  "Imports future calendar entries by calling khal externally.

The time delta which determines how far into the future events
are imported is configured through `khalel-import-time-delta'.
CAUTION: The results are imported into the file
`khalel-import-org-file' which is overwritten to avoid adding
duplicate entires already imported previously.

Please note that the resulting org file does not necessarily
include all information contained in the .ics files it is based
on. Khal only supports certain (basic) fields. This is
particularly important when you consider to edit and export an
event back to khal: some fields might be discarded!

Examples of such fields are timezone information, categories,
organizer, URL (which will become part of the description
instead), alarms (which will be replaced with a default value
configurable via `khalel-default-alarm')."
  (interactive)
  (let
    ( ;; call khal directly.
      (khal-bin (or khalel-khal-command
        (executable-find "khal")))
      (dst (generate-new-buffer "khalel-output")))
          (call-process khal-bin nil dst nil "list" "--format"
          (format "* {title} {cancelled}\n\
SCHEDULED: <{start-date} {start-time}-{end-time}>\n\
:PROPERTIES:\n:CALENDAR: {calendar}\n\
:LOCATION: {location}\n\
:ID: {uid}\n\
:APPT_WARNTIME: %s\n:END:\n {description}\n{url}\n{organizer}" khalel-default-alarm)
          "--day-format" "" "today" khalel-import-time-delta)
          (save-excursion
            (with-current-buffer dst
              ;; remove any prefix added to the UID by org-icalendar-export-to-ics
              ;; so that we can edit and re-export events without creating duplicates
              (goto-char (point-min))
              (while (re-search-forward "^\\(:ID:[[:blank:]]*\\)DL-\\|SC-\\|TS[[:digit:]]+-" nil t)
                (replace-match "\\1" nil nil))
              ;; cosmetic fix for all-day events w/o end time
              (goto-char (point-min))
              (while (re-search-forward "^\\(SCHEDULED:.*?\\) ->" nil t)
                (replace-match "\\1>" nil nil))
              (write-file khalel-import-org-file khalel-import-org-file-confirm-overwrite)
              (message (format "Imported %d future events from khal into %s"
                               (length (org-map-entries nil nil nil))
                               khalel-import-org-file))))
          (kill-buffer dst)))


(defun khalel-export-org-subtree-to-calendar ()
  "Exports current subtree as ics file and into an external khal calendar.
A UID will be automatically be created and stored as property of
the subtree. See documentation of `org-icalendar-export-to-ics'
for details of the supported fields."
  (interactive)
  (save-excursion
    ;; org-icalendar-export-to-ics doesn't reliably export the full event when
    ;; operating on a subtree only; narrowing the buffer, however, works fine
    (org-narrow-to-subtree)
    (let*
        ;; store IDs right away to avoid duplicates
        ((org-icalendar-store-UID 't)
         ;; create events from non-TODO entries with scheduled time
         (org-icalendar-use-scheduled '(event-if-not-todo))
         (khal-bin (or khalel-khal-command
                       (executable-find "khal")))
         (path (file-name-directory
                (buffer-file-name
                 (buffer-base-buffer))))
         (entriescal (org-entry-get nil "calendar"))
         (calendar (or
                    (when (string-match "[^[:blank:]]" entriescal) entriescal)
                    khalel-default-calendar))
         ;; export to ics
         (ics
          (org-icalendar-export-to-ics nil nil 't)
          )
         ;; call khal import
         (import
          (with-temp-buffer
            (list
             :exit-status
             (if calendar
                 (call-process khal-bin nil t nil
                               "import" "-a" calendar
                               "--batch"
                               (concat path ics))
               (call-process khal-bin nil t nil
                             "import"
                             "--batch"
                             (concat path ics)))
             :output
             (buffer-string)))))
      (widen)
      (when
          (/= 0 (plist-get import :exit-status))
        (message
         (format
          "%s failed importing %s into calendar '%s' and exited with status %d: %s"
          khal-bin
          ics
          calendar
          (plist-get import :exit-status)
          (plist-get import :output)))))))

(defun khalel--make-temp-file ()
  "Create and visit a temporary file for capturing and exporting events."
  (find-file (make-temp-file "khalel-capture" nil ".org")))

(defun khalel-add-capture-template (&optional key)
  "Add an `org-capture' template with KEY for creating new events.
If argument is nil then `khalel-capture-key' will be used as
default instead. New events will be captured in a temporary file
and immediately exported to khal."
  (with-eval-after-load 'org
    (add-to-list 'org-capture-templates
                 `(,(or key khalel-capture-key) "calendar event"
                   entry
                   (function khalel--make-temp-file)
                   ,(concat "* %?\nSCHEDULED: %^T\n:PROPERTIES:\n:CREATED: %U\n:CALENDAR: \n\
:CATEGORY: event\n:LOCATION: unknown\n\
:APPT_WARNTIME: " khalel-default-alarm "\n:END:\n" ))))
  (add-hook 'org-capture-before-finalize-hook
            'khalel--capture-finalize-calendar-export))

;;;; Functions
(defun khalel--capture-finalize-calendar-export ()
  "Exports current event capture.
To be added as hook to `org-capture-before-finalize-hook'."
  (let ((key  (plist-get org-capture-plist :key))
        (desc (plist-get org-capture-plist :description)))
    (when (and (not org-note-abort) (equal key khalel-capture-key))
      (khalel-export-org-subtree-to-calendar))))

;;;; Footer
(provide 'khalel)
;;; khalel.el ends here
