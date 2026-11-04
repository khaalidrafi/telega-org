;;; test.el --- ert tests for telega-org  -*- lexical-binding:t -*-

;; Copyright (C) 2026 by Khalid Rafi
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Pure elisp tests: no telega-server, no Telegram account, and not even
;; telega itself.  The stubs below are the public API that telega-org
;; declares, reduced to the shape the tests feed them, so the tests run
;; anywhere Emacs does.
;;
;; Run with:  make test
;;   or:  emacs --batch -L . -l test -f ert-run-tests-batch-and-exit

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'telega-org)

(defvar telega-org-test--chats nil
  "What the stub of `telega-chats-list' returns.")

(defvar telega-org-test--order-dirty nil
  "What the stub of `telega-chat-order-dirty-p' returns.")

(defvar telega-org-test--calls nil
  "Telega commands the code under test called, most recent first.")

(defun telega-org-test--chat (id title &rest props)
  "Return a chat plist for ID named TITLE, with PROPS.
The shape TDLib hands over is all that matters here: the renderer only
ever reads plists."
  (append (list :@type "chat" :id id :title title) props))

(defun telega-org-test--message (date text &optional by-me content-type)
  "Return a message plist sent at DATE.
TEXT is its text, or nil for a message whose CONTENT-TYPE says what it
is instead, such as \"Photo\"."
  (list :@type "message"
        :date date
        :is_outgoing (and by-me t)
        :content (cond (text (list :@type "messageText" :text text))
                       (content-type
                        (list :@type (concat "message" content-type))))))

(defun telega-org-test--match-p (chat temex)
  "Stub of `telega-chat-match-p', for the temexes the tests group with.
A temex is a symbol, a list of one symbol like the (is-pinned) the
groups use, or a list starting with a symbol, of which `unread' takes
an optional N - which is what `telega-chat-match-p' takes."
  (when (and (consp temex) (symbolp (car temex)) (null (cdr temex)))
    (setq temex (car temex)))
  (cond ((eq temex 'is-pinned) (plist-get chat :pinned))
        ((eq temex 'muted) (plist-get chat :muted))
        ((eq temex 'is-known) (not (plist-get chat :archived)))
        ((eq temex 'main) t)
        ((or (eq temex 'unread) (and (consp temex) (eq (car temex) 'unread)))
         ;; N is optional, and 1 when it is left out
         (>= (or (plist-get chat :unread_count) 0)
             (if (consp temex) (or (cadr temex) 1) 1)))
        ((or (eq temex 'mention) (and (consp temex) (eq (car temex) 'mention)))
         (>= (or (plist-get chat :unread_mention_count) 0)
             (if (consp temex) (or (cadr temex) 1) 1)))
        ((and (consp temex) (eq (car temex) 'not))
         (not (telega-org-test--match-p chat (cadr temex))))
        ((and (consp temex) (eq (car temex) 'or))
         (seq-some (lambda (one) (telega-org-test--match-p chat one))
                   (cdr temex)))
        (t (error "telega-org-test: unhandled temex %S groups %S" temex telega-org-groups))))

(defmacro telega-org-test--with-stubs (&rest body)
  "Run BODY with the public telega API stubbed out.
Binds the variables the stubs read, and records what the commands stub
the code under test would call in `telega-org-test--calls'."
  (declare (indent 0))
  `(let ((telega-date-format-alist '((today . "%H:%M")
                                     (time . "%d %b")
                                     (old . "%d.%m.%y")))
         (telega-org-test--calls nil)
         (telega-org-test--order-dirty nil)
         (telega-org-test--chats telega-org-test--chats))
     (cl-letf (((symbol-function 'telega-chats-list)
                (lambda () telega-org-test--chats))
               ((symbol-function 'telega-filter-chats)
                (lambda (chats &rest _) chats))
               ((symbol-function 'telega-sort-chats)
                (lambda (_ chats) chats))
               ((symbol-function 'telega-chat-order-dirty-p)
                (lambda () telega-org-test--order-dirty))
               ((symbol-function 'telega-chat-p)
                (lambda (obj) (equal "chat" (plist-get obj :@type))))
               ((symbol-function 'telega-chat-title)
                (lambda (chat &optional _fmt no-badges)
                  ;; badges arrive unless the caller asks for none
                  (let ((title (plist-get chat :title)))
                    (propertize (if no-badges title (concat title " 🔕"))
                                'face 'bold))))
               ((symbol-function 'telega-chat-match-p)
                #'telega-org-test--match-p)
               ((symbol-function 'telega-symbol)
                (lambda (ending &optional _) (if (eq ending 'pin) "P" "?")))
               ((symbol-function 'telega-server-live-p) (lambda () t))
               ((symbol-function 'telega-msg-p)
                (lambda (obj) (equal "message" (plist-get obj :@type))))
               ((symbol-function 'telega-msg-chat)
                (lambda (msg) (plist-get msg :chat)))
               ((symbol-function 'telega-msg-content-text)
                (lambda (msg) (plist-get (plist-get msg :content) :text)))
               ((symbol-function 'telega-msg-by-me-p)
                (lambda (msg) (plist-get msg :is_outgoing)))
               ((symbol-function 'telega-chat-with)
                (lambda (chat) (push (cons 'telega-chat-with (plist-get chat :id))
                                     telega-org-test--calls)))
               ((symbol-function 'telega-chat-toggle-read)
                (lambda (chat) (push (cons 'telega-chat-toggle-read (plist-get chat :id))
                                     telega-org-test--calls)))
               ((symbol-function 'telega-completing-read-chat)
                (lambda (prompt &optional _chats _criteria)
                  (seq-find (lambda (chat)
                              (string-match-p (regexp-quote prompt)
                                              (plist-get chat :title)))
                            telega-org-test--chats)))
               ((symbol-function 'telega-chat-get)
                (lambda (chat-id &optional _offline)
                  (seq-find (lambda (chat)
                              (equal chat-id (plist-get chat :id)))
                            telega-org-test--chats)))
               ((symbol-function 'org-link-store-props)
                (lambda (&rest props)
                  (push (cons 'org-link-store-props props)
                        telega-org-test--calls))))
       ,@body)))

(defmacro telega-org-test--with-buffer (&rest body)
  "Run BODY in a `telega-org-mode' buffer."
  (declare (indent 0))
  `(with-temp-buffer
     (telega-org-mode)
     (setq telega-org--dirty-all nil)
     (clrhash telega-org--dirty)
     (when telega-org--timer
       (cancel-timer telega-org--timer)
       (setq telega-org--timer nil))
     ,@body))

;;;; One chat

(ert-deftest telega-org-title-test ()
  "Test the title is plain text: no badges, no faces carried over.
A title keeping the face `telega-chat-title' puts on it would hide the
face this package chooses, and a badge would read as part of the name."
  (telega-org-test--with-stubs
    (should (equal (telega-org--title (telega-org-test--chat 1 " Alice  "))
                   "Alice"))
    (should-not (get-text-property 0 'face
                                   (telega-org--title (telega-org-test--chat 1 "Alice"))))))

(ert-deftest telega-org-tags-test ()
  "Test the Org tags of a chat: mute, unread count, mentions."
  (telega-org-test--with-stubs
    (should (equal (telega-org--tags (telega-org-test--chat 1 "Alice")) ""))
    (should (equal (telega-org--tags (telega-org-test--chat 1 "Alice" :pinned t))
                   ""))
    (should (equal (telega-org--tags (telega-org-test--chat 1 "Alice" :muted t))
                   ":mute:"))
    (should (equal (telega-org--tags (telega-org-test--chat 1 "Alice" :unread_count 3))
                   ":unread:3:"))
    (should (equal (telega-org--tags (telega-org-test--chat 1 "Alice"
                                                  :unread_mention_count 1
                                                  :unread_count 3))
                   ":unread:3::mention:1:"))
    ;; zero is what telega-server reports for a value it left out, and
    ;; must not show up as ":unread:0:"
    (should (equal (telega-org--tags (telega-org-test--chat 1 "Alice" :unread_count 0))
                   ""))))

(ert-deftest telega-org-message-text-test ()
  "Test a message is one line of text, or a word for its kind.
A chat whose last message is a photo should say so, rather than read
as if nothing had been said."
  (telega-org-test--with-stubs
    (let ((now (float-time)))
      (should (equal (telega-org--message-text
                      (telega-org-test--message now "hi")) "hi"))
      (should (equal (telega-org--message-text
                      (telega-org-test--message now nil nil "Photo"))
                     "Photo"))
      (should (equal (telega-org--message-text
                      (telega-org-test--message now nil nil "Sticker"))
                     "Sticker"))
      (should (equal (telega-org--message-text
                      (telega-org-test--message now nil nil nil))
                     ""))
      ;; telega may hand the text over with its own faces on it; the
      ;; preview must not carry them behind the faces this package sets
      ;; (standard section 8: backend text properties are stripped).
      ;; Two properties: a partial implementation (say, one that only
      ;; removed the face) must not pass.
      (let ((stripped (telega-org--message-text
                       (telega-org-test--message
                        now (propertize "hi" 'face 'bold
                                        'keymap '(keymap (t . ignore)))))))
        ;; content survives the strip: equal ignores text properties,
        ;; so this is the content check the property checks cannot be
        (should (equal stripped "hi"))
        (should-not (get-text-property 0 'face stripped))
        (should-not (get-text-property 0 'keymap stripped))))))

(ert-deftest telega-org-time-test ()
  "Test a message is stamped with today, this week, or a date."
  (telega-org-test--with-stubs
    (should (equal (telega-org--time (float-time))
                   (format-time-string "%H:%M")))
    ;; format the same instant the same way the renderer does: the
    ;; expected string must not drift by a day over UTC
    (let ((then (- (float-time) (* 2 24 3600))))
      (should (equal (telega-org--time then)
                     (format-time-string "%d %b" then))))
    (let ((then (- (float-time) (* 40 24 3600))))
      (should (equal (telega-org--time then)
                     (format-time-string "%d.%m.%y" then))))))

(ert-deftest telega-org-heading-test ()
  "Test one chat as one Org heading, with its tags and a face."
  (telega-org-test--with-stubs
    (should (equal (telega-org--heading (telega-org-test--chat 1 "Alice"))
                   "** Alice"))
    (should (equal (telega-org--heading
                    (telega-org-test--chat 1 "Alice" :pinned t :unread_count 2))
                   "** P Alice :unread:2:"))
    ;; a mention is the louder news, so it takes the face
    (let ((heading (telega-org--heading
                    (telega-org-test--chat 1 "Alice" :unread_count 2
                                           :unread_mention_count 1))))
      (should (string-prefix-p "** Alice" heading))
      (should (equal (get-text-property 3 'face heading)
                     'telega-org-mention-face)))
    ;; and the chat last opened is underlined, not bold
    (let* ((chat (telega-org-test--chat 1 "Alice"))
           (telega-org-current-chat chat)
           (heading (telega-org--heading chat)))
      (should (equal (get-text-property 3 'face heading)
                     'telega-org-current-face)))))

;;;; The list

(ert-deftest telega-org-groups-test ()
  "Test a chat lands in the first group it matches, and in none if it matches none.
That is what keeps a pinned unread chat from being listed twice."
  (telega-org-test--with-stubs
    (let ((telega-org-groups '(("Pinned" . (is-pinned))
                              ("Unread" . (unread))
                              ("Chats"  . nil))))
      (should (equal (car (telega-org--group-of
                           (telega-org-test--chat 1 "A" :pinned t)))
                     "Pinned"))
      (should (equal (car (telega-org--group-of
                           (telega-org-test--chat 2 "B" :pinned t :unread_count 4)))
                     "Pinned"))
      (should (equal (car (telega-org--group-of
                           (telega-org-test--chat 3 "C" :unread_count 4)))
                     "Unread"))
      (should (equal (car (telega-org--group-of (telega-org-test--chat 4 "D")))
                     "Chats")))
    (let ((telega-org-groups '(("Unread" . (unread)))))
      (should-not (telega-org--group-of (telega-org-test--chat 4 "D"))))))

(ert-deftest telega-org-group-chats-test ()
  "Test the chat list is grouped, in order, and empty groups are dropped."
  (telega-org-test--with-stubs
    (let* ((telega-org-groups '(("Pinned" . (is-pinned))
                                ("Unread" . (unread))
                                ("Chats"  . nil)))
           (telega-org-test--chats
           (list (telega-org-test--chat 1 "Alice")
                 (telega-org-test--chat 2 "Bob" :pinned t)
                 (telega-org-test--chat 3 "Carol" :unread_count 1))))
      (should (equal (mapcar #'car (telega-org--group-chats telega-org-test--chats))
                     '("Pinned" "Unread" "Chats")))
      (should (equal (mapcar (lambda (bucket)
                               (mapcar (lambda (chat) (plist-get chat :id))
                                       (cdr bucket)))
                             (telega-org--group-chats telega-org-test--chats))
                     '((2) (3) (1)))))))

(ert-deftest telega-org-buffer-test ()
  "Test the buffer is one heading per group, two lines per chat."
  (telega-org-test--with-stubs
    ;; one fixed instant, so the %H:%M the renderer stamps cannot roll
    ;; over to another minute between rendering and the expectation
    (let* ((now (float-time))
           (telega-org-groups '(("Chats" . nil)))
           (telega-org-test--chats
            (list (telega-org-test--chat 1 "Alice"
                                         :last_message (telega-org-test--message
                                                        now "hi" t))
                  (telega-org-test--chat 2 "Bob"
                                         :unread_count 2
                                         :last_message (telega-org-test--message
                                                        now "hey")))))
      (telega-org-test--with-buffer
        (telega-org-refresh)
        (goto-char (point-min))
        (should (looking-at "\\* Chats"))
        (forward-line 1)
        (should (string-prefix-p "** Alice" (thing-at-point 'line t)))
        ;; one heading line and one preview line per chat, no blanks:
        ;; Alice sent the last message, so her preview carries the
        ;; outgoing arrow, and Bob's incoming one the down arrow
        ;; (standard section 3.4)
        (let ((stamp (format "%-7s" (format-time-string "%H:%M" now))))
          (should (equal (buffer-string)
                         (format (concat "* Chats\n"
                                         "** Alice\n  %s↑ hi\n"
                                         "** Bob :unread:2:\n  %s↓ hey\n")
                                 stamp stamp))))))))

(ert-deftest telega-org-preview-arrow-test ()
  "Test the preview carries the direction arrow (standard section 3.4).
Outgoing points up, incoming down - the incoming one used to render as
two blanks, which read as missing grammar, not as an arrow.  The faces
ride their roles: time face on the time, preview face on the text, and
nothing where the arrow sits - the arrow is grammar text, and section 6
has no arrow role (the old bold `telega-org-unread-face' on the
outgoing arrow read \"unread\", a tag's job, not an arrow's)."
  (telega-org-test--with-stubs
    (let* ((now (float-time))
           (out (telega-org--preview
                 (telega-org-test--chat 1 "Alice"
                                        :last_message
                                        (telega-org-test--message now "hi" t))))
           (in (telega-org--preview
                (telega-org-test--chat 2 "Bob"
                                       :last_message
                                       (telega-org-test--message now "hey")))))
      (should (string-match-p "↑" out))
      (should (string-match-p "↓" in))
      ;; no face where the arrow sits - read at the arrow's own
      ;; position, not at offset 0, which is the uncolored leading
      ;; spaces and would pass even with a colored arrow
      (should-not (get-text-property (string-match-p "↑" out) 'face out))
      (should-not (get-text-property (string-match-p "↓" in) 'face in))
      ;; the roles keep their faces: time after the two leading spaces,
      ;; preview on the message text
      (should (eq (get-text-property 2 'face out)
                  'telega-org-time-face))
      (should (eq (get-text-property (string-match-p "hi" out) 'face out)
                  'telega-org-preview-face)))))

(ert-deftest telega-org-undo-disabled-test ()
  "The list buffer keeps undo disabled (standard section 8).
telega's update hooks redraw the list on the idle timer: with undo on,
every redraw would pile up undo entries nobody wants to walk back."
  (telega-org-test--with-stubs
    (telega-org-test--with-buffer
      (should (eq buffer-undo-list t))
      (let ((telega-org-groups '(("Chats" . nil)))
            (telega-org-test--chats (list (telega-org-test--chat 1 "Alice"))))
        (telega-org-refresh)
        (should (eq buffer-undo-list t))))))

(ert-deftest telega-org-chat-at-point-test ()
  "Test the chat at point, on the title and on the preview below it,
and nil on a group heading."
  (telega-org-test--with-stubs
    (let* ((telega-org-groups '(("Pinned" . (is-pinned))
                                ("Chats"  . nil)))
           (telega-org-test--chats
           (list (telega-org-test--chat 1 "Alice")
                 (telega-org-test--chat 2 "Bob" :pinned t))))
      (telega-org-test--with-buffer
        (telega-org-refresh)
        (goto-char (point-min))
        (should-not (telega-org--chat-at-point))
        ;; Pinned, Bob, then its preview, then Chats, Alice
        (search-forward "Bob")
        (should (equal (plist-get (telega-org--chat-at-point) :id) 2))
        (forward-line 1)
        (should (equal (plist-get (telega-org--chat-at-point) :id) 2))
        (search-forward "Alice")
        (should (equal (plist-get (telega-org--chat-at-point) :id) 1))))))

(ert-deftest telega-org-first-unread-test ()
  "Test point lands on the first unread chat when the list is opened."
  (telega-org-test--with-stubs
    (let* ((telega-org-groups '(("Chats" . nil)))
           (telega-org-test--chats
           (list (telega-org-test--chat 1 "Alice")
                 (telega-org-test--chat 2 "Bob" :unread_count 1))))
      (telega-org-test--with-buffer
        (telega-org-refresh)
        (should (equal (plist-get (telega-org--chat-at-point) :id) 2))))))

(ert-deftest telega-org-filter-test ()
  "Test the filter keeps the chats whose title matches, and empties out."
  (telega-org-test--with-stubs
    (let* ((telega-org-groups '(("Chats" . nil)))
           (telega-org-test--chats
           (list (telega-org-test--chat 1 "Alice")
                 (telega-org-test--chat 2 "Bob"))))
      (telega-org-test--with-buffer
        (let ((telega-org-filter-regexp "Ali"))
          (telega-org-refresh)
          (should (string-match-p "Alice" (buffer-string)))
          (should-not (string-match-p "Bob" (buffer-string))))
        (setq telega-org-filter-regexp nil)
        (telega-org-refresh)
        (should (string-match-p "Bob" (buffer-string)))))))

(ert-deftest telega-org-update-test ()
  "Test an update rewrites the two lines of one chat, and leaves the
rest of the buffer exactly where it was."
  (telega-org-test--with-stubs
    (let* ((telega-org-groups '(("Chats" . nil)))
           (telega-org-test--chats
           (list (telega-org-test--chat 1 "Alice")
                 (telega-org-test--chat 2 "Bob"
                                         :last_message
                                         (telega-org-test--message
                                          (float-time) "before")))))
      (telega-org-test--with-buffer
        (telega-org-refresh)
        (let ((bob (gethash 2 telega-org--locations))
              (alice (gethash 1 telega-org--locations)))
          ;; Bob gets a new message
          (puthash 2 (telega-org-test--chat 2 "Bob" :unread_count 1
                                          :last_message
                                          (telega-org-test--message
                                           (float-time) "after"))
                   telega-org--chats-cache)
          (puthash 2 t telega-org--dirty)
          (telega-org--flush)
          (should (string-match-p "after" (buffer-string)))
          (should-not (string-match-p "before" (buffer-string)))
          ;; both chats are still where they were, Bob still is two
          ;; lines long, and Alice was not touched
          (should (equal alice (gethash 1 telega-org--locations)))
          (should (equal (car bob) (car (gethash 2 telega-org--locations)))))))))

(ert-deftest telega-org-update-nothing-test ()
  "Test an update that changes nothing leaves the buffer untouched.
TDLib repeats unchanged chats on every update, so this is the common
case: it must not redraw the whole list."
  (telega-org-test--with-stubs
    (let* ((telega-org-groups '(("Chats" . nil)))
           (telega-org-test--chats (list (telega-org-test--chat 1 "Alice"))))
      (telega-org-test--with-buffer
        (telega-org-refresh)
        (puthash 1 t telega-org--dirty)
        (should-not telega-org--dirty-all)
        (telega-org--flush)
        (should-not telega-org--dirty-all)))))

(ert-deftest telega-org-update-group-change-test ()
  "Test a chat moving between groups redraws the list, because a
heading has to appear or disappear."
  (telega-org-test--with-stubs
    (let* ((telega-org-groups '(("Pinned" . (is-pinned))
                                ("Chats"  . nil)))
           (telega-org-test--chats (list (telega-org-test--chat 1 "Alice"))))
      (telega-org-test--with-buffer
        (telega-org-refresh)
        (should-not (string-match-p "Pinned" (buffer-string)))
        ;; telega keeps its own chat list fresh as it reports updates,
        ;; and a full redraw reads it back: say the chat is pinned now
        (setq telega-org-test--chats
              (list (telega-org-test--chat 1 "Alice" :pinned t)))
        (puthash 1 (telega-org-test--chat 1 "Alice" :pinned t) telega-org--chats-cache)
        (puthash 1 t telega-org--dirty)
        (telega-org--flush)
        (should (string-match-p "^\\* Pinned" (buffer-string)))
        (should-not (equal (gethash 1 telega-org--groups) "Chats"))))))

(ert-deftest telega-org-update-order-dirty-test ()
  "Test a stale chat order redraws the whole list, so the most recent
chat comes first."
  (telega-org-test--with-stubs
    (let* ((telega-org-groups '(("Chats" . nil)))
           (telega-org-test--chats (list (telega-org-test--chat 1 "Alice")))
           (telega-org-test--order-dirty t))
      (telega-org-test--with-buffer
        (telega-org-refresh)
        (telega-org--flush)
        ;; a full redraw empties and rebuilds the caches, so the chat is
        ;; back in them only through the chat list, and the ids are gone
        ;; from the stale state
        (should (hash-table-count telega-org--locations))))))

;;;; Commands

(ert-deftest telega-org-open-test ()
  "Test opening a chat marks it as the current one, and hands it to telega."
  (telega-org-test--with-stubs
    (let* ((telega-org-groups '(("Chats" . nil)))
           (telega-org-test--chats (list (telega-org-test--chat 1 "Alice")
                                         (telega-org-test--chat 2 "Bob"))))
      (telega-org-test--with-buffer
        (telega-org-refresh)
        (search-forward "Alice")
        (telega-org-open)
        (should (equal telega-org-test--calls '((telega-chat-with . 1))))
        (should (equal (plist-get telega-org-current-chat :id) 1))
        ;; and its heading is underlined now
        (goto-char (point-min))
        (search-forward "Alice")
        (should (equal (get-text-property (- (point) 1) 'face)
                       'telega-org-current-face))))))

(ert-deftest telega-org-mark-read-test ()
  "Test mark read asks telega to toggle the chat at point."
  (telega-org-test--with-stubs
    (let* ((telega-org-groups '(("Chats" . nil)))
           (telega-org-test--chats (list (telega-org-test--chat 1 "Alice"
                                                    :unread_count 2))))
      (telega-org-test--with-buffer
        (telega-org-refresh)
        (search-forward "Alice")
        (telega-org-mark-read)
        (should (equal telega-org-test--calls '((telega-chat-toggle-read . 1))))))))

(ert-deftest telega-org-quit-test ()
  "q buries the list buffer and never kills it (standard section 8).
telega is an add-on dependency, so quitting the list must leave the
backend alone: the buffer survives, at the end of the buffer list."
  (telega-org-test--with-stubs
    (telega-org-test--with-buffer
      (let ((buf (current-buffer)))
        (telega-org-quit)
        (should (buffer-live-p buf))
        (should (eq buf (car (last (buffer-list)))))))))

(ert-deftest telega-org-switch-chat-test ()
  "Test the completing command finds the chat and opens it."
  (telega-org-test--with-stubs
    (let* ((telega-org-groups '(("Chats" . nil)))
           (telega-org-test--chats (list (telega-org-test--chat 1 "Alice")
                                         (telega-org-test--chat 2 "Bob"))))
      (telega-org-test--with-buffer
        (telega-org-refresh)
        (telega-org-switch-chat "Bob")
        (should (equal telega-org-test--calls '((telega-chat-with . 2))))))))

(ert-deftest telega-org-open-not-on-chat-test ()
  "Test opening on a group heading is an error, not a random chat."
  (telega-org-test--with-stubs
    (let ((telega-org-groups '(("Chats" . nil)))
          (telega-org-test--chats (list (telega-org-test--chat 1 "Alice"))))
      (telega-org-test--with-buffer
        (telega-org-refresh)
        (goto-char (point-min))
        (should-error (telega-org-open) :type 'user-error)))))

(ert-deftest telega-org-move-chat-test ()
  "Test the next and previous chat skip the group headings."
  (telega-org-test--with-stubs
    (let* ((telega-org-groups '(("Pinned" . (is-pinned))
                                ("Chats"  . nil)))
           (telega-org-test--chats (list (telega-org-test--chat 1 "Alice")
                                         (telega-org-test--chat 2 "Bob" :pinned t)
                                         (telega-org-test--chat 3 "Carol"))))
      (telega-org-test--with-buffer
        (telega-org-refresh)
        (goto-char (point-min))
        (telega-org-next-chat)
        (should (equal (plist-get (telega-org--chat-at-point) :id) 2))
        (telega-org-next-chat)
        (should (equal (plist-get (telega-org--chat-at-point) :id) 1))
        (telega-org-previous-chat)
        (should (equal (plist-get (telega-org--chat-at-point) :id) 2))))))

(ert-deftest telega-org-jump-to-unread-test ()
  "Test jump-to-unread visits every unread chat and wraps around.
A mention counts as unread too, so a chat with only a mention is not
skipped."
  (telega-org-test--with-stubs
    (let* ((telega-org-groups '(("Chats" . nil)))
           (telega-org-test--chats
            (list (telega-org-test--chat 1 "Alice")
                  (telega-org-test--chat 2 "Bob" :unread_count 2)
                  (telega-org-test--chat 3 "Carol" :unread_mention_count 1))))
      (telega-org-test--with-buffer
        (telega-org-refresh)
        (goto-char (point-min))
        (forward-line 1)                ; Alice, the only chat with no tag
        (telega-org-jump-to-unread)
        (should (equal (plist-get (telega-org--chat-at-point) :id) 2))
        (telega-org-jump-to-unread)
        (should (equal (plist-get (telega-org--chat-at-point) :id) 3))
        ;; the last unread leads back to the first, not out of the list
        (telega-org-jump-to-unread)
        (should (equal (plist-get (telega-org--chat-at-point) :id) 2))))))

(ert-deftest telega-org-jump-to-unread-none-test ()
  "Test jump-to-unread says so when nothing is unread."
  (telega-org-test--with-stubs
    (let ((telega-org-groups '(("Chats" . nil)))
          (telega-org-test--chats (list (telega-org-test--chat 1 "Alice"))))
      (telega-org-test--with-buffer
        (telega-org-refresh)
        (should-error (telega-org-jump-to-unread) :type 'user-error)))))

(ert-deftest telega-org-sparse-tree-test ()
  "Test the sparse tree hides the chats that do not match the query.
The tags on each heading are the query language, so no chat list code
is involved beyond calling Org's own `org-match-sparse-tree'."
  (telega-org-test--with-stubs
    (let* ((telega-org-groups '(("Chats" . nil)))
           (telega-org-test--chats
            (list (telega-org-test--chat 1 "Alice")
                  (telega-org-test--chat 2 "Bob" :unread_count 2))))
      (telega-org-test--with-buffer
        (telega-org-refresh)
        (telega-org-sparse-tree "unread")
        (goto-char (point-min))
        (search-forward "Alice")
        (should (get-char-property (line-beginning-position) 'invisible))
        (goto-char (point-min))
        (search-forward "Bob")
        (should-not (get-char-property (line-beginning-position) 'invisible))
        ;; an empty query shows the whole list again
        (telega-org-sparse-tree "")
        (goto-char (point-min))
        (search-forward "Alice")
        (should-not (get-char-property (line-beginning-position) 'invisible))))))

(ert-deftest telega-org-columns-test ()
  "Test column view uses the configured format and Org's own command.
The view itself is an overlay, which a batch run has no window to draw,
so the test watches what the command does: put point before the first
headline, so the view spans the whole list, and hand over to
`org-columns'."
  (telega-org-test--with-stubs
    (let ((telega-org-groups '(("Chats" . nil)))
          (telega-org-test--chats (list (telega-org-test--chat 1 "Alice"))))
      (telega-org-test--with-buffer
        ;; the mode makes Org's own `org-columns' work on the list too
        (should (equal org-columns-default-format telega-org-columns-format))
        (telega-org-refresh)
        (goto-char (point-max))
        (cl-letf (((symbol-function 'org-columns)
                   (lambda (&optional _)
                     (push (list 'org-columns (line-number-at-pos))
                           telega-org-test--calls))))
          (telega-org-columns)
          (should (equal telega-org-test--calls '((org-columns 1)))))))))

(ert-deftest telega-org-keymap-test ()
  "Test the chat list keys are bound, so muscle memory carries over."
  (telega-org-test--with-stubs
    (telega-org-test--with-buffer
      (dolist (key '("RET" "o" "n" "p" "g" "j" "q" "u" "c" "m" "r" "s"
                     "C-c /" "C-c C-c"))
        (should (commandp (lookup-key telega-org-mode-map (kbd key)))))
      ;; the standard section 7 verbs are the ones the standard names:
      ;; g refresh, j jump to first unread, q quit - r and u stay as the
      ;; pre-standard spellings
      (should (eq (lookup-key telega-org-mode-map (kbd "g"))
                  #'telega-org-refresh))
      (should (eq (lookup-key telega-org-mode-map (kbd "j"))
                  #'telega-org-jump-to-unread))
      (should (eq (lookup-key telega-org-mode-map (kbd "q"))
                  #'telega-org-quit))
      ;; column view is Org's own key, inherited by the derived mode
      (should (commandp (lookup-key telega-org-mode-map (kbd "C-c C-x C-c")))))))

;;;; The telega: Org link

(ert-deftest telega-org-link-follow-test ()
  "Test following a telegram link opens the chat it names in telega.
A link like \"telega:42\" is a chat id and nothing else, so following
it looks the id up in telega's own cache and opens that chat."
  (telega-org-test--with-stubs
    (let ((telega-org-test--chats (list (telega-org-test--chat 1 "Alice"))))
      (telega-org-test--with-buffer
        (telega-org-refresh)
        (telega-org-link-follow "1" nil)
        (should (equal telega-org-test--calls '((telega-chat-with . 1))))
        (should-error (telega-org-link-follow "42" nil) :type 'user-error)))))

(ert-deftest telega-org-link-path-test ()
  "Test the link path is the chat id, with the optional message id
after \"::\" dropped - it is TDLib's, not used yet."
  (should (equal (telega-org--link-path "42") "42"))
  (should (equal (telega-org--link-path "42::0") "42")))

(ert-deftest telega-org-link-export-test ()
  "Test a chat id becomes a t.me URL abroad, and stays a link in ASCII.
The chat list's own text is shown for the formats without a URL syntax."
  (telega-org-test--with-stubs
    (should (equal (telega-org-link-export "42" "Alice" 'html nil)
                   "<a href=\"https://t.me/42\">Alice</a>"))
    (should (equal (telega-org-link-export "42" "Alice" 'latex nil)
                   "\\href{https://t.me/42}{Alice}"))
    (should (equal (telega-org-link-export "42" "Alice" 'ascii nil)
                   "Alice (telega:42)"))
    (let ((telega-org-export-base-url "https://example.org/chat/"))
      (should (equal (telega-org-link-export "42" "Alice" 'html nil)
                     "<a href=\"https://example.org/chat/42\">Alice</a>")))))

(ert-deftest telega-org-link-store-test ()
  "Test storing a link from a chat line remembers the chat and its title."
  (telega-org-test--with-stubs
    (let ((telega-org-groups '(("Chats" . nil)))
          (telega-org-test--chats (list (telega-org-test--chat 1 "Alice"))))
      (telega-org-test--with-buffer
        (telega-org-refresh)
        (search-forward "Alice")
        (should (telega-org-link-store))
        (should (equal telega-org-test--calls
                       (list (cons 'org-link-store-props
                                   (list :type "telega" :link "telega:1"
                                         :description "Alice")))))))))

(ert-deftest telega-org-link-complete-test ()
  "Test link completion is the chat list read through the same filtered,
sorted list the buffer shows."
  (telega-org-test--with-stubs
    (let ((telega-org-test--chats (list (telega-org-test--chat 1 "Alice"))))
      (cl-letf (((symbol-function 'telega-completing-read-chat)
                 (lambda (_prompt &optional _chats _criteria)
                   (car telega-org-test--chats))))
        (should (equal (telega-org-link-complete) "1"))))))

;;;; The telega-org dynamic block

(ert-deftest telega-org-dblock-test ()
  "Test the dynamic block writes the chat list into an Org file.
The block is any Org file's copy of the chat list buffer, so the text
is the same, and Org's folding, tags and links work in it too."
  (telega-org-test--with-stubs
    (let* ((telega-org-groups '(("Chats" . nil)))
           (telega-org-test--chats (list (telega-org-test--chat 1 "Alice"))))
      (with-temp-buffer
        (org-mode)
        (insert "before\n#+BEGIN: telega-org\n#+END:\nafter\n")
        (goto-char (point-min))
        (re-search-forward "^#\\+BEGIN" nil t)
        (org-dblock-update)
        (should (string-match-p "^\\* Chats" (buffer-string)))
        (should (string-match-p "^\\*\\* Alice" (buffer-string)))))))

(ert-deftest telega-org-insert-chat-list-test ()
  "Test inserting a chat list block fills it in on the spot."
  (telega-org-test--with-stubs
    (let ((telega-org-groups '(("Chats" . nil)))
          (telega-org-test--chats (list (telega-org-test--chat 1 "Alice"))))
      (with-temp-buffer
        (org-mode)
        (telega-org-insert-chat-list)
        (should (string-match-p "#\\+BEGIN: telega-org" (buffer-string)))
        (should (string-match-p "^\\*\\* Alice" (buffer-string)))))))

;;;; Touch

(ert-deftest telega-org-touch-detect-test ()
  "Test touch detection: the Android app by `system-type', Termux by
env, and nothing in a plain batch on this Linux machine."
  (telega-org-test--with-stubs
    ;; emacs --batch runs on a dumb terminal: no touch parameter
    (should-not (telega-org--touch-device-p))
    ;; the org.gnu.emacs app: configure sets SYSTEM_TYPE=android for it
    (let ((system-type 'android))
      (should (telega-org--touch-device-p)))
    ;; Emacs run as a Termux package sees the shell's variable
    (cl-letf (((symbol-function 'getenv)
               (lambda (name)
                 (when (equal name "TERMUX_VERSION") "0.134"))))
      (should (telega-org--touch-device-p)))))

(ert-deftest telega-org-touch-setup-test ()
  "Test the buffer adapts to a touch device: tap keys, smooth
scrolling and no wrapped lines on the narrow screen."
  (telega-org-test--with-stubs
    (cl-letf (((symbol-function 'getenv)
               (lambda (name)
                 (when (equal name "TERMUX_VERSION") "0.134"))))
      (telega-org-test--with-buffer
        (should (eq truncate-lines t))
        (should (local-variable-p 'truncate-lines))
        (should (eq scroll-conservatively 101))
        (should (commandp (lookup-key telega-org-mode-map [mouse-1])))
        (should (commandp (lookup-key telega-org-mode-map [mouse-3])))))))

(ert-deftest telega-org-tap-test ()
  "Test a tap opens a chat and folds a group, and that neither
happens off to the side of everything."
  (telega-org-test--with-stubs
    (let* ((telega-org-groups '(("Pinned" . (is-pinned))
                                ("Chats"  . nil)))
           (telega-org-test--chats
            (list (telega-org-test--chat 1 "Alice")
                  (telega-org-test--chat 2 "Bob" :pinned t))))
      (telega-org-test--with-buffer
        (telega-org-refresh)
        (cl-letf (((symbol-function 'org-cycle)
                   (lambda () (push 'org-cycle telega-org-test--calls))))
          ;; the first line is the Pinned group: fold, do not open
          (goto-char (point-min))
          (telega-org-tap)
          (should (equal telega-org-test--calls '(org-cycle)))
          ;; a chat opens, and its empty preview line taps as itself
          (search-forward "Alice")
          (telega-org-tap)
          (should (equal telega-org-test--calls
                         (list (cons 'telega-chat-with 1) 'org-cycle))))))))

(provide 'telega-org-test)
;;; test.el ends here