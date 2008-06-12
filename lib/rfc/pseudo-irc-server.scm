(define-module rfc.pseudo-irc-server
  (use srfi-1)
  (use srfi-13)
  (use gauche.net)
  (use gauche.selector)
  (export
    <pseudo-irc-server>
    <pseudo-irc-server-client>
    <irc-message>
    <irc-message-prefix>
    irc-server-start
    irc-server-register-callback
    irc-server-register-default-callbacks
    irc-send-message-to-client
    irc-server-send-message-to-all-clients
    irc-server-send-message-to-channel
    irc-send-notice-to-client
    irc-send-notice-to-channel
    irc-send-privmsg-to-client
    irc-send-privmsg-to-channel
    irc-prefix-of
    irc-message->string
    irc-message-prefix->string
    make-irc-message
    make-irc-message-prefix
    ))
(select-module rfc.pseudo-irc-server)

;; 疑似IRCサーバ
(define-class <pseudo-irc-server> ()
  ((listen-port :init-keyword :listen-port
                :init-value 6667)
   (clients     :init-value '())
   (channels    :init-value '())

   (callbacks   :init-thunk make-hash-table)

   (server-socket)
   (selector)

   (name    :init-value "pseudo-irc-server/gauche")
   (version :init-value 0.01)))

;; <pseudo-irc-server> に接続しているクライアント
(define-class <pseudo-irc-server-client> ()
  ((socket   :init-keyword :socket)
   (nick     :init-keyword :nick     :init-value #f)
   (user     :init-keyword :user     :init-value #f)
   (password :init-keyword :password :init-value #f)
   (channels                         :init-value '())))

;; IRCメッセージ
(define-class <irc-message> ()
  ((prefix  :init-keyword :prefix)   ; コマンドのプレフィックス <irc-command-prefix> または #f
   (command :init-keyword :command)  ; コマンド名
   (params  :init-keyword :params))) ; パラメータのリスト

(define-method initialize ((obj <irc-message>) initargs)
  (next-method)
  (unless (is-a? (slot-ref obj 'prefix) <irc-message-prefix>)
    (slot-set! obj 'prefix (parse-irc-message-prefix (slot-ref obj 'prefix)))))

;; プレフィックス
(define-class <irc-message-prefix> ()
  ((nick :init-keyword :nick)
   (user :init-keyword :user)
   (host :init-keyword :host)))

;; 疑似IRCサーバを開始
(define-method irc-server-start ((self <pseudo-irc-server>))
  (let ((selector      (make <selector>))
        (server-socket (make-server-socket (slot-ref self 'listen-port) :reuse-addr? #t)))
    (slot-set! self 'selector      selector)
    (slot-set! self 'server-socket server-socket)
    (selector-add!
      selector
      (socket-fd server-socket)
      (pa$ pseudo-irc-server-accept-handler self) '(r))

    (do () (#f)
      (selector-select selector '(5 0)))))

;; クライアントの接続
(define-method pseudo-irc-server-accept-handler ((self <pseudo-irc-server>) sock flag)
  (let* ((client-socket (socket-accept (slot-ref self 'server-socket)))
         (client        (make <pseudo-irc-server-client> :socket client-socket)))
    (slot-push! self 'clients client)
    (selector-add!
      (slot-ref self 'selector)
      (socket-input-port client-socket :buffering :none)
      (pa$ pseudo-irc-server-client-input-handler self client)
      '(r))))

;; クライアントからの入力
(define-method pseudo-irc-server-client-input-handler ((self <pseudo-irc-server>) (client <pseudo-irc-server-client>) (port <port>) flag)
  (or
    (and-let*
        (( (not (port-closed? port)) )
         (line (guard (e (else #f)) (read-line port)))
         ( (not (eof-object? line)) )
         (irc-message (parse-irc-message line)))
      (pseudo-irc-server-handle-callback self client irc-message))
    (begin
      (slot-delete! self 'clients client)
      (selector-delete! (slot-ref self 'selector) port #f #f)
      (socket-close (slot-ref client 'socket)))))

;; IRCコマンドに対応するコールバック関数を呼ぶ
(define-method pseudo-irc-server-handle-callback ((self <pseudo-irc-server>) (client <pseudo-irc-server-client>) (message <irc-message>))
  (for-each
    (cut <> self client message)
    (append (reverse (hash-table-get (slot-ref self 'callbacks) (slot-ref message 'command) '()))
            (reverse (hash-table-get (slot-ref self 'callbacks) '*                          '())))))

;; コールバックを登録
(define-method irc-server-register-callback ((self <pseudo-irc-server>) command callback)
  (hash-table-push!
    (slot-ref self 'callbacks)
    (string->symbol (string-upcase (x->string command)))
    callback))

;; クライアントにメッセージを送信
(define-method irc-send-message-to-client ((client <pseudo-irc-server-client>) (message <irc-message>))
  (display #`",(irc-message->string message)\r\n" (socket-output-port (slot-ref client 'socket))))

(define-method irc-send-message-to-client ((client <pseudo-irc-server-client>) prefix command . params)
  (irc-send-message-to-client client (make <irc-message> :prefix prefix :command command :params params)))

;; 接続しているクライアント全員にメッセージを送信
(define-method irc-server-send-message-to-all-clients ((server <pseudo-irc-server>) (message <irc-message>))
  (for-each
    (cut irc-send-message-to-client <> message)
    (slot-ref server 'clients)))

(define-method irc-server-send-message-to-all-clients ((server <pseudo-irc-server>) prefix command . params)
  (irc-server-send-message-to-all-clients server (make <irc-message> :prefix prefix :command command :params params)))

;; 特定のチャンネルにいるクライアント全員にメッセージを送信
(define-method irc-server-send-message-to-channel ((server <pseudo-irc-server>) channel (message <irc-message>))
  (for-each
    (cut irc-send-message-to-client <> message)
    (filter (lambda (client) (and (member channel (slot-ref client 'channels))
                                  (or (not (eq? (slot-ref message 'command) 'PRIVMSG))
                                      (not (string= (slot-ref (slot-ref message 'prefix) 'nick) (slot-ref client 'nick))))))
            (slot-ref server 'clients))))

(define-method irc-server-send-message-to-channel ((server <pseudo-irc-server>) channel prefix command . params)
  (irc-server-send-message-to-channel server channel (make <irc-message> :prefix prefix :command command :params params)))

(define-method irc-send-privmsg-to-client (sender (client <pseudo-irc-server-client>) msg)
  (irc-send-message-to-client client (irc-prefix-of sender) 'PRIVMSG msg))

(define-method irc-send-notice-to-client (sender (client <pseudo-irc-server-client>) msg)
  (irc-send-message-to-client client (irc-prefix-of sender) 'NOTICE msg))

(define-method irc-send-privmsg-to-channel ((server <pseudo-irc-server>) channel msg)
  (irc-send-privmsg-to-channel server server channel msg))

(define-method irc-send-privmsg-to-channel ((server <pseudo-irc-server>) sender channel msg)
  (irc-server-send-message-to-channel server channel (irc-prefix-of sender) 'PRIVMSG channel msg))

(define-method irc-send-notice-to-channel ((server <pseudo-irc-server>) channel msg)
  (irc-send-notice-to-channel server server channel msg))

(define-method irc-send-notice-to-channel ((server <pseudo-irc-server>) sender channel msg)
  (irc-server-send-message-to-channel server channel (irc-prefix-of sender) 'NOTICE channel msg))

;;; デフォルトのハンドラ
(define-method irc-server-register-default-callbacks ((server <pseudo-irc-server>))
  (irc-server-register-callback server 'PASS set-client-password)
  (irc-server-register-callback server 'NICK set-client-nick)
  (irc-server-register-callback server 'USER send-welcome-message)
  (irc-server-register-callback server 'USER set-client-user)
  (irc-server-register-callback server 'JOIN join-channel)
  (irc-server-register-callback server 'PART part-channel)
  (irc-server-register-callback server 'QUIT quit-server))

;; password スロットを更新
(define-method set-client-password ((server <pseudo-irc-server>) (client <pseudo-irc-server-client>) (message <irc-message>))
  (slot-set! client 'password (first (slot-ref message 'params))))

;; nick スロットを更新
(define-method set-client-nick ((server <pseudo-irc-server>) (client <pseudo-irc-server-client>) (message <irc-message>))
  (slot-set! client 'nick (first (slot-ref message 'params))))

;; user スロットを更新
(define-method set-client-user ((server <pseudo-irc-server>) (client <pseudo-irc-server-client>) (message <irc-message>))
  (slot-set! client 'user (first (slot-ref message 'params))))

;; ログイン完了メッセージを送信
(define-method send-welcome-message ((server <pseudo-irc-server>) (client <pseudo-irc-server-client>) (message <irc-message>))
  (for-each
    (cut irc-send-message-to-client client (slot-ref server 'name) <> (slot-ref client 'nick) <>)
    '(001 002)
    `(,#`"Welcome to the Internet Relay Network ,(irc-message-prefix->string (irc-prefix-of client))"
      ,#`"Your host is ,(slot-ref server 'name), running version ,(slot-ref server 'version)")))

;; チャンネルにJOIN
(define-method join-channel ((server <pseudo-irc-server>) (client <pseudo-irc-server-client>) (message <irc-message>))
  (for-each
    (lambda (channel)
      (irc-send-message-to-client client (irc-prefix-of client) 'JOIN channel)
      (unless (member channel (slot-ref server 'channels))
        (slot-push! server 'channels channel))
      (unless (member channel (slot-ref client 'channels))
        (slot-push! client 'channels channel)))
    (string-split (first (slot-ref message 'params)) ",")))

;; チャンネルからPART
(define-method part-channel ((server <pseudo-irc-server>) (client <pseudo-irc-server-client>) (message <irc-message>))
  (let1 channel (first (slot-ref message 'params))
    (irc-send-message-to-client client (irc-prefix-of client) 'PART channel)
    (slot-delete! server 'channels channel)
    (slot-delete! client 'channels channel)))

;; QUIT
(define-method quit-server ((server <pseudo-irc-server>) (client <pseudo-irc-server-client>) (message <irc-message>))
  (slot-delete! server 'clients client)
  (selector-delete! (slot-ref server 'selector) (socket-input-port (slot-ref client 'socket)) #f #f)
  (socket-close (slot-ref client 'socket)))

;; prefix
(define-method irc-prefix-of ((server <pseudo-irc-server>))
  (make <irc-message-prefix>
        :nick (slot-ref server 'name)
        :user "localhost"
        :host "localhost"))

(define-method irc-prefix-of ((client <pseudo-irc-server-client>))
  (let1 addr (sockaddr-addr (socket-address (slot-ref client 'socket)))
    (make <irc-message-prefix>
          :nick (slot-ref client 'nick)
          :user (slot-ref client 'user)
          :host (inet-address->string addr AF_INET))))

(define-method irc-prefix-of ((string <string>))
  (or (parse-irc-message-prefix string)
      (parse-irc-message-prefix #`",|string|!pseudo@localhost")))

;;; IRCコマンドの解析
(define (parse-irc-message raw-line)
  (rxmatch-let (#/^(:(\S+?) )?([a-zA-Z]+|\d\d\d)(.*)/ raw-line)
      (#f #f prefix command params)
    (make <irc-message>
          :prefix  (parse-irc-message-prefix prefix)
          :command (string->symbol (string-upcase command))
          :params  (split-irc-message-params params))))

(define (parse-irc-message-prefix prefix)
  (rxmatch-if (and prefix (#/^(.*?)!(.*?)@(.*)$/ prefix))
      (#f nick user host)
    (make <irc-message-prefix>
          :nick nick
          :user user
          :host host)
    #f))

(define (make-irc-message prefix command . params)
  (make <irc-message>
        :prefix  prefix
        :command command
        :params  params))

(define (make-irc-message-prefix nick user host)
  (make <irc-message-prefix>
        :nick nick
        :user user
        :host host))

(define-method irc-message-prefix->string ((prefix <irc-message-prefix>))
  #`",(slot-ref prefix 'nick)!,(slot-ref prefix 'user)@,(slot-ref prefix 'host)")

(define (split-irc-message-params raw-params)
  (rxmatch-let (#/^(.*?)( :(.*))?$/ raw-params)
      (#f params #f trail)
    (append
      (remove string-null? (string-split params " "))
      (if trail (list trail) '()))))

(define-method irc-message->string ((message <irc-message>))
  (let ((prefix  (slot-ref message 'prefix))
        (command (slot-ref message 'command))
        (params  (slot-ref message 'params)))
    (let1 line (string-append
                 (string-upcase (format #f "~3,,,'0@a" command))
                 (if (or (not params) (null? params))
                   ""
                   (string-join `(,@(map x->string (drop-right params 1)) ,#`":,(last params)") " " 'prefix)))
      (if prefix #`":,(irc-message-prefix->string prefix) ,line" line))))

;;; ユーティリティ
(define (slot-delete! obj slot x)
  (slot-set! obj slot (delete x (slot-ref obj slot))))

(provide "rfc/pseudo-irc-server")