;;; telega-org.el --- Org mode UI for telega  -*- lexical-binding:t -*-

;; Copyright (C) 2026 by Khalid Rafi
;; Author: Khalid Rafi <khaalidrafi@gmail.com>
;; Maintainer: Khalid Rafi <khaalidrafi@gmail.com>
;; URL: https://github.com/khaalidrafi/telega-org
;; Version: 0.1.0
;; Keywords: comm, org
;; Package-Requires: ((emacs "28.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; telega's chat list is an ewoc of buttons: avatars, inline message
;; previews and redisplay timers.  Redrawing a few hundred of those costs
;; seconds of CPU, which is the whole story on a phone or an old laptop.
;; An Org buffer holding two lines of text per chat costs nothing to
;; redraw, and Org already comes with folding, motion, narrowing and
;; search.
;;
;; `telega-org-mode' renders the chat list like this:
;;
;;   * Pinned                        a group, see `telega-org-groups'
;;   ** Alice :unread:3: 📌           one heading per chat
;;      2m  ↑ call me tonight          last message as plain text
;;
;; Groups are telega match expressions, so what goes where is configured
;; in `telega-org-groups' and not coded here: a chat belongs to the
;; first group it matches.
;;
;; This is an add-on: it uses only telega's public API - the functions
;; declared below, its hooks and its customizable variables - so it loads
;; against any telega, from MELPA, a distribution package or a checkout,
;; and it cannot break silently when upstream renames an internal.  telega
;; is deliberately NOT in Package-Requires, because package.el cannot see
;; a telega installed by the distribution.
;;
;; It replaces the chat list only.  RET hands you over to
;; `telega-chat-with' and you type there, in telega's own chat buffer,
;; which is what that buffer is good at.
;;
;; Android / touch (the org.gnu.emacs app, Termux, tablets): a finger taps and
;; never hovers, so on a touch device - `telega-org-adapt-for-touch',
;; which detects it the way telega-lite does - a single tap on a chat
;; opens it (`telega-org-tap'), a tap on a group heading folds the
;; group with Org's own `org-cycle', a long press (touch systems send it
;; as mouse-3) marks the chat read, dragging scrolls line by line with
;; the finger, and lines are cut at the window edge instead of wrapping:
;; on a phone screen wrapping doubles the height of every chat for
;; nothing.
;;
;; Org features, used where each one already fits:
;;
;;   - `telega:ID' links (see `telega-org-link-follow') store a chat
;;     reference in any Org file, with C-c l there while the chat is
;;     open;
;;   - a #+BEGIN: telega-org dynamic block (M-x
;;     telega-org-insert-chat-list) embeds the chat list in any Org
;;     file, refreshed with C-c C-c on it;
;;   - `telega-org-sparse-tree' (C-c /) runs a tag query through Org's
;;     own `org-match-sparse-tree': "unread", "unread+mute", with
;;     M-g n / M-g p to step through the matches;
;;   - `telega-org-jump-to-unread' (j, or u) jumps to the first unread
;;     chat, then cycles;
;;   - `telega-org-columns' (c) shows the list as one row per chat in
;;     Org's column view.
;;
;; The buffer grammar follows ORG-CHAT-STANDARD.org (v1.1): g refreshes,
;; j jumps to the first unread chat, q buries the list - r and u are the
;; pre-standard spellings, kept working.
;;
;; From a checkout:
;;
;;   (use-package telega-org
;;     :load-path "~/telega-org/"
;;     :after telega)
;;
;; then M-x telega-org-list.

;;; Code:
(require 'cl-lib)
(require 'org)
(require 'subr-x)

(defconst telega-org-version "0.1.0"
  "Version of the telega-org package.")

;; telega's public API, the whole of it, declared and never required: the
;; point of an add-on is that it loads without telega, and the tests stub
;; these functions instead.  Should upstream rename one of them, the byte
;; compiler here says so, instead of the user finding a void-function in a
;; live session.
(declare-function telega-chats-list "telega-core" ())
(declare-function telega-chat-order-dirty-p "telega-core" ())
(declare-function telega-filter-chats "telega-filter" (chat-list &optional temex))
(declare-function telega-sort-chats "telega-sort" (criteria chats))
(declare-function telega-chat-p "telega-core" (msg-sender))
(declare-function telega-chat-title "telega-chat" (chat &optional fmt no-badges))
(declare-function telega-chat-match-p "telega-core" (chat temex))
(declare-function telega-chat-with "telega-chat" (chat-or-user))
(declare-function telega-chat-toggle-read "telega-chat" (chat))
(declare-function telega-msg-p "telega-msg" (obj))
(declare-function telega-msg-chat "telega-msg" (msg &optional offline-p))
(declare-function telega-msg-content-text "telega-msg" (msg &optional speech-p))
(declare-function telega-msg-by-me-p "telega-msg" (msg))
(declare-function telega-completing-read-chat "telega-util"
                   (prompt &optional chats sort-criteria))
(declare-function telega-server-live-p "telega-server" ())
(declare-function telega-symbol "telega-util" (ending &optional image))
(declare-function telega-chat-get "telega-chat" (chat-id &optional offline-p))
(declare-function mouse-set-point "mouse" (event &optional strategy))
(declare-function org-columns "org-colview" (&optional arg))

;; A docstring is required, not decoration: without one a defvar does not
;; mark the variable special, and a test that let-binds it under
;; lexical-binding then binds it lexically, where the renderer cannot see
;; it.  No value, so loading this never clobbers telega's own setting.
(defvar telega-date-format-alist
  "Alist of date formats telega uses, see `telega-org--time'.")

(defgroup telega-org nil
  "Org mode user interface for the telega Telegram client."
  :group 'telega-modes
  :prefix "telega-org-")

(defface telega-org-unread-face
  '((t :inherit bold :weight bold))
  "Face for the title of a chat with unread messages."
  :group 'telega-org)

(defface telega-org-mention-face
  '((t :inherit bold :foreground "red1"))
  "Face for the title of a chat with unread mentions."
  :group 'telega-org)

(defface telega-org-preview-face
  '((t :inherit shadow))
  "Face for the text of the last message of a chat."
  :group 'telega-org)

(defface telega-org-time-face
  '((t :inherit shadow))
  "Face for the time of the last message of a chat."
  :group 'telega-org)

(defface telega-org-current-face
  '((t :inherit bold :underline t))
  "Face for the title of the chat last opened from `telega-org-mode'."
  :group 'telega-org)

(defcustom telega-org-groups
  '(("Pinned" . (is-pinned))
    ("Unread" . (unread))
    ("Chats"  . nil))
  "Chat groups, as an alist of (TITLE . TEMEX), in display order.
TITLE is a level 1 heading in the chat list, TEMEX is a telega match
expression selecting the chats of that group, see `telega-chat-match-p'.
A chat is shown in the first group it matches, so a pinned unread chat
lands under \"Pinned\", and not under both.

A group whose TEMEX is nil is the catch all: every chat not matched by an
earlier group ends up there.  Without such a group, unmatched chats are
not shown at all.  A group with no chats gets no heading."
  :package-version '(telega-org . "0.1.0")
  :type '(repeat sexp)
  :group 'telega-org)

(defcustom telega-org-chat-sort-criteria '(chatbuf-visibility chatbuf-recency order id)
  "Criteria used to walk the chat list, most recent first.
This is a telega sort criteria list, see `telega-sort-criteria-alist'.  It
is only used to read the chat list: telega's own sort order, its filters
and its root buffer are never touched.

The value is telega's own `telega-chat-completing-sort-criteria', spelled
out rather than read from telega, because this package has to load before
telega does.  Copy it here if you change it there."
  :package-version '(telega-org . "0.1.0")
  :type '(choice symbol (repeat symbol))
  :group 'telega-org)

(defcustom telega-org-idle-delay 0.4
  "Seconds of idleness before the chat list updates itself.
TDLib reports updates one chat at a time, and a sync can report hundreds;
the list is therefore redrawn once per quiet spell, the same trick telega
plays with `telega-idle-delay'."
  :package-version '(telega-org . "0.1.0")
  :type 'number
  :group 'telega-org)

(defcustom telega-org-filter-regexp nil
  "Keep only the chats whose title matches this regexp.
nil, the default, keeps every chat.  M-x telega-org-filter sets it.
It is a plain Emacs regexp, matched case sensitively against the chat
title."
  :package-version '(telega-org . "0.1.0")
  :type '(choice (const :tag "All chats" nil) regexp)
  :group 'telega-org)

(defcustom telega-org-focus-unread t
  "Non-nil to put point on the first unread chat when the list is opened."
  :package-version '(telega-org . "0.1.0")
  :type 'boolean
  :group 'telega-org)

(defcustom telega-org-show-pin-symbol t
  "Non-nil to mark pinned chats with telega's pin symbol."
  :package-version '(telega-org . "0.1.0")
  :type 'boolean
  :group 'telega-org)

(defcustom telega-org-read-only t
  "Non-nil to make `telega-org-mode' buffers read only.
The chat list is generated, not a document, but read only costs one
C-x C-q to turn off, and Org's refilling and aligning will not fight the
renderer."
  :package-version '(telega-org . "0.1.0")
  :type 'boolean
  :group 'telega-org)

(defcustom telega-org-buffer-name "*Telega Org*"
  "Name of the buffer showing the chat list."
  :package-version '(telega-org . "0.1.0")
  :type 'string
  :group 'telega-org)

(defcustom telega-org-adapt-for-touch t
  "Non-nil to adapt `telega-org-mode' to touch screens.
Applies only when a touch device is detected, see
`telega-org--touch-device-p': taps open chats, taps on a group
heading fold it, a long press marks a chat read, scrolling follows
the finger, and lines are truncated rather than wrapped on the
narrow screen.  nil keeps the plain keyboard behaviour everywhere."
  :package-version '(telega-org . "0.1.0")
  :type 'boolean
  :group 'telega-org)

(defcustom telega-org-export-base-url nil
  "Base URL for t.me links in exports, e.g. \"https://t.me/joinchat/\".
Used by `telega-org-link-export' when a chat is exported to HTML,
LaTeX or Texinfo.  nil means \"https://t.me/\", the web client's own
chat URLs, which work for public usernames only."
  :package-version '(telega-org . "0.2.0")
  :type '(choice (const :tag "t.me" nil) string)
  :group 'telega-org)

(defcustom telega-org-columns-format "%ITEM %TAGS"
  "Column format `telega-org-columns' overlays on the chat list.
A string in Org's column format, see `org-columns-default-format' and
the \"Defining columns\" node of the Org manual.  The default shows the
chat title and its tags in two columns, which is all a chat list has:
the unread and mention counts live in the tags.  It is set buffer
locally, so Org's own \\[org-columns] works on the list too."
  :package-version '(telega-org . "0.2.0")
  :type 'string
  :group 'telega-org)

(defcustom telega-org-mode-line-format
  '((:eval (concat " Telega" telega-org-status)))
  "Mode line format of `telega-org-mode' buffers.
`telega-org-status' is recomputed on every refresh, so a mode line that
reads it costs nothing."
  :package-version '(telega-org . "0.1.0")
  :type 'sexp
  :group 'telega-org)

(defvar telega-org-status ""
  "Chat counters for the mode line, recomputed on refresh.
Buffer local in `telega-org-mode' buffers.")

(defvar telega-org-current-chat nil
  "Chat last opened from `telega-org-mode', underlined in the list.
A chat plist, or nil.  Buffer local in `telega-org-mode' buffers.")

;;;; Rendering one chat

(defun telega-org--count (obj prop)
  "Return OBJ's count PROP, zero when it is missing.
This is what telega's own `telega-tl-get0' expands to: telega-server
leaves out the values that are zero, so reading one means answering zero
for it.  It is spelled out here because that is a macro in telega, and a
macro cannot be used from a package that is byte compiled without telega
on the load path."
  (or (plist-get obj prop) 0))

(defun telega-org--title (chat)
  "Return the plain title of CHAT.
The last argument drops telega's badges, and dropping the text
properties is what keeps a title from carrying faces into the Org
buffer behind the faces this package sets."
  (string-trim (substring-no-properties (telega-chat-title chat nil t))))

(defun telega-org--tags (chat)
  "Return the Org tags of CHAT, tags included.
The empty string for a chat with nothing to report, so that the caller
can leave the space off."
  (concat (when (telega-chat-match-p chat 'muted) ":mute:")
          (let ((n (telega-org--count chat :unread_count)))
            (when (> n 0) (format ":unread:%s:" n)))
          (let ((n (telega-org--count chat :unread_mention_count)))
            (when (> n 0) (format ":mention:%s:" n)))))

(defun telega-org--same-day-p (date)
  "Return non-nil if DATE falls on today's calendar day.
`decode-time' returns the year, the month and the day as its fifth,
fourth and third elements."
  (let ((then (decode-time date))
        (now (decode-time)))
    (and (= (nth 5 then) (nth 5 now))
         (= (nth 4 then) (nth 4 now))
         (= (nth 3 then) (nth 3 now)))))

(defun telega-org--time (date)
  "Return DATE formatted for a chat list line.
Telega's own `telega-date-format-alist' decides how that looks, so the
list follows the user's telega settings instead of a second set of them
here."
  (format-time-string
   (cond ((telega-org--same-day-p date)
          (cdr (assq 'today telega-date-format-alist)))
         ;; a week old and no more: the time of day still tells them
         ;; apart, without crowding out the message
         ((<= (- (float-time) date) (* 7 24 3600))
          (cdr (assq 'time telega-date-format-alist)))
         (t (cdr (assq 'old telega-date-format-alist))))
   date))

(defun telega-org--message-text (msg)
  "Return MSG as one line of plain text.
The text of the message, or a word for its kind when there is none, so
that a chat whose last message is a photo reads \"photo\" rather than
nothing at all.  The empty string when there is neither: TDLib leaves a
field out rather than sending a null, and the callers splice this
straight into the buffer."
  (let ((text (telega-msg-content-text msg)))
    ;; telega hands the text over with its own faces on it: stripping the
    ;; text properties is what keeps a backend face from riding into the
    ;; buffer under the face this package sets (standard section 8), the
    ;; same treatment `telega-org--title' gives the title.
    (or (and text (substring-no-properties text))
        (let* ((content (plist-get msg :content))
               (type (and content (plist-get content :@type)))
               (kind (and type
                          (string-remove-prefix "message" (downcase type)))))
          (if kind
              (capitalize (replace-regexp-in-string "_" " " kind))
            "")))))

(defun telega-org--preview (chat)
  "Return the body line of CHAT: when it was, and what it said.
The empty string for a chat with no message yet."
  (let ((msg (plist-get chat :last_message)))
    (if (null msg)
        ""
      (concat "  "
              (propertize (format "%-7s"
                                  (telega-org--time (plist-get msg :date)))
                          'face 'telega-org-time-face)
              ;; standard section 3.4: the direction arrow, outgoing up
              ;; and incoming down, as plain grammar text - section 6
              ;; assigns faces to roles, and an arrow is not one (the
              ;; old bold `telega-org-unread-face' on the outgoing arrow
              ;; read "unread", and the incoming side had no arrow at
              ;; all, just two blanks)
              (if (telega-msg-by-me-p msg) "↑ " "↓ ")
              (propertize (or (telega-org--message-text msg) "")
                          'face 'telega-org-preview-face)))))

(defun telega-org--heading (chat)
  "Return the heading line of CHAT, stars and tags included."
  (let* ((unread (telega-org--count chat :unread_count))
         (mentions (telega-org--count chat :unread_mention_count))
         (tags (telega-org--tags chat))
         (face (cond ((> mentions 0) 'telega-org-mention-face)
                     ((> unread 0) 'telega-org-unread-face)
                     ((eq chat telega-org-current-chat) 'telega-org-current-face))))
    (concat "** "
            (when (and telega-org-show-pin-symbol
                       (telega-chat-match-p chat 'is-pinned))
              ;; telega's symbol table is a backend string like any
              ;; other: its text properties do not belong in the buffer
              (concat (substring-no-properties (telega-symbol 'pin)) " "))
            (propertize (telega-org--title chat) 'face face)
            (unless (string-empty-p tags)
              (concat " " tags)))))

(defun telega-org--chat-lines (chat)
  "Return CHAT as exactly two lines: a heading and a preview.
Keeping it at two lines is what lets a single chat be redrawn without
moving anything around it."
  (concat (telega-org--heading chat) "\n" (telega-org--preview chat)))

;;;; Grouping the chat list

(defun telega-org--matches-filter-p (chat)
  "Return non-nil if CHAT survives `telega-org-filter-regexp'."
  (or (null telega-org-filter-regexp)
      (string-match-p telega-org-filter-regexp (telega-org--title chat))))

(defun telega-org--chats ()
  "Return the known chats in display order, `telega-org-filter-regexp' applied."
  (telega-sort-chats
   telega-org-chat-sort-criteria
   (seq-filter #'telega-org--matches-filter-p
               (telega-filter-chats (telega-chats-list) 'is-known))))

(defun telega-org--group-of (chat)
  "Return the `telega-org-groups' entry CHAT belongs to.
CHAT goes to the first group it matches, or to the group with no match
expression at all.  Nil when it matches none, and then it is not shown."
  (or (seq-find (lambda (group)
                  (and (cdr group) (telega-chat-match-p chat (cdr group))))
                telega-org-groups)
      (seq-find (lambda (group) (null (cdr group)))
                telega-org-groups)))

(defun telega-org--group-chats (chats)
  "Return one (TITLE . CHATS) per non-empty `telega-org-groups' entry.
CHATS are the chats to group, in display order, and they keep it inside
their group."
  ;; (TITLE TEMEX . REVERSED-CHATS) per group, freshly built: `push' on
  ;; a cons cell of `telega-org-groups' itself would corrupt the user's
  ;; value, and a chat matched by a later group would then match on the
  ;; chats an earlier one collected.
  (let ((buckets (mapcar (lambda (group) (list (car group) (cdr group) nil))
                        telega-org-groups)))
    (dolist (chat chats)
      (let ((bucket (seq-find (lambda (one)
                                (or (null (nth 1 one))
                                    (telega-chat-match-p chat (nth 1 one))))
                              buckets)))
        (when bucket
          (setf (nth 2 bucket) (cons chat (nth 2 bucket))))))
    ;; drop the empty groups, on the cons that has the chats as its cdr:
    ;; the bucket itself still has three elements, but the converted one
    ;; has two
    (seq-filter (lambda (one) (cdr one))
                (mapcar (lambda (one)
                          (cons (nth 0 one) (nreverse (nth 2 one))))
                        buckets))))

;;;; The buffer

(defvar telega-org--chats-cache (make-hash-table :test #'eq)
  "Chat id to chat plist, as last seen by this package.
Kept current from the chat list and from telega's update hooks: telega
hands out a fresh chat plist on every update, and there is no public
chat from id lookup, so this is where a chat is found again.")

(defvar telega-org--locations (make-hash-table :test #'eq)
  "Chat id to the bounds of its two lines, as (HEADING . END).")

(defvar telega-org--rendered (make-hash-table :test #'eq)
  "Chat id to the text last rendered for it, so idle updates cost
nothing.")

(defvar telega-org--groups (make-hash-table :test #'eq)
  "Chat id to the title of the group it was last rendered under.")

(defvar telega-org--dirty (make-hash-table :test #'eq)
  "Chat ids whose two lines are out of date.")

(defvar telega-org--dirty-all nil
  "Non-nil when the whole buffer has to be rendered again.")

(defvar telega-org--timer nil
  "Idle timer of the pending update, or nil.")

(defun telega-org--id-at-point ()
  "Return the telega-org-id text property at point, or nil.
Both positions are tried, since the property ends with the title while
the tags after it are not covered."
  (or (get-text-property (point) 'telega-org-id)
      (get-text-property (max (point-min) (1- (point))) 'telega-org-id)))

(defun telega-org--nearest-id ()
  "Return the telega-org-id of the line at point, or of the line above it.
A chat is a heading and its preview, so the preview belongs to the
heading above it: the whole of a chat is clickable, and not only its
title."
  (save-excursion
    (beginning-of-line)
    (or (telega-org--id-at-point)
        (and (not (bobp))
             (progn (forward-line -1)
                    (telega-org--id-at-point))))))

(defun telega-org--chat-at-point (&optional pos)
  "Return the chat at POS, defaulting to point, or nil.
Nil on a group heading, which is not a chat."
  (let ((id (save-excursion
              (goto-char (or pos (point)))
              (telega-org--nearest-id))))
    (and id (gethash id telega-org--chats-cache))))

(defconst telega-org--unread-regexp " :\\(?:unread\\|mention\\):"
  "Regexp matching the start of an unread or mention tag.
The leading space is part of it: it is what tells a tag on a heading
from the same text appearing inside a chat title or a preview line.")

(defun telega-org--unread-pos ()
  "Return the position of the unread tag at point, or nil.
Only a tag that belongs to a chat counts, which the `telega-org-id'
text property tells: a chat title or a preview line that happens to
read \" :unread:\" is not one."
  (when (get-text-property (match-beginning 0) 'telega-org-id)
    (line-beginning-position)))

(defun telega-org--first-unread ()
  "Return the position of the first unread chat, or nil."
  (save-excursion
    (goto-char (point-min))
    (catch 'found
      (while (re-search-forward telega-org--unread-regexp nil t)
        (when-let ((pos (telega-org--unread-pos)))
          (throw 'found pos))))))

(defun telega-org--insert-chat (chat)
  "Insert the two lines of CHAT at point, and remember where they are."
  (let* ((id (plist-get chat :id))
         (start (point))
         (lines (telega-org--chat-lines chat)))
    (insert lines "\n")
    (put-text-property start (+ start (length (telega-org--heading chat)))
                       'telega-org-id id)
    (puthash id (cons start (+ start (length lines)))
             telega-org--locations)
    (puthash id lines telega-org--rendered)))

(defun telega-org--update-chat (chat)
  "Redraw the two lines of CHAT in place, if they changed.
Asks for a redraw of the whole buffer instead when CHAT is not where it
was, since a group heading or a chat line then has to move."
  (let* ((id (plist-get chat :id))
         (bounds (gethash id telega-org--locations)))
    (cond
     ((or (null bounds)
          ;; compare against the title, which is what
          ;; `telega-org--groups' keeps, not the whole group entry
          (not (equal (car-safe (telega-org--group-of chat))
                      (gethash id telega-org--groups))))
      (setq telega-org--dirty-all t))
     (t
      (let* ((lines (telega-org--chat-lines chat))
             (inhibit-read-only t))
        ;; faces count: a chat underlined as the current one has to
        ;; lose that underline when another chat is opened
        (unless (equal-including-properties lines (gethash id telega-org--rendered))
          (save-excursion
            (goto-char (car bounds))
            (delete-region (car bounds) (cdr bounds))
            (insert lines)
            (put-text-property (car bounds)
                               (+ (car bounds) (length (telega-org--heading chat)))
                               'telega-org-id id)
            (puthash id (cons (car bounds) (+ (car bounds) (length lines)))
                     telega-org--locations)
            (puthash id lines telega-org--rendered))))))))

(defun telega-org--update-chats ()
  "Redraw the lines of the chats queued in `telega-org--dirty'.
Point and window start are kept: this runs while the user is reading."
  (save-excursion
    (dolist (id (hash-table-keys telega-org--dirty))
      (let ((chat (gethash id telega-org--chats-cache)))
        (if chat
            (telega-org--update-chat chat)
          ;; a chat that is gone, or that no group matches any more
          (setq telega-org--dirty-all t))))
    (when (or telega-org--dirty-all (telega-chat-order-dirty-p))
      (telega-org-refresh))))

(defun telega-org--set-current-chat (chat)
  "Highlight CHAT as the last opened chat, and unhighlight the previous one."
  (let ((previous telega-org-current-chat))
    (setq telega-org-current-chat chat)
    (when previous
      (telega-org--update-chat previous))
    (telega-org--update-chat chat)))

;;;###autoload
(defun telega-org-refresh ()
  "Redraw the whole chat list.
Cheap enough for a few hundred chats, being plain text and no images,
but the update hooks prefer to patch the few lines they have to."
  (interactive)
  (unless (derived-mode-p 'telega-org-mode)
    (user-error "Not in a `telega-org-mode' buffer"))
  (let ((inhibit-read-only t)
        (current (telega-org--chat-at-point))
        (chats (telega-org--chats)))
    (erase-buffer)
    (clrhash telega-org--chats-cache)
    (clrhash telega-org--locations)
    (clrhash telega-org--rendered)
    (clrhash telega-org--groups)
    (dolist (chat chats)
      (puthash (plist-get chat :id) chat telega-org--chats-cache))
    (dolist (bucket (telega-org--group-chats chats))
      (insert "* " (car bucket) "\n")
      (dolist (chat (cdr bucket))
        (puthash (plist-get chat :id) (car bucket) telega-org--groups)
        (telega-org--insert-chat chat)))
    (let ((unread (seq-count (lambda (chat)
                               (> (telega-org--count chat :unread_count) 0))
                             chats)))
      (setq telega-org-status
            (concat (format " %d chats" (length chats))
                    (if (> unread 0) (format " %d unread" unread) "")
                    (if (telega-server-live-p) "" " offline"))))
    ;; stay on the chat, not on the line, it was on
    (goto-char (or (and current
                        (gethash (plist-get current :id) telega-org--locations))
                   (and telega-org-focus-unread (telega-org--first-unread))
                   (point-min)))))

(defun telega-org--flush ()
  "Apply the chat list update queued for this quiet spell."
  (setq telega-org--timer nil)
  (when (derived-mode-p 'telega-org-mode)
    (if (or telega-org--dirty-all (telega-chat-order-dirty-p))
        (telega-org-refresh)
      (telega-org--update-chats)))
  (clrhash telega-org--dirty)
  (setq telega-org--dirty-all nil)
  (force-mode-line-update))

(defun telega-org--schedule ()
  "Queue an update of the chat list, one per quiet spell."
  (unless telega-org--timer
    (setq telega-org--timer
          (run-with-idle-timer telega-org-idle-delay nil
                              #'telega-org--flush))))

(defun telega-org--chat-dirty (obj)
  "Queue OBJ for redraw.
Called from telega's update hooks, where OBJ is a chat or a message.
A nil OBJ means every chat: that is `telega-user-update-hook', whose
argument is a user, and a user name appears in as many chat titles as it
appears in messages."
  (let* ((chat (cond ((null obj) nil)
                     ((telega-msg-p obj) (telega-msg-chat obj))
                     (t obj)))
         (id (and (telega-chat-p chat) (plist-get chat :id))))
    (if id
        (progn
          (puthash id chat telega-org--chats-cache)
          (puthash id t telega-org--dirty))
      (setq telega-org--dirty-all t))
    (telega-org--schedule)))

(defun telega-org--all-dirty ()
  "Queue the whole chat list for redraw, from telega's own hooks."
  (setq telega-org--dirty-all t)
  (telega-org--schedule))

;;;###autoload
(defun telega-org-open ()
  "Open the chat at point in a telega chat buffer.
Telega types there: it renders messages as they should be, with the
markup and the media, which a line of an Org buffer cannot."
  (interactive)
  (let ((chat (telega-org--chat-at-point)))
    (unless chat
      (user-error "Point is not on a chat"))
    (telega-org--set-current-chat chat)
    (telega-chat-with chat)))

;;;###autoload
(defun telega-org-switch-chat (prompt)
  "Open the chat matching PROMPT, with telega's own completion."
  (interactive (list (read-string "Open chat: ")))
  (let ((chat (telega-completing-read-chat prompt)))
    (unless chat
      (user-error "No chat matching \"%s\"" prompt))
    (telega-org--set-current-chat chat)
    (telega-chat-with chat)))

;;;###autoload
(defun telega-org-filter (regexp)
  "Keep only the chats whose title matches REGEXP.
An empty REGEXP clears the filter, and shows every chat again."
  (interactive
   (list (read-string (if telega-org-filter-regexp
                          "Keep chats matching: "
                        "Keep chats matching (empty clears): ")
                      nil nil telega-org-filter-regexp)))
  (setq telega-org-filter-regexp (unless (string-empty-p regexp) regexp))
  (telega-org-refresh))

;;;###autoload
(defun telega-org-quit ()
  "Bury the chat list, leaving telega itself alone.
Standard section 8: q buries the list, and killing it never kills the
backend either - telega keeps running underneath."
  (interactive)
  (bury-buffer))

;;;###autoload
(defun telega-org-mark-read ()
  "Toggle the chat at point as read or unread."
  (interactive)
  (let ((chat (telega-org--chat-at-point)))
    (unless chat
      (user-error "Point is not on a chat"))
    (telega-chat-toggle-read chat)))

(defun telega-org--move-chat (backwards)
  "Move point to the neighbouring chat heading.
To the previous one when BACKWARDS is non-nil, to the next one
otherwise, and over to the top of the list once the end is reached.

Org renames its heading motion commands between releases, so the two
lines of `search' here are cheaper than picking one of the spellings.

The line is stepped off first: point normally sits on a heading, and a
plain search would match that same heading and go nowhere."
  (goto-char (progn
               (if backwards (beginning-of-line) (end-of-line))
               (if (if backwards
                       (re-search-backward "^\\*\\* " nil t)
                     (re-search-forward "^\\*\\* " nil t))
                   (match-beginning 0)
                 (point-min)))))

;;;###autoload
(defun telega-org-next-chat ()
  "Move point to the next chat."
  (interactive)
  (telega-org--move-chat nil))

;;;###autoload
(defun telega-org-previous-chat ()
  "Move point to the previous chat."
  (interactive)
  (telega-org--move-chat t))

;;;; Navigation

;; The buffer is a real outline, so the machine that walks an outline -
;; Org's own sparse trees and `next-error' - walks the chat list with no
;; code of ours at all: the tags on each heading, "unread:3:" and its
;; friends, are the query language.

;;;###autoload
(defun telega-org-jump-to-unread ()
  "Move point to the next chat with unread messages.
Searching wraps around, so the last unread chat leads back to the
first one rather than leaving a half-seen list.  With no unread chat
at all, point stays and a message says why."
  (interactive)
  (let ((from (point)))
    (catch 'found
      ;; Two passes: from the next chat onwards, then from the top for
      ;; the ones before point.  Both walk plain text - the chats have no
      ;; org-id of their own - so this is motion, not an outline walk.
      (dolist (start (list (save-excursion
                             (goto-char from)
                             (forward-line)
                             (point))
                           (point-min)))
        (goto-char start)
        (while (re-search-forward telega-org--unread-regexp nil t)
          (when-let ((pos (telega-org--unread-pos)))
            (goto-char pos)
            (throw 'found nil))))
      (goto-char from)
      (user-error "No chats with unread messages"))))

;;;###autoload
(defun telega-org-sparse-tree (query)
  "Show only the chats matching QUERY, with Org's sparse tree.
QUERY is a tag search, ‘=unread=’ or ‘=unread+mute=’, just as it is typed
into the Org agenda.  An empty QUERY shows the whole list again, the
way C-c C-c in a tag search does."
  (interactive
   (list (read-string "Tag query (empty clears): " "unread" nil "unread" t)))
  (if (string-empty-p (string-trim query))
      (org-fold-show-all)
    (org-match-sparse-tree nil (string-trim query)))
  (goto-char (point-min)))

;;;###autoload
(defun telega-org-columns ()
  "Show the chat list as an Org column view.
One row per chat, the title in one column and the tags - unread,
mention, mute - in another, drawn by Org's own `org-columns' over the
format in `telega-org-columns-format'.  Press q or C-c C-c on a row to
leave the view again."
  (interactive)
  (unless (derived-mode-p 'telega-org-mode)
    (user-error "Not in a `telega-org-mode' buffer"))
  ;; from before the first headline, so the view covers the whole list
  (goto-char (point-min))
  (org-columns))

;;;###autoload
(defun telega-org-tap ()
  "Do what a tap on the line at point means.
A chat opens, a group heading folds and unfolds with Org's own
`org-cycle', and the preview under a chat belongs to that chat,
same as for `telega-org-open'."
  (interactive)
  (cond ((telega-org--chat-at-point) (telega-org-open))
        ((save-excursion
           (beginning-of-line)
           (looking-at-p "\\* "))
         (org-cycle))
        (t (user-error "Nothing to tap here"))))

(defun telega-org--tap-mouse (event)
  "Tap: position point at EVENT and run `telega-org-tap'."
  (interactive "e")
  (mouse-set-point event)
  (telega-org-tap))

(defun telega-org--mark-read-mouse (event)
  "Long press: mark the chat under EVENT read, and do nothing on
a group heading - there is no chat there to mark."
  (interactive "e")
  (mouse-set-point event)
  (when (telega-org--chat-at-point)
    (telega-org-mark-read)))

(defun telega-org--touch-device-p ()
  "Return non-nil if Emacs runs on a touch device.
Three signals, any one of which is enough: the official Emacs Android
app (org.gnu.emacs) reports `system-type' as `android' - its value
comes from configure's opsys, confirmed against the Emacs 30 source;
Emacs run as a Termux package sees the `TERMUX_VERSION' environment
variable the Termux shell exports; and a touch terminal advertises the
`touch-screen' terminal parameter, the checks telega-lite uses."
  (or (eq system-type 'android)
      (getenv "TERMUX_VERSION")
      (cl-loop for frame in (frame-list)
               thereis (terminal-parameter frame 'touch-screen))))

(defvar telega-org-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'telega-org-open)
    (define-key map (kbd "o") #'telega-org-open)
    (define-key map (kbd "n") #'telega-org-next-chat)
    (define-key map (kbd "p") #'telega-org-previous-chat)
    ;; standard section 7 verbs: g refreshes, j jumps to the first
    ;; unread chat, q buries.  r and u are the pre-standard spellings,
    ;; kept so the muscle memory of earlier releases keeps working.
    (define-key map (kbd "g") #'telega-org-refresh)
    (define-key map (kbd "j") #'telega-org-jump-to-unread)
    (define-key map (kbd "q") #'telega-org-quit)
    (define-key map (kbd "u") #'telega-org-jump-to-unread)
    (define-key map (kbd "c") #'telega-org-columns)
    (define-key map (kbd "m") #'telega-org-mark-read)
    (define-key map (kbd "r") #'telega-org-refresh)
    (define-key map (kbd "s") #'telega-org-filter)
    ;; Org's own dispatcher, but the two keys this package's buffer is
    ;; actually navigated with come out of it, "+unread" and the query
    ;; prompt, without having to remember the extra keys.
    (define-key map (kbd "C-c /") #'telega-org-sparse-tree)
    (define-key map (kbd "C-c C-c") #'telega-org-switch-chat)
    map)
  "Keymap of `telega-org-mode'.
The keys are the ones telega's root buffer uses where they mean the same
thing, so that the muscle memory carries over.")

(defun telega-org--setup-touch ()
  "Bind the touch keys of `telega-org-mode-map', once per Emacs.
The detection result is fixed for a running Emacs, so the keymap
of the desktop case is never touched.  A tap lands on text, not
on a button, so it must both position point and follow it, and
`mouse-3' is what touch systems send for a long press."
  (when (and telega-org-adapt-for-touch
             (not (lookup-key telega-org-mode-map [mouse-1]))
             (telega-org--touch-device-p))
    (define-key telega-org-mode-map [mouse-1] #'telega-org--tap-mouse)
    (define-key telega-org-mode-map [mouse-3]
      #'telega-org--mark-read-mouse)))

;;;###autoload
(define-derived-mode telega-org-mode org-mode "TelegaOrg"
  "Org buffer showing the telega chat list, one heading per chat.
See `telega-org-groups' for how the chats are grouped, and
`telega-org-open' for handing a chat over to telega itself."
  :group 'telega-org
  (setq-local comment-start nil comment-end nil)
  (setq-local tab-width 2)
  ;; standard section 8: telega's update hooks redraw the list on the
  ;; idle timer, process-driven inserts, so undo would only pile up
  ;; entries across redraws that nobody wants to walk back
  (buffer-disable-undo)
  (setq-local buffer-read-only telega-org-read-only)
  (setq-local mode-line-process nil)
  (setq-local telega-org-status "")
  (setq-local telega-org-current-chat nil)
  (setq-local mode-line-format telega-org-mode-line-format)
  ;; so Org's own `org-columns' works on the list too, not only
  ;; `telega-org-columns'
  (setq-local org-columns-default-format telega-org-columns-format)
  (when (and telega-org-adapt-for-touch (telega-org--touch-device-p))
    (telega-org--setup-touch)
    ;; a finger drags, it does not hop page to page
    (setq-local scroll-conservatively 101)
    (setq-local mouse-wheel-progressive-speed nil)
    (setq-local mouse-wheel-follow-mouse t)
    ;; a wrapped chat is two screen rows for no information: cut the
    ;; line at the window edge instead, and redisplay is cheaper too
    (setq-local truncate-lines t)))

;;;###autoload
(defun telega-org-list (&optional arg)
  "Show the telega chat list in an Org buffer.
With a prefix ARG, or when there is no such buffer yet, draw the list
in a fresh buffer; otherwise show the buffer as it is."
  (interactive "P")
  (if (or arg (not (get-buffer telega-org-buffer-name)))
      (let ((buffer (generate-new-buffer telega-org-buffer-name)))
        (with-current-buffer buffer
          (telega-org-mode)
          (telega-org-refresh))
        (pop-to-buffer buffer))
    (pop-to-buffer telega-org-buffer-name)))

;;;###autoload
(with-eval-after-load 'telega
  ;; telega is an add-on dependency, so wiring hooks here is the only way
  ;; in: adding them at load time would declare the hook variables before
  ;; telega does, which telega's own style guide warns against.
  (add-hook 'telega-ready-hook #'telega-org--all-dirty)
  (add-hook 'telega-chats-fetched-hook #'telega-org--all-dirty)
  (add-hook 'telega-kill-hook #'telega-org--all-dirty)
  (add-hook 'telega-chat-update-hook #'telega-org--chat-dirty)
  (add-hook 'telega-chat-created-hook #'telega-org--chat-dirty)
  (add-hook 'telega-chat-post-message-hook #'telega-org--chat-dirty)
  (add-hook 'telega-user-update-hook
            (lambda (&rest _) (telega-org--chat-dirty nil))))

;;;; The telega: Org link

;; A chat is a number in TDLib, so a link to one is a chat id and nothing
;; else: `telega:42'.  Following it looks the chat up in telega's own
;; cache, so a link pasted in any Org buffer - an agenda, a note, a task -
;; opens the very chat it names, with the user's telega identity already
;; loaded, and an unknown id gives a proper error rather than a silence.

(defun telega-org--link-path (path)
  "Return the chat id in PATH, spelled either \"42\" or \"42::0\".
The optional message id after \"::\" is TDLib's, and it is left in the
plist where `org-link-set-parameters' can see it, but it is not used yet:
opening a message needs `telega-chat--goto-msg', which is internal to
telega."
  (let ((pos (string-match "::" path)))
    (if pos (substring path 0 pos) path)))

(defun telega-org-link-follow (path _)
  "Open the telega chat named by PATH in a telega chat buffer."
  (let* ((id (string-to-number (telega-org--link-path path)))
         (chat (telega-chat-get id 'offline)))
    (unless chat
      (user-error "telega-org: no chat with id %d; is telega started?" id))
    (telega-org--set-current-chat chat)
    (telega-chat-with chat)))

(defun telega-org-link-complete ()
  "Complete the path of a telega link with a chat title, for `org-insert-link'.
The completion list is the chat list itself, read through the same
sorted, filtered chat list the buffer shows, and not a second one kept
here."
  (let ((chat (telega-completing-read-chat
               "Chat: " (telega-org--chats) telega-org-chat-sort-criteria)))
    (number-to-string (plist-get chat :id))))

(defun telega-org-link-store (&rest _)
  "Store a link to the chat at point, from a `telega-org-mode' buffer."
  (when (derived-mode-p 'telega-org-mode)
    (let ((chat (telega-org--chat-at-point)))
      (when chat
        (org-link-store-props
         :type "telega"
         :link (concat "telega:" (number-to-string (plist-get chat :id)))
         :description (telega-org--title chat))
        t))))

(defun telega-org-link-export (link description format _)
  "Export a telega link, which is a chat id and means nothing abroad.
The HTML, LaTeX and Texinfo backends get a t.me URL, which is the one
place a chat id is still actionable outside telega; ASCII has no such
place and prints the link as Org spells it, the way those backends
print any other link they cannot follow."
  (let* ((desc (or description link))
         (chat-id (telega-org--link-path link))
         (url (or telega-org-export-base-url "https://t.me/")))
    (pcase format
      (`html (format "<a href=\"%s\">%s</a>" (concat url chat-id) desc))
      (`latex (format "\\href{%s}{%s}" (concat url chat-id) desc))
      (`texinfo (format "@uref{%s,%s}" (concat url chat-id) desc))
      (`ascii (format "%s (telega:%s)" desc chat-id))
      (_ desc))))

;;;###autoload
(org-link-set-parameters
 "telega"
 :follow #'telega-org-link-follow
 :store #'telega-org-link-store
 :export #'telega-org-link-export
 :complete #'telega-org-link-complete)

;;;; The telega-org dynamic block

;; A chat list that lives in your own notes rather than in a buffer of
;; its own: put this block in any Org file, and C-c C-x C-u rewrites it
;; with the chats of the moment.  It is the same text the chat list
;; buffer holds, so folding, tags and the telega: link all work in it.
;;
;;   #+BEGIN: telega-org
;;   #+END:

(defun org-dblock-write:telega-org (_params)
  "Write the chat list into the dynamic block at point.
_PARAMS are Org's - the block name, anything on its \"#+BEGIN:\" line,
the text the block held before it, and its indentation - and none of
them is read: the block always shows the grouped chat list, so it stays
the same text as the chat list buffer and needs no second set of options."
  (dolist (bucket (telega-org--group-chats (telega-org--chats)))
    (insert "* " (car bucket) "\n")
    (dolist (chat (cdr bucket))
      (insert (telega-org--chat-lines chat) "\n"))))

;;;###autoload
(defun telega-org-insert-chat-list ()
  "Insert a telega-org dynamic block at point, then fill it in.
The block is any Org file's copy of the chat list: update it later with
\\[org-dblock-update] or `org-update-all-dblocks'."
  (interactive)
  ;; Point sits after `#+END:' once both lines are in, and
  ;; `org-dblock-update' searches backwards from point, so step back onto
  ;; the BEGIN line for it to find the block at all.
  (insert "#+BEGIN: telega-org\n#+END:\n")
  (forward-line -2)
  (org-dblock-update))

(provide 'telega-org)
;;; telega-org.el ends here