marked.use({ gfm: true, breaks: true });

const I18n = {
    _lang: localStorage.getItem('lang') || 'en',
    _strings: {
        en: {
            retry: 'Retry', clear: 'Clear', send: 'Send', cancel: 'Cancel', ok: 'OK', stopGen: '■ Stop',
            update: 'Update', rename: 'Rename', delete_: 'Delete', download: '⬇ Download',
            newSession: '+ New Session', defaultSession: 'Default Session', newChat: 'New chat',
            typePlaceholder: 'Type a message...', attachFile: 'Attach file',
            ollamaEndpoint: 'Ollama Endpoint',
            cannotConnect: 'Cannot connect to Ollama',
            cannotConnectFull: 'Cannot connect to Ollama. Please correct Ollama URL endpoint.',
            cannotConnectTo: 'Cannot connect to ',
            renameSession: 'Rename session', newSessionName: 'New session name',
            deleteSession: 'Delete session',
            deleteConfirm1: 'Delete "', deleteConfirm2: '"? This cannot be undone.',
            clearSession: 'Clear session',
            clearConfirm1: 'Clear all history in "', clearConfirm2: '"? This cannot be undone.',
            confirm: 'Confirm', updating: 'Updating...',
            unsupported1: 'Unsupported file: ', unsupported2: '. Supported: PDF, DOCX, XLSX, plain text, ',
            noVision1: '⚠ ', noVision2: ' does not support images. Switch to a vision-capable model and send again.',
            genKeywords: 'Generating search keywords...',
            searchingWeb: 'Searching the web...',
            synthesizing: 'Synthesizing results...',
            waiting1: 'Waiting for ', waiting2: ' in thread "', waiting3: '" to answer...',
            searchUnavail: '⚠ Web search unavailable — answering from model training data, which may be outdated.',
            attaching: 'Preparing attachment...',
            voiceListening: 'Recording... tap to stop',
            voiceNotSupported: 'Voice input not supported in this browser',
            voiceHttpError: 'Voice input requires HTTPS. Access the app on port 8443 to enable it.',
            voiceEmpty: 'Nothing was recognized. To record in a different language, tap the flag button to switch language first. Currently listening in ',
            iosChromeHint: 'To add DMH-AI to your home screen, open this page in Safari, tap the Share button (⎙), then "Add to Home Screen".',
            iosCertHint: 'To avoid the certificate warning: tap here to install the certificate, then go to Settings → General → About → Certificate Trust Settings and enable it.',
            pwWarning: '⚠ You are using the default password. Please change it now.',
            pwWarningBtn: 'Change password',
        },
        vi: {
            retry: 'Thử lại', clear: 'Xóa', send: 'Gửi', cancel: 'Hủy', ok: 'OK', stopGen: '■ Dừng',
            update: 'Cập nhật', rename: 'Đổi tên', delete_: 'Xóa', download: '⬇ Tải về',
            newSession: '+ Phiên mới', defaultSession: 'Phiên mặc định', newChat: 'Cuộc trò chuyện mới',
            typePlaceholder: 'Nhập tin nhắn...', attachFile: 'Đính kèm tệp',
            ollamaEndpoint: 'Điểm cuối Ollama',
            cannotConnect: 'Không thể kết nối Ollama',
            cannotConnectFull: 'Không thể kết nối Ollama. Vui lòng kiểm tra lại URL endpoint của Ollama.',
            cannotConnectTo: 'Không thể kết nối ',
            renameSession: 'Đổi tên phiên', newSessionName: 'Tên phiên mới',
            deleteSession: 'Xóa phiên',
            deleteConfirm1: 'Xóa "', deleteConfirm2: '"? Không thể hoàn tác.',
            clearSession: 'Xóa phiên',
            clearConfirm1: 'Xóa toàn bộ lịch sử trong "', clearConfirm2: '"? Không thể hoàn tác.',
            confirm: 'Xác nhận', updating: 'Đang cập nhật...',
            unsupported1: 'Tệp không hỗ trợ: ', unsupported2: '. Hỗ trợ: PDF, DOCX, XLSX, văn bản, ',
            noVision1: '⚠ ', noVision2: ' không hỗ trợ hình ảnh. Hãy chọn mô hình hỗ trợ hình ảnh và gửi lại.',
            genKeywords: 'Đang tạo từ khóa tìm kiếm...',
            searchingWeb: 'Đang tìm kiếm trên web...',
            synthesizing: 'Đang tổng hợp kết quả...',
            waiting1: 'Đang chờ ', waiting2: ' trong phiên "', waiting3: '" trả lời...',
            searchUnavail: '⚠ Tìm kiếm web không khả dụng — trả lời từ dữ liệu huấn luyện, có thể đã lỗi thời.',
            attaching: 'Đang chuẩn bị tệp đính kèm...',
            voiceListening: 'Đang ghi âm... nhấn để dừng',
            voiceNotSupported: 'Trình duyệt này không hỗ trợ nhập giọng nói',
            voiceHttpError: 'Nhập giọng nói yêu cầu HTTPS. Truy cập ứng dụng qua cổng 8443 để sử dụng.',
            voiceEmpty: 'Không nhận ra giọng nói. Để ghi âm bằng ngôn ngữ khác, nhấn nút cờ để chọn ngôn ngữ trước. Hiện đang nghe bằng ',
            iosChromeHint: 'Để thêm DMH-AI vào màn hình chính, mở trang này trong Safari, nhấn nút Chia sẻ (⎙), rồi chọn "Thêm vào Màn hình chính".',
            iosCertHint: 'Để bỏ cảnh báo chứng chỉ: nhấn đây để cài chứng chỉ, rồi vào Cài đặt → Cài đặt chung → Giới thiệu → Cài đặt tin cậy chứng chỉ và bật lên.',
            pwWarning: '⚠ Bạn đang dùng mật khẩu mặc định. Hãy đổi mật khẩu ngay.',
            pwWarningBtn: 'Đổi mật khẩu',
        },
        de: {
            retry: 'Wiederholen', clear: 'Löschen', send: 'Senden', cancel: 'Abbrechen', ok: 'OK', stopGen: '■ Stopp',
            update: 'Aktualisieren', rename: 'Umbenennen', delete_: 'Löschen', download: '⬇ Herunterladen',
            newSession: '+ Neue Sitzung', defaultSession: 'Standardsitzung', newChat: 'Neuer Chat',
            typePlaceholder: 'Nachricht eingeben...', attachFile: 'Datei anhängen',
            ollamaEndpoint: 'Ollama-Endpunkt',
            cannotConnect: 'Verbindung zu Ollama fehlgeschlagen',
            cannotConnectFull: 'Verbindung zu Ollama fehlgeschlagen. Bitte überprüfen Sie die Ollama-URL-Endpunkt.',
            cannotConnectTo: 'Verbindung fehlgeschlagen: ',
            renameSession: 'Sitzung umbenennen', newSessionName: 'Neuer Sitzungsname',
            deleteSession: 'Sitzung löschen',
            deleteConfirm1: '"', deleteConfirm2: '" löschen? Dies kann nicht rückgängig gemacht werden.',
            clearSession: 'Sitzung leeren',
            clearConfirm1: 'Gesamten Verlauf in "', clearConfirm2: '" löschen? Dies kann nicht rückgängig gemacht werden.',
            confirm: 'Bestätigen', updating: 'Aktualisierung...',
            unsupported1: 'Nicht unterstützte Datei: ', unsupported2: '. Unterstützt: PDF, DOCX, XLSX, Text, ',
            noVision1: '⚠ ', noVision2: ' unterstützt keine Bilder. Wählen Sie ein bildtaugliches Modell und senden Sie erneut.',
            genKeywords: 'Suchbegriffe werden generiert...',
            searchingWeb: 'Websuche läuft...',
            synthesizing: 'Ergebnisse werden zusammengefasst...',
            waiting1: 'Warte auf ', waiting2: ' in Sitzung "', waiting3: '"...',
            searchUnavail: '⚠ Websuche nicht verfügbar — Antwort basiert auf Trainingsdaten, möglicherweise veraltet.',
            attaching: 'Anhang wird vorbereitet...',
            voiceListening: 'Aufnahme... tippen zum Stoppen',
            voiceNotSupported: 'Spracheingabe in diesem Browser nicht unterstützt',
            voiceHttpError: 'Spracheingabe erfordert HTTPS. Öffnen Sie die App über Port 8443.',
            voiceEmpty: 'Nichts erkannt. Um in einer anderen Sprache aufzunehmen, tippen Sie zuerst auf die Flagge. Aktuell wird gehört auf ',
            iosChromeHint: 'Um DMH-AI zum Home-Bildschirm hinzuzufügen, öffnen Sie die Seite in Safari, tippen auf Teilen (⎙) und wählen „Zum Home-Bildschirm".',
            iosCertHint: 'Um die Zertifikatwarnung zu vermeiden: hier tippen zum Installieren, dann Einstellungen → Allgemein → Info → Zertifikat-Vertrauenseinstellungen und aktivieren.',
            pwWarning: '⚠ Sie verwenden noch das Standardpasswort. Bitte jetzt ändern.',
            pwWarningBtn: 'Passwort ändern',
        },
        es: {
            retry: 'Reintentar', clear: 'Limpiar', send: 'Enviar', cancel: 'Cancelar', ok: 'OK', stopGen: '■ Detener',
            update: 'Actualizar', rename: 'Renombrar', delete_: 'Eliminar', download: '⬇ Descargar',
            newSession: '+ Nueva sesión', defaultSession: 'Sesión predeterminada', newChat: 'Nueva conversación',
            typePlaceholder: 'Escribe un mensaje...', attachFile: 'Adjuntar archivo',
            ollamaEndpoint: 'Punto de acceso Ollama',
            cannotConnect: 'No se puede conectar a Ollama',
            cannotConnectFull: 'No se puede conectar a Ollama. Verifique la URL del endpoint de Ollama.',
            cannotConnectTo: 'No se puede conectar a ',
            renameSession: 'Renombrar sesión', newSessionName: 'Nombre de nueva sesión',
            deleteSession: 'Eliminar sesión',
            deleteConfirm1: '¿Eliminar "', deleteConfirm2: '"? Esto no se puede deshacer.',
            clearSession: 'Limpiar sesión',
            clearConfirm1: '¿Borrar todo el historial en "', clearConfirm2: '"? Esto no se puede deshacer.',
            confirm: 'Confirmar', updating: 'Actualizando...',
            unsupported1: 'Archivo no compatible: ', unsupported2: '. Compatible: PDF, DOCX, XLSX, texto, ',
            noVision1: '⚠ ', noVision2: ' no admite imágenes. Seleccione un modelo con visión y envíe de nuevo.',
            genKeywords: 'Generando palabras clave...',
            searchingWeb: 'Buscando en la web...',
            synthesizing: 'Sintetizando resultados...',
            waiting1: 'Esperando a ', waiting2: ' en hilo "', waiting3: '" para responder...',
            searchUnavail: '⚠ Búsqueda web no disponible — respondiendo con datos de entrenamiento, pueden estar desactualizados.',
            attaching: 'Preparando archivo adjunto...',
            voiceListening: 'Grabando... toca para detener',
            voiceNotSupported: 'Entrada de voz no compatible con este navegador',
            voiceHttpError: 'La entrada de voz requiere HTTPS. Acceda a la aplicación por el puerto 8443.',
            voiceEmpty: 'No se reconoció nada. Para grabar en otro idioma, toca el botón de bandera primero. Actualmente escuchando en ',
            iosChromeHint: 'Para agregar DMH-AI a la pantalla de inicio, abre la página en Safari, toca Compartir (⎙) y selecciona "Agregar a inicio".',
            iosCertHint: 'Para evitar la advertencia: toca aquí para instalar el certificado, luego ve a Ajustes → General → Información → Configuración de confianza de certificados y actívalo.',
            pwWarning: '⚠ Está usando la contraseña predeterminada. Cámbiela ahora.',
            pwWarningBtn: 'Cambiar contraseña',
        },
        fr: {
            retry: 'Réessayer', clear: 'Effacer', send: 'Envoyer', cancel: 'Annuler', ok: 'OK', stopGen: '■ Arrêter',
            update: 'Mettre à jour', rename: 'Renommer', delete_: 'Supprimer', download: '⬇ Télécharger',
            newSession: '+ Nouvelle session', defaultSession: 'Session par défaut', newChat: 'Nouvelle conversation',
            typePlaceholder: 'Tapez un message...', attachFile: 'Joindre un fichier',
            ollamaEndpoint: 'Point d\'accès Ollama',
            cannotConnect: 'Connexion à Ollama impossible',
            cannotConnectFull: 'Connexion à Ollama impossible. Veuillez vérifier l\'URL du endpoint Ollama.',
            cannotConnectTo: 'Connexion impossible à ',
            renameSession: 'Renommer la session', newSessionName: 'Nom de la nouvelle session',
            deleteSession: 'Supprimer la session',
            deleteConfirm1: 'Supprimer "', deleteConfirm2: '" ? Cette action est irréversible.',
            clearSession: 'Effacer la session',
            clearConfirm1: 'Effacer tout l\'historique de "', clearConfirm2: '" ? Cette action est irréversible.',
            confirm: 'Confirmer', updating: 'Mise à jour...',
            unsupported1: 'Fichier non pris en charge : ', unsupported2: '. Pris en charge : PDF, DOCX, XLSX, texte, ',
            noVision1: '⚠ ', noVision2: ' ne prend pas en charge les images. Sélectionnez un modèle compatible et réessayez.',
            genKeywords: 'Génération des mots-clés...',
            searchingWeb: 'Recherche sur le web...',
            synthesizing: 'Synthèse des résultats...',
            waiting1: 'En attente de ', waiting2: ' dans le fil "', waiting3: '"...',
            searchUnavail: '⚠ Recherche web indisponible — réponse basée sur les données d\'entraînement, potentiellement obsolètes.',
            attaching: 'Préparation de la pièce jointe...',
            voiceListening: 'Enregistrement... appuyez pour arrêter',
            voiceNotSupported: 'Saisie vocale non prise en charge par ce navigateur',
            voiceHttpError: 'La saisie vocale nécessite HTTPS. Accédez à l\'application via le port 8443.',
            voiceEmpty: 'Rien reconnu. Pour enregistrer dans une autre langue, appuyez d\'abord sur le drapeau. Langue actuelle : ',
            iosChromeHint: 'Pour ajouter DMH-AI à l\'écran d\'accueil, ouvrez la page dans Safari, appuyez sur Partager (⎙) puis « Sur l\'écran d\'accueil ».',
            iosCertHint: 'Pour éviter l\'avertissement : appuyez ici pour installer le certificat, puis Réglages → Général → À propos → Réglages de confiance des certificats et activez.',
            pwWarning: '⚠ Vous utilisez le mot de passe par défaut. Veuillez le changer maintenant.',
            pwWarningBtn: 'Changer le mot de passe',
        }
    },
    t: function(key) { return (this._strings[this._lang] || this._strings.en)[key] || this._strings.en[key] || key; },
    setLang: function(lang) { this._lang = lang; localStorage.setItem('lang', lang); },
    get lang() { return this._lang; },
    flags: { en: '🇬🇧', vi: '🇻🇳', de: '🇩🇪', es: '🇪🇸', fr: '🇫🇷' },
    names: { en: 'English', vi: 'Tiếng Việt', de: 'Deutsch', es: 'Español', fr: 'Français' }
};
function t(key) { return I18n.t(key); }

const Auth = {
    _token: localStorage.getItem('auth_token'),
    _user: (function() { try { return JSON.parse(localStorage.getItem('auth_user')); } catch(e) { return null; } })(),
    get token() { return this._token; },
    get user() { return this._user; },
    get isLoggedIn() { return !!this._token && !!this._user; },
    async login(email, password) {
        const res = await fetch('/auth/login', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ email: email, password: password })
        });
        if (!res.ok) throw new Error('Invalid username or password');
        const data = await res.json();
        this._token = data.token;
        this._user = data.user;
        localStorage.setItem('auth_token', data.token);
        localStorage.setItem('auth_user', JSON.stringify(data.user));
        return data.user;
    },
    async logout() {
        if (this._token) {
            fetch('/auth/logout', { method: 'POST', headers: { 'Authorization': 'Bearer ' + this._token } }).catch(function() {});
        }
        this._token = null;
        this._user = null;
        localStorage.removeItem('auth_token');
        localStorage.removeItem('auth_user');
    },
    async validate() {
        if (!this._token) return null;
        const res = await fetch('/auth/me', { headers: { 'Authorization': 'Bearer ' + this._token } });
        if (!res.ok) {
            this._token = null; this._user = null;
            localStorage.removeItem('auth_token'); localStorage.removeItem('auth_user');
            return null;
        }
        const user = await res.json();
        this._user = user;
        localStorage.setItem('auth_user', JSON.stringify(user));
        return user;
    }
};

function apiFetch(url, options) {
    options = options || {};
    if (Auth.token) {
        options.headers = options.headers || {};
        options.headers['Authorization'] = 'Bearer ' + Auth.token;
    }
    return fetch(url, options);
}

function syslog(msg) {
    apiFetch('/log', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({msg}) }).catch(function(){});
}

const AppConfig = {
    get searxngUrl() { return localStorage.getItem('searxng-url') || 'http://localhost:8888'; },
    saveSearxng: function(url) {
        if (url) localStorage.setItem('searxng-url', url);
        else localStorage.removeItem('searxng-url');
    },
    get ollamaEndpoint() { return localStorage.getItem('ollama-endpoint') || ''; },
    saveOllamaEndpoint: function(url) {
        if (url) localStorage.setItem('ollama-endpoint', url);
        else localStorage.removeItem('ollama-endpoint');
    }
};

const Modal = {
    _resolve: null,

    _open: function(title, message, inputDefault, okLabel, danger) {
        document.getElementById('modal-title').textContent = title;
        document.getElementById('modal-message').textContent = message;
        const input = document.getElementById('modal-input');
        const okBtn = document.getElementById('modal-ok');
        okBtn.textContent = okLabel || t('ok');
        okBtn.className = 'modal-btn ' + (danger ? 'modal-btn-danger' : 'modal-btn-ok');
        if (inputDefault !== null) {
            input.style.display = 'block';
            input.value = inputDefault;
            setTimeout(function() { input.focus(); input.select(); }, 50);
        } else {
            input.style.display = 'none';
        }
        document.getElementById('modal-overlay').classList.add('visible');
        const self = this;
        return new Promise(function(resolve) { self._resolve = resolve; });
    },

    _close: function(value) {
        document.getElementById('modal-overlay').classList.remove('visible');
        if (this._resolve) { this._resolve(value); this._resolve = null; }
    },

    confirm: function(title, message, okLabel) {
        return this._open(title, message, null, okLabel || t('confirm'), true);
    },

    prompt: function(title, defaultValue) {
        return this._open(title, '', defaultValue || '', 'OK', false);
    },

    init: function() {
        const self = this;
        document.getElementById('modal-ok').addEventListener('click', function() {
            const input = document.getElementById('modal-input');
            self._close(input.style.display !== 'none' ? input.value : true);
        });
        document.getElementById('modal-cancel').addEventListener('click', function() { self._close(null); });
        document.getElementById('modal-overlay').addEventListener('click', function(e) {
            if (e.target === e.currentTarget) self._close(null);
        });
        document.getElementById('modal-input').addEventListener('keydown', function(e) {
            const input = document.getElementById('modal-input');
            if (e.key === 'Enter') { self._close(input.value); }
            if (e.key === 'Escape') { self._close(null); }
        });
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape' && document.getElementById('modal-overlay').classList.contains('visible')) {
                self._close(null);
            }
        });
    }
};

const SessionStore = {
    BASE: '/sessions',
    getSessions: async function() {
        const res = await apiFetch(this.BASE);
        return res.json();
    },
    createSession: async function(name, model) {
        const session = {
            id: Date.now().toString(),
            name: name || 'New Session',
            model: model || '',
            messages: [],
            context: { summary: null, summaryUpToIndex: -1 },
            createdAt: Date.now()
        };
        await apiFetch(this.BASE, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(session)
        });
        return session;
    },
    getSession: async function(id) {
        const res = await apiFetch(this.BASE + '/' + id);
        if (!res.ok) return null;
        return res.json();
    },
    updateSession: async function(session) {
        await apiFetch(this.BASE + '/' + session.id, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(session)
        });
    },
    deleteSession: async function(id) {
        await apiFetch(this.BASE + '/' + id, { method: 'DELETE' });
    },
    getCurrentSessionId: async function() {
        const res = await apiFetch(this.BASE + '/current');
        const data = await res.json();
        return data.id;
    },
    setCurrentSessionId: async function(id) {
        await apiFetch(this.BASE + '/current', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ id: id })
        });
    }
};

const OllamaAPI = {
    endpoint: '',
    contextWindowCache: {},
    capabilityCache: {},
    get BASE_URL() { return this.endpoint ? this.endpoint + '/api' : '/api'; },
    setEndpoint: function(url) {
        this.endpoint = url.replace(/\/+$/, '');
        this.contextWindowCache = {};
        this.capabilityCache = {};
    },
    hasVision: async function(model) {
        if (model in this.capabilityCache) return this.capabilityCache[model];
        try {
            const res = await fetch(this.BASE_URL + '/show', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name: model })
            });
            const data = await res.json();
            const result = (data.capabilities || []).includes('vision');
            this.capabilityCache[model] = result;
            return result;
        } catch (e) {
            return false;
        }
    },
    formatSize: function(bytes) {
        if (!bytes) return '';
        if (bytes < 1e9) return ' (' + (bytes / 1e6).toFixed(0) + ' MB)';
        return ' (' + (bytes / 1e9).toFixed(1) + ' GB)';
    },
    fetchModels: async function() {
        try {
            const response = await fetch(this.BASE_URL + '/tags');
            if (!response.ok) throw new Error('Failed to fetch models');
            const data = await response.json();
            const models = data.models || [];
            models.sort(function(a, b) { return (a.size || 0) - (b.size || 0); });
            return models;
        } catch (e) {
            console.error('Failed to fetch models:', e);
            throw e;
        }
    },
    fetchContextWindow: async function(model) {
        if (this.contextWindowCache[model]) return this.contextWindowCache[model];
        try {
            const res = await fetch(this.BASE_URL + '/show', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name: model })
            });
            if (!res.ok) throw new Error('show failed');
            const data = await res.json();
            const info = data.model_info || {};
            const entry = Object.entries(info).find(function(kv) { return kv[0].endsWith('context_length'); });
            const ctxLen = (entry ? entry[1] : null) || 4096;
            this.contextWindowCache[model] = ctxLen;
            return ctxLen;
        } catch (e) {
            return 4096;
        }
    },
    summarize: async function(model, messages) {
        try {
            const res = await fetch(this.BASE_URL + '/chat', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ model: model, messages: messages, stream: false, think: false })
            });
            if (!res.ok) throw new Error('summarize failed');
            const data = await res.json();
            return (data.message && data.message.content) ? data.message.content : null;
        } catch (e) {
            console.error('Summarization failed:', e);
            return null;
        }
    },
    streamChat: function(model, messages, onChunk, onComplete, onError, signal) {
        const controller = signal ? null : new AbortController();
        fetch(this.BASE_URL + '/chat', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ model: model, messages: messages, stream: true, think: false }),
            signal: signal || controller.signal
        })
        .then(async function(response) {
            if (!response.ok) {
                const errText = await response.text().catch(() => '');
                let msg = 'Chat request failed (' + response.status + ')';
                try { const e = JSON.parse(errText); if (e.error) msg += ': ' + e.error; } catch(_) { if (errText) msg += ': ' + errText.slice(0, 200); }
                throw new Error(msg);
            }
            const reader = response.body.getReader();
            const decoder = new TextDecoder();
            let buffer = '';
            while (true) {
                const result = await reader.read();
                if (result.done) break;
                buffer += decoder.decode(result.value, { stream: true });
                var lines = buffer.split('\n');
                buffer = lines.pop();
                for (var i = 0; i < lines.length; i++) {
                    var line = lines[i].trim();
                    if (line) {
                        try {
                            var json = JSON.parse(line);
                            if (json.message && json.message.content) {
                                onChunk(json.message.content);
                            }
                        } catch (e) {}
                    }
                }
            }
            if (onComplete) onComplete();
        })
        .catch(function(err) {
            if (err.name !== 'AbortError' && onError) onError(err);
        });
        return controller || { signal: signal };
    }
};

function wrapTables(el) {
    el.querySelectorAll('table').forEach(function(table) {
        if (table.parentElement.classList.contains('table-wrap')) return;
        var wrap = document.createElement('div');
        wrap.className = 'table-wrap';
        table.parentNode.insertBefore(wrap, table);
        wrap.appendChild(table);
    });
}

function addCopyButtons(el) {
    el.querySelectorAll('pre').forEach(function(pre) {
        if (pre.querySelector('.code-copy-btn')) return;
        var btn = document.createElement('button');
        btn.className = 'code-copy-btn';
        btn.textContent = '⧉';
        btn.addEventListener('click', function() {
            var code = pre.querySelector('code');
            var text = (code || pre).textContent;
            navigator.clipboard.writeText(text).then(function() {
                btn.textContent = '✓';
                setTimeout(function() { btn.textContent = '⧉'; }, 5000);
            });
        });
        pre.appendChild(btn);
    });
}

function formatTs(ts) {
    if (!ts) return '';
    var d = new Date(ts);
    var now = new Date();
    var pad = function(n) { return n < 10 ? '0' + n : '' + n; };
    var time = pad(d.getHours()) + ':' + pad(d.getMinutes());
    if (d.toDateString() === now.toDateString()) return time;
    var yesterday = new Date(now); yesterday.setDate(now.getDate() - 1);
    if (d.toDateString() === yesterday.toDateString()) return 'Yesterday ' + time;
    var months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    var sameYear = d.getFullYear() === now.getFullYear();
    return months[d.getMonth()] + ' ' + d.getDate() + (sameYear ? '' : ' ' + d.getFullYear()) + ' ' + time;
}

function buildMsgHeader(msg, session) {
    var ts = formatTs(msg.ts);
    var prefix = ts ? '[' + ts + '] ' : '';
    if (msg.role === 'user') {
        var user = Auth._user;
        var displayName = user ? (user.name || user.email.split('@')[0]) : '';
        return prefix + displayName + ':';
    }
    var model = msg.model || (session && session.model) || '';
    return prefix + (model || 'Assistant') + ':';
}

function prepareForAPI(messages) {
    return messages.map(function(msg) {
        if (msg.role !== 'user') return msg;
        return { role: 'user', content: msg.content };
    });
}

const ContextManager = {
    COMPACT_THRESHOLD: 0.80,
    KEEP_RECENT: 6,

    estimateTokens: function(messages) {
        return messages.reduce(function(sum, m) {
            return sum + Math.ceil((m.content || '').length / 4);
        }, 0);
    },

    buildContextMessages: function(session) {
        var ctx = session.context;
        if (!ctx || !ctx.summary) return session.messages.slice();
        var recent = session.messages.slice(ctx.summaryUpToIndex + 1);
        return [
            { role: 'user', content: '[Summary of our conversation so far]\n' + ctx.summary },
            { role: 'assistant', content: 'Understood, I have the full context of our conversation.' }
        ].concat(recent);
    },

    shouldCompact: function(session, contextWindow, pendingContent) {
        var contextMsgs = this.buildContextMessages(session);
        var pendingTokens = Math.ceil((pendingContent || '').length / 4);
        var total = this.estimateTokens(contextMsgs) + pendingTokens;
        return (total / contextWindow) > this.COMPACT_THRESHOLD;
    },

    compact: async function(session) {
        var ctx = session.context || { summary: null, summaryUpToIndex: -1 };
        var keepFrom = Math.max(0, session.messages.length - this.KEEP_RECENT);
        var startFrom = ctx.summaryUpToIndex + 1;
        var toSummarize = session.messages.slice(startFrom, keepFrom);
        if (toSummarize.length === 0) return;

        var summarizeInput = [];
        if (ctx.summary) {
            summarizeInput.push({ role: 'user', content: '[Previous summary]\n' + ctx.summary });
            summarizeInput.push({ role: 'assistant', content: 'Understood.' });
        }
        summarizeInput = summarizeInput.concat(toSummarize.map(function(msg) {
            return { role: msg.role, content: msg.content };
        }));
        summarizeInput.push({ role: 'user', content: 'Write a concise but complete summary of this conversation. Preserve: key facts, decisions made, user preferences, ongoing tasks, and any code or technical details. Discard: repetitive exchanges, clarifications of already-established facts, false starts, and conversational filler. Be dense and factual.' });

        var summary = await OllamaAPI.summarize(session.model, summarizeInput);
        if (!summary) return;

        session.context = { summary: summary, summaryUpToIndex: keepFrom - 1 };
        await SessionStore.updateSession(session);
    }
};

// Module-level helpers used by UIManager methods called outside init's closure
function applyLanguage() {
    var langFlag = document.getElementById('lang-flag');
    var langDropdown = document.getElementById('lang-dropdown');
    if (langFlag) langFlag.textContent = I18n.flags[I18n.lang];
    if (langDropdown) langDropdown.querySelectorAll('.lang-option').forEach(function(el) {
        el.classList.toggle('active', el.dataset.lang === I18n.lang);
    });
    document.getElementById('new-session-btn').textContent = t('newSession');
    document.getElementById('endpoint-label').textContent = t('ollamaEndpoint');
    document.getElementById('endpoint-update-btn').textContent = t('update');
    document.getElementById('message-input').placeholder = t('typePlaceholder');
    document.getElementById('send-label').textContent = t('send');
    document.getElementById('stop-gen-btn').textContent = t('stopGen');
    document.getElementById('attach-btn').title = t('attachFile');
    document.getElementById('error-message').textContent = t('cannotConnect');
    document.querySelector('#error-banner button').textContent = t('retry');
    document.getElementById('modal-cancel').textContent = t('cancel');
    document.getElementById('pw-warning-text').textContent = t('pwWarning');
    document.getElementById('pw-warning-btn').textContent = t('pwWarningBtn');
}

function setCpwError(msg) {
    var el = document.getElementById('cpw-error');
    el.textContent = msg;
    el.style.display = msg ? '' : 'none';
}

const UIManager = {
    currentSession: null,
    isStreaming: false,
    attachedFiles: [],
    _streamController: null,
    _lastUsedModel: null,
    _pendingContent: '',
    _pendingSession: null,

    init: function() {
        const self = this;
        Modal.init();
        var sidebar = document.getElementById('sidebar');
        var overlay = document.getElementById('sidebar-overlay');
        var toggle = document.getElementById('sidebar-toggle');
        var headerLogo = document.getElementById('header-logo');
        var isMobile = function() { return window.innerWidth <= 768; };
        function closeSidebar() { sidebar.classList.add('collapsed'); overlay.classList.remove('visible'); headerLogo.style.display = ''; }
        function openSidebar() { sidebar.classList.remove('collapsed'); if (isMobile()) overlay.classList.add('visible'); headerLogo.style.display = 'none'; }
        toggle.addEventListener('click', function() { sidebar.classList.contains('collapsed') ? openSidebar() : closeSidebar(); });
        document.getElementById('header-new-chat-btn').addEventListener('click', function() { self.createNewSession(); });
        overlay.addEventListener('click', closeSidebar);
        document.getElementById('message-input').addEventListener('focus', function() { if (isMobile()) closeSidebar(); });
        if (window.innerWidth <= 768) closeSidebar();

        // Language switcher
        var langDropdown = document.getElementById('lang-dropdown');
        Object.keys(I18n.names).forEach(function(code) {
            var btn = document.createElement('button');
            btn.className = 'lang-option';
            btn.dataset.lang = code;
            btn.textContent = I18n.flags[code] + '  ' + I18n.names[code];
            btn.addEventListener('click', function() {
                I18n.setLang(code);
                applyLanguage();
                langDropdown.classList.remove('open');
                UIManager.savePrefs({ lang: code });
            });
            langDropdown.appendChild(btn);
        });
        document.getElementById('lang-flag').addEventListener('click', function(e) {
            e.stopPropagation();
            langDropdown.classList.toggle('open');
        });
        document.addEventListener('click', function() { langDropdown.classList.remove('open'); });
        applyLanguage();

        document.getElementById('stop-gen-btn').addEventListener('click', function() {
            if (self._streamController) { self._streamController.abort(); self._streamController = null; }
            self.saveStreamingProgress();
            self.isStreaming = false;
            self.updateSendBtn();
            self.setStatus('');
            document.getElementById('stop-gen-btn').style.display = 'none';
        });
        document.addEventListener('visibilitychange', function() {
            if (document.hidden && self.isStreaming) self.saveStreamingProgress();
        });
        window.addEventListener('beforeunload', function() {
            if (self.isStreaming) self.saveStreamingProgress();
        });

        if (window.visualViewport) {
            window.visualViewport.addEventListener('resize', function() {
                document.documentElement.style.height = window.visualViewport.height + 'px';
                var chat = document.getElementById('chat-container');
                chat.scrollTop = chat.scrollHeight;
            });
        }
        document.getElementById('new-session-btn').addEventListener('click', function() { self.createNewSession(); });
        document.getElementById('endpoint-update-btn').addEventListener('click', function() { self.updateEndpoint(); });
        document.getElementById('endpoint-input').addEventListener('keydown', function(e) { if (e.key === 'Enter') self.updateEndpoint(); });
        document.getElementById('send-btn').addEventListener('click', function() { self.sendMessage(); });
        document.getElementById('message-input').addEventListener('keydown', function(e) {
            if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); if (!self.isStreaming) self.sendMessage(); }
        });
        document.getElementById('message-input').addEventListener('input', function() {
            this.style.height = 'auto';
            this.style.height = Math.min(this.scrollHeight, 100) + 'px';
            self.updateSendBtn();
        });
        document.getElementById('message-input').addEventListener('paste', function(e) {
            var items = e.clipboardData && e.clipboardData.items;
            if (!items) return;
            for (var i = 0; i < items.length; i++) {
                if (items[i].type.startsWith('image/')) {
                    e.preventDefault();
                    var blob = items[i].getAsFile();
                    if (blob) {
                        var ext = items[i].type.split('/')[1] || 'png';
                        var file = new File([blob], 'paste-' + Date.now() + '.' + ext, { type: items[i].type });
                        self.handleFileSelect([file]);
                    }
                }
            }
        });
        document.getElementById('header-model-select').addEventListener('change', function(e) { self.switchModel(e.target.value); });

        // User menu
        var userMenuBtn = document.getElementById('user-menu-btn');
        var userDropdown = document.getElementById('user-dropdown');
        userMenuBtn.addEventListener('click', function(e) {
            e.stopPropagation();
            userDropdown.classList.toggle('open');
        });
        document.addEventListener('click', function() { userDropdown.classList.remove('open'); });
        userDropdown.addEventListener('click', function(e) { e.stopPropagation(); });
        document.getElementById('user-clear-btn').addEventListener('click', function() {
            userDropdown.classList.remove('open');
            self.clearSession();
        });
        document.getElementById('user-change-pw-btn').addEventListener('click', function() {
            userDropdown.classList.remove('open');
            self.showChangePassword();
        });
        document.getElementById('user-manage-btn').addEventListener('click', function() {
            userDropdown.classList.remove('open');
            self.showManageUsers();
        });
        document.getElementById('user-signout-btn').addEventListener('click', async function() {
            userDropdown.classList.remove('open');
            await Auth.logout();
            self.showLoginScreen();
        });
        document.getElementById('pw-warning-btn').addEventListener('click', function() {
            self.showChangePassword();
        });
        var attachMenu = document.getElementById('attach-menu');
        var isMobileDevice = /Android|iPhone|iPad|iPod/i.test(navigator.userAgent);
        document.getElementById('attach-btn').addEventListener('click', function(e) {
            e.stopPropagation();
            if (isMobileDevice) {
                attachMenu.classList.toggle('open');
            } else {
                document.getElementById('file-input').click();
            }
        });
        document.addEventListener('click', function() { attachMenu.classList.remove('open'); });
        function attachInput(id) {
            document.getElementById(id).addEventListener('click', function(e) { e.stopPropagation(); });
            document.getElementById(id).addEventListener('change', function(e) {
                if (e.target.files.length) self.handleFileSelect(e.target.files);
                e.target.value = '';
                attachMenu.classList.remove('open');
            });
        }
        attachInput('file-input');
        attachInput('camera-input');
        attachInput('video-input');
        attachInput('gallery-input');
        document.getElementById('attach-camera').addEventListener('click', function() { document.getElementById('camera-input').click(); });
        document.getElementById('attach-video').addEventListener('click', function() { document.getElementById('video-input').click(); });
        document.getElementById('attach-gallery').addEventListener('click', function() { document.getElementById('gallery-input').click(); });
        document.getElementById('attach-file').addEventListener('click', function() { document.getElementById('file-input').click(); });

        var _voiceRecognition = null;
        var _voiceTranscript = '';
        var _voiceAccum = '';
        var _langMap = { en: 'en-US', vi: 'vi-VN', de: 'de-DE', es: 'es-ES', fr: 'fr-FR' };
        function stopVoice() {
            if (_voiceRecognition) { _voiceRecognition.stop(); _voiceRecognition = null; }
            document.getElementById('voice-bar').classList.remove('visible');
        }
        document.getElementById('voice-bar').addEventListener('click', stopVoice);
        document.getElementById('attach-voice').addEventListener('click', function() {
            attachMenu.classList.remove('open');
            var SR = window.SpeechRecognition || window.webkitSpeechRecognition;
            if (!SR) {
                self.setStatus(t('voiceNotSupported'));
                setTimeout(function() { self.setStatus(''); }, 5000);
                return;
            }
            var rec = new SR();
            _voiceRecognition = rec;
            _voiceTranscript = '';
            _voiceAccum = '';
            rec.lang = _langMap[I18n._lang] || 'en-US';
            rec.continuous = true;
            rec.interimResults = false;
            var bar = document.getElementById('voice-bar');
            var barText = document.getElementById('voice-bar-text');
            barText.textContent = t('voiceListening');
            bar.classList.add('visible');
            rec.onresult = function(e) {
                var cur = '';
                for (var i = 0; i < e.results.length; i++) {
                    if (e.results[i].isFinal) cur += e.results[i][0].transcript + ' ';
                }
                _voiceTranscript = (_voiceAccum + cur).trim();
            };
            rec.onend = function() {
                if (_voiceRecognition) {
                    // Browser auto-stopped (silence timeout) — save and restart
                    _voiceAccum = _voiceTranscript ? _voiceTranscript + ' ' : '';
                    try { rec.start(); } catch(e) {}
                    return;
                }
                bar.classList.remove('visible');
                var text = _voiceTranscript.trim();
                if (!text) {
                    self.setStatus(t('voiceEmpty') + I18n.names[I18n._lang] + '.');
                    setTimeout(function() { self.setStatus(''); }, 5000);
                    return;
                }
                var sessionId = self.currentSession ? self.currentSession.id : 'default';
                var blob = new Blob([text], { type: 'text/plain' });
                var file = new File([blob], 'voice.txt', { type: 'text/plain' });
                var formData = new FormData();
                formData.append('file', file);
                formData.append('sessionId', sessionId);
                self.setStatus(t('attaching'));
                apiFetch('/assets', { method: 'POST', body: formData })
                    .then(function(r) { return r.json(); })
                    .then(function(data) {
                        var lines = text.split('\n');
                        var snippet = lines.slice(0, 5).join('\n') + (lines.length > 5 ? '\n…' : '');
                        self.attachedFiles.push({ id: data.id, name: '🎤 recorded-audio.txt', type: 'text', snippet: snippet, fullContent: text });
                        self.renderAttachments();
                        self.setStatus('');
                    }).catch(function() { self.setStatus(''); });
            };
            rec.onerror = function(e) {
                _voiceRecognition = null;
                bar.classList.remove('visible');
                var msg = (e.error === 'not-allowed' || e.error === 'service-not-allowed')
                    ? t('voiceHttpError') : t('voiceNotSupported');
                self.setStatus(msg);
                setTimeout(function() { self.setStatus(''); }, 5000);
            };
            rec.start();
        });

        // Login screen
        var loginBtn = document.getElementById('login-btn');
        var loginEmail = document.getElementById('login-email');
        var loginPw = document.getElementById('login-password');
        var loginErr = document.getElementById('login-error');
        async function doLogin() {
            loginBtn.disabled = true;
            loginErr.textContent = '';
            try {
                var username = loginEmail.value.trim();
                if (username && !username.includes('@')) username += '@dmhai.local';
                await Auth.login(username, loginPw.value);
                self.hideLoginScreen();
                self.initializeApp();
            } catch(e) {
                loginErr.textContent = e.message || 'Login failed';
            } finally {
                loginBtn.disabled = false;
            }
        }
        loginBtn.addEventListener('click', doLogin);
        loginEmail.addEventListener('keydown', function(e) { if (e.key === 'Enter') { loginPw.focus(); } });
        loginPw.addEventListener('keydown', function(e) { if (e.key === 'Enter') doLogin(); });

        // Change password modal
        function closeCpw() { document.getElementById('cpw-overlay').classList.remove('visible'); }
        document.getElementById('cpw-cancel').addEventListener('click', closeCpw);
        document.getElementById('cpw-overlay').addEventListener('click', function(e) { if (e.target === e.currentTarget) closeCpw(); });
        document.getElementById('cpw-ok').addEventListener('click', async function() {
            var cur = document.getElementById('cpw-current').value;
            var nw = document.getElementById('cpw-new').value;
            var cf = document.getElementById('cpw-confirm').value;
            setCpwError('');
            if (!cur || !nw || !cf) { setCpwError('All fields are required'); return; }
            if (nw !== cf) { setCpwError('New passwords do not match'); return; }
            var btn = document.getElementById('cpw-ok');
            btn.disabled = true;
            try {
                const res = await apiFetch('/auth/password', {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ current: cur, new: nw })
                });
                if (!res.ok) {
                    var msg = 'Current password is incorrect';
                    try { var d = await res.json(); if (d.error) msg = d.error; } catch(_) {}
                    setCpwError(msg);
                } else {
                    if (Auth._user) { Auth._user.passwordChanged = true; localStorage.setItem('auth_user', JSON.stringify(Auth._user)); }
                    UIManager.updatePwWarning();
                    closeCpw();
                }
            } catch(e) {
                setCpwError('Could not connect to server');
            } finally {
                btn.disabled = false;
            }
        });

        // Manage users close
        document.getElementById('mgr-close').addEventListener('click', function() {
            document.getElementById('mgr-overlay').classList.remove('visible');
        });
        document.getElementById('mgr-overlay').addEventListener('click', function(e) {
            if (e.target === e.currentTarget) document.getElementById('mgr-overlay').classList.remove('visible');
        });

        this.checkAuthAndInit();
    },

    showLoginScreen: function() {
        document.getElementById('login-screen').classList.remove('hidden');
        document.getElementById('login-email').value = '';
        document.getElementById('login-password').value = '';
        document.getElementById('login-error').textContent = '';
        setTimeout(function() { document.getElementById('login-email').focus(); }, 50);
    },

    hideLoginScreen: function() {
        document.getElementById('login-screen').classList.add('hidden');
        var user = Auth.user;
        if (user) {
            document.getElementById('user-dropdown-identity').textContent = 'Signed in as ' + (user.name || user.email);
            var isAdmin = user.role === 'admin';
            document.getElementById('user-manage-btn').style.display = isAdmin ? '' : 'none';
            document.getElementById('user-manage-sep').style.display = isAdmin ? '' : 'none';
        }
        this.updatePwWarning();
    },

    updatePwWarning: function() {
        var user = Auth.user;
        var show = user && user.role === 'admin' && !user.passwordChanged;
        document.getElementById('pw-warning-banner').style.display = show ? 'block' : 'none';
    },

    checkAuthAndInit: async function() {
        const user = await Auth.validate();
        if (!user) {
            this.showLoginScreen();
            return;
        }
        this.hideLoginScreen();
        this.initializeApp();
    },

    showChangePassword: function() {
        var cpwOverlay = document.getElementById('cpw-overlay');
        cpwOverlay.classList.add('visible');
        document.getElementById('cpw-current').value = '';
        document.getElementById('cpw-new').value = '';
        document.getElementById('cpw-confirm').value = '';
        setCpwError('');
        setTimeout(function() { document.getElementById('cpw-current').focus(); }, 50);
    },

    showManageUsers: async function() {
        var self = this;
        var overlay = document.getElementById('mgr-overlay');
        overlay.classList.add('visible');
        await self.refreshUserTable();
        document.getElementById('mgr-error').textContent = '';
        document.getElementById('mgr-email').value = '';
        document.getElementById('mgr-name').value = '';
        document.getElementById('mgr-pw').value = '';
        document.getElementById('mgr-role').value = 'user';
        document.getElementById('mgr-add-btn').onclick = async function() {
            var email = document.getElementById('mgr-email').value.trim().toLowerCase();
            if (email && !email.includes('@')) email += '@dmhai.local';
            var name = document.getElementById('mgr-name').value.trim();
            var pw = document.getElementById('mgr-pw').value;
            var role = document.getElementById('mgr-role').value;
            var errEl = document.getElementById('mgr-error');
            errEl.textContent = '';
            if (!email || !pw) { errEl.textContent = 'Email and password are required'; return; }
            try {
                const res = await apiFetch('/users', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ email: email, name: name || null, password: pw, role: role })
                });
                const data = await res.json();
                if (!res.ok) { errEl.textContent = data.error || 'Failed'; return; }
                document.getElementById('mgr-email').value = '';
                document.getElementById('mgr-name').value = '';
                document.getElementById('mgr-pw').value = '';
                await self.refreshUserTable();
            } catch(e) { errEl.textContent = e.message; }
        };
    },

    refreshUserTable: async function() {
        var self = this;
        try {
            const res = await apiFetch('/users');
            const users = await res.json();
            var tbody = document.getElementById('mgr-tbody');
            tbody.innerHTML = '';
            users.forEach(function(u) {
                var tr = document.createElement('tr');
                var tdEmail = document.createElement('td');
                tdEmail.textContent = u.email;
                var tdName = document.createElement('td');
                tdName.textContent = u.name || '—';
                var tdRole = document.createElement('td');
                tdRole.textContent = u.role;
                var tdAct = document.createElement('td');
                if (u.id !== Auth.user.id) {
                    var del = document.createElement('button');
                    del.className = 'mgr-del-btn';
                    del.title = 'Remove';
                    del.innerHTML = '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14H6L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/><path d="M9 6V4h6v2"/></svg>';
                    del.addEventListener('click', async function() {
                        if (!confirm('Remove ' + u.email + '?')) return;
                        await apiFetch('/users/' + u.id, { method: 'DELETE' });
                        await self.refreshUserTable();
                    });
                    tdAct.appendChild(del);
                }
                tr.appendChild(tdEmail); tr.appendChild(tdName); tr.appendChild(tdRole); tr.appendChild(tdAct);
                tbody.appendChild(tr);
            });
        } catch(e) { console.error('Failed to load users:', e); }
    },

    initializeApp: async function() {
        this.updateSendBtn();
        var ua = navigator.userAgent;
        var isIos = /iphone|ipad|ipod/i.test(ua);
        var isIosChrome = isIos && /CriOS/i.test(ua);
        var isIosSafari = isIos && !isIosChrome;
        if (isIosChrome && !localStorage.getItem('iosChromeHintShown')) {
            localStorage.setItem('iosChromeHintShown', '1');
            this.setStatus(t('iosChromeHint'));
            setTimeout(function() { UIManager.setStatus(''); }, 9000);
        }
        if (isIosSafari && location.protocol === 'https:' && !localStorage.getItem('iosCertHintShown')) {
            localStorage.setItem('iosCertHintShown', '1');
            var certUrl = 'http://' + location.hostname + ':8080/dmh-ai.crt';
            var statusEl = document.getElementById('status-bar');
            statusEl.innerHTML = '<a href="' + certUrl + '" style="color:#c87830">' + t('iosCertHint') + '</a>';
            statusEl.classList.add('visible');
            setTimeout(function() { statusEl.classList.remove('visible'); statusEl.innerHTML = ''; }, 15000);
        }
        const savedEndpoint = AppConfig.ollamaEndpoint;
        OllamaAPI.setEndpoint(savedEndpoint);
        document.getElementById('endpoint-input').value = savedEndpoint;

        await this.loadPrefs();

        try {
            const models = await OllamaAPI.fetchModels();
            this.populateModelSelects(models);
        } catch (e) {
            this.showError(t('cannotConnectFull'));
        }

        try {
            const sessions = await SessionStore.getSessions();
            if (sessions.length === 0) {
                const model = document.getElementById('header-model-select').value;
                const defaultSession = await SessionStore.createSession(t('defaultSession'), model);
                await SessionStore.setCurrentSessionId(defaultSession.id);
                this.currentSession = defaultSession;
            } else {
                const currentId = await SessionStore.getCurrentSessionId();
                this.currentSession = currentId ? sessions.find(function(s) { return s.id === currentId; }) : sessions[0];
                if (!this.currentSession) this.currentSession = sessions[0];
                await SessionStore.setCurrentSessionId(this.currentSession.id);
                var lastActivity = parseInt(localStorage.getItem('lastActivityAt') || '0');
                var thirtyMin = 30 * 60 * 1000;
                if (lastActivity && Date.now() - lastActivity > thirtyMin &&
                        this.currentSession.messages && this.currentSession.messages.length > 0) {
                    var autoModel = document.getElementById('header-model-select').value || this.currentSession.model;
                    var autoSession = await SessionStore.createSession(t('defaultSession'), autoModel);
                    await SessionStore.setCurrentSessionId(autoSession.id);
                    this.currentSession = autoSession;
                }
            }
            if (this.currentSession && this.currentSession.model) {
                document.getElementById('header-model-select').value = this.currentSession.model;
            }
            await this.renderSessions();
            this.renderChat();
            document.getElementById('message-input').focus();
        } catch (e) {
            console.error('Failed to load sessions:', e);
        }
    },

    populateModelSelects: function(models) {
        const select = document.getElementById('header-model-select');
        select.innerHTML = '';
        const self = this;
        models.forEach(function(model) {
            const option = document.createElement('option');
            option.value = model.name;
            option.textContent = model.name + OllamaAPI.formatSize(model.size);
            select.appendChild(option);
        });
        const names = models.map(function(m) { return m.name; });
        if (self._lastUsedModel && names.indexOf(self._lastUsedModel) !== -1) {
            select.value = self._lastUsedModel;
        } else if (models.length > 0) {
            self._lastUsedModel = models[0].name;
            select.value = models[0].name;
        }
    },

    renderSessions: async function() {
        const self = this;
        const container = document.getElementById('sessions-list');
        container.innerHTML = '';
        const sessions = await SessionStore.getSessions();
        sessions.forEach(function(s) {
            const item = document.createElement('div');
            item.className = 'session-item' + (s.id === self.currentSession.id ? ' active' : '');

            const nameSpan = document.createElement('span');
            nameSpan.className = 'session-name';
            nameSpan.textContent = s.name;
            nameSpan.title = s.name;
            item.addEventListener('click', function() { self.switchSession(s.id); });

            const actions = document.createElement('div');
            actions.className = 'session-actions';

            const editBtn = document.createElement('button');
            editBtn.className = 'session-btn session-btn-edit';
            editBtn.title = t('rename');
            editBtn.innerHTML = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg>';
            editBtn.addEventListener('click', async function(e) {
                e.stopPropagation();
                const newName = await Modal.prompt(t('renameSession'), s.name);
                if (!newName || !newName.trim() || newName === s.name) return;
                s.name = newName;
                await SessionStore.updateSession(s);
                if (self.currentSession.id === s.id) self.currentSession.name = newName;
                await self.renderSessions();
            });

            const delBtn = document.createElement('button');
            delBtn.className = 'session-btn session-btn-delete';
            delBtn.title = t('delete_');
            delBtn.innerHTML = '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6M14 11v6"/><path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/></svg>';
            delBtn.addEventListener('click', async function(e) {
                e.stopPropagation();
                const ok = await Modal.confirm(t('deleteSession'), t('deleteConfirm1') + s.name + t('deleteConfirm2'), t('delete_'));
                if (!ok) return;
                await SessionStore.deleteSession(s.id);
                if (self.currentSession.id === s.id) {
                    const remaining = await SessionStore.getSessions();
                    self.currentSession = remaining.length > 0
                        ? remaining[0]
                        : await SessionStore.createSession('New Session', '');
                    await SessionStore.setCurrentSessionId(self.currentSession.id);
                    self.renderChat();
                }
                await self.renderSessions();
            });

            actions.appendChild(editBtn);
            actions.appendChild(delBtn);
            item.appendChild(nameSpan);
            item.appendChild(actions);
            container.appendChild(item);
        });
    },

    renderChat: function() {
        const container = document.getElementById('chat-container');
        container.innerHTML = '';
        if (!this.currentSession) return;
        var sessionId = this.currentSession.id;
        var renderSession = this.currentSession;
        this.currentSession.messages.forEach(function(msg) {
            const div = document.createElement('div');
            div.className = 'message ' + msg.role;
            var hdr = document.createElement('div');
            hdr.className = 'msg-header';
            hdr.textContent = buildMsgHeader(msg, renderSession);
            div.appendChild(hdr);
            var body = document.createElement('div');
            body.className = 'msg-body';
            if (msg.role === 'assistant') {
                body.innerHTML = marked.parse(msg.content || '');
                div.appendChild(body);
                addCopyButtons(body); wrapTables(body);
            } else {
                body.textContent = msg.content || '';
                if (msg.images && msg.images.length > 0) {
                    msg.images.forEach(function(img) {
                        var wrap = document.createElement('div');
                        wrap.style.cssText = 'margin-top:10px;';
                        var el = document.createElement('img');
                        var src = img.thumbnail
                            ? 'data:image/jpeg;base64,' + img.thumbnail
                            : 'data:' + img.mime + ';base64,' + img.base64;
                        el.src = src;
                        el.style.cssText = 'max-width:100px;border-radius:4px;display:block;';
                        wrap.appendChild(el);
                        if (img.fileId) {
                            var dl = document.createElement('button');
                            dl.style.cssText = 'display:inline-block;margin-top:5px;padding:3px 10px;background:#c87830;color:#fff;font-size:11px;font-weight:600;border-radius:4px;border:none;cursor:pointer;';
                            dl.textContent = '⬇ Download';
                            (function(sid, fid, fname) {
                                dl.onclick = function() {
                                    apiFetch('/assets/' + sid + '/' + fid)
                                        .then(function(r) { return r.blob(); })
                                        .then(function(blob) {
                                            var url = URL.createObjectURL(blob);
                                            var a = document.createElement('a');
                                            a.href = url; a.download = fname;
                                            a.style.display = 'none';
                                            document.body.appendChild(a);
                                            a.click();
                                            document.body.removeChild(a);
                                            setTimeout(function() { URL.revokeObjectURL(url); }, 10000);
                                        });
                                };
                            })(sessionId, img.fileId, img.name || img.fileId);
                            wrap.appendChild(dl);
                        }
                        body.appendChild(wrap);
                    });
                }
                if (msg.files && msg.files.length > 0) {
                    msg.files.forEach(function(f) {
                        var wrap = document.createElement('div');
                        wrap.style.cssText = 'margin-top:8px;border:1px solid #281e38;border-radius:6px;overflow:hidden;max-width:420px;';
                        var header = document.createElement('div');
                        header.style.cssText = 'background:#281e38;padding:4px 10px;font-size:12px;color:#d8c0a0;display:flex;justify-content:space-between;align-items:center;';
                        var nameSpan = document.createElement('span');
                        nameSpan.textContent = '📄 ' + f.name;
                        header.appendChild(nameSpan);
                        if (f.fileId) {
                            var dl = document.createElement('button');
                            dl.style.cssText = 'padding:2px 8px;background:#c87830;color:#fff;font-size:11px;font-weight:600;border-radius:4px;border:none;cursor:pointer;white-space:nowrap;';
                            dl.textContent = '⬇ Download';
                            (function(sid, fid, fname) {
                                dl.onclick = function() {
                                    apiFetch('/assets/' + sid + '/' + fid)
                                        .then(function(r) { return r.blob(); })
                                        .then(function(blob) {
                                            var url = URL.createObjectURL(blob);
                                            var a = document.createElement('a');
                                            a.href = url; a.download = fname;
                                            a.click();
                                            URL.revokeObjectURL(url);
                                        });
                                };
                            })(sessionId, f.fileId, f.name || f.fileId);
                            header.appendChild(dl);
                        }
                        wrap.appendChild(header);
                        if (f.snippet) {
                            var pre = document.createElement('pre');
                            pre.style.cssText = 'margin:0;padding:8px 10px;font-size:11px;color:#9888a8;overflow:hidden;white-space:pre-wrap;word-break:break-all;';
                            pre.textContent = f.snippet;
                            wrap.appendChild(pre);
                        }
                        body.appendChild(wrap);
                    });
                }
                div.appendChild(body);
            }
            container.appendChild(div);
        });
        container.scrollTop = container.scrollHeight;
    },

    fileToBase64: function(file) {
        return new Promise(function(resolve) {
            var reader = new FileReader();
            reader.onload = function(e) { resolve(e.target.result.split(',')[1]); };
            reader.readAsDataURL(file);
        });
    },

    generateThumbnail: function(base64, mime) {
        return new Promise(function(resolve) {
            var img = new Image();
            img.onload = function() {
                var scale = Math.min(1, 100 / img.naturalWidth);
                var canvas = document.createElement('canvas');
                canvas.width = Math.round(img.naturalWidth * scale);
                canvas.height = Math.round(img.naturalHeight * scale);
                canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
                resolve(canvas.toDataURL('image/jpeg', 0.8).split(',')[1]);
            };
            img.src = 'data:' + mime + ';base64,' + base64;
        });
    },

    resizeImage: function(file) {
        var MAX_PX = 1920;
        return new Promise(function(resolve) {
            var url = URL.createObjectURL(file);
            var img = new Image();
            img.onload = function() {
                URL.revokeObjectURL(url);
                var w = img.naturalWidth, h = img.naturalHeight;
                if (w <= MAX_PX && h <= MAX_PX) { resolve(file); return; }
                var scale = MAX_PX / Math.max(w, h);
                var canvas = document.createElement('canvas');
                canvas.width = Math.round(w * scale);
                canvas.height = Math.round(h * scale);
                canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
                canvas.toBlob(function(blob) {
                    resolve(new File([blob], file.name, { type: 'image/jpeg' }));
                }, 'image/jpeg', 0.85);
            };
            img.src = url;
        });
    },

    extractPdfText: async function(file) {
        if (!window.pdfjsLib) throw new Error('PDF.js not loaded');
        var arrayBuffer = await file.arrayBuffer();
        var pdf = await window.pdfjsLib.getDocument({ data: arrayBuffer }).promise;
        var text = '';
        for (var p = 1; p <= pdf.numPages; p++) {
            var page = await pdf.getPage(p);
            var content = await page.getTextContent();
            text += content.items.map(function(item) { return item.str; }).join(' ') + '\n';
        }
        return text.trim();
    },

    isPdf: async function(file) {
        var slice = await file.slice(0, 4).arrayBuffer();
        var bytes = new Uint8Array(slice);
        return bytes[0] === 0x25 && bytes[1] === 0x50 && bytes[2] === 0x44 && bytes[3] === 0x46;
    },

    detectOfficeFormat: async function(file) {
        var slice = await file.slice(0, 4).arrayBuffer();
        var bytes = new Uint8Array(slice);
        if (!(bytes[0] === 0x50 && bytes[1] === 0x4B && bytes[2] === 0x03 && bytes[3] === 0x04)) return null;
        var buf = await file.arrayBuffer();
        var wb = XLSX.read(new Uint8Array(buf), { type: 'array', bookSheets: true });
        if (wb && wb.SheetNames && wb.SheetNames.length > 0) return 'xlsx';
        return null;
    },

    detectDocxOrXlsx: async function(file) {
        var name = file.name.toLowerCase();
        if (name.endsWith('.docx') || file.type.includes('wordprocessingml')) return 'docx';
        if (name.endsWith('.xlsx') || file.type.includes('spreadsheetml')) return 'xlsx';
        var slice = await file.slice(0, 4).arrayBuffer();
        var bytes = new Uint8Array(slice);
        if (!(bytes[0] === 0x50 && bytes[1] === 0x4B && bytes[2] === 0x03 && bytes[3] === 0x04)) return null;
        var buf = await file.arrayBuffer();
        var zip = new Uint8Array(buf);
        var text = new TextDecoder('utf-8', { fatal: false }).decode(zip);
        if (text.includes('word/document.xml')) return 'docx';
        if (text.includes('xl/workbook.xml')) return 'xlsx';
        return null;
    },

    extractDocxText: async function(file) {
        var buf = await file.arrayBuffer();
        var result = await mammoth.extractRawText({ arrayBuffer: buf });
        return result.value.trim();
    },

    extractXlsxText: async function(file) {
        var buf = await file.arrayBuffer();
        var wb = XLSX.read(new Uint8Array(buf), { type: 'array' });
        return wb.SheetNames.map(function(name) {
            var csv = XLSX.utils.sheet_to_csv(wb.Sheets[name]);
            return '--- Sheet: ' + name + ' ---\n' + csv;
        }).join('\n\n').trim();
    },

    handleFileSelect: async function(files) {
        const self = this;
        const sessionId = this.currentSession ? this.currentSession.id : 'default';
        self.setStatus(t('attaching'));
        for (var i = 0; i < files.length; i++) {
            var file = files[i];
            try {
                var IMAGE_EXTS = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.heic', '.heif'];
                var nameLower = file.name.toLowerCase();
                var isHeic = nameLower.endsWith('.heic') || nameLower.endsWith('.heif') ||
                             file.type === 'image/heic' || file.type === 'image/heif';
                if (isHeic && typeof heic2any !== 'undefined') {
                    var converted = await heic2any({ blob: file, toType: 'image/jpeg', quality: 0.9 });
                    var jpegName = file.name.replace(/\.hei[cf]$/i, '.jpg');
                    file = new File([converted], jpegName, { type: 'image/jpeg' });
                    nameLower = file.name.toLowerCase();
                }
                var isImage = IMAGE_EXTS.some(function(ext) { return nameLower.endsWith(ext); });
                var isText = file.type.startsWith('text/');
                var isPdf = await self.isPdf(file);
                var officeFormat = (!isImage && !isText && !isPdf) ? await self.detectDocxOrXlsx(file) : null;

                if (!isImage && !isText && !isPdf && !officeFormat) {
                    self.setStatus(t('unsupported1') + file.name + t('unsupported2') + IMAGE_EXTS.join('/') + '.');
                    setTimeout(function() { self.setStatus(''); }, 4000);
                    continue;
                }

                var extractedText = null;
                if (isPdf) extractedText = await self.extractPdfText(file);
                else if (officeFormat === 'docx') extractedText = await self.extractDocxText(file);
                else if (officeFormat === 'xlsx') extractedText = await self.extractXlsxText(file);

                var uploadFile = file;
                if (extractedText !== null) {
                    uploadFile = new File([extractedText], file.name + '.txt', { type: 'text/plain' });
                }
                var formData = new FormData();
                formData.append('file', uploadFile);
                formData.append('sessionId', sessionId);
                var res = await apiFetch('/assets', { method: 'POST', body: formData });
                var data = await res.json();

                if (isImage) {
                    var resizedFile = await self.resizeImage(file);
                    var resizedBase64 = await self.fileToBase64(resizedFile);
                    var thumbnail = await self.generateThumbnail(resizedBase64, 'image/jpeg');
                    self.attachedFiles.push({
                        id: data.id, name: file.name, type: 'image', mime: data.mime,
                        thumbnailBase64: thumbnail,
                        fullBase64: resizedBase64
                    });
                } else {
                    var lines = (data.content || '').split('\n');
                    var snippet = lines.slice(0, 5).join('\n') + (lines.length > 5 ? '\n…' : '');
                    self.attachedFiles.push({
                        id: data.id, name: file.name, type: 'text',
                        snippet: snippet,
                        fullContent: data.content
                    });
                }
                self.renderAttachments();
            } catch (e) {
                console.error('Upload failed:', e);
            }
        }
        self.setStatus('');
    },

    removeAttachment: function(id) {
        this.attachedFiles = this.attachedFiles.filter(function(f) { return f.id !== id; });
        this.renderAttachments();
    },

    renderAttachments: function() {
        const bar = document.getElementById('attachments-bar');
        const self = this;
        if (this.attachedFiles.length === 0) {
            bar.className = 'attachments-bar';
            bar.innerHTML = '';
            return;
        }
        bar.className = 'attachments-bar visible';
        bar.innerHTML = '';
        this.attachedFiles.forEach(function(f) {
            var chip = document.createElement('div');
            chip.className = 'attachment-chip';
            var icon = f.type === 'image' ? '🖼 ' : '📄 ';
            chip.innerHTML = '<span>' + icon + f.name + '</span>';
            var btn = document.createElement('button');
            btn.textContent = '×';
            btn.onclick = function() { self.removeAttachment(f.id); };
            chip.appendChild(btn);
            bar.appendChild(chip);
        });
        this.updateSendBtn();
    },

    updateSendBtn: function() {
        var hasText = document.getElementById('message-input').value.trim() !== '';
        var hasAttachment = this.attachedFiles.length > 0;
        document.getElementById('send-btn').disabled = !hasText && !hasAttachment;
    },

    saveStreamingProgress: function() {
        if (!this._pendingContent || !this._pendingSession) return;
        var last = this._pendingSession.messages[this._pendingSession.messages.length - 1];
        if (last && last.role === 'assistant') return;
        this._pendingSession.messages.push({ role: 'assistant', content: this._pendingContent });
        var prev = this._pendingSession.messages[this._pendingSession.messages.length - 2];
        if (prev && prev.role === 'user') prev._sentToLLM = true;
        SessionStore.updateSession(this._pendingSession);
        this._pendingContent = '';
        this._pendingSession = null;
    },

    updateEndpoint: async function() {
        const url = document.getElementById('endpoint-input').value.trim();
        if (!url) return;
        OllamaAPI.setEndpoint(url);
        AppConfig.saveOllamaEndpoint(url);
        const btn = document.getElementById('endpoint-update-btn');
        btn.disabled = true;
        btn.textContent = t('updating');
        try {
            const models = await OllamaAPI.fetchModels();
            const currentModel = this.currentSession ? this.currentSession.model : null;
            this.populateModelSelects(models);
            const names = models.map(function(m) { return m.name; });
            if (currentModel && names.indexOf(currentModel) !== -1) {
                document.getElementById('header-model-select').value = currentModel;
            } else if (models.length > 0) {
                this.switchModel(models[0].name);
            }
        } catch (e) {
            this.showError(t('cannotConnectTo') + url);
        } finally {
            btn.disabled = false;
            btn.textContent = t('update');
        }
    },

    clearSession: async function() {
        if (!this.currentSession) return;
        const ok = await Modal.confirm(t('clearSession'), t('clearConfirm1') + this.currentSession.name + t('clearConfirm2'), t('clear'));
        if (!ok) return;
        this.currentSession.messages = [];
        this.currentSession.context = { summary: null, summaryUpToIndex: -1 };
        await SessionStore.updateSession(this.currentSession);
        this.attachedFiles = [];
        this.renderAttachments();
        this.renderChat();
    },

    createNewSession: async function() {
        const currentModel = document.getElementById('header-model-select').value;
        const session = await SessionStore.createSession(t('newChat'), currentModel);
        await SessionStore.setCurrentSessionId(session.id);
        this.currentSession = session;
        await this.renderSessions();
        this.renderChat();
        document.getElementById('message-input').focus();
    },

    switchSession: async function(id) {
        this.currentSession = await SessionStore.getSession(id);
        await SessionStore.setCurrentSessionId(id);
        document.getElementById('header-model-select').value = this.currentSession.model;
        await this.renderSessions();
        this.renderChat();
    },

    savePrefs: function(partial) {
        apiFetch('/users/prefs', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(partial) }).catch(function() {});
    },

    loadPrefs: async function() {
        try {
            const res = await apiFetch('/users/prefs');
            if (!res.ok) return;
            const prefs = await res.json();
            if (prefs.lang && I18n._strings[prefs.lang]) {
                I18n.setLang(prefs.lang);
                applyLanguage();
            }
            if (prefs.model) this._lastUsedModel = prefs.model;
        } catch(e) {}
    },

    switchModel: function(modelName) {
        if (this.currentSession) {
            this.currentSession.model = modelName;
            SessionStore.updateSession(this.currentSession);
        }
        this._lastUsedModel = modelName;
        this.savePrefs({ model: modelName });
        document.getElementById('header-model-select').value = modelName;
    },

    setStatus: function(text) {
        document.getElementById('status-text').textContent = text;
        document.getElementById('status-bar').classList.toggle('visible', !!text);
    },

    detectWebSearch: async function(userMessage, recentMsgs, signal) {
        try {
            var contextBlock = '';
            if (recentMsgs && recentMsgs.length > 0) {
                contextBlock = 'Recent conversation:\n' + recentMsgs.map(function(m) {
                    var text = typeof m.content === 'string' ? m.content : (Array.isArray(m.content) ? m.content.filter(function(p) { return p.type === 'text'; }).map(function(p) { return p.text; }).join(' ') : '');
                    return (m.role === 'user' ? 'User: ' : 'Assistant: ') + text.slice(0, 300);
                }).join('\n') + '\n\n';
            }
            const res = await fetch(OllamaAPI.BASE_URL + '/generate', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    model: this.currentSession.model,
                    stream: false,
                    think: false,
                    options: { temperature: 0, num_predict: 4 },
                    prompt: contextBlock + 'New message: ' + userMessage + '\n\nDoes this new message require a live internet search to answer — such as current news, prices, weather, sports scores, recent events, or anything that changes over time? Answer NO if the message is a follow-up, formatting request, rephrasing, or asks to rewrite/translate/summarize/explain a previous response. Reply in English only with YES or NO.\n\nAnswer:'
                }),
                signal: signal
            });
            const data = await res.json();
            return /^(yes|ja|oui|s[ií]|да)/i.test((data.response || '').trim());
        } catch (e) { return false; }
    },

    getSearchKeywords: async function(userMessage, signal) {
        try {
            const res = await fetch(OllamaAPI.BASE_URL + '/generate', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    model: this.currentSession.model,
                    stream: false,
                    think: false,
                    options: { temperature: 0 },
                    prompt:
                        'You are a search query generator. Rules:\n' +
                        '1. Do NOT answer the question\n' +
                        '2. Do NOT use names, facts, or answers from your training data — they may be outdated\n' +
                        '3. Generate neutral descriptive keywords a human would search to find the CURRENT answer online\n' +
                        '4. Always include the year ' + new Date().getFullYear() + '\n\n' +
                        'Does this question need current/live information (current leaders, prices, news, events, etc.)?\n' +
                        'Question: "' + userMessage + '"\n\n' +
                        'If YES: reply with ONLY 4-6 search keywords. No names from your training. No explanation.\n' +
                        'If NO: reply with only the word NO.\n' +
                        'Always reply in English only.'
                }),
                signal: signal
            });
            const data = await res.json();
            const reply = (data.response || '').trim();
            if (!reply || /^(no|nein|non|нет)\b/i.test(reply)) return null;
            return reply.replace(/['"*\n]/g, ' ').trim();
        } catch (e) { return null; }
    },

    searchWeb: async function(keywords, signal) {
        try {
            const url = '/search?q=' + encodeURIComponent(keywords) + '&engine=' + encodeURIComponent(AppConfig.searxngUrl);
            const res = await apiFetch(url, { signal: signal });
            if (!res.ok) return null;
            const data = await res.json();
            const results = (data.results || []).filter(function(r) { return r.title || r.content; });
            if (!results.length) return null;
            return results.map(function(r, i) {
                return (i + 1) + '. ' + r.title + ' (' + r.url + ')\n   ' + (r.content || '').slice(0, 800);
            }).join('\n\n');
        } catch (e) { return null; }
    },

    synthesizeResults: async function(question, keywords, results, today, signal) {
        try {
            const res = await fetch(OllamaAPI.BASE_URL + '/generate', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    model: this.currentSession.model,
                    stream: false,
                    think: false,
                    options: { temperature: 0 },
                    prompt: 'Today is ' + today + '. Extract the key facts from these web search results to answer the question. Be concise and factual. Use only what the results say.\n\nQuestion: ' + question + '\n\nSearch results:\n' + results + '\n\nKey facts from results:'
                }),
                signal: signal
            });
            const data = await res.json();
            return (data.response || '').trim() || results;
        } catch (e) { return results; }
    },

    sendMessage: async function() {
        const self = this;
        if (this.isStreaming) return;
        const input = document.getElementById('message-input');
        const content = input.value.trim();
        if (!content && this.attachedFiles.length === 0) return;

        if (!this.currentSession.context) {
            this.currentSession.context = { summary: null, summaryUpToIndex: -1 };
        }

        const contextWindow = await OllamaAPI.fetchContextWindow(this.currentSession.model);
        if (ContextManager.shouldCompact(this.currentSession, contextWindow, content)) {
            await ContextManager.compact(this.currentSession);
        }

        var contentForAPI = content;
        var imagesForAPI = [];
        var imagesForStorage = [];
        var filesForStorage = [];
        this.attachedFiles.forEach(function(f) {
            if (f.type === 'text') {
                contentForAPI += '\n\n[File: ' + f.name + ']\n```\n' + f.fullContent + '\n```';
                filesForStorage.push({ name: f.name, fileId: f.id, snippet: f.snippet });
            } else if (f.type === 'image') {
                imagesForAPI.push(f.fullBase64);
                imagesForStorage.push({ thumbnail: f.thumbnailBase64, mime: f.mime, fileId: f.id, name: f.name });
            }
        });

        if (imagesForAPI.length > 0 && !(await OllamaAPI.hasVision(this.currentSession.model))) {
            this.setStatus(t('noVision1') + this.currentSession.model + t('noVision2'));
            setTimeout(function() { self.setStatus(''); }, 6000);
            return;
        }

        var userMsgForStorage = { role: 'user', content: content, ts: Date.now() };
        if (imagesForStorage.length > 0) userMsgForStorage.images = imagesForStorage;
        if (filesForStorage.length > 0) userMsgForStorage.files = filesForStorage;
        var userMsgForAPI = { role: 'user', content: contentForAPI };
        if (imagesForAPI.length > 0) userMsgForAPI.images = imagesForAPI;

        this.currentSession.messages.push(userMsgForStorage);
        localStorage.setItem('lastActivityAt', Date.now().toString());
        this.attachedFiles = [];
        this.renderAttachments();
        await SessionStore.updateSession(this.currentSession);
        this.renderChat();
        input.value = '';
        input.style.height = 'auto';

        const container = document.getElementById('chat-container');
        const assistantTs = Date.now();
        const assistantDiv = document.createElement('div');
        assistantDiv.className = 'message assistant';
        const assistantHdr = document.createElement('div');
        assistantHdr.className = 'msg-header';
        assistantHdr.textContent = buildMsgHeader({ role: 'assistant', ts: assistantTs, model: this.currentSession.model }, this.currentSession);
        assistantDiv.appendChild(assistantHdr);
        const bodyDiv = document.createElement('div');
        bodyDiv.className = 'msg-body';
        assistantDiv.appendChild(bodyDiv);
        container.appendChild(assistantDiv);
        container.scrollTop = container.scrollHeight;

        this.isStreaming = true;
        this._pendingContent = '';
        this._pendingSession = null;
        const pipelineController = new AbortController();
        const pipelineSignal = pipelineController.signal;
        self._streamController = pipelineController;
        document.getElementById('send-btn').disabled = true;
        document.getElementById('stop-gen-btn').textContent = t('stopGen');
        document.getElementById('stop-gen-btn').style.display = '';

        let apiMessages = prepareForAPI(ContextManager.buildContextMessages(this.currentSession));
        apiMessages[apiMessages.length - 1] = userMsgForAPI;
        const recentMsgs = (this.currentSession.messages || []).filter(function(m) { return m.role === 'user' || m.role === 'assistant'; }).slice(-4);
        const needsWebSearch = await this.detectWebSearch(content, recentMsgs, pipelineSignal);
        if (pipelineSignal.aborted) return;
        const cleanedContent = content;
        syslog('[SEND] user="' + content.slice(0, 120) + '" needsWebSearch=' + needsWebSearch + ' cleanedQuery="' + cleanedContent + '"');
        if (AppConfig.searxngUrl && needsWebSearch) {
            this.setStatus(t('genKeywords'));
            const keywords = await this.getSearchKeywords(cleanedContent, pipelineSignal);
            if (pipelineSignal.aborted) return;
            syslog('[KEYWORDS] result="' + keywords + '"');
            if (keywords) {
                this.setStatus(t('searchingWeb'));
                const results = await this.searchWeb(keywords, pipelineSignal);
                if (pipelineSignal.aborted) return;
                syslog('[SEARCH] got results: ' + (results ? results.slice(0, 200) : 'null'));
                if (results) {
                    this.setStatus(t('synthesizing'));
                    const today = new Date().toDateString();
                    const synthesis = await this.synthesizeResults(cleanedContent, keywords, results, today, pipelineSignal);
                    if (pipelineSignal.aborted) return;
                    syslog('[SYNTHESIS] ' + synthesis);
                    apiMessages = apiMessages.slice(0, -1).concat([{
                        role: 'user',
                        content: 'User request: ' + cleanedContent + '\n\nWeb search results (retrieved ' + today + '):\n' + synthesis + '\n\nUsing the user request and the web search results above, compile a complete and accurate answer.'
                    }]);
                    syslog('[INJECT] synthesized results injected into context');
                } else {
                    syslog('[SEARCH] fallback: search returned no results');
                    bodyDiv.innerHTML = '<em style="color:#d0a050;">' + t('searchUnavail') + '</em><br><br>';
                }
            }
        }
        this.setStatus(t('waiting1') + this.currentSession.model + t('waiting2') + this.currentSession.name + t('waiting3'));

        let assistantContent = '';
        const searchWarning = bodyDiv.innerHTML;
        const sessionAtSend = this.currentSession;
        self._pendingSession = sessionAtSend;
        OllamaAPI.streamChat(
            sessionAtSend.model,
            apiMessages,
            function(chunk) {
                assistantContent += chunk;
                self._pendingContent = assistantContent;
                if (self.currentSession === sessionAtSend) {
                    bodyDiv.innerHTML = searchWarning + marked.parse(assistantContent);
                    addCopyButtons(bodyDiv); wrapTables(bodyDiv);
                    container.scrollTop = container.scrollHeight;
                }
            },
            function() {
                sessionAtSend.messages.push({ role: 'assistant', content: assistantContent, ts: assistantTs, model: sessionAtSend.model });
                var userMsg = sessionAtSend.messages[sessionAtSend.messages.length - 2];
                if (userMsg && userMsg.role === 'user') userMsg._sentToLLM = true;
                SessionStore.updateSession(sessionAtSend);
                self._pendingContent = '';
                self._pendingSession = null;
                self._streamController = null;
                self.isStreaming = false;
                self.updateSendBtn();
                self.setStatus('');
                document.getElementById('stop-gen-btn').style.display = 'none';
                if (sessionAtSend.messages.length === 2) {
                    var _defaultNames = [];
                    Object.keys(I18n._strings).forEach(function(lang) {
                        var s = I18n._strings[lang];
                        if (s.newChat) _defaultNames.push(s.newChat.toLowerCase());
                        if (s.defaultSession) _defaultNames.push(s.defaultSession.toLowerCase());
                    });
                    if (_defaultNames.indexOf(sessionAtSend.name.toLowerCase()) !== -1) {
                        self.autoNameSession(sessionAtSend);
                    }
                }
            },
            function(err) {
                console.error('Stream error:', err);
                if (self.currentSession === sessionAtSend && assistantContent) {
                    bodyDiv.innerHTML = searchWarning + marked.parse(assistantContent);
                    addCopyButtons(bodyDiv); wrapTables(bodyDiv);
                }
                self.saveStreamingProgress();
                self._streamController = null;
                self.isStreaming = false;
                self.updateSendBtn();
                self.setStatus('');
                document.getElementById('stop-gen-btn').style.display = 'none';
            },
            pipelineSignal
        );
    },

    autoNameSession: async function(session) {
        try {
            var firstUser = session.messages.find(function(m) { return m.role === 'user'; });
            if (!firstUser) return;
            var userText = typeof firstUser.content === 'string' ? firstUser.content
                : (Array.isArray(firstUser.content) ? ((firstUser.content.find(function(p) { return p.type === 'text'; }) || {}).text || '') : '');
            if (!userText.trim()) return;
            var name = await OllamaAPI.summarize(session.model, [{
                role: 'user',
                content: 'Give a short title (3-5 words) for a chat conversation that starts with this message: "' + userText.slice(0, 300) + '". Reply with only the title, no quotes, no explanation.'
            }]);
            if (!name || !name.trim()) return;
            name = name.trim().replace(/^["""''']+|["""''']+$/g, '').trim();
            if (!name) return;
            session.name = name;
            await SessionStore.updateSession(session);
            await this.renderSessions();
        } catch(e) {}
    },

    showError: function(message) {
        document.getElementById('error-message').textContent = message;
        document.getElementById('error-banner').style.display = 'block';
    },

    hideError: function() {
        document.getElementById('error-banner').style.display = 'none';
    }
};

document.addEventListener('DOMContentLoaded', function() {
    UIManager.init();
});
