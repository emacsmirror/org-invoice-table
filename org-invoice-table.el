;;; org-invoice-table.el --- Invoicing table formatter for org-mode -*- lexical-binding: t -*-
;;
;; Copyright (C) 2022 Trevor Richards
;;
;; Author: Trevor Richards <trev@trevdev.ca>
;; Maintainer: Trevor Richards <trev@trevdev.ca>
;; URL: https://codeberg.org/trevdev/org-invoice-table
;; Created: 7th September, 2022
;; Version: 1.1.2
;; License: GPL3
;; Package-Requires: ((emacs "26.1"))
;;
;; This file is not a part of GNU Emacs.
;;
;; This program is free software: you can redistribute it and/or modify it under
;; the terms of the GNU General Public License as published by the Free Software
;; Foundation, either version 3 of the License, or (at your option) any later
;; version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.
;;
;; See the GNU General Public License for more details. You should have received
;; a copy of the GNU General Public License along with this program. If not, see
;; <https://www.gnu.org/licenses/>.
;;
;;; Commentary:
;; This package adds a table formatter for calculating invoices for project
;; based todo items. You may use it with the `:formatter' keyword in the
;; #+BEGIN: clocktable option.
;;
;; The formatter will also generate columns for effort estimates & comments if
;; they are specified and applicable. Use the `:properties' keyword and provide
;; a list containing property you would like as a column. For example:
;; :properties ("Effort" "Comments").
;;
;; You may also override the billable rate for the table with the `:rate'
;; property.
;;
;;; Code:

(require 'seq)
(require 'calc-misc)

(defgroup org-invoice-table nil
  "Customize the 'org-invoice-table'."
  :group 'org-clocktable)

(defcustom org-invoice-table-rate 80.0
  "The default billable rate for generating the invoice table."
  :type 'float
  :group 'org-invoice-table)

(defcustom org-invoice-table-hourly-accuracy 3
  "The accuracy of the time spent on tasks in fractional hours.
For example, when `org-invoice-table-hourly-accuracy' is set to 3, and
a billable task ran for 95 minutes, the hourly time is set to 1.583."
  :type 'integer
  :group 'org-invoice-table)

(defcustom org-invoice-table-time-display 'hours
  "The display format for the time column.
It can be either billable `hours' or `time'."
  :type '(radio (const :tag "Billable Hours" hours)
                (const :tag "Clock Time" time))
  :group 'org-invoice-table)

(defun org-invoice-table-indent (level)
  "Create an indent based on org LEVEL."
  (if (= level 1) ""
    (concat (make-string (1- level) ?—) " ")))

(defun org-invoice-table-get-prop (key props)
  "Retrieve the assoc value of some PROPS using a KEY."
  (cdr (assoc key props)))

(defun org-invoice-table-price (hours &optional rate)
  "Get the cost of HOURS spent on a project.
Optionally accepts a RATE but defaults to `org-invoice-table-rate'."
  (let* ((mult (math-pow 10 org-invoice-table-hourly-accuracy))
         (amount (* hours (cond ((numberp rate) rate)
                                ((numberp org-invoice-table-rate)
                                 org-invoice-table-rate)
                                (0))))
         (billable (/ (round (* amount mult)) (float mult))))
    billable))

(defun org-invoice-table-hours (minutes)
  "Convert MINUTES into billable hours."
  (let ((mult (math-pow 10 org-invoice-table-hourly-accuracy)))
    (/ (round (* (/ minutes 60.0) mult)) (float mult))))

(defun org-invoice-table-format-hours (hours)
  "Convert a float HOURS value into a string."
  (format (concat "%." (format "%d" org-invoice-table-hourly-accuracy) "f")
          hours))

(defun org-invoice-table-modify-entry (rate)
  "Get a mapper that leverages a RATE to create a billable entry."
  (lambda (entry)
    (pcase-let ((`(,level ,headline ,_tgs ,_ts ,minutes ,props) entry))
      (let ((billable-hours (org-invoice-table-hours minutes)))
        (list minutes
              billable-hours
              (org-invoice-table-price billable-hours rate)
              level
              headline
              props)))))

(defun org-invoice-table-update-tables (tables rate)
  "Convert clock TABLES into billable tables with a given RATE."
  (mapcar (lambda (table)
            (pcase-let ((`(,_file-name ,file-mins ,entries-in) table))
              (let ((entries-out
                     (mapcar (org-invoice-table-modify-entry rate)
                             entries-in))
                    (file-hours (org-invoice-table-hours file-mins)))
                (list file-mins
                      file-hours
                      (org-invoice-table-price file-hours rate)
                      entries-out))))
          (seq-filter (lambda (table)
                        (let ((file-time (cadr table)))
                          (and file-time (> file-time 0))))
                      tables)))

(defun org-invoice-table-display-time (mins hours)
  "Display time with MINS or billable HOURS."
  (if (eq org-invoice-table-time-display 'hours)
      (org-invoice-table-format-hours hours)
    (org-duration-from-minutes mins)))

(defun org-invoice-table-emph (string &optional emph)
  "Emphasize a STRING if EMPH is non-nil."
  (if emph
      (format "*%s*" string)
    string))

(declare-function org-clock--translate "org-clock.el")
(declare-function org-time-stamp-format "org.el")
(declare-function org-clock-special-range "org-clock.el")
(declare-function org-duration-from-minutes "org-duration.el")
(declare-function org-duration-to-minutes "org-duration.el")
(declare-function org-table-align "org-table.el")
(declare-function org-table-recalculate "org-table.el")
(defvar org-duration-format) ; org-duration.el
(declare-function org-ctrl-c-ctrl-c "org.el")

;;;###autoload
(defun org-invoice-table (ipos tables params)
  "Generate an invoicing clocktable with the given IPOS, TABLES and PARAMS.
The IPOS is the point position. TABLES should be a list of table data.
The PARAMS should be a property list of table keywords and values.

See `org-clocktable-write-default' if you want an example of how the standard
clocktable works."
  (let* ((lang (or (plist-get params :lang) "en"))
         (block (plist-get params :block))
         (emph (plist-get params :emphasize))
         (header (plist-get params :header))
         (properties (or (plist-get params :properties) '()))
         (comments-on (member "Comment" properties))
         (formula (plist-get params :formula))
         (rate (plist-get params :rate))
         (has-formula (cond ((and formula (stringp formula))
                             t)
                            (formula (user-error "Invalid :formula param"))))
         (effort-on (member "Effort" properties))
         (billable-tables (org-invoice-table-update-tables tables rate))
         (org-duration-format `((special . h:mm))))
    (goto-char ipos)

    (insert-before-markers
     (or header
         ;; Format the standard header.
         (format "#+CAPTION: %s %s%s\n"
                 (org-clock--translate "Clock summary at" lang)
                 (format-time-string (org-time-stamp-format t t))
                 (if block
                     (let ((range-text
                            (nth 2 (org-clock-special-range
                                    block nil t
                                    (plist-get params :wstart)
                                    (plist-get params :mstart)))))
                       (format ", for %s." range-text))
                   "")))
     "| Task " (if effort-on "| Est" "")
     "| Time | Billable"
     (if comments-on "| Comment" "") "\n")
    (let ((total-mins (apply #'+ (mapcar #'car billable-tables)))
          (total-hours (apply #'+ (mapcar #'cadr billable-tables)))
          (total-cost (apply #'+ (mapcar #'caddr billable-tables))))
      (when (and total-mins (> total-mins 0))
        (pcase-dolist (`(,_file-mins ,_file-hours ,_file-cost ,entries)
                       billable-tables)
          (pcase-dolist (`(,mins ,hours ,cost ,level ,headline ,props) entries)
            (insert-before-markers
             (if (= level 1) "|-\n|" "|")
             (org-invoice-table-indent level)
             (concat (org-invoice-table-emph headline (and emph (= level 1))) "|")
             (if effort-on
                 (concat
                  (if-let ((effort (org-invoice-table-get-prop "Effort" props)))
                      (org-invoice-table-emph
                       (org-invoice-table-display-time
                        (org-duration-to-minutes effort)
                        (org-invoice-table-hours
                         (org-duration-to-minutes effort))))
                    "")
                  "|")
               "")
             (concat (org-invoice-table-emph
                      (org-invoice-table-display-time mins hours)
                      (and emph (= level 1)))
                     "|")
             (concat (org-invoice-table-emph
                      (format "$%.2f" cost)
                      (and emph (= level 1)))
                     "|")
             (if-let* (comments-on
                       (comment
                        (org-invoice-table-get-prop "Comment" props)))
                 (concat comment "\n")
               "\n"))))
        (let ((cols-adjust (if effort-on 2 1)))
          (insert-before-markers
           (concat "|-\n| "
                   (org-invoice-table-emph "Totals" emph)
                   (make-string cols-adjust ?|))
           (concat (org-invoice-table-emph
                    (org-invoice-table-display-time total-mins total-hours)
                    emph)
                   "|")
           (concat (org-invoice-table-emph
                    (format "$%.2f" total-cost)
                    emph) "|" ))
          (when has-formula
            (insert "\n#+TBLFM: " formula)))))
    (goto-char ipos)
    (skip-chars-forward "^|")
    (org-table-align)
    (when has-formula (org-table-recalculate 'all))))

;;;###autoload
(defun org-invoice-table-toggle-duration-format ()
  "Toggle the `org-duration-format' from fractional hours to hours/minutes."
  (interactive)
  (if (eq org-invoice-table-time-display 'hours)
      (setq-local org-invoice-table-time-display 'time)
    (setq-local org-invoice-table-time-display 'hours))
  (org-ctrl-c-ctrl-c))

(provide 'org-invoice-table)

;;; org-invoice-table.el ends here
