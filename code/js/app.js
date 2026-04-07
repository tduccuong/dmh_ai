marked.use({
    gfm: true,
    breaks: true,
    renderer: {
        link: function(token) {
            return '<a href="' + token.href + '" target="_blank" rel="noopener noreferrer">' + token.text + '</a>';
        }
    }
});

function renderWithMath(markdown) {
    if (!window.katex) return marked.parse(markdown);
    var blocks = [];
    var n = 0;
    var ph = function(i) { return 'KATEXBLOCK' + i + 'END'; };
    // Extract math blocks before marked sees them (longest delimiters first)
    var safe = markdown
        .replace(/\$\$([\s\S]*?)\$\$/g, function(_, m) { blocks.push({d: true, m: m}); return ph(n++); })
        .replace(/\\\[([\s\S]*?)\\\]/g, function(_, m) { blocks.push({d: true, m: m}); return ph(n++); })
        .replace(/\\\(([\s\S]*?)\\\)/g, function(_, m) { blocks.push({d: false, m: m}); return ph(n++); })
        .replace(/\$([^\$\n]{1,400}?)\$/g, function(_, m) { blocks.push({d: false, m: m}); return ph(n++); });
    var html = marked.parse(safe);
    blocks.forEach(function(b, i) {
        var rendered = katex.renderToString(b.m, { displayMode: b.d, throwOnError: false, output: 'html' });
        html = html.split(ph(i)).join(rendered);
    });
    return html;
}

const I18n = {
    _lang: localStorage.getItem('lang') || 'en',
    _strings: {
        en: {
            retry: 'Retry', clear: 'Clear', send: 'Send', cancel: 'Cancel', ok: 'OK', stopGen: 'Stop',
            update: 'Update', rename: 'Rename', delete_: 'Delete', download: '⬇ Download',
            newSession: '+ New Session', newChat: 'New chat',
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
            fetchingPages: 'Reading web sources...',
            synthesizing: 'Synthesizing results...',
            thinking: ' is thinking...', answering: ' is answering...', compacting: 'Compacting conversation...',
            settingsChatSection: 'Chat', settingsCompactLabel: 'Compact after messages', settingsKeepRecentLabel: 'Keep recent messages',
            settingsNavModel: 'Models', settingsNavConversation: 'Conversation',
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
            settings: 'Settings', sysSettings: 'System Settings',
            recQuickAnswer: '👁 Quick Answer', recDeepThinker: '💡 Deep Thinker', recTechExpert: '🛠 Technical Expert', recWordsmith: '✍ Wordsmith', recMathMaster: '🧮 Math Master',
            noModelAvail: 'No model available. Please configure a model in Settings first.',
            profileSection: 'Companion Memory', profileEmpty: 'No facts remembered yet.',
            profileClear: 'Clear memory', profileClearConfirm: 'This will reset everything DMH-AI has learned about you. You may notice a different feeling next time — it will understand you again over time, but that takes a while. You can always rebuild it from Conversation Settings. Are you sure?',
            profileCondenseLabel: 'Condense after facts',
            convSettings: 'Conversation Settings',
        },
        vi: {
            retry: 'Thử lại', clear: 'Xóa', send: 'Gửi', cancel: 'Hủy', ok: 'OK', stopGen: 'Dừng',
            update: 'Cập nhật', rename: 'Đổi tên', delete_: 'Xóa', download: '⬇ Tải về',
            newSession: '+ Phiên mới', newChat: 'Cuộc trò chuyện mới',
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
            searchingWeb: 'Đang tìm kiếm web...',
            fetchingPages: 'Đang đọc nguồn web...',
            synthesizing: 'Đang tổng hợp kết quả...',
            thinking: ' đang suy nghĩ...', answering: ' đang trả lời...', compacting: 'Đang nén hội thoại...',
            settingsChatSection: 'Chat', settingsCompactLabel: 'Nén sau số tin nhắn', settingsKeepRecentLabel: 'Giữ tin nhắn gần đây',
            settingsNavModel: 'Mô hình', settingsNavConversation: 'Hội thoại',
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
            settings: 'Cài đặt', sysSettings: 'Cài đặt hệ thống',
            recQuickAnswer: '👁 Trả lời nhanh', recDeepThinker: '💡 Suy nghĩ sâu', recTechExpert: '🛠 Chuyên gia kỹ thuật', recWordsmith: '✍ Nhà văn', recMathMaster: '🧮 Toán học',
            noModelAvail: 'Không có mô hình nào. Vui lòng cấu hình trong Cài đặt trước.',
            profileSection: 'Bộ nhớ đồng hành', profileEmpty: 'Chưa ghi nhớ điều gì.',
            profileClear: 'Xóa bộ nhớ', profileClearConfirm: 'Thao tác này sẽ xóa toàn bộ những gì DMH-AI đã hiểu về bạn. Lần trò chuyện tiếp theo có thể cảm giác khác đi — DMH-AI sẽ dần hiểu bạn trở lại theo thời gian. Bạn có thể xây dựng lại bất cứ lúc nào trong Cài đặt hội thoại. Bạn có chắc không?',
            profileCondenseLabel: 'Cô đọng sau số sự kiện',
            convSettings: 'Cài đặt hội thoại',
        },
        de: {
            retry: 'Wiederholen', clear: 'Löschen', send: 'Senden', cancel: 'Abbrechen', ok: 'OK', stopGen: 'Stopp',
            update: 'Aktualisieren', rename: 'Umbenennen', delete_: 'Löschen', download: '⬇ Herunterladen',
            newSession: '+ Neue Sitzung', newChat: 'Neuer Chat',
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
            fetchingPages: 'Web-Quellen werden gelesen...',
            synthesizing: 'Ergebnisse werden zusammengefasst...',
            thinking: ' denkt nach...', answering: ' antwortet...', compacting: 'Konversation wird komprimiert...',
            settingsChatSection: 'Chat', settingsCompactLabel: 'Komprimieren nach Nachrichten', settingsKeepRecentLabel: 'Neueste Nachrichten behalten',
            settingsNavModel: 'Modelle', settingsNavConversation: 'Gespräch',
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
            settings: 'Einstellungen', sysSettings: 'Systemeinstellungen',
            recQuickAnswer: '👁 Schnelle Antwort', recDeepThinker: '💡 Tiefdenker', recTechExpert: '🛠 Technischer Experte', recWordsmith: '✍ Wortschmied', recMathMaster: '🧮 Mathe-Meister',
            noModelAvail: 'Kein Modell verfügbar. Bitte zuerst in den Einstellungen konfigurieren.',
            profileSection: 'Begleitergedächtnis', profileEmpty: 'Noch keine Fakten gespeichert.',
            profileClear: 'Gedächtnis löschen', profileClearConfirm: 'Damit wird alles zurückgesetzt, was DMH-AI über Sie gelernt hat. Beim nächsten Gespräch kann sich etwas anders anfühlen — es wird Sie mit der Zeit wieder verstehen. Sie können es jederzeit über die Gesprächseinstellungen neu aufbauen. Sind Sie sicher?',
            profileCondenseLabel: 'Verdichten nach Fakten',
            convSettings: 'Gesprächseinstellungen',
        },
        es: {
            retry: 'Reintentar', clear: 'Limpiar', send: 'Enviar', cancel: 'Cancelar', ok: 'OK', stopGen: 'Detener',
            update: 'Actualizar', rename: 'Renombrar', delete_: 'Eliminar', download: '⬇ Descargar',
            newSession: '+ Nueva sesión', newChat: 'Nueva conversación',
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
            fetchingPages: 'Leyendo fuentes web...',
            synthesizing: 'Sintetizando resultados...',
            thinking: ' está pensando...', answering: ' está respondiendo...', compacting: 'Comprimiendo conversación...',
            settingsChatSection: 'Chat', settingsCompactLabel: 'Compactar después de mensajes', settingsKeepRecentLabel: 'Mantener mensajes recientes',
            settingsNavModel: 'Modelos', settingsNavConversation: 'Conversación',
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
            settings: 'Configuración', sysSettings: 'Configuración del sistema',
            recQuickAnswer: '👁 Respuesta rápida', recDeepThinker: '💡 Pensador profundo', recTechExpert: '🛠 Experto técnico', recWordsmith: '✍ Plumista', recMathMaster: '🧮 Maestro Matemático',
            noModelAvail: 'Ningún modelo disponible. Configure uno en Ajustes primero.',
            profileSection: 'Memoria del compañero', profileEmpty: 'Aún no hay hechos recordados.',
            profileClear: 'Borrar memoria', profileClearConfirm: 'Esto reiniciará todo lo que DMH-AI ha aprendido sobre usted. La próxima vez que chatee puede sentirse diferente — lo entenderá de nuevo con el tiempo. Siempre puede reconstruirlo desde Configuración de conversación. ¿Está seguro?',
            profileCondenseLabel: 'Condensar después de hechos',
            convSettings: 'Configuración de conversación',
        },
        fr: {
            retry: 'Réessayer', clear: 'Effacer', send: 'Envoyer', cancel: 'Annuler', ok: 'OK', stopGen: 'Arrêter',
            update: 'Mettre à jour', rename: 'Renommer', delete_: 'Supprimer', download: '⬇ Télécharger',
            newSession: '+ Nouvelle session', newChat: 'Nouvelle conversation',
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
            searchingWeb: 'Recherche web...',
            fetchingPages: 'Lecture des sources web...',
            synthesizing: 'Synthèse des résultats...',
            thinking: ' réfléchit...', answering: ' répond...', compacting: 'Compactage de la conversation...',
            settingsChatSection: 'Chat', settingsCompactLabel: 'Compacter après messages', settingsKeepRecentLabel: 'Garder les messages récents',
            settingsNavModel: 'Modèles', settingsNavConversation: 'Conversation',
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
            settings: 'Paramètres', sysSettings: 'Paramètres système',
            recQuickAnswer: '👁 Réponse rapide', recDeepThinker: '💡 Réflexion profonde', recTechExpert: '🛠 Expert technique', recWordsmith: '✍ Plume', recMathMaster: '🧮 Maître des maths',
            noModelAvail: 'Aucun modèle disponible. Veuillez d\'abord en configurer un dans les Paramètres.',
            profileSection: 'Mémoire du compagnon', profileEmpty: 'Aucun fait mémorisé pour l\'instant.',
            profileClear: 'Effacer la mémoire', profileClearConfirm: 'Cela réinitialisera tout ce que DMH-AI a appris sur vous. La prochaine conversation pourrait sembler différente — il vous comprendra à nouveau avec le temps. Vous pouvez toujours le reconstruire depuis Paramètres de conversation. Êtes-vous sûr ?',
            profileCondenseLabel: 'Condenser après faits',
            convSettings: 'Paramètres de conversation',
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
        let res;
        try {
            res = await fetch('/auth/login', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ email: email, password: password }),
                signal: AbortSignal.timeout(10000)
            });
        } catch(e) {
            // On iOS/Android with an untrusted self-signed certificate, fetch hangs or
            // fails immediately with a network error. Give the user actionable guidance.
            if (location.protocol === 'https:') {
                throw new Error('Cannot connect. On mobile, you may need to install the self-signed certificate first — see the README or try the HTTP endpoint (port 8080).');
            }
            throw new Error('Cannot connect to server. Is the app running?');
        }
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

function isCloudModel(model) {
    return RECOMMENDED_CLOUD_MODEL_NAMES.indexOf(model) !== -1 ||
           Settings.cloudModels.indexOf(model) !== -1;
}

function cloudRoutedFetch(model, path, body, signal) {
    var acct = isCloudModel(model) ? CloudAccountPool.getNext() : null;
    var url = acct ? '/cloud-api' + path : OllamaAPI.BASE_URL + path;
    var headers = { 'Content-Type': 'application/json' };
    if (acct) {
        headers['Authorization'] = 'Bearer ' + (Auth.token || '');
        headers['X-Cloud-Key'] = acct.apiKey;
    }
    return fetch(url, { method: 'POST', headers: headers, body: JSON.stringify(body), signal: signal });
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

function getRecommendedCloudModels() {
    return [
        { name: 'ministral-3:14b-cloud',          label: t('recQuickAnswer') },
        { name: 'gemma4:31b-cloud',               label: t('recWordsmith') },
        { name: 'qwen3-vl:235b-instruct-cloud',   label: t('recDeepThinker') },
        { name: 'qwen3-vl:235b-cloud',            label: t('recMathMaster') },
    ];
}
// Constant names for filtering (language-independent)
const RECOMMENDED_CLOUD_MODEL_NAMES = ['ministral-3:14b-cloud', 'qwen3-vl:235b-instruct-cloud', 'gemma4:31b-cloud', 'qwen3-vl:235b-cloud'];

function getModelDisplayName(model) {
    var rec = getRecommendedCloudModels().find(function(r) { return r.name === model; });
    return rec ? rec.label : model;
}

const Settings = {
    _accounts: [],
    _cloudModels: [],
    _ollamaEndpoint: '',
    _compactTurns: 90,
    _keepRecent: 0,
    _condenseFacts: 50,
    get accounts() { return this._accounts; },
    get cloudModels() { return this._cloudModels; },
    saveAccounts: function(list) {
        this._accounts = list;
        this._persist();
    },
    saveCloudModels: function(list) {
        this._cloudModels = list;
        this._persist();
    },
    saveOllamaEndpoint: function(url) {
        this._ollamaEndpoint = url || '';
        AppConfig.saveOllamaEndpoint(url);
    },
    _persist: function() {
        return apiFetch('/admin/settings', {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ accounts: this._accounts, cloudModels: this._cloudModels, ollamaEndpoint: this._ollamaEndpoint, compactTurns: this._compactTurns, keepRecent: this._keepRecent, condenseFacts: this._condenseFacts })
        }).catch(function() {});
    },
    load: async function() {
        try {
            const res = await apiFetch('/admin/settings');
            if (res && res.ok) {
                const d = await res.json();
                this._accounts = Array.isArray(d.accounts) ? d.accounts : [];
                this._cloudModels = Array.isArray(d.cloudModels) ? d.cloudModels : [];
                if (d.ollamaEndpoint !== undefined) {
                    this._ollamaEndpoint = d.ollamaEndpoint || '';
                    AppConfig.saveOllamaEndpoint(this._ollamaEndpoint);
                    OllamaAPI.setEndpoint(this._ollamaEndpoint);
                }
                if (d.compactTurns !== undefined) {
                    this._compactTurns = parseInt(d.compactTurns) || ContextManager.TURN_THRESHOLD;
                    ContextManager.TURN_THRESHOLD = this._compactTurns;
                }
                if (d.keepRecent !== undefined) {
                    this._keepRecent = parseInt(d.keepRecent) || 0;
                    ContextManager.KEEP_RECENT_OVERRIDE = this._keepRecent;
                }
                if (d.condenseFacts !== undefined) {
                    this._condenseFacts = parseInt(d.condenseFacts) || 50;
                }
            }
        } catch(e) {}
    }
};

const UserProfile = {
    _facts: '',  // plain text bullet list

    load: async function() {
        try {
            const res = await apiFetch('/user/profile');
            if (res && res.ok) {
                const d = await res.json();
                this._facts = d.profile || '';
                syslog('[PROFILE] loaded ' + this._facts.split('\n').filter(function(l){return l.trim();}).length + ' fact(s)');
            }
        } catch(e) { syslog('[PROFILE] load error: ' + e); }
    },

    save: async function() {
        try {
            await apiFetch('/user/profile', {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ profile: this._facts })
            });
        } catch(e) {}
    },

    clear: async function() {
        this._facts = '';
        await this.save();
    },

    // Run after each LLM turn — extract new facts and merge into profile
    extractAndMerge: async function(userText, assistantText, model) {
        if (!userText || !assistantText) return;
        try {
            syslog('[PROFILE] extracting from user="' + userText.slice(0, 80) + '"');
            const existing = this._facts ? 'Already known:\n' + this._facts + '\n\n' : '';
            const prompt =
                '[USER MESSAGE]\n"' + userText.slice(0, 800) + '"\n[END USER MESSAGE]\n\n' +
                existing +
                'Task: Extract personal facts the user stated about themselves directly in the USER MESSAGE.\n' +
                'Only extract from explicit self-descriptions: "I am...", "I have...", "My X is/are...", "I live in...", "I work as...", etc.\n' +
                '\n' +
                'Valid categories (only if explicitly stated by the user):\n' +
                '- Name, age, gender\n' +
                '- Occupation / job title\n' +
                '- City or country of residence — ONLY if user says "I live in X" or "I am from X". Searching for things in a city is NOT a location fact.\n' +
                '- Nationality\n' +
                '- Family: spouse, children with names/ages\n' +
                '- Health conditions they mentioned about themselves\n' +
                '- Hobbies, interests, and things they enjoy or like (e.g. "I like X", "I enjoy X", "I love X", "I prefer X")\n' +
                '- Significant personal events (past trips, milestones) they described\n' +
                '\n' +
                'NEVER extract:\n' +
                '- Anything inferred or assumed (e.g. "likely lives in X", "probably interested in...")\n' +
                '- Things they are searching for, shopping for, or asking about\n' +
                '- Preferences inferred from requests (e.g. user asks about bike shops → do NOT extract bike preferences)\n' +
                '- Anything from the ASSISTANT RESPONSE section\n' +
                '- Duplicates of Already known facts\n' +
                '\n' +
                'The user message may be in any language. Extract facts regardless of language and always write the output in English.\n' +
                'Format: one bullet per fact, e.g. "- Name: Carl" or "- Occupation: software engineer" or "- Visited Greece in 2025".\n' +
                'Plain text only, no markdown formatting.\n' +
                'If nothing qualifies, reply: NONE';
            const res = await cloudRoutedFetch(model, '/generate', {
                model: model, stream: false, think: false,
                options: { temperature: 0, num_predict: 200, think: false },
                prompt: prompt
            }, null);
            if (!res || !res.ok) return;
            const data = await res.json();
            const reply = (data.response || '').trim();
            syslog('[PROFILE] extraction result="' + reply.slice(0, 200) + '"');
            if (!reply || reply === 'NONE' || /^none$/i.test(reply)) return;
            // Merge new bullets into existing profile
            var newLines = reply.split('\n')
                .map(function(l) { return l.trim().replace(/\*{1,3}([^*]*)\*{1,3}/g, '$1').replace(/_{1,2}([^_]*)_{1,2}/g, '$1'); })
                .filter(function(l) { return l.startsWith('-'); });
            if (newLines.length === 0) return;
            this._facts = (this._facts ? this._facts + '\n' : '') + newLines.join('\n');
            var allLines = this._facts.split('\n').filter(function(l) { return l.trim().startsWith('-'); });
            this._facts = allLines.join('\n');
            syslog('[PROFILE] merged ' + newLines.length + ' new fact(s): ' + newLines.join(' | ').slice(0, 200));
            // Condense if over threshold
            var condenseThreshold = (typeof Settings !== 'undefined' && Settings._condenseFacts) || 50;
            if (allLines.length >= condenseThreshold) {
                await this._condense(model, allLines);
            } else {
                await this.save();
            }
        } catch(e) {}
    },

    _condense: async function(model, allLines) {
        try {
            var targetCount = Math.ceil((typeof Settings !== 'undefined' && Settings._condenseFacts || 50) / 2);
            syslog('[PROFILE] condensing ' + allLines.length + ' facts → target ~' + targetCount);
            var condensePrompt =
                'Below is a list of personal facts about a user, accumulated over many conversations.\n\n' +
                allLines.join('\n') + '\n\n' +
                'Task: Condense this list to the ' + targetCount + ' most important, distinct facts.\n' +
                'Rules:\n' +
                '- Merge near-duplicates into one line (e.g. two lines about the same city → one)\n' +
                '- If a fact has been superseded by a newer one (e.g. old job vs new job), keep only the newer one\n' +
                '- Merge closely related facts into a single line where natural\n' +
                '- Drop trivial or very low-signal facts if over the limit\n' +
                '- Keep all facts in English\n' +
                'Output: one bullet per fact, same format as input (e.g. "- Name: Carl").\n' +
                'Plain text only, no extra commentary.';
            var res = await cloudRoutedFetch(model, '/generate', {
                model: model, stream: false, think: false,
                options: { temperature: 0, num_predict: 600, think: false },
                prompt: condensePrompt
            }, null);
            if (!res || !res.ok) { await this.save(); return; }
            var data = await res.json();
            var condensed = (data.response || '').trim();
            var condensedLines = condensed.split('\n')
                .map(function(l) { return l.trim().replace(/\*{1,3}([^*]*)\*{1,3}/g, '$1').replace(/_{1,2}([^_]*)_{1,2}/g, '$1'); })
                .filter(function(l) { return l.startsWith('-'); });
            if (condensedLines.length > 0) {
                this._facts = condensedLines.join('\n');
                syslog('[PROFILE] condensed to ' + condensedLines.length + ' fact(s)');
            }
            await this.save();
        } catch(e) { await this.save(); }
    }
};

const SettingsModal = {
    open: async function(page) {
        await Settings.load();
        this._renderAccounts();
        this._renderCloudModels();
        this._updateSubsectionState();
        document.getElementById('settings-ollama-url').value = AppConfig.ollamaEndpoint || '';
        document.getElementById('settings-compact-turns').value = Settings._compactTurns;
        document.getElementById('settings-keep-recent').value = Settings._keepRecent > 0 ? Settings._keepRecent : '';
        document.getElementById('settings-condense-facts').value = Settings._condenseFacts;
        var targetPage = page || 'page-model';
        document.querySelectorAll('.settings-page').forEach(function(p) { p.classList.remove('active'); });
        document.getElementById(targetPage).classList.add('active');
        document.getElementById('settings-modal-title').textContent = t(targetPage === 'page-conversation' ? 'convSettings' : 'sysSettings');
        document.getElementById('settings-overlay').classList.add('open');
    },
    close: function() {
        document.getElementById('settings-overlay').classList.remove('open');
    },
    _normalizeOllamaUrl: function(raw) {
        var s = raw.trim().replace(/\/+$/, ''); // strip trailing slashes
        var hasScheme = /^https?:\/\//i.test(s);
        var scheme = 'http://';
        var host = s;
        if (hasScheme) {
            var m = s.match(/^(https?:\/\/)(.*)/i);
            scheme = m[1].toLowerCase();
            host = m[2];
        }
        // Add default port if none specified (ignore IPv6 brackets)
        if (!/:\d+$/.test(host)) host = host + ':11434';
        return scheme + host;
    },
    _trashBtn: function() {
        var btn = document.createElement('button');
        btn.className = 'settings-trash-btn';
        btn.innerHTML = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14H6L5 6"/><path d="M9 6V4h6v2"/></svg>';
        return btn;
    },
    _renderAccounts: function() {
        var list = document.getElementById('cloud-accounts-list');
        list.innerHTML = '';
        Settings.accounts.forEach(function(acct, i) {
            var item = document.createElement('div');
            item.className = 'settings-list-item';
            item.innerHTML = '<span class="settings-list-item-label">' + acct.name + '</span><span class="settings-list-item-sub">••••••••</span>';
            var del = SettingsModal._trashBtn();
            del.addEventListener('click', function() {
                var accts = Settings.accounts;
                accts.splice(i, 1);
                Settings.saveAccounts(accts);
                SettingsModal._renderAccounts();
                SettingsModal._updateSubsectionState();
                UIManager.refreshModelSelect();
            });
            item.appendChild(del);
            list.appendChild(item);
        });
    },
    _renderCloudModels: function() {
        var list = document.getElementById('cloud-models-list');
        list.innerHTML = '';
        Settings.cloudModels.forEach(function(name, i) {
            var item = document.createElement('div');
            item.className = 'settings-list-item';
            item.innerHTML = '<span class="settings-list-item-label">' + name + '</span>';
            var del = SettingsModal._trashBtn();
            del.addEventListener('click', function() {
                var models = Settings.cloudModels;
                models.splice(i, 1);
                Settings.saveCloudModels(models);
                SettingsModal._renderCloudModels();
                UIManager.refreshModelSelect();
            });
            item.appendChild(del);
            list.appendChild(item);
        });
    },
    _updateSubsectionState: function() {
        var sub = document.getElementById('cloud-models-section');
        var hasAccounts = Settings.accounts.length > 0;
        sub.classList.toggle('disabled', !hasAccounts);
    },
    _addCloudModel: function(name) {
        name = name.trim();
        if (!name) return;
        // Recommended models are shown automatically — don't add to user list
        if (RECOMMENDED_CLOUD_MODEL_NAMES.indexOf(name) !== -1) return;
        var models = Settings.cloudModels;
        if (models.indexOf(name) !== -1) return;
        models.push(name);
        Settings.saveCloudModels(models);
        this._renderCloudModels();
        UIManager.refreshModelSelect();
        document.getElementById('cloud-model-search').value = '';
        document.getElementById('cloud-model-suggestions').classList.remove('open');
    },
    init: function() {
        var self = this;
        document.getElementById('settings-close-btn').addEventListener('click', function() { self.close(); });
        document.getElementById('settings-overlay').addEventListener('click', function(e) {
            if (e.target === e.currentTarget) self.close();
        });
        // Add account — probe first
        document.getElementById('cloud-acct-add-btn').addEventListener('click', async function() {
            var name = document.getElementById('cloud-acct-name').value.trim();
            var key = document.getElementById('cloud-acct-key').value.trim();
            var errEl = document.getElementById('cloud-acct-error');
            errEl.style.display = 'none';
            if (!name || !key) return;
            var btn = document.getElementById('cloud-acct-add-btn');
            btn.disabled = true;
            btn.textContent = 'Checking…';
            var ok = await CloudAccountPool.probe({ name: name, apiKey: key });
            btn.disabled = false;
            btn.textContent = '+ Add';
            if (!ok) {
                errEl.textContent = 'Account unreachable. Check the API key and try again.';
                errEl.style.display = 'block';
                return;
            }
            var accts = Settings.accounts;
            if (accts.some(function(a) { return a.name === name; })) {
                errEl.textContent = 'An account with that name already exists.';
                errEl.style.display = 'block';
                return;
            }
            accts.push({ name: name, apiKey: key });
            Settings.saveAccounts(accts);
            document.getElementById('cloud-acct-name').value = '';
            document.getElementById('cloud-acct-key').value = '';
            self._renderAccounts();
            self._updateSubsectionState();
            UIManager.refreshModelSelect();
        });
        // Cloud model search
        var searchInput = document.getElementById('cloud-model-search');
        var suggestions = document.getElementById('cloud-model-suggestions');
        var _searchTimer = null;
        searchInput.addEventListener('input', function() {
            var q = this.value.trim();
            suggestions.innerHTML = '';
            if (!q) { suggestions.classList.remove('open'); return; }
            clearTimeout(_searchTimer);
            _searchTimer = setTimeout(async function() {
                suggestions.innerHTML = '';
                var models = [];
                // Search Ollama public registry via backend proxy
                try {
                    var res = await apiFetch('/registry?q=' + encodeURIComponent(q));
                    if (res.ok) {
                        var data = await res.json();
                        models = (data.models || [])
                            .map(function(m) { return m.name; })
                            .filter(function(n) { return RECOMMENDED_CLOUD_MODEL_NAMES.indexOf(n) === -1; });
                    }
                } catch(e) {}
                // Also show locally-installed cloud models that match the query
                try {
                    var localModels = await OllamaAPI.fetchModels();
                    var localCloud = localModels
                        .filter(function(m) {
                            var tag = m.name.includes(':') ? m.name.split(':')[1] : '';
                            return tag.includes('cloud')
                                && m.name.toLowerCase().includes(q.toLowerCase())
                                && RECOMMENDED_CLOUD_MODEL_NAMES.indexOf(m.name) === -1;
                        })
                        .map(function(m) { return m.name; });
                    localCloud.forEach(function(n) { if (models.indexOf(n) === -1) models.push(n); });
                } catch(e) {}
                if (!models.length) { suggestions.classList.remove('open'); return; }
                models.forEach(function(name) {
                    var item = document.createElement('div');
                    item.className = 'settings-suggestion-item';
                    item.textContent = name;
                    item.addEventListener('mousedown', function(e) {
                        e.preventDefault();
                        self._addCloudModel(name);
                    });
                    suggestions.appendChild(item);
                });
                suggestions.classList.add('open');
            }, 350);
        });
        searchInput.addEventListener('blur', function() {
            setTimeout(function() { suggestions.classList.remove('open'); }, 150);
        });
        searchInput.addEventListener('keydown', function(e) {
            if (e.key === 'Enter') self._addCloudModel(searchInput.value);
        });
        document.getElementById('cloud-model-add-btn').addEventListener('click', function() {
            self._addCloudModel(searchInput.value);
        });
        // Local Ollama URL save
        document.getElementById('settings-ollama-url-save').addEventListener('click', function() {
            var raw = document.getElementById('settings-ollama-url').value.trim();
            var url = raw ? SettingsModal._normalizeOllamaUrl(raw) : '';
            document.getElementById('settings-ollama-url').value = url;
            UIManager.updateEndpoint(url);
        });
        // Compact turns save
        document.getElementById('settings-compact-turns-save').addEventListener('click', function() {
            var val = parseInt(document.getElementById('settings-compact-turns').value);
            if (!val || val < 10) return;
            Settings._compactTurns = val;
            ContextManager.TURN_THRESHOLD = val;
            Settings._persist();
        });
        // Keep recent save
        document.getElementById('settings-keep-recent-save').addEventListener('click', function() {
            var raw = document.getElementById('settings-keep-recent').value.trim();
            var val = raw === '' ? 0 : parseInt(raw);
            if (isNaN(val) || val < 0) return;
            Settings._keepRecent = val;
            ContextManager.KEEP_RECENT_OVERRIDE = val;
            Settings._persist();
        });
        // Condense facts threshold save
        document.getElementById('settings-condense-facts-save').addEventListener('click', function() {
            var val = parseInt(document.getElementById('settings-condense-facts').value);
            if (!val || val < 10) return;
            Settings._condenseFacts = val;
            Settings._persist();
        });
        document.getElementById('settings-profile-clear-btn').addEventListener('click', async function() {
            if (!confirm(t('profileClearConfirm'))) return;
            await UserProfile.clear();
        });
    }
};

const CloudAccountPool = {
    _idx: 0,
    _state: {}, // { name: { unreachableUntil, backoffMs, probeTimer } }

    probe: async function(acct) {
        try {
            const res = await fetch('/cloud-api/tags', {
                headers: {
                    'Authorization': 'Bearer ' + (Auth.token || ''),
                    'X-Cloud-Key': acct.apiKey
                },
                signal: AbortSignal.timeout(8000)
            });
            return res.ok;
        } catch(e) {
            return false;
        }
    },

    getNext: function() {
        const accounts = Settings.accounts;
        if (!accounts.length) return null;
        const now = Date.now();
        for (let i = 0; i < accounts.length; i++) {
            const idx = (this._idx + i) % accounts.length;
            const acct = accounts[idx];
            const state = this._state[acct.name];
            if (!state || now >= state.unreachableUntil) {
                this._idx = (idx + 1) % accounts.length;
                return acct;
            }
        }
        // All unreachable — return least-recently-failed
        let bestAcct = null, earliest = Infinity;
        accounts.forEach(function(acct) {
            const st = CloudAccountPool._state[acct.name];
            if (st && st.unreachableUntil < earliest) { earliest = st.unreachableUntil; bestAcct = acct; }
        });
        return bestAcct || accounts[this._idx % accounts.length];
    },

    markFailed: function(acct) {
        if (!acct) return;
        const MIN_BACKOFF = 30000;
        const state = this._state[acct.name] || { backoffMs: MIN_BACKOFF };
        if (!this._state[acct.name]) state.backoffMs = MIN_BACKOFF;
        state.unreachableUntil = Date.now() + state.backoffMs;
        this._state[acct.name] = state;
        this._scheduleProbe(acct, state.backoffMs);
        state.backoffMs = Math.min(state.backoffMs * 2, 30 * 60 * 1000);
    },

    markRecovered: function(acct) {
        if (!acct) return;
        const state = this._state[acct.name];
        if (state && state.probeTimer) clearTimeout(state.probeTimer);
        delete this._state[acct.name];
    },

    _scheduleProbe: function(acct, delay) {
        const self = this;
        const state = this._state[acct.name];
        if (!state) return;
        if (state.probeTimer) clearTimeout(state.probeTimer);
        state.probeTimer = setTimeout(async function() {
            if (!self._state[acct.name]) return;
            const ok = await self.probe(acct);
            if (ok) {
                self.markRecovered(acct);
            } else {
                self.markFailed(acct);
            }
        }, delay);
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
            context: { summary: null, summaryUpToIndex: -1, needsNaming: true },
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

const Lightbox = {
    _scale: 1,
    _tx: 0,
    _ty: 0,
    _dragging: false,
    _lastX: 0,
    _lastY: 0,
    _lastDist: 0,
    _lastMidX: 0,
    _lastMidY: 0,
    _open: false,

    open: function(thumbSrc, fileId, sessionId) {
        var lb = document.getElementById('img-lightbox');
        var img = document.getElementById('img-lightbox-img');
        this._scale = 1;
        this._tx = 0;
        this._ty = 0;
        this._open = true;
        img.src = thumbSrc;
        lb.style.display = 'flex';
        this._applyTransform();

        // Load full image from server if available
        if (fileId && sessionId) {
            apiFetch('/assets/' + sessionId + '/' + fileId)
                .then(function(r) {
                    if (!r.ok) throw new Error('fetch failed: ' + r.status);
                    return r.blob();
                })
                .then(function(blob) {
                    var url = URL.createObjectURL(blob);
                    var full = new Image();
                    full.onload = function() { img.src = url; };
                    full.src = url;
                })
                .catch(function(e) { console.warn('Lightbox full-res load failed:', e); });
        }

        // Push history state so back button closes lightbox
        history.pushState({ lightbox: true }, '');
    },

    close: function() {
        if (!this._open) return;
        this._open = false;
        var lb = document.getElementById('img-lightbox');
        lb.style.display = 'none';
        var img = document.getElementById('img-lightbox-img');
        img.src = '';
    },

    _applyTransform: function() {
        var img = document.getElementById('img-lightbox-img');
        img.style.transform = 'translate(' + this._tx + 'px, ' + this._ty + 'px) scale(' + this._scale + ')';
        img.style.cursor = this._scale > 1 ? 'grab' : 'zoom-in';
    },

    _clampPan: function() {
        var img = document.getElementById('img-lightbox-img');
        var vw = window.innerWidth, vh = window.innerHeight;
        var iw = img.naturalWidth || img.offsetWidth;
        var ih = img.naturalHeight || img.offsetHeight;
        // Scaled image dimensions
        var sw = Math.min(iw, vw) * this._scale;
        var sh = Math.min(ih, vh) * this._scale;
        var maxTx = Math.max(0, (sw - vw) / 2);
        var maxTy = Math.max(0, (sh - vh) / 2);
        this._tx = Math.max(-maxTx, Math.min(maxTx, this._tx));
        this._ty = Math.max(-maxTy, Math.min(maxTy, this._ty));
    },

    init: function() {
        var self = this;
        var lb = document.getElementById('img-lightbox');
        var img = document.getElementById('img-lightbox-img');

        // Close button
        document.getElementById('img-lightbox-close').addEventListener('click', function(e) {
            e.stopPropagation();
            history.back();
        });

        // Click backdrop to close (only when not zoomed and click wasn't a drag)
        lb.addEventListener('click', function(e) {
            if (e.target === lb && self._scale <= 1) history.back();
        });

        // Esc key
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape' && self._open) history.back();
        });

        // Back button
        window.addEventListener('popstate', function(e) {
            if (self._open) self.close();
        });

        // ---- Mouse events (desktop) ----
        var mouseMoved = false;
        img.addEventListener('mousedown', function(e) {
            if (self._scale <= 1) return;
            e.preventDefault();
            self._dragging = true;
            self._lastX = e.clientX;
            self._lastY = e.clientY;
            mouseMoved = false;
            img.style.cursor = 'grabbing';
        });
        window.addEventListener('mousemove', function(e) {
            if (!self._dragging) return;
            var dx = e.clientX - self._lastX;
            var dy = e.clientY - self._lastY;
            if (Math.abs(dx) > 2 || Math.abs(dy) > 2) mouseMoved = true;
            self._tx += dx;
            self._ty += dy;
            self._lastX = e.clientX;
            self._lastY = e.clientY;
            self._clampPan();
            self._applyTransform();
        });
        window.addEventListener('mouseup', function() {
            if (self._dragging) {
                self._dragging = false;
                img.style.cursor = self._scale > 1 ? 'grab' : 'zoom-in';
            }
        });

        // Scroll wheel zoom
        lb.addEventListener('wheel', function(e) {
            if (!self._open) return;
            e.preventDefault();
            var factor = e.deltaY < 0 ? 1.15 : 1 / 1.15;
            var newScale = Math.max(0.5, Math.min(10, self._scale * factor));
            // Zoom toward mouse pointer
            var rect = img.getBoundingClientRect();
            var mx = e.clientX - (rect.left + rect.width / 2);
            var my = e.clientY - (rect.top + rect.height / 2);
            self._tx += mx * (1 - factor);
            self._ty += my * (1 - factor);
            self._scale = newScale;
            self._clampPan();
            self._applyTransform();
        }, { passive: false });

        // ---- Touch events (mobile) ----
        var lastTap = 0;
        lb.addEventListener('touchstart', function(e) {
            if (!self._open) return;
            if (e.touches.length === 1) {
                self._lastX = e.touches[0].clientX;
                self._lastY = e.touches[0].clientY;
                self._dragging = true;
                mouseMoved = false;
                // Double-tap to reset zoom
                var now = Date.now();
                if (now - lastTap < 300) {
                    self._scale = 1; self._tx = 0; self._ty = 0;
                    self._applyTransform();
                }
                lastTap = now;
            } else if (e.touches.length === 2) {
                self._dragging = false;
                var dx = e.touches[1].clientX - e.touches[0].clientX;
                var dy = e.touches[1].clientY - e.touches[0].clientY;
                self._lastDist = Math.hypot(dx, dy);
                self._lastMidX = (e.touches[0].clientX + e.touches[1].clientX) / 2;
                self._lastMidY = (e.touches[0].clientY + e.touches[1].clientY) / 2;
            }
        }, { passive: true });

        lb.addEventListener('touchmove', function(e) {
            if (!self._open) return;
            e.preventDefault();
            if (e.touches.length === 1 && self._dragging && self._scale > 1) {
                var dx = e.touches[0].clientX - self._lastX;
                var dy = e.touches[0].clientY - self._lastY;
                if (Math.abs(dx) > 2 || Math.abs(dy) > 2) mouseMoved = true;
                self._tx += dx;
                self._ty += dy;
                self._lastX = e.touches[0].clientX;
                self._lastY = e.touches[0].clientY;
                self._clampPan();
                self._applyTransform();
            } else if (e.touches.length === 2) {
                var ddx = e.touches[1].clientX - e.touches[0].clientX;
                var ddy = e.touches[1].clientY - e.touches[0].clientY;
                var dist = Math.hypot(ddx, ddy);
                var factor = dist / self._lastDist;
                var newScale = Math.max(0.5, Math.min(10, self._scale * factor));
                // Zoom toward pinch midpoint
                var midX = (e.touches[0].clientX + e.touches[1].clientX) / 2;
                var midY = (e.touches[0].clientY + e.touches[1].clientY) / 2;
                var img2 = document.getElementById('img-lightbox-img');
                var rect = img2.getBoundingClientRect();
                var cx = midX - (rect.left + rect.width / 2);
                var cy = midY - (rect.top + rect.height / 2);
                self._tx += cx * (1 - factor);
                self._ty += cy * (1 - factor);
                self._scale = newScale;
                self._lastDist = dist;
                self._lastMidX = midX;
                self._lastMidY = midY;
                self._clampPan();
                self._applyTransform();
            }
        }, { passive: false });

        lb.addEventListener('touchend', function(e) {
            if (e.touches.length < 2) self._lastDist = 0;
            if (e.touches.length === 0) self._dragging = false;
        }, { passive: true });
    }
};

const OllamaAPI = {
    endpoint: '',
    contextWindowCache: {},
    capabilityCache: {},
    get BASE_URL() { return this.endpoint ? '/local-api' : '/api'; },
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
    summarize: async function(model, messages, signal) {
        try {
            const res = await cloudRoutedFetch(model, '/chat',
                { model: model, messages: messages, stream: false, think: false }, signal);
            if (!res.ok) throw new Error('summarize failed');
            const data = await res.json();
            return (data.message && data.message.content) ? data.message.content : null;
        } catch (e) {
            console.error('Summarization failed:', e);
            return null;
        }
    },
    streamChat: function(model, messages, onChunk, onComplete, onError, signal, authHeaders, baseUrl) {
        const controller = signal ? null : new AbortController();
        const hdrs = Object.assign({ 'Content-Type': 'application/json' }, authHeaders || {});
        const url = (baseUrl || this.BASE_URL) + '/chat';
        fetch(url, {
            method: 'POST',
            headers: hdrs,
            body: JSON.stringify({ model: model, messages: messages, stream: true }),
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
        if (msg.role === 'assistant') return { role: 'assistant', content: msg.content || '' };
        var content = msg.content || '';
        if (msg.files && msg.files.length > 0) {
            content += msg.files.map(function(f) {
                return '\n\n[File: ' + f.name + ']\n' + (f.snippet || '');
            }).join('');
            content = content.trim();
        }
        return { role: 'user', content: content };
    });
}

const ContextManager = {
    COMPACT_THRESHOLD: 0.45,
    TURN_THRESHOLD: 90,
    KEEP_RECENT: 16, // fallback for unknown model size (8 turns)
    KEEP_RECENT_OVERRIDE: 0, // 0 = auto (model-based), >0 = user override

    getKeepRecent: function(model) {
        if (this.KEEP_RECENT_OVERRIDE > 0) return this.KEEP_RECENT_OVERRIDE;
        var m = (model || '').toLowerCase().match(/(\d+(?:\.\d+)?)b/);
        var params = m ? parseFloat(m[1]) : 0;
        if (params >= 70) return 12;  // 6 turns
        if (params >= 20) return 16;  // 8 turns
        if (params >= 7)  return 20;  // 10 turns
        if (params > 0)   return 20;  // 10 turns (small local)
        return 16;                    // 8 turns fallback
    },

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
        var ctx = session.context;
        var summaryUpTo = ctx ? ctx.summaryUpToIndex : -1;
        var recentCount = session.messages.length - (summaryUpTo + 1);
        if (recentCount > this.TURN_THRESHOLD) return true;
        var contextMsgs = this.buildContextMessages(session);
        var pendingTokens = Math.ceil((pendingContent || '').length / 4);
        var total = this.estimateTokens(contextMsgs) + pendingTokens;
        return (total / contextWindow) > this.COMPACT_THRESHOLD;
    },

    retrieveRelevant: function(session, query, topK) {
        var ctx = session.context;
        if (!ctx || !ctx.summary || ctx.summaryUpToIndex < 0) return [];
        var end = ctx.summaryUpToIndex + 1;
        var oldMessages = session.messages.slice(Math.max(0, end - 2000), end);
        if (oldMessages.length === 0) return [];
        var keywords = StopWords.extractKeywords(query).toLowerCase().split(/\s+/).filter(Boolean);
        if (keywords.length === 0) return [];
        function getText(msg) {
            if (typeof msg.content === 'string') return msg.content;
            if (Array.isArray(msg.content)) {
                return msg.content.filter(function(p) { return p.type === 'text'; }).map(function(p) { return p.text || ''; }).join(' ');
            }
            return '';
        }
        var pairs = [];
        for (var i = 0; i < oldMessages.length; i++) {
            if (oldMessages[i].role === 'user') {
                var userText = getText(oldMessages[i]);
                var assistantText = (oldMessages[i+1] && oldMessages[i+1].role === 'assistant') ? getText(oldMessages[i+1]) : '';
                var combined = (userText + ' ' + assistantText).toLowerCase();
                var matches = keywords.filter(function(k) { return combined.indexOf(k) !== -1; });
                if (matches.length > 0) {
                    pairs.push({ score: matches.length / keywords.length, user: userText, assistant: assistantText });
                }
                if (assistantText) i++;
            }
        }
        pairs.sort(function(a, b) { return b.score - a.score; });
        return pairs.slice(0, topK).filter(function(p) { return p.score >= 0.25; });
    },

    compact: async function(session) {
        var ctx = session.context || { summary: null, summaryUpToIndex: -1 };
        var keepFrom = Math.max(0, session.messages.length - this.getKeepRecent(session.model));
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

        session.context = { summary: summary, summaryUpToIndex: keepFrom - 1, needsNaming: ctx.needsNaming };
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
    document.getElementById('message-input').placeholder = t('typePlaceholder');
    document.getElementById('send-label').textContent = t('send');
    document.getElementById('stop-label').textContent = t('stopGen');
    document.getElementById('attach-btn').title = t('attachFile');
    document.getElementById('error-message').textContent = t('cannotConnect');
    document.querySelector('#error-banner button').textContent = t('retry');
    document.getElementById('modal-cancel').textContent = t('cancel');
    document.getElementById('pw-warning-text').textContent = t('pwWarning');
    document.getElementById('pw-warning-btn').textContent = t('pwWarningBtn');
    document.getElementById('sidebar-settings-label').textContent = t('sysSettings');
    document.getElementById('settings-modal-title').textContent = t('sysSettings');
    var userSettingsLabel = document.getElementById('user-settings-label');
    if (userSettingsLabel) userSettingsLabel.textContent = t('sysSettings');
    document.getElementById('settings-chat-section-title').textContent = t('settingsChatSection');
    document.getElementById('settings-compact-turns-label').textContent = t('settingsCompactLabel');
    document.getElementById('settings-keep-recent-label').textContent = t('settingsKeepRecentLabel');
    document.getElementById('settings-profile-section-title').textContent = t('profileSection');
    document.getElementById('settings-condense-facts-label').textContent = t('profileCondenseLabel');
    document.getElementById('settings-profile-clear-btn').textContent = t('profileClear');
    var convSettingsLabel = document.getElementById('user-conv-settings-label');
    if (convSettingsLabel) convSettingsLabel.textContent = t('convSettings');
    if (typeof UIManager !== 'undefined' && UIManager.refreshModelSelect) {
        UIManager.refreshModelSelect();
    }
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
    _streamMap: new Map(),  // sessionId -> { content, searchWarning, session } — only 1 entry at a time
    _wakeLock: null,
    _activeBodyDiv: null,
    _streamingWhenHidden: false,

    init: function() {
        const self = this;
        Modal.init();
        var sidebar = document.getElementById('sidebar');
        var overlay = document.getElementById('sidebar-overlay');
        var toggle = document.getElementById('sidebar-toggle');
        var headerLogo = document.getElementById('header-logo');
        var isMobile = function() { return window.innerWidth <= 768; };
        function closeSidebar() { sidebar.classList.add('collapsed'); overlay.classList.remove('visible'); headerLogo.style.display = 'none'; }
        function openSidebar() { sidebar.classList.remove('collapsed'); if (isMobile()) overlay.classList.add('visible'); headerLogo.style.display = 'none'; }
        toggle.addEventListener('click', function() { sidebar.classList.contains('collapsed') ? openSidebar() : closeSidebar(); });
        document.getElementById('header-new-chat-btn').addEventListener('click', function() { self.createNewSession(); });
        overlay.addEventListener('click', closeSidebar);
        document.getElementById('sidebar-close-btn').addEventListener('click', closeSidebar);

        // Wake lock + visibility recovery for mobile streaming
        document.addEventListener('visibilitychange', function() {
            if (document.visibilityState === 'hidden') {
                self._streamingWhenHidden = self.isStreaming;
            } else {
                if (self._streamingWhenHidden && !self.isStreaming && self._activeBodyDiv) {
                    var notice = document.createElement('div');
                    notice.style.cssText = 'margin-top:10px;padding:8px 12px;background:#2a1a10;border:1px solid #c87830;border-radius:6px;color:#d0a050;font-size:13px;display:flex;align-items:center;gap:10px;';
                    notice.innerHTML = '⚠ Response was interrupted (screen locked).';
                    var retryBtn = document.createElement('button');
                    retryBtn.textContent = 'Retry';
                    retryBtn.style.cssText = 'padding:4px 12px;background:#c87830;color:#fff;border:none;border-radius:4px;cursor:pointer;font-size:12px;font-weight:600;flex-shrink:0;';
                    retryBtn.onclick = function() { self.retryLastMessage(); };
                    notice.appendChild(retryBtn);
                    var wlBody = document.getElementById('streaming-body') || self._activeBodyDiv;
                    if (wlBody) wlBody.appendChild(notice);
                }
                self._streamingWhenHidden = false;
                if (self.isStreaming) self._acquireWakeLock();
            }
        });
        document.getElementById('message-input').addEventListener('focus', function() { if (isMobile()) closeSidebar(); });
        if (window.innerWidth <= 768 && window.innerHeight > window.innerWidth) closeSidebar();

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
            self._releaseWakeLock();
            self.updateSendBtn();
            self.setStatus('');
            document.getElementById('stop-gen-btn').style.display = 'none';
            document.getElementById('scroll-bottom-btn').style.display = 'none';
            if (pendingSession && pendingSession.context && pendingSession.context.needsNaming) {
                self.autoNameSession(pendingSession);
            }
        });
        document.getElementById('scroll-bottom-btn').addEventListener('click', function() {
            var c = document.getElementById('chat-container');
            c.scrollTop = c.scrollHeight;
        });
        document.getElementById('chat-container').addEventListener('scroll', function() {
            var c = this;
            var atBottom = c.scrollHeight - c.scrollTop - c.clientHeight < 40;
            if (atBottom) {
                document.getElementById('scroll-bottom-btn').style.display = 'none';
            } else if (c.scrollHeight > c.clientHeight) {
                document.getElementById('scroll-bottom-btn').style.display = 'flex';
            }
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
        document.getElementById('sidebar-settings-btn').addEventListener('click', function() { SettingsModal.open(); });
        document.getElementById('send-btn').addEventListener('click', function() { self.sendMessage(); });
        document.getElementById('message-input').addEventListener('keydown', function(e) {
            if (e.key === 'Enter' && e.ctrlKey) { e.preventDefault(); if (!self.isStreaming) self.sendMessage(); }
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
        // Custom model dropdown open/close
        document.getElementById('model-dropdown-trigger').addEventListener('click', function() {
            var menu = document.getElementById('model-dropdown-menu');
            var trigger = this;
            var isOpen = menu.classList.toggle('open');
            trigger.classList.toggle('open', isOpen);
            if (isOpen && window.innerWidth <= 768) {
                var rect = trigger.getBoundingClientRect();
                menu.style.top = (rect.bottom + 4) + 'px';
            } else {
                menu.style.top = '';
            }
        });
        document.addEventListener('click', function(e) {
            if (!document.getElementById('model-dropdown-wrap').contains(e.target)) {
                var menu = document.getElementById('model-dropdown-menu');
                menu.classList.remove('open');
                menu.style.top = '';
                document.getElementById('model-dropdown-trigger').classList.remove('open');
            }
        });

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

        // Settings
        SettingsModal.init();
        document.getElementById('user-settings-btn').addEventListener('click', function() {
            document.getElementById('user-dropdown').classList.remove('open');
            SettingsModal.open();
        });
        document.getElementById('user-conv-settings-btn').addEventListener('click', function() {
            document.getElementById('user-dropdown').classList.remove('open');
            SettingsModal.open('page-conversation');
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
            document.getElementById('user-settings-btn').style.display = isAdmin ? '' : 'none';
            document.getElementById('user-conv-settings-btn').style.display = isAdmin ? '' : 'none';
            document.getElementById('user-settings-sep').style.display = isAdmin ? '' : 'none';
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

        await this.loadPrefs();
        await Settings.load();
        await UserProfile.load();

        try {
            const models = await OllamaAPI.fetchModels();
            this.populateModelSelects(models);
        } catch (e) {
            if (OllamaAPI.endpoint) {
                // Custom endpoint unreachable — fall back to default /api so local models still appear
                OllamaAPI.setEndpoint('');
                try {
                    const models = await OllamaAPI.fetchModels();
                    this.populateModelSelects(models);
                } catch (e2) {
                    this.showError(t('cannotConnectFull'));
                }
            } else {
                this.showError(t('cannotConnectFull'));
            }
        }

        try {
            const sessions = await SessionStore.getSessions();
            if (sessions.length === 0) {
                const defaultSession = await SessionStore.createSession(t('newChat'), this.getDefaultModel());
                await SessionStore.setCurrentSessionId(defaultSession.id);
                this.currentSession = defaultSession;
            } else {
                const currentId = await SessionStore.getCurrentSessionId();
                this.currentSession = currentId ? sessions.find(function(s) { return s.id === currentId; }) : sessions[0];
                if (!this.currentSession) this.currentSession = sessions[0];
                await SessionStore.setCurrentSessionId(this.currentSession.id);
                // No auto-creation on return — stay in the last active session
            }
            if (this.currentSession && this.currentSession.model) {
                var sel = document.getElementById('header-model-select');
                var sessionModel = this.currentSession.model;
                var modelAvailable = Array.from(sel.options).some(function(o) { return o.value === sessionModel; });
                if (modelAvailable) {
                    this._setModelDropdownValue(sessionModel);
                } else {
                    // Model no longer available (e.g. pool deleted); keep dropdown value from populateModelSelects
                    var dropdownModel = sel.value || this._lastUsedModel;
                    if (dropdownModel && dropdownModel !== sessionModel) {
                        this.currentSession.model = dropdownModel;
                        SessionStore.updateSession(this.currentSession);
                    }
                }
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
        const menu = document.getElementById('model-dropdown-menu');
        select.innerHTML = '';
        menu.innerHTML = '';
        const self = this;
        const hasPool = Settings.accounts.length > 0;
        const recModels = getRecommendedCloudModels();
        const recNames = RECOMMENDED_CLOUD_MODEL_NAMES;
        const cloudModelNames = Settings.cloudModels.filter(function(n) { return recNames.indexOf(n) === -1; });
        const localModels = models.filter(function(m) {
            return recNames.indexOf(m.name) === -1 && Settings.cloudModels.indexOf(m.name) === -1;
        }).sort(function(a, b) { return (a.size || 0) - (b.size || 0); });

        function makeOption(value, text) {
            var opt = document.createElement('option');
            opt.value = value; opt.textContent = text;
            select.appendChild(opt);
        }
        function makeItem(value, text, disabled) {
            var el = document.createElement('div');
            el.className = 'model-dropdown-item' + (disabled ? ' disabled' : '');
            el.textContent = text;
            el.dataset.value = value;
            if (!disabled) {
                el.addEventListener('click', function() {
                    self._setModelDropdownValue(value);
                    document.getElementById('header-model-select').dispatchEvent(new Event('change'));
                    var menu = document.getElementById('model-dropdown-menu');
                    menu.classList.remove('open');
                    menu.style.top = '';
                    document.getElementById('model-dropdown-trigger').classList.remove('open');
                });
            }
            return el;
        }

        // Recommended section — always visible, disabled when no pool account is active
        var recSection = document.createElement('div');
        recSection.className = 'model-dropdown-section';
        var recHdr = document.createElement('div');
        recHdr.className = 'model-dropdown-section-hdr recommended' + (hasPool ? '' : ' inactive');
        recHdr.innerHTML = '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/></svg> Recommended';
        recSection.appendChild(recHdr);
        recModels.forEach(function(rec) {
            var displayText = rec.label + ' - ' + rec.name;
            if (hasPool) makeOption(rec.name, displayText);
            recSection.appendChild(makeItem(rec.name, displayText, !hasPool));
        });
        menu.appendChild(recSection);
        var dividerRec = document.createElement('div');
        dividerRec.className = 'model-dropdown-divider';
        menu.appendChild(dividerRec);

        // Cloud Models section (user-added, excluding recommended)
        var cloudSection = document.createElement('div');
        cloudSection.className = 'model-dropdown-section';
        var cloudHdr = document.createElement('div');
        cloudHdr.className = 'model-dropdown-section-hdr cloud';
        cloudHdr.innerHTML = '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 10h-1.26A8 8 0 1 0 9 20h9a5 5 0 0 0 0-10z"/></svg> Cloud Models';
        cloudSection.appendChild(cloudHdr);
        if (cloudModelNames.length === 0) {
            cloudSection.appendChild(makeItem('', 'No cloud models configured', true));
        } else {
            cloudModelNames.forEach(function(name) {
                makeOption(name, name);
                cloudSection.appendChild(makeItem(name, name, false));
            });
        }
        menu.appendChild(cloudSection);

        // Divider
        var divider = document.createElement('div');
        divider.className = 'model-dropdown-divider';
        menu.appendChild(divider);

        // Local Models section
        var localSection = document.createElement('div');
        localSection.className = 'model-dropdown-section';
        var localHdr = document.createElement('div');
        localHdr.className = 'model-dropdown-section-hdr local';
        localHdr.innerHTML = '<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="20" height="14" rx="2"/><line x1="8" y1="21" x2="16" y2="21"/><line x1="12" y1="17" x2="12" y2="21"/></svg> Local Models';
        localSection.appendChild(localHdr);
        if (localModels.length === 0) {
            localSection.appendChild(makeItem('', 'No local models configured', true));
        } else {
            localModels.forEach(function(model) {
                makeOption(model.name, model.name + OllamaAPI.formatSize(model.size));
                localSection.appendChild(makeItem(model.name, model.name + OllamaAPI.formatSize(model.size), false));
            });
        }
        menu.appendChild(localSection);

        // Set initial value: last used (if still active) → first recommended (if pool) → first user cloud → first local
        const activeNames = (hasPool ? recNames : []).concat(cloudModelNames).concat(localModels.map(function(m) { return m.name; }));
        var initial = (self._lastUsedModel && activeNames.indexOf(self._lastUsedModel) !== -1)
            ? self._lastUsedModel
            : (hasPool ? recNames[0] : (cloudModelNames.length > 0 ? cloudModelNames[0] : (localModels.length > 0 ? localModels[0].name : '')));
        self._setModelDropdownValue(initial || '');
        // Update current session model if it differs, but do NOT call switchModel here —
        // switchModel persists to prefs and would corrupt _lastUsedModel if Settings hasn't loaded yet
        // (populateModelSelects can be called from applyLanguage before Settings.load completes).
        if (initial && self.currentSession && self.currentSession.model !== initial) {
            self.currentSession.model = initial;
            SessionStore.updateSession(self.currentSession);
        }
    },

    _setModelDropdownValue: function(value) {
        var select = document.getElementById('header-model-select');
        var label = document.getElementById('model-dropdown-label');
        select.value = value;
        var rec = value && getRecommendedCloudModels().find(function(r) { return r.name === value; });
        label.textContent = rec ? (rec.label + ' - ' + value) : (value || 'Select model...');
        // Update selected highlight
        document.getElementById('model-dropdown-menu').querySelectorAll('.model-dropdown-item').forEach(function(el) {
            el.classList.toggle('selected', el.dataset.value === value);
        });
    },

    refreshModelSelect: async function() {
        try {
            var models = await OllamaAPI.fetchModels();
            this.populateModelSelects(models);
        } catch(e) {}
    },

    renderSessions: async function() {
        const self = this;
        const container = document.getElementById('sessions-list');
        container.innerHTML = '';
        const sessions = await SessionStore.getSessions();
        sessions.forEach(function(s) {
            const item = document.createElement('div');
            item.className = 'session-item' + (s.id === self.currentSession.id ? ' active' : '');
            item.dataset.id = s.id;

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
                        : await SessionStore.createSession(t('newChat'), self.getDefaultModel());
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
                body.innerHTML = renderWithMath(msg.content || '');
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
                        el.className = 'img-thumb-clickable';
                        (function(thumbSrc, fid, sid) {
                            el.addEventListener('click', function() {
                                Lightbox.open(thumbSrc, fid, sid);
                            });
                        })(src, img.fileId || null, sessionId);
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
        // If there's an active stream for this session, render a live placeholder
        var streamEntry = this._streamMap.get(this.currentSession.id);
        if (streamEntry) {
            var streamDiv = document.createElement('div');
            streamDiv.className = 'message assistant';
            var streamHdr = document.createElement('div');
            streamHdr.className = 'msg-header';
            streamHdr.textContent = buildMsgHeader({ role: 'assistant', ts: Date.now(), model: streamEntry.session.model }, streamEntry.session);
            streamDiv.appendChild(streamHdr);
            var streamBody = document.createElement('div');
            streamBody.className = 'msg-body';
            streamBody.id = 'streaming-body';
            streamBody.innerHTML = streamEntry.searchWarning + renderWithMath(streamEntry.content);
            addCopyButtons(streamBody); wrapTables(streamBody);
            streamDiv.appendChild(streamBody);
            container.appendChild(streamDiv);
        }
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
                var scale = Math.min(1, 500 / img.naturalWidth);
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
        // Keep API payload small — 768px is sufficient for vision models to understand content.
        // The original full-res file is already stored in user_assets before this is called.
        var MAX_PX = 768;
        return new Promise(function(resolve) {
            var url = URL.createObjectURL(file);
            var img = new Image();
            img.onload = function() {
                URL.revokeObjectURL(url);
                var w = img.naturalWidth, h = img.naturalHeight;
                var scale = Math.min(1, MAX_PX / Math.max(w, h));
                var canvas = document.createElement('canvas');
                canvas.width = Math.round(w * scale);
                canvas.height = Math.round(h * scale);
                canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
                canvas.toBlob(function(blob) {
                    resolve(new File([blob], file.name, { type: 'image/jpeg' }));
                }, 'image/jpeg', 0.82);
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
        document.getElementById('send-btn').disabled = this.isStreaming || (!hasText && !hasAttachment);
    },

    saveStreamingProgress: function() {
        if (this._streamMap.size === 0) return;
        var entry = Array.from(this._streamMap.values())[0];
        if (!entry.content || !entry.session) return;
        var session = entry.session;
        var last = session.messages[session.messages.length - 1];
        if (last && last.role === 'assistant') return;
        session.messages.push({ role: 'assistant', content: entry.content });
        var prev = session.messages[session.messages.length - 2];
        if (prev && prev.role === 'user') prev._sentToLLM = true;
        SessionStore.updateSession(session);
        this._streamMap.clear();
    },

    updateEndpoint: async function(url) {
        var prevEndpoint = Settings._ollamaEndpoint;
        // Write new endpoint to DB first so the backend proxy uses it when we test
        Settings._ollamaEndpoint = url;
        OllamaAPI.setEndpoint(url);
        AppConfig.saveOllamaEndpoint(url);
        await Settings._persist();
        if (!url) {
            // Cleared — just reload models via default /api path
            try {
                var models = await OllamaAPI.fetchModels();
                this.populateModelSelects(models);
            } catch(e) {}
            return;
        }
        try {
            var models = await OllamaAPI.fetchModels();
            const currentModel = this.currentSession ? this.currentSession.model : null;
            this.populateModelSelects(models);
            const names = models.map(function(m) { return m.name; });
            if (currentModel && names.indexOf(currentModel) !== -1) {
                this._setModelDropdownValue(currentModel);
            } else if (models.length > 0) {
                this.switchModel(models[0].name);
            }
            UIManager._showOllamaUrlMsg('Successfully connected to the Ollama instance at ' + url + '.', false);
        } catch (e) {
            // Revert to previous endpoint
            Settings._ollamaEndpoint = prevEndpoint;
            OllamaAPI.setEndpoint(prevEndpoint);
            AppConfig.saveOllamaEndpoint(prevEndpoint);
            await Settings._persist();
            document.getElementById('settings-ollama-url').value = prevEndpoint;
            UIManager._showOllamaUrlMsg('There is no Ollama instance at ' + url + '. I auto-reverted the URL to the previous value. Please modify and save again.', true);
        }
    },

    _showOllamaUrlMsg: function(text, isError) {
        var el = document.getElementById('settings-ollama-url-msg');
        if (!el) return;
        el.textContent = text;
        el.style.color = isError ? '#e05060' : '#60c080';
        el.style.display = 'block';
        clearTimeout(el._hideTimer);
        el._hideTimer = setTimeout(function() { el.style.display = 'none'; }, isError ? 8000 : 5000);
    },

    clearSession: async function() {
        if (!this.currentSession) return;
        const ok = await Modal.confirm(t('clearSession'), t('clearConfirm1') + this.currentSession.name + t('clearConfirm2'), t('clear'));
        if (!ok) return;
        this.currentSession.messages = [];
        this.currentSession.context = { summary: null, summaryUpToIndex: -1, needsNaming: true };
        await SessionStore.updateSession(this.currentSession);
        this.attachedFiles = [];
        this.renderAttachments();
        this.renderChat();
    },

    _acquireWakeLock: async function() {
        if (!('wakeLock' in navigator) || this._wakeLock) return;
        try {
            var self = this;
            this._wakeLock = await navigator.wakeLock.request('screen');
            this._wakeLock.addEventListener('release', function() { self._wakeLock = null; });
        } catch (e) {}
    },

    _releaseWakeLock: function() {
        if (this._wakeLock) { this._wakeLock.release(); this._wakeLock = null; }
    },

    retryLastMessage: function() {
        if (!this.currentSession) return;
        var msgs = this.currentSession.messages;
        // Find last user message that has not yet a complete assistant reply after it
        for (var i = msgs.length - 1; i >= 0; i--) {
            if (msgs[i].role === 'user') {
                document.getElementById('message-input').value = msgs[i].content || '';
                // Remove the partial assistant message and the user message from history
                this.currentSession.messages = msgs.slice(0, i);
                SessionStore.updateSession(this.currentSession);
                this.renderChat();
                this.sendMessage();
                return;
            }
        }
    },

    getDefaultModel: function() {
        const sel = document.getElementById('header-model-select');
        const activeOptions = Array.from(sel.options).map(function(o) { return o.value; }).filter(Boolean);
        syslog('[MODEL] getDefaultModel _lastUsedModel=' + this._lastUsedModel + ' activeOptions=' + activeOptions.join(','));
        // User's last-selected model takes priority if still available
        if (this._lastUsedModel && activeOptions.indexOf(this._lastUsedModel) !== -1) {
            return this._lastUsedModel;
        }
        // Fallback order: Recommended → Cloud → Local
        const hasPool = Settings.accounts.length > 0;
        if (hasPool) {
            var rec = RECOMMENDED_CLOUD_MODEL_NAMES.find(function(n) { return activeOptions.indexOf(n) !== -1; });
            if (rec) return rec;
        }
        const userCloudModels = Settings.cloudModels.filter(function(n) {
            return RECOMMENDED_CLOUD_MODEL_NAMES.indexOf(n) === -1 && activeOptions.indexOf(n) !== -1;
        });
        if (userCloudModels.length > 0) return userCloudModels[0];
        return activeOptions.length > 0 ? activeOptions[0] : null;
    },

    createNewSession: async function() {
        // If already in an empty session, just focus input
        if (this.currentSession && (!this.currentSession.messages || this.currentSession.messages.length === 0)) {
            document.getElementById('message-input').focus();
            return;
        }
        // Reuse an existing empty session if one exists
        const sessions = await SessionStore.getSessions();
        var empty = sessions.find(function(s) { return !s.messages || s.messages.length === 0; });
        const defaultModel = this.getDefaultModel();
        if (!defaultModel) {
            this.showError(t('noModelAvail'));
            return;
        }
        if (!empty) {
            empty = await SessionStore.createSession(t('newChat'), defaultModel);
        } else if (defaultModel && empty.model !== defaultModel) {
            empty.model = defaultModel;
            SessionStore.updateSession(empty);
        }
        await SessionStore.setCurrentSessionId(empty.id);
        this.currentSession = empty;
        this._setModelDropdownValue(this.currentSession.model);
        await this.renderSessions();
        this.renderChat();
        document.getElementById('message-input').focus();
    },

    switchSession: async function(id) {
        // Immediately highlight the clicked item before any async work
        document.querySelectorAll('.session-item').forEach(function(el) {
            el.classList.toggle('active', el.dataset.id === id);
        });
        this.currentSession = await SessionStore.getSession(id);
        await SessionStore.setCurrentSessionId(id);
        this._setModelDropdownValue(this.currentSession.model);
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
            if (prefs.model) { this._lastUsedModel = prefs.model; syslog('[MODEL] loadPrefs model=' + prefs.model); }
        } catch(e) {}
    },

    switchModel: function(modelName) {
        syslog('[MODEL] switchModel=' + modelName + ' session=' + (this.currentSession ? this.currentSession.id : 'null') + ' caller=' + (new Error().stack || '').split('\n')[2]);
        if (this.currentSession) {
            this.currentSession.model = modelName;
            SessionStore.updateSession(this.currentSession);
        }
        this._lastUsedModel = modelName;
        this.savePrefs({ model: modelName });
        this._setModelDropdownValue(modelName);
    },

    setStatus: function(text) {
        document.getElementById('status-text').textContent = text;
        document.getElementById('status-bar').classList.toggle('visible', !!text);
    },

    detectWebSearch: async function(userMessage, recentMsgs, signal, images) {
        // Explicit user instruction always wins — skip LLM check.
        // Match: any search-intent word + any web/internet/online word (covers all 5 UI languages).
        var _hasSearchVerb = /\b(search|find|look up|google|tìm\s*ki[eế]m|tìm|such[et]?|googlen|busca[r]?|busque|cherche[rz]?|recherche[rz]?)\b/i;
        var _hasWebMedium = /\b(web|online|internet|en\s+ligne|en\s+l[ií]nea|trên\s+(web|m[aạ]ng|internet)|im\s+(web|internet|netz)|sur\s+(le\s+)?web|sur\s+internet)\b/i;
        if (_hasSearchVerb.test(userMessage) && _hasWebMedium.test(userMessage)) {
            return true;
        }
        try {
            var contextBlock = '';
            if (recentMsgs && recentMsgs.length > 0) {
                contextBlock = 'Conversation so far:\n' + recentMsgs.map(function(m) {
                    var text = typeof m.content === 'string' ? m.content : (Array.isArray(m.content) ? m.content.filter(function(p) { return p.type === 'text'; }).map(function(p) { return p.text; }).join(' ') : '');
                    return (m.role === 'user' ? 'User: ' : 'Assistant: ') + text.slice(0, 400);
                }).join('\n') + '\n\n';
            }
            var body = {
                model: this.currentSession.model,
                stream: false,
                think: false,
                options: { temperature: 0, num_predict: 300, think: false },
                prompt: contextBlock +
                    'New message: ' + userMessage + '\n\n' +
                    'Should this message be answered with a live web search?\n\n' +
                    'Answer YES if any of these apply:\n' +
                    '- The user explicitly asks for "current", "latest", "up-to-date", "this year" information — in any language (aktuell, dieses Jahr, derzeit, actuel, cette année, actualmente, hiện tại, năm nay, etc.)\n' +
                    '- The topic involves figures that change year-to-year: tax rates, salary tables, laws, regulations, prices, statistics\n' +
                    '- Breaking news, live scores, current prices, stock values, today\'s weather\n' +
                    '- A specific named product, tool, software, or system the assistant may not know well or that may have been released recently\n' +
                    '- The user implies the previous answer was outdated or asks for fresher data\n' +
                    '- A person\'s current status, recent actions, or latest work\n\n' +
                    'Answer NO for: science/how things work, history, math/logic, geography, well-known concepts, opinions/debates, coding help, writing help — anything well-covered by training data where the user is not asking for current figures.\n\n' +
                    'Reply with YES or NO only.\n\nAnswer:'
            };
            if (images && images.length > 0) body.images = images;
            syslog('[DETECT] model=' + body.model + ' isCloud=' + isCloudModel(body.model) + ' msg=' + userMessage.slice(0, 80));
            const res = await cloudRoutedFetch(body.model, '/generate', body, signal);
            if (!res.ok) { syslog('[DETECT] fetch failed status=' + res.status); return false; }
            const text = await res.text();
            syslog('[DETECT] raw response=' + text.slice(0, 200));
            var responseText = '';
            try {
                var parsed = JSON.parse(text);
                // response field first; fall back to thinking field (some models put answer there)
                responseText = parsed.response || parsed.thinking || '';
            } catch(e) {
                // NDJSON: accumulate response fields across lines
                text.trim().split('\n').forEach(function(line) {
                    try { var obj = JSON.parse(line); if (obj.response) responseText += obj.response; } catch(_) {}
                });
            }
            syslog('[DETECT] responseText=' + responseText.trim().slice(0, 40));
            return /^(yes|ja|oui|s[ií]|да)/i.test(responseText.trim());
        } catch (e) { syslog('[DETECT] error=' + e.message); return false; }
    },

    _buildBaseQuery: function(userMessage, recentMsgs) {
        var year = new Date().getFullYear();
        var keywords = StopWords.extractKeywords(userMessage);
        // If the current message is too short to be a useful query (< 3 keywords),
        // augment with keywords from the most recent prior user message for context.
        if (keywords.split(/\s+/).filter(Boolean).length < 3 && recentMsgs && recentMsgs.length > 0) {
            var priorUser = null;
            for (var i = recentMsgs.length - 1; i >= 0; i--) {
                if (recentMsgs[i].role === 'user') { priorUser = recentMsgs[i]; break; }
            }
            if (priorUser) {
                var priorText = typeof priorUser.content === 'string' ? priorUser.content
                    : (Array.isArray(priorUser.content) ? priorUser.content.filter(function(p) { return p.type === 'text'; }).map(function(p) { return p.text; }).join(' ') : '');
                var priorKeywords = StopWords.extractKeywords(priorText);
                if (priorKeywords) keywords = (priorKeywords + ' ' + keywords).trim();
            }
        }
        return keywords.indexOf(String(year)) === -1 ? keywords + ' ' + year : keywords;
    },

    getSearchQueries: async function(userMessage, recentMsgs, signal) {
        const baseQuery = this._buildBaseQuery(userMessage, recentMsgs);
        try {
            const model = this.currentSession.model;
            var contextBlock = '';
            if (recentMsgs && recentMsgs.length > 0) {
                contextBlock = 'Conversation context:\n' + recentMsgs.map(function(m) {
                    var text = typeof m.content === 'string' ? m.content : (Array.isArray(m.content) ? m.content.filter(function(p) { return p.type === 'text'; }).map(function(p) { return p.text; }).join(' ') : '');
                    return (m.role === 'user' ? 'User: ' : 'Assistant: ') + text.slice(0, 300);
                }).join('\n') + '\n\n';
            }
            const res = await cloudRoutedFetch(model, '/generate', {
                    model: model,
                    stream: false,
                    think: false,
                    options: { temperature: 0 },
                    prompt:
                        contextBlock +
                        'Current request: "' + userMessage + '"\n' +
                        'Base query: "' + baseQuery + '"\n\n' +
                        'Generate 1-2 keyword search queries to find current information for the above request.\n' +
                        'Rules:\n' +
                        '- Keyword-style only: NO sentences, NO filler words (für, mit, und, the, de, pour…), NO connectives\n' +
                        '- 4-8 words max per query — same compact style as the base query\n' +
                        '- Use synonyms for the main topic words only\n' +
                        '- Keep ALL proper names, brand names, and product names exactly as-is\n' +
                        '- Always include the year ' + new Date().getFullYear() + '\n' +
                        '- Reply in the SAME language as the request\n' +
                        '- First line: LANG:xx where xx is the ISO 639-1 language code of the request (e.g. en, vi, de, fr, es). Then one query per line. No numbering, no explanation.\n'
                }, signal);
            const data = await res.json();
            const reply = (data.response || '').trim();
            var lang = 'auto';
            var lines = reply.split('\n').map(function(s) { return s.trim(); }).filter(Boolean);
            if (lines.length > 0 && /^LANG:[a-z]{2}$/i.test(lines[0])) {
                lang = lines[0].split(':')[1].toLowerCase();
                lines = lines.slice(1);
            }
            const variations = lines.length
                ? lines
                    .map(function(s) { return s.replace(/^[\d\.\-\*\s]+/, '').replace(/['"*]/g, '').trim(); })
                    .filter(Boolean)
                    .slice(0, 2)
                : [];
            // Base query always first — guaranteed accurate
            return { queries: [baseQuery].concat(variations), lang: lang };
        } catch (e) {
            return { queries: [baseQuery], lang: 'auto' };
        }
    },

    searchWebRaw: async function(keywords, lang, signal) {
        try {
            const url = '/search?q=' + encodeURIComponent(keywords) + '&lang=' + encodeURIComponent(lang || 'auto') + '&engine=' + encodeURIComponent(AppConfig.searxngUrl);
            const res = await apiFetch(url, { signal: signal });
            if (!res.ok) return [];
            const data = await res.json();
            return (data.results || []).filter(function(r) { return r.title || r.content; });
        } catch (e) { return []; }
    },

    formatSearchResults: function(results) {
        var n = 0;
        return results.map(function(r) {
            if (!r.fetchedContent && !r.content) return null;
            n++;
            if (r.fetchedContent) {
                return n + '. ' + r.title + '\n' + r.fetchedContent;
            } else {
                return n + '. ' + r.title + '\n' + r.content.slice(0, 300);
            }
        }).filter(Boolean).join('\n\n');
    },

    searchWebParallel: async function(queries, lang, signal) {
        const arrays = await Promise.all(queries.map(function(q) { return this.searchWebRaw(q, lang, signal); }, this));
        const seen = new Set();
        const merged = [];
        arrays.forEach(function(arr) {
            arr.forEach(function(r) {
                if (!seen.has(r.url)) { seen.add(r.url); merged.push(r); }
            });
        });
        return merged;
    },

    enrichResults: async function(results, signal) {
        var SKIP_DOMAINS = ['facebook.com', 'instagram.com', 'twitter.com', 'x.com', 'youtube.com', 'youtu.be', 'tiktok.com', 'linkedin.com', 'reddit.com'];
        var fetchable = results.filter(function(r) {
            try { var h = new URL(r.url).hostname; return !SKIP_DOMAINS.some(function(d) { return h === d || h.endsWith('.' + d); }); }
            catch(e) { return false; }
        });
        var toFetch = fetchable.slice(0, 8);
        var fetches = toFetch.map(function(r) {
            return apiFetch('/fetch-page?url=' + encodeURIComponent(r.url), { signal: signal })
                .then(function(res) { return res.ok ? res.json() : null; })
                .catch(function() { return null; });
        });
        var texts = await Promise.all(fetches);
        // First pass: collect pages that have enough content
        var pagesWithContent = [];
        texts.forEach(function(data, i) {
            if (data && data.text && data.text.length >= 500) {
                pagesWithContent.push({ result: toFetch[i], text: data.text });
            }
        });
        // Distribute content budget proportionally by page size
        var TOTAL_CONTENT_BUDGET = 8000;
        var totalSize = pagesWithContent.reduce(function(sum, p) { return sum + p.text.length; }, 0);
        pagesWithContent.forEach(function(p) {
            var budget = totalSize <= TOTAL_CONTENT_BUDGET
                ? p.text.length
                : Math.floor(TOTAL_CONTENT_BUDGET * p.text.length / totalSize);
            p.result.fetchedContent = p.text.slice(0, budget);
        });
        return results;
    },

    synthesizeResults: async function(question, keywords, results, today, signal) {
        try {
            const model = this.currentSession.model;
            const res = await cloudRoutedFetch(model, '/generate', {
                    model: model,
                    stream: false,
                    think: false,
                    options: { temperature: 0 },
                    prompt: 'Today is ' + today + '. Extract the key facts from these web search results to answer the question. Be concise and factual. Use only what the results say.\n\nQuestion: ' + question + '\n\nSearch results:\n' + results + '\n\nKey facts from results:'
                }, signal);
            const data = await res.json();
            return (data.response || '').trim() || null;
        } catch (e) { return null; }
    },

    sendMessage: async function() {
        const self = this;
        if (this.isStreaming) return;
        // Cancel any in-flight naming call so it doesn't queue behind this message in Ollama
        if (this._namingController) {
            this._namingController.abort();
            this._namingController = null;
        }
        const input = document.getElementById('message-input');
        const content = input.value.trim();
        if (!content && this.attachedFiles.length === 0) return;

        if (!this.currentSession.context) {
            this.currentSession.context = { summary: null, summaryUpToIndex: -1, needsNaming: true };
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

        const sessionAtSend = this.currentSession;
        sessionAtSend.messages.push(userMsgForStorage);
        localStorage.setItem('lastActivityAt', Date.now().toString());
        this.attachedFiles = [];
        this.renderAttachments();
        await SessionStore.updateSession(sessionAtSend);
        this.renderChat();
        input.value = '';
        input.style.height = 'auto';

        const container = document.getElementById('chat-container');
        // Capture user message element now (before assistantDiv is appended) so the RAF uses the right ref
        var userMsgEl = container.lastElementChild;
        requestAnimationFrame(function() {
            if (userMsgEl) container.scrollTop = userMsgEl.offsetTop;
        });

        const assistantTs = Date.now();
        const assistantDiv = document.createElement('div');
        assistantDiv.className = 'message assistant';
        const assistantHdr = document.createElement('div');
        assistantHdr.className = 'msg-header';
        assistantHdr.textContent = buildMsgHeader({ role: 'assistant', ts: assistantTs, model: this.currentSession.model }, this.currentSession);
        assistantDiv.appendChild(assistantHdr);
        const bodyDiv = document.createElement('div');
        bodyDiv.className = 'msg-body';
        bodyDiv.id = 'streaming-body';
        assistantDiv.appendChild(bodyDiv);
        container.appendChild(assistantDiv);

        this.isStreaming = true;
        this._acquireWakeLock();
        self._streamMap.clear();
        self._streamMap.set(sessionAtSend.id, { content: '', searchWarning: '', session: sessionAtSend });
        const pipelineController = new AbortController();
        const pipelineSignal = pipelineController.signal;
        self._streamController = pipelineController;
        document.getElementById('send-btn').disabled = true;
        document.getElementById('stop-label').textContent = t('stopGen');
        document.getElementById('stop-gen-btn').style.display = '';
        this.setStatus(getModelDisplayName(this.currentSession.model) + t('thinking'));

        let apiMessages = prepareForAPI(ContextManager.buildContextMessages(this.currentSession));
        apiMessages[apiMessages.length - 1] = userMsgForAPI;
        var systemPrompt = 'You are DMH-AI, a helpful, knowledgeable, and friendly AI assistant. You are ready to help with anything — answering questions, writing, analysis, coding, math, research, brainstorming, and more. Be clear, concise, and honest. If you don\'t know something, say so. Never claim to be a different AI (such as ChatGPT, Gemini, or Claude).';
        if (UserProfile._facts) {
            systemPrompt += '\n\nWhat you know about this user:\n' + UserProfile._facts + '\n\nRefer to these naturally when relevant. If the user asks what you know about them, share these facts directly.';
        }
        apiMessages.unshift({ role: 'system', content: systemPrompt });
        var relevant = ContextManager.retrieveRelevant(this.currentSession, content, 4);
        if (relevant.length > 0) {
            var snippets = relevant.map(function(p, i) {
                return (i + 1) + '. User: ' + p.user.slice(0, 600) + (p.assistant ? '\n   Assistant: ' + p.assistant.slice(0, 600) : '');
            }).join('\n\n');
            apiMessages.splice(apiMessages.length - 1, 0,
                { role: 'user', content: '[Potentially relevant excerpts from earlier in this conversation]\n\n' + snippets },
                { role: 'assistant', content: 'Noted — I have those earlier exchanges in context.' }
            );
        }
        const recentMsgs = (this.currentSession.messages || []).filter(function(m) { return m.role === 'user' || m.role === 'assistant'; }).slice(-4);
        const effectiveContent = contentForAPI.trim() || content.trim();
        const needsWebSearch = await this.detectWebSearch(effectiveContent, recentMsgs, pipelineSignal, imagesForAPI);
        if (pipelineSignal.aborted) return;
        const cleanedContent = effectiveContent;
        syslog('[SEND] user="' + content.slice(0, 120) + '" needsWebSearch=' + needsWebSearch + ' cleanedQuery="' + cleanedContent + '"');
        if (AppConfig.searxngUrl && needsWebSearch) {
            this.setStatus(t('genKeywords'));
            const queryResult = await this.getSearchQueries(cleanedContent, recentMsgs, pipelineSignal);
            if (pipelineSignal.aborted) return;
            const queries = queryResult.queries;
            const queryLang = queryResult.lang;
            syslog('[QUERIES] lang=' + queryLang + ' result="' + (queries ? queries.join(' | ') : 'null') + '"');
            if (queries) {
                this.setStatus(t('searchingWeb'));
                const allRaw = await this.searchWebParallel(queries, queryLang, pipelineSignal);
                if (pipelineSignal.aborted) return;
                syslog('[SEARCH] got ' + allRaw.length + ' results');

                if (allRaw.length > 0) {
                    this.setStatus(t('fetchingPages'));
                    await this.enrichResults(allRaw, pipelineSignal);
                    if (pipelineSignal.aborted) return;
                }
                // Cap to top 10 results to keep synthesis prompt bounded
                const topResults = allRaw.slice(0, 10);
                const allFormatted = topResults.length ? this.formatSearchResults(topResults) : null;
                if (allFormatted) {
                    this.setStatus(t('synthesizing'));
                    const today = new Date().toDateString();
                    const synthesis = await this.synthesizeResults(cleanedContent, queries.join(' '), allFormatted, today, pipelineSignal);
                    if (pipelineSignal.aborted) return;
                    // Use synthesis if available, otherwise fall back to truncated raw results
                    const injectedResults = synthesis || allFormatted.slice(0, 8000);
                    syslog('[SYNTHESIS] ' + (synthesis ? 'ok' : 'failed, using raw') + ' len=' + injectedResults.length);
                    var injectedMsg = {
                        role: 'user',
                        content: 'User request: ' + cleanedContent + '\n\nWeb search results (retrieved ' + today + '):\n' + injectedResults + '\n\nUsing the user request and the web search results above, compile a complete and accurate answer.'
                    };
                    if (imagesForAPI.length > 0) injectedMsg.images = imagesForAPI;
                    apiMessages = apiMessages.slice(0, -1).concat([injectedMsg]);
                    syslog('[INJECT] results injected into context');
                } else {
                    syslog('[SEARCH] fallback: all rounds returned no results');
                    var warnHtml = '<em style="color:#d0a050;">' + t('searchUnavail') + '</em><br><br>';
                    bodyDiv.innerHTML = warnHtml;
                    self._streamMap.get(sessionAtSend.id).searchWarning = warnHtml;
                }
            }
        }
        let assistantContent = '';
        let firstChunk = true;
        const usePool = isCloudModel(sessionAtSend.model) && Settings.accounts.length > 0;
        const maxRetries = usePool ? Settings.accounts.length : 0;

        function doStream(acct, retryCount) {
            const authHeaders = acct ? {
                'Authorization': 'Bearer ' + (Auth.token || ''),
                'X-Cloud-Key': acct.apiKey
            } : {};
            const baseUrl = acct ? '/cloud-api' : null;
            OllamaAPI.streamChat(
                sessionAtSend.model,
                apiMessages,
                function(chunk) {
                    if (firstChunk) {
                        firstChunk = false;
                        self.setStatus(getModelDisplayName(sessionAtSend.model) + t('answering'));
                    }
                    assistantContent += chunk;
                    var mapEntry = self._streamMap.get(sessionAtSend.id);
                    if (mapEntry) {
                        mapEntry.content = assistantContent;
                        if (self.currentSession && self.currentSession.id === sessionAtSend.id) {
                            var activeBody = document.getElementById('streaming-body');
                            if (activeBody) {
                                activeBody.innerHTML = mapEntry.searchWarning + renderWithMath(assistantContent);
                                addCopyButtons(activeBody); wrapTables(activeBody);
                                var overflowed = container.scrollHeight > container.scrollTop + container.clientHeight + 40;
                                document.getElementById('scroll-bottom-btn').style.display = overflowed ? 'flex' : 'none';
                            }
                        }
                    }
                },
                function() {
                    if (acct) CloudAccountPool.markRecovered(acct);
                    sessionAtSend.messages.push({ role: 'assistant', content: assistantContent, ts: assistantTs, model: sessionAtSend.model });
                    var userMsg = sessionAtSend.messages[sessionAtSend.messages.length - 2];
                    if (userMsg && userMsg.role === 'user') userMsg._sentToLLM = true;
                    self._streamMap.delete(sessionAtSend.id);
                    SessionStore.updateSession(sessionAtSend);
                    self._streamController = null;
                    self._activeBodyDiv = null;
                    self.isStreaming = false;
                    self._releaseWakeLock();
                    self.updateSendBtn();
                    self.setStatus('');
                    document.getElementById('stop-gen-btn').style.display = 'none';
                    if (self.currentSession && self.currentSession.id === sessionAtSend.id) {
                        self.currentSession = sessionAtSend;
                        self.renderChat();
                    }
                    if (sessionAtSend.context && sessionAtSend.context.needsNaming) {
                        self.autoNameSession(sessionAtSend);
                    }
                    // Background profile extraction — runs after response, non-blocking
                    (function() {
                        var lastUser = sessionAtSend.messages[sessionAtSend.messages.length - 2];
                        var userText = lastUser && lastUser.role === 'user'
                            ? (typeof lastUser.content === 'string' ? lastUser.content
                                : (Array.isArray(lastUser.content) ? lastUser.content.filter(function(p){return p.type==='text';}).map(function(p){return p.text||'';}).join(' ') : ''))
                            : '';
                        UserProfile.extractAndMerge(userText, assistantContent, sessionAtSend.model);
                    })();
                    // Background compaction — runs after response, transparent to user
                    OllamaAPI.fetchContextWindow(sessionAtSend.model).then(function(contextWindow) {
                        if (ContextManager.shouldCompact(sessionAtSend, contextWindow, '')) {
                            if (!self.isStreaming) self.setStatus(t('compacting'));
                            ContextManager.compact(sessionAtSend).then(function() {
                                if (!self.isStreaming) self.setStatus('');
                            }).catch(function() {
                                if (!self.isStreaming) self.setStatus('');
                            });
                        }
                    }).catch(function() {});
                },
                function(err) {
                    if (acct && retryCount < maxRetries) {
                        var statusMatch = err.message && err.message.match(/\((\d+)\)/);
                        var status = statusMatch ? parseInt(statusMatch[1]) : 0;
                        if (status === 429 || status === 503 || status === 401 || status === 403) {
                            CloudAccountPool.markFailed(acct);
                            var nextAcct = CloudAccountPool.getNext();
                            if (nextAcct && nextAcct.name !== acct.name) {
                                doStream(nextAcct, retryCount + 1);
                                return;
                            }
                        }
                    }
                    console.error('Stream error:', err);
                    if (assistantContent) {
                        var errEntry = self._streamMap.get(sessionAtSend.id);
                        var errBody = document.getElementById('streaming-body');
                        if (errBody && errEntry) { errBody.innerHTML = errEntry.searchWarning + renderWithMath(assistantContent); addCopyButtons(errBody); wrapTables(errBody); }
                    }
                    self.saveStreamingProgress();
                    self._streamMap.delete(sessionAtSend.id);
                    self._streamController = null;
                    self.isStreaming = false;
                    self._releaseWakeLock();
                    self.updateSendBtn();
                    self.setStatus('');
                    document.getElementById('stop-gen-btn').style.display = 'none';
                },
                pipelineSignal,
                authHeaders,
                baseUrl
            );
        }

        doStream(usePool ? CloudAccountPool.getNext() : null, 0);
    },

    autoNameSession: async function(session) {
        if (!this._namingInProgress) this._namingInProgress = new Set();
        if (this._namingInProgress.has(session.id)) return;
        this._namingInProgress.add(session.id);
        const controller = new AbortController();
        this._namingController = controller;
        try {
            var msgs = (session.messages || []).slice(-4);
            if (!msgs.length) return;
            var excerpt = msgs.map(function(m) {
                var text = typeof m.content === 'string' ? m.content : '';
                if (!text.trim() && m.files && m.files.length > 0)
                    text = m.files.map(function(f) { return f.snippet || ''; }).join(' ');
                return (m.role === 'user' ? 'User: ' : 'Assistant: ') + text.slice(0, 200);
            }).join('\n');
            if (!excerpt.trim()) return;
            syslog('[NAMING] model=' + session.model + ' excerpt="' + excerpt.slice(0, 80) + '"');
            var name = await OllamaAPI.summarize(session.model, [{
                role: 'user',
                content: 'Give a short title (3-5 words) for this conversation:\n\n' + excerpt + '\n\nReply with only the title, no quotes, no explanation.'
            }], controller.signal);
            syslog('[NAMING] result="' + (name || '').trim().slice(0, 80) + '"');
            if (controller.signal.aborted) return;
            if (!name || !name.trim()) return;
            name = name.trim()
                .replace(/^["""''']+|["""''']+$/g, '')   // strip surrounding quotes
                .replace(/\*{1,3}([^*]*)\*{1,3}/g, '$1') // strip ***bold italic*** **bold** *italic*
                .replace(/_{1,2}([^_]*)_{1,2}/g, '$1')   // strip __bold__ _italic_
                .replace(/^#{1,6}\s+/, '')                // strip heading markers
                .replace(/`([^`]*)`/g, '$1')              // strip inline code
                .trim();
            if (!name) return;
            session.name = name;
            session.context.needsNaming = false;
            await SessionStore.updateSession(session);
            await this.renderSessions();
        } catch(e) {}
        finally {
            this._namingInProgress.delete(session.id);
            if (this._namingController === controller) this._namingController = null;
        }
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
    Lightbox.init();
    UIManager.init();
});
