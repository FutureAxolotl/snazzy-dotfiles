;;; discord-emacs.el --- Discord ipc for emacs -*- lexical-binding: t -*-
;; Author: Ben Simms <ben@bensimms.moe>
;; Version: 20210522
;; URL: https://github.com/nitros12/discord-emacs.el
;;
;;; Commentary:

;; Discord rich presence for Emacs.

(require 'json)
(require 'bindat)
(require 'cl-lib)

;;; Code:

(defgroup discord-emacs nil
  "Discord rich presence for Emacs."
  :prefix "discord-emacs-"
  :group 'external)

(defcustom discord-emacs-ipc-dir (format "/run/user/%i/" (user-uid))
  "Directory where discord IPC socket lives."
  :group 'discord-emacs
  :type 'string)

(defcustom discord-emacs-ipc-name "discord-ipc-0"
  "Discord IPC socket name."
  :group 'discord-emacs
  :type 'string)

(defcustom discord-emacs-blacklisted-buffer-names '("^\\s-*\\*")
  "Buffers matching any of these regexes will not be shown on the rich presence."
  :group 'discord-emacs
  :type '(regexp))

(defcustom discord-emacs-blacklisted-major-modes '("circe-channel-mode" "circe-server-mode")
  "Buffers with major modes matching any of these will be ignored."
  :group 'discord-emacs
  :type '(string))

(defvar discord-emacs--+handshake+ 0)
(defvar discord-emacs--+frame+ 1)
(defvar discord-emacs--+close+ 2)
(defvar discord-emacs--+ping+ 3)
(defvar discord-emacs--+pong+ 4)

(defvar discord-emacs--spec
  '((opcode u32r)
    (length u32r)
    (data str (length))))

(defvar discord-emacs--rich-presence-version 1)

(defvar discord-emacs--client-id nil)
(defvar discord-emacs--current-buffer nil)
(defvar discord-emacs--started nil)

(defun discord-emacs--get-ipc-url ()
  "Get the socket address to make the ipc connection on."
  (concat (file-name-as-directory discord-emacs-ipc-dir) discord-emacs-ipc-name))

(defun discord-emacs--make-ipc-connection ()
  "Make a ipc socket connection."
  (let ((p (make-network-process :name "discord-ipc-process"
                                 :remote (discord-emacs--get-ipc-url))))
    (set-process-query-on-exit-flag p nil)
    p))

(defun discord-emacs--pack-data (opcode data)
  "Pack OPCODE and DATA."
  (let ((encoded-json (json-encode data)))
    (bindat-pack discord-emacs--spec `((opcode . ,opcode)
                                       (length . ,(length encoded-json))
                                       (data . ,encoded-json)))))

(defun discord-emacs--ipc-handshake (client-id)
  "Perform an ipc handshake with the client id CLIENT-ID."
  `((v .  ,discord-emacs--rich-presence-version)
    (client_id . ,client-id)))

(defun discord-emacs--rich-presence (&rest fields)
  "Build a rich presence payload with the fields FIELDS."
  `((cmd . "SET_ACTIVITY")
    (args . ((pid . ,(emacs-pid))
             (activity . ,fields)))
    (nonce . ,(number-to-string (random)))))

(defun discord-emacs--send-json (opcode data)
  "Send a JSON payload over the ipc connection with the opcode OPCODE and data DATA."
  (let ((process (get-process "discord-ipc-process")))
    (if (and process
             (process-live-p process))
        (process-send-string process (discord-emacs--pack-data opcode data))
      (discord-emacs--ipc-connect discord-emacs--client-id))))

(defun discord-emacs--ipc-connect (client-id)
  "Make an ipc connection to discord with the client id CLIENT-ID."
  (discord-emacs--make-ipc-connection)
  (discord-emacs--send-json discord-emacs--+handshake+ (discord-emacs--ipc-handshake client-id))
  (setq discord-emacs--started t))

(defun discord-emacs--count-buffers ()
  "Count the number of buffers."
  (cl-count-if
   (lambda (b)
     (or (buffer-file-name b)
         (not (discord-emacs--test-buffer b))))
   (buffer-list)))

(defun discord-emacs--get-current-major-mode (buffer)
  "Get the current major mode of BUFFER."
  (when-let ((mode (assq 'major-mode (buffer-local-variables buffer))))
    (symbol-name (cdr mode))))

(defun discord-emacs--start-time ()
  "Get the start time of this Emacs instance."
  (let* ((uptime (string-to-number (emacs-uptime "%s")))
         (current-time (string-to-number (format-time-string "%s" (current-time)))))
    (- current-time uptime)))

(defun discord-emacs--projectile-current-project (s)
  "Prepend the current project to S if projectile is installed."
  (if (fboundp 'projectile-project-name)
      (format "Project: %s, %s" (projectile-project-name) s)
    s))

(defun discord-emacs--gather-data ()
  "Gather data for a rich presence payload."
  (discord-emacs--rich-presence
   :details (format "Editing buffer: %s" (buffer-name))
   :state (discord-emacs--projectile-current-project (format "Buffers open: %d" (discord-emacs--count-buffers)))
   :timestamps `(:start ,(discord-emacs--start-time))
   :assets `((large_image . ,(if buffer-file-name (file-name-extension buffer-file-name) "no-extension"))
             (large_text . ,(discord-emacs--get-current-major-mode (current-buffer)))
             (small_image . "emacs")
             (small_text . "emacs"))))

(defun discord-emacs--some-pred (predicates val)
  "Apply all PREDICATES to VAL, return the first non-nil value or nil."
  (cl-some (lambda (pred) (funcall pred val))
           predicates))

(defun discord-emacs--test-buffer (buffer)
  "Test if the BUFFER is one that we should build a rich presence for."
  (or
   (discord-emacs--some-pred
    (cl-mapcar (lambda (regex)
                 (lambda (s) (string-match regex s)))
               discord-emacs-blacklisted-buffer-names)
    (buffer-name buffer))
   (discord-emacs--some-pred
    (cl-mapcar (lambda (blacklisted-mode)
                 (lambda (s) (string= blacklisted-mode s)))
               discord-emacs-blacklisted-major-modes)
    (discord-emacs--get-current-major-mode buffer))))

(defun discord-emacs--ipc-send-update ()
  "Send an ipc update to discord."
  (unless (or (string= discord-emacs--current-buffer (buffer-name))
              (discord-emacs--test-buffer (current-buffer)))
    ;; dont send messages when we are in the same buffer or enter the minibuf
    (setq discord-emacs--current-buffer (buffer-name))
    (discord-emacs--send-json discord-emacs--+frame+ (discord-emacs--gather-data))))

(defun discord-emacs-run (client-id)
  "Run the rich presence with the client id CLIENT-ID."
  (unless discord-emacs--started
    (setq discord-emacs--client-id client-id)
    (add-hook 'post-command-hook #'discord-emacs--ipc-send-update)
    (add-hook 'kill-emacs-hook #'discord-emacs-stop)
    (ignore-errors ; if we fail here we'll just reconnect later
      (discord-emacs--ipc-connect client-id))))

(defun discord-emacs-stop ()
  "Stop the Emacs rich presence."
  (when-let ((process (get-process "discord-ipc-process")))
    (delete-process process)
    (setq discord-emacs--started nil)))

(provide 'discord-emacs)

;;; discord-emacs.el ends here
