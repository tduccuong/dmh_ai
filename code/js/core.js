/*
 * Copyright (c) 2026 Cuong Truong
 * This project is licensed under the AGPL v3.
 * See the LICENSE file in the repository root for full details.
 * For commercial inquiries, contact: tduccuong@gmail.com
 */

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
    _lang: localStorage.getItem('lang') || (function() {
        var supported = { en: 1, vi: 1, de: 1, es: 1, fr: 1 };
        var langs = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || 'en'];
        for (var i = 0; i < langs.length; i++) {
            var code = langs[i].split('-')[0].toLowerCase();
            if (supported[code]) return code;
        }
        return 'en';
    })(),
    _strings: {
        en: {
            retry: 'Retry', clear: 'Clear', send: 'Send', cancel: 'Cancel', ok: 'OK', stopGen: 'Stop',
            update: 'Update', rename: 'Rename', delete_: 'Delete', download: '⬇ Download',
            newSession: '+ New Session', newChat: 'New chat',
            typePlaceholder: 'Type a message and click Send or press Ctrl-Enter...', typePlaceholderShort: 'Type a message...', attachFile: 'Attach file',
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
            noVideo1: '⚠ ', noVideo2: ' does not support video. Switch to a video-capable model and send again.',
            genKeywords: ' is generating search keywords...',
            searchingWeb: ' is searching the web...',
            fetchingPages: ' is reading web sources...',
            synthesizing: ' is synthesizing the answer...',
            waitingFor: 'Waiting for ', thinking: ' is thinking...', answering: ' is streaming the answer...', compacting: 'Compacting conversation...',
            settingsChatSection: 'Chat', settingsCompactLabel: 'Compact after messages', settingsKeepRecentLabel: 'Keep recent messages',
            settingsNavModel: 'Models', settingsNavConversation: 'Conversation',
            searchUnavail: 'No search results found — answering from what I know, which may not include the latest updates.',
            attaching: 'Preparing attachment...',
            voiceListening: 'Recording... tap this button to stop',
            voiceNotSupported: 'Voice input not supported in this browser',
            voiceHttpError: 'Voice input requires HTTPS. Access the app on port 8443 to enable it.',
            voiceEmpty: 'Nothing was recognized. To record in a different language, tap the flag button to switch language first. Currently listening in ',
            voiceLangTitle: 'Voice Recording',
            voiceLangMsg: 'Currently recording in <strong>{lang}</strong>.<br><br>To record in a different language, please switch the language first by clicking the language button in the top bar.',
            voiceLangCancel: 'Cancel',
            voiceLangOk: 'Start Recording',
            iosChromeHint: 'To add DMH-AI to your home screen, open this page in Safari, tap the Share button (⎙), then "Add to Home Screen".',
            iosCertHint: 'To avoid the certificate warning: tap here to install the certificate, then go to Settings → General → About → Certificate Trust Settings and enable it.',
            pwWarning: '⚠ You are using the default password. Please change it now.',
            pwWarningBtn: 'Change password',
            settings: 'Settings', sysSettings: 'System Settings',
            recQuickAnswer: '👁 Quick-Wit', recDeepThinker: '💡 Deep Thinker', recTechExpert: '🛠 Technical Expert', recWordsmith: '✍ Lexicon',
            aboutBtn: 'About', aboutDesc: 'A self-hosted, multi-user AI chat platform supporting local and cloud LLMs, real-time web search with answer synthesis, voice input, and rich document and image attachments — designed for private deployment.', aboutLegalTitle: 'Legal & License', aboutLicenseLabel: 'License:', aboutLicenseBody: 'Licensed under the GNU Affero General Public License v3 (AGPL-3.0).', aboutAttrib: 'Pursuant to the Additional Terms (Section 7b), any redistribution or derivative of this software must maintain this attribution and link to the original source.', aboutSourceLabel: 'Source Code:', aboutCommercialLabel: 'Commercial Licensing:', aboutCommercialBody: 'For inquiries regarding commercial use or proprietary licensing, please contact Cuong Truong at tduccuong@gmail.com.', aboutClose: 'Close',
            noModelAvail: 'No model available. Please configure a model in Settings first.',
            profileSection: 'Companion Memory', profileEmpty: 'No facts remembered yet.',
            profileClear: 'Clear memory', profileClearConfirm: 'This will reset everything DMH-AI has learned about you. You may notice a different feeling next time — it will understand you again over time, but that takes a while. You can always rebuild it from Conversation Settings. Are you sure?',
            profileCondenseLabel: 'Condense after facts',
            convSettings: 'Conversation Settings',
            multimediaSection: 'Multimedia', videoDetailLabel: 'Video analysis depth',
            videoDetailLow: 'Low (4 frames)', videoDetailMedium: 'Medium (8 frames)', videoDetailHigh: 'High (12 frames)',
        },
        vi: {
            retry: 'Thử lại', clear: 'Xóa', send: 'Gửi', cancel: 'Hủy', ok: 'OK', stopGen: 'Dừng',
            update: 'Cập nhật', rename: 'Đổi tên', delete_: 'Xóa', download: '⬇ Tải về',
            newSession: '+ Phiên mới', newChat: 'Cuộc trò chuyện mới',
            typePlaceholder: 'Nhập tin nhắn và nhấn Gửi hoặc Ctrl-Enter...', typePlaceholderShort: 'Nhập tin nhắn...', attachFile: 'Đính kèm tệp',
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
            noVideo1: '⚠ ', noVideo2: ' không hỗ trợ video. Hãy chọn mô hình hỗ trợ video và gửi lại.',
            genKeywords: ' đang tạo từ khóa tìm kiếm...',
            searchingWeb: ' đang tìm kiếm web...',
            fetchingPages: ' đang đọc nguồn web...',
            synthesizing: ' đang tổng hợp câu trả lời...',
            waitingFor: 'Đang chờ ', thinking: ' đang suy nghĩ...', answering: ' đang phát trực tiếp câu trả lời...', compacting: 'Đang nén hội thoại...',
            settingsChatSection: 'Chat', settingsCompactLabel: 'Nén sau số tin nhắn', settingsKeepRecentLabel: 'Giữ tin nhắn gần đây',
            settingsNavModel: 'Mô hình', settingsNavConversation: 'Hội thoại',
            searchUnavail: 'Không tìm thấy kết quả tìm kiếm — tôi sẽ trả lời từ những gì tôi biết, có thể chưa có thông tin mới nhất.',
            attaching: 'Đang chuẩn bị tệp đính kèm...',
            voiceListening: 'Đang ghi âm... nhấn nút này để dừng',
            voiceNotSupported: 'Trình duyệt này không hỗ trợ nhập giọng nói',
            voiceHttpError: 'Nhập giọng nói yêu cầu HTTPS. Truy cập ứng dụng qua cổng 8443 để sử dụng.',
            voiceEmpty: 'Không nhận ra giọng nói. Để ghi âm bằng ngôn ngữ khác, nhấn nút cờ để chọn ngôn ngữ trước. Hiện đang nghe bằng ',
            voiceLangTitle: 'Ghi âm giọng nói',
            voiceLangMsg: 'Đang ghi âm bằng <strong>{lang}</strong>.<br><br>Để ghi âm bằng ngôn ngữ khác, hãy chuyển ngôn ngữ trước bằng cách nhấn nút ngôn ngữ trên thanh công cụ.',
            voiceLangCancel: 'Hủy',
            voiceLangOk: 'Bắt đầu ghi âm',
            iosChromeHint: 'Để thêm DMH-AI vào màn hình chính, mở trang này trong Safari, nhấn nút Chia sẻ (⎙), rồi chọn "Thêm vào Màn hình chính".',
            iosCertHint: 'Để bỏ cảnh báo chứng chỉ: nhấn đây để cài chứng chỉ, rồi vào Cài đặt → Cài đặt chung → Giới thiệu → Cài đặt tin cậy chứng chỉ và bật lên.',
            pwWarning: '⚠ Bạn đang dùng mật khẩu mặc định. Hãy đổi mật khẩu ngay.',
            pwWarningBtn: 'Đổi mật khẩu',
            settings: 'Cài đặt', sysSettings: 'Cài đặt hệ thống',
            recQuickAnswer: '👁 Nhanh Trí', recDeepThinker: '💡 Triết Gia', recTechExpert: '🛠 Kỹ Thuật Gia', recWordsmith: '✍ Ngòi Bút',
            aboutBtn: 'Giới thiệu', aboutDesc: 'Nền tảng chat AI đa người dùng tự lưu trữ, hỗ trợ mô hình cục bộ và đám mây, tìm kiếm web thời gian thực với tổng hợp câu trả lời, nhập liệu bằng giọng nói và đính kèm tài liệu, hình ảnh phong phú — được thiết kế cho triển khai riêng tư.', aboutLegalTitle: 'Pháp lý & Giấy phép', aboutLicenseLabel: 'Giấy phép:', aboutLicenseBody: 'Được cấp phép theo Giấy phép Công cộng GNU Affero phiên bản 3 (AGPL-3.0).', aboutAttrib: 'Theo Điều khoản Bổ sung (Mục 7b), mọi sự phân phối lại hoặc phái sinh của phần mềm này phải duy trì thông tin ghi công này và liên kết đến nguồn gốc.', aboutSourceLabel: 'Mã nguồn:', aboutCommercialLabel: 'Cấp phép thương mại:', aboutCommercialBody: 'Để được tư vấn về sử dụng thương mại hoặc cấp phép độc quyền, vui lòng liên hệ Cuong Truong tại tduccuong@gmail.com.', aboutClose: 'Đóng',
            noModelAvail: 'Không có mô hình nào. Vui lòng cấu hình trong Cài đặt trước.',
            profileSection: 'Bộ nhớ đồng hành', profileEmpty: 'Chưa ghi nhớ điều gì.',
            profileClear: 'Xóa bộ nhớ', profileClearConfirm: 'Thao tác này sẽ xóa toàn bộ những gì DMH-AI đã hiểu về bạn. Lần trò chuyện tiếp theo có thể cảm giác khác đi — DMH-AI sẽ dần hiểu bạn trở lại theo thời gian. Bạn có thể xây dựng lại bất cứ lúc nào trong Cài đặt hội thoại. Bạn có chắc không?',
            profileCondenseLabel: 'Cô đọng sau số sự kiện',
            convSettings: 'Cài đặt hội thoại',
            multimediaSection: 'Đa phương tiện', videoDetailLabel: 'Độ chi tiết phân tích video',
            videoDetailLow: 'Thấp (4 khung)', videoDetailMedium: 'Trung bình (8 khung)', videoDetailHigh: 'Cao (12 khung)',
        },
        de: {
            retry: 'Wiederholen', clear: 'Löschen', send: 'Senden', cancel: 'Abbrechen', ok: 'OK', stopGen: 'Stopp',
            update: 'Aktualisieren', rename: 'Umbenennen', delete_: 'Löschen', download: '⬇ Herunterladen',
            newSession: '+ Neue Sitzung', newChat: 'Neuer Chat',
            typePlaceholder: 'Nachricht eingeben und auf Senden klicken oder Strg-Enter drücken...', typePlaceholderShort: 'Nachricht eingeben...', attachFile: 'Datei anhängen',
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
            noVideo1: '⚠ ', noVideo2: ' unterstützt kein Video. Wählen Sie ein videofähiges Modell und senden Sie erneut.',
            genKeywords: ' generiert Suchbegriffe...',
            searchingWeb: ' durchsucht das Web...',
            fetchingPages: ' liest Web-Quellen...',
            synthesizing: ' synthetisiert die Antwort...',
            waitingFor: 'Warte auf ', thinking: ' denkt nach...', answering: ' streamt die Antwort...', compacting: 'Konversation wird komprimiert...',
            settingsChatSection: 'Chat', settingsCompactLabel: 'Komprimieren nach Nachrichten', settingsKeepRecentLabel: 'Neueste Nachrichten behalten',
            settingsNavModel: 'Modelle', settingsNavConversation: 'Gespräch',
            searchUnavail: 'Keine Suchergebnisse gefunden — ich antworte aus meinem Wissen, das möglicherweise nicht auf dem neuesten Stand ist.',
            attaching: 'Anhang wird vorbereitet...',
            voiceListening: 'Aufnahme... diese Schaltfläche zum Stoppen tippen',
            voiceNotSupported: 'Spracheingabe in diesem Browser nicht unterstützt',
            voiceHttpError: 'Spracheingabe erfordert HTTPS. Öffnen Sie die App über Port 8443.',
            voiceEmpty: 'Nichts erkannt. Um in einer anderen Sprache aufzunehmen, tippen Sie zuerst auf die Flagge. Aktuell wird gehört auf ',
            voiceLangTitle: 'Sprachaufnahme',
            voiceLangMsg: 'Aktuell wird aufgenommen in <strong>{lang}</strong>.<br><br>Um in einer anderen Sprache aufzunehmen, wechseln Sie zuerst die Sprache über die Schaltfläche in der oberen Leiste.',
            voiceLangCancel: 'Abbrechen',
            voiceLangOk: 'Aufnahme starten',
            iosChromeHint: 'Um DMH-AI zum Home-Bildschirm hinzuzufügen, öffnen Sie die Seite in Safari, tippen auf Teilen (⎙) und wählen „Zum Home-Bildschirm".',
            iosCertHint: 'Um die Zertifikatwarnung zu vermeiden: hier tippen zum Installieren, dann Einstellungen → Allgemein → Info → Zertifikat-Vertrauenseinstellungen und aktivieren.',
            pwWarning: '⚠ Sie verwenden noch das Standardpasswort. Bitte jetzt ändern.',
            pwWarningBtn: 'Passwort ändern',
            settings: 'Einstellungen', sysSettings: 'Systemeinstellungen',
            recQuickAnswer: '👁 Schlagfertig', recDeepThinker: '💡 Tiefdenker', recTechExpert: '🛠 Technischer Experte', recWordsmith: '✍ Lexicon',
            aboutBtn: 'Über', aboutDesc: 'Eine selbst gehostete, mehrbenutzer-fähige KI-Chat-Plattform mit Unterstützung für lokale und Cloud-LLMs, Echtzeit-Websuche mit Antwortsynthese, Spracheingabe und umfangreichen Dokument- und Bildanhängen — für private Bereitstellung konzipiert.', aboutLegalTitle: 'Recht & Lizenz', aboutLicenseLabel: 'Lizenz:', aboutLicenseBody: 'Lizenziert unter der GNU Affero General Public License v3 (AGPL-3.0).', aboutAttrib: 'Gemäß den Zusatzbedingungen (Abschnitt 7b) muss jede Weiterverbreitung oder Ableitung dieser Software diese Zuschreibung und den Link zur Originalquelle beibehalten.', aboutSourceLabel: 'Quellcode:', aboutCommercialLabel: 'Kommerzielle Lizenzierung:', aboutCommercialBody: 'Für Anfragen zur kommerziellen Nutzung oder proprietären Lizenzierung wenden Sie sich bitte an Cuong Truong unter tduccuong@gmail.com.', aboutClose: 'Schließen',
            noModelAvail: 'Kein Modell verfügbar. Bitte zuerst in den Einstellungen konfigurieren.',
            profileSection: 'Begleitergedächtnis', profileEmpty: 'Noch keine Fakten gespeichert.',
            profileClear: 'Gedächtnis löschen', profileClearConfirm: 'Damit wird alles zurückgesetzt, was DMH-AI über Sie gelernt hat. Beim nächsten Gespräch kann sich etwas anders anfühlen — es wird Sie mit der Zeit wieder verstehen. Sie können es jederzeit über die Gesprächseinstellungen neu aufbauen. Sind Sie sicher?',
            profileCondenseLabel: 'Verdichten nach Fakten',
            convSettings: 'Gesprächseinstellungen',
            multimediaSection: 'Multimedia', videoDetailLabel: 'Videoanalyse-Tiefe',
            videoDetailLow: 'Niedrig (4 Frames)', videoDetailMedium: 'Mittel (8 Frames)', videoDetailHigh: 'Hoch (12 Frames)',
        },
        es: {
            retry: 'Reintentar', clear: 'Limpiar', send: 'Enviar', cancel: 'Cancelar', ok: 'OK', stopGen: 'Detener',
            update: 'Actualizar', rename: 'Renombrar', delete_: 'Eliminar', download: '⬇ Descargar',
            newSession: '+ Nueva sesión', newChat: 'Nueva conversación',
            typePlaceholder: 'Escribe un mensaje y haz clic en Enviar o presiona Ctrl-Enter...', typePlaceholderShort: 'Escribe un mensaje...', attachFile: 'Adjuntar archivo',
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
            noVideo1: '⚠ ', noVideo2: ' no admite vídeo. Seleccione un modelo compatible con vídeo y envíe de nuevo.',
            genKeywords: ' está generando palabras clave...',
            searchingWeb: ' está buscando en la web...',
            fetchingPages: ' está leyendo fuentes web...',
            synthesizing: ' está sintetizando la respuesta...',
            waitingFor: 'Esperando a ', thinking: ' está pensando...', answering: ' está transmitiendo la respuesta...', compacting: 'Comprimiendo conversación...',
            settingsChatSection: 'Chat', settingsCompactLabel: 'Compactar después de mensajes', settingsKeepRecentLabel: 'Mantener mensajes recientes',
            settingsNavModel: 'Modelos', settingsNavConversation: 'Conversación',
            searchUnavail: 'No se encontraron resultados — responderé desde lo que sé, que puede no incluir las últimas novedades.',
            attaching: 'Preparando archivo adjunto...',
            voiceListening: 'Grabando... toca este botón para detener',
            voiceNotSupported: 'Entrada de voz no compatible con este navegador',
            voiceHttpError: 'La entrada de voz requiere HTTPS. Acceda a la aplicación por el puerto 8443.',
            voiceEmpty: 'No se reconoció nada. Para grabar en otro idioma, toca el botón de bandera primero. Actualmente escuchando en ',
            voiceLangTitle: 'Grabación de voz',
            voiceLangMsg: 'Grabando actualmente en <strong>{lang}</strong>.<br><br>Para grabar en otro idioma, cambia el idioma primero usando el botón de idioma en la barra superior.',
            voiceLangCancel: 'Cancelar',
            voiceLangOk: 'Iniciar grabación',
            iosChromeHint: 'Para agregar DMH-AI a la pantalla de inicio, abre la página en Safari, toca Compartir (⎙) y selecciona "Agregar a inicio".',
            iosCertHint: 'Para evitar la advertencia: toca aquí para instalar el certificado, luego ve a Ajustes → General → Información → Configuración de confianza de certificados y actívalo.',
            pwWarning: '⚠ Está usando la contraseña predeterminada. Cámbiela ahora.',
            pwWarningBtn: 'Cambiar contraseña',
            settings: 'Configuración', sysSettings: 'Configuración del sistema',
            recQuickAnswer: '👁 Perspicaz', recDeepThinker: '💡 Pensador Profundo', recTechExpert: '🛠 Experto Técnico', recWordsmith: '✍ Lexicon',
            aboutBtn: 'Acerca de', aboutDesc: 'Una plataforma de chat de IA multiusuario autohospedada que admite LLMs locales y en la nube, búsqueda web en tiempo real con síntesis de respuestas, entrada de voz y archivos adjuntos de documentos e imágenes — diseñada para implementación privada.', aboutLegalTitle: 'Legal y Licencia', aboutLicenseLabel: 'Licencia:', aboutLicenseBody: 'Con licencia bajo la Licencia Pública General GNU Affero v3 (AGPL-3.0).', aboutAttrib: 'Conforme a los Términos Adicionales (Sección 7b), cualquier redistribución o derivado de este software debe mantener esta atribución y el enlace a la fuente original.', aboutSourceLabel: 'Código fuente:', aboutCommercialLabel: 'Licencias comerciales:', aboutCommercialBody: 'Para consultas sobre uso comercial o licencias propietarias, contacte a Cuong Truong en tduccuong@gmail.com.', aboutClose: 'Cerrar',
            noModelAvail: 'Ningún modelo disponible. Configure uno en Ajustes primero.',
            profileSection: 'Memoria del compañero', profileEmpty: 'Aún no hay hechos recordados.',
            profileClear: 'Borrar memoria', profileClearConfirm: 'Esto reiniciará todo lo que DMH-AI ha aprendido sobre usted. La próxima vez que chatee puede sentirse diferente — lo entenderá de nuevo con el tiempo. Siempre puede reconstruirlo desde Configuración de conversación. ¿Está seguro?',
            profileCondenseLabel: 'Condensar después de hechos',
            convSettings: 'Configuración de conversación',
            multimediaSection: 'Multimedia', videoDetailLabel: 'Profundidad de análisis de vídeo',
            videoDetailLow: 'Baja (4 fotogramas)', videoDetailMedium: 'Media (8 fotogramas)', videoDetailHigh: 'Alta (12 fotogramas)',
        },
        fr: {
            retry: 'Réessayer', clear: 'Effacer', send: 'Envoyer', cancel: 'Annuler', ok: 'OK', stopGen: 'Arrêter',
            update: 'Mettre à jour', rename: 'Renommer', delete_: 'Supprimer', download: '⬇ Télécharger',
            newSession: '+ Nouvelle session', newChat: 'Nouvelle conversation',
            typePlaceholder: 'Tapez un message et cliquez sur Envoyer ou appuyez sur Ctrl-Entrée...', typePlaceholderShort: 'Tapez un message...', attachFile: 'Joindre un fichier',
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
            noVideo1: '⚠ ', noVideo2: ' ne prend pas en charge la vidéo. Sélectionnez un modèle compatible vidéo et réessayez.',
            genKeywords: ' génère des mots-clés...',
            searchingWeb: ' effectue une recherche web...',
            fetchingPages: ' lit les sources web...',
            synthesizing: ' synthétise la réponse...',
            waitingFor: 'En attente de ', thinking: ' réfléchit...', answering: ' diffuse la réponse...', compacting: 'Compactage de la conversation...',
            settingsChatSection: 'Chat', settingsCompactLabel: 'Compacter après messages', settingsKeepRecentLabel: 'Garder les messages récents',
            settingsNavModel: 'Modèles', settingsNavConversation: 'Conversation',
            searchUnavail: 'Aucun résultat trouvé — je répondrai d\'après ce que je sais, qui peut ne pas inclure les dernières mises à jour.',
            attaching: 'Préparation de la pièce jointe...',
            voiceListening: 'Enregistrement... appuyez sur ce bouton pour arrêter',
            voiceNotSupported: 'Saisie vocale non prise en charge par ce navigateur',
            voiceHttpError: 'La saisie vocale nécessite HTTPS. Accédez à l\'application via le port 8443.',
            voiceEmpty: 'Rien reconnu. Pour enregistrer dans une autre langue, appuyez d\'abord sur le drapeau. Langue actuelle : ',
            voiceLangTitle: 'Enregistrement vocal',
            voiceLangMsg: 'Enregistrement actuellement en <strong>{lang}</strong>.<br><br>Pour enregistrer dans une autre langue, changez d\'abord la langue en cliquant sur le bouton de langue dans la barre supérieure.',
            voiceLangCancel: 'Annuler',
            voiceLangOk: 'Démarrer l\'enregistrement',
            iosChromeHint: 'Pour ajouter DMH-AI à l\'écran d\'accueil, ouvrez la page dans Safari, appuyez sur Partager (⎙) puis « Sur l\'écran d\'accueil ».',
            iosCertHint: 'Pour éviter l\'avertissement : appuyez ici pour installer le certificat, puis Réglages → Général → À propos → Réglages de confiance des certificats et activez.',
            pwWarning: '⚠ Vous utilisez le mot de passe par défaut. Veuillez le changer maintenant.',
            pwWarningBtn: 'Changer le mot de passe',
            settings: 'Paramètres', sysSettings: 'Paramètres système',
            recQuickAnswer: '👁 Esprit Vif', recDeepThinker: '💡 Penseur Profond', recTechExpert: '🛠 Expert Technique', recWordsmith: '✍ Lexicon',
            aboutBtn: 'À propos', aboutDesc: 'Une plateforme de chat IA multi-utilisateurs auto-hébergée prenant en charge les LLMs locaux et cloud, la recherche web en temps réel avec synthèse des réponses, la saisie vocale et les pièces jointes de documents et d\'images — conçue pour un déploiement privé.', aboutLegalTitle: 'Mentions légales et Licence', aboutLicenseLabel: 'Licence :', aboutLicenseBody: 'Sous licence GNU Affero General Public License v3 (AGPL-3.0).', aboutAttrib: 'Conformément aux Conditions supplémentaires (Section 7b), toute redistribution ou dérivé de ce logiciel doit conserver cette attribution et le lien vers la source originale.', aboutSourceLabel: 'Code source :', aboutCommercialLabel: 'Licences commerciales :', aboutCommercialBody: 'Pour toute demande concernant l\'utilisation commerciale ou une licence propriétaire, veuillez contacter Cuong Truong à tduccuong@gmail.com.', aboutClose: 'Fermer',
            noModelAvail: 'Aucun modèle disponible. Veuillez d\'abord en configurer un dans les Paramètres.',
            profileSection: 'Mémoire du compagnon', profileEmpty: 'Aucun fait mémorisé pour l\'instant.',
            profileClear: 'Effacer la mémoire', profileClearConfirm: 'Cela réinitialisera tout ce que DMH-AI a appris sur vous. La prochaine conversation pourrait sembler différente — il vous comprendra à nouveau avec le temps. Vous pouvez toujours le reconstruire depuis Paramètres de conversation. Êtes-vous sûr ?',
            profileCondenseLabel: 'Condenser après faits',
            convSettings: 'Paramètres de conversation',
            multimediaSection: 'Multimédia', videoDetailLabel: 'Profondeur d\'analyse vidéo',
            videoDetailLow: 'Faible (4 images)', videoDetailMedium: 'Moyen (8 images)', videoDetailHigh: 'Élevé (12 images)',
        }
    },
    t: function(key) { return (this._strings[this._lang] || this._strings.en)[key] || this._strings.en[key] || key; },
    setLang: function(lang) { this._lang = lang; localStorage.setItem('lang', lang); },
    get lang() { return this._lang; },
    flags: { en: 'EN', vi: 'VI', de: 'DE', es: 'ES', fr: 'FR' },
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
    return (model || '').endsWith('-cloud') ||
           RECOMMENDED_CLOUD_MODEL_NAMES.indexOf(model) !== -1 ||
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
        { name: 'qwen3.5:cloud',              label: t('recDeepThinker') },
    ];
}
// Constant names for filtering (language-independent)
const RECOMMENDED_CLOUD_MODEL_NAMES = ['ministral-3:14b-cloud', 'qwen3.5:cloud', 'gemma4:31b-cloud'];

var _MODEL_ACRONYMS = { vl: 'VL', rnj: 'RNJ', gpt: 'GPT', oss: 'OSS', glm: 'GLM' };
function normalizeModelLabel(model) {
    var s = model.replace(/-cloud$/, '');
    var ci = s.indexOf(':');
    var base = ci >= 0 ? s.slice(0, ci) : s;
    var tag  = ci >= 0 ? s.slice(ci + 1) : '';
    // strip namespace prefix (e.g. "ns/model")
    var si = base.indexOf('/');
    if (si >= 0) base = base.slice(si + 1);
    // split base on '-', then insert space at letter→digit boundary
    var words = [];
    base.split('-').forEach(function(seg) {
        seg.replace(/([a-zA-Z])([0-9])/g, '$1 $2').split(' ').forEach(function(t) {
            if (t) words.push(t);
        });
    });
    var baseStr = words.map(function(t) {
        var lo = t.toLowerCase();
        return _MODEL_ACRONYMS[lo] || (t.charAt(0).toUpperCase() + t.slice(1));
    }).join(' ');
    // tag: skip if it is just 'cloud'; replace '-' with space
    var tagStr = (tag && tag !== 'cloud') ? '(' + tag.replace(/-/g, ' ') + ')' : '';
    return tagStr ? baseStr + ' ' + tagStr : baseStr;
}
function getModelDisplayName(model) {
    if (Settings.modelLabels && Settings.modelLabels[model]) return Settings.modelLabels[model];
    var rec = getRecommendedCloudModels().find(function(r) { return r.name === model; });
    if (rec) return rec.label;
    return normalizeModelLabel(model);
}
