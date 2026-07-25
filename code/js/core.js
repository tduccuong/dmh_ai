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

// Walk text nodes under `el` and wrap `&<slug>` / `@<handle>` tokens
// in styled spans so the user (and the model, indirectly via the
// readback) can see at a glance which substrings the runtime is
// treating as workflow / mention references. Idempotent — already-
// wrapped tokens live inside a non-text element and the walker
// skips them. Safe against KaTeX / code-block content because the
// walker excludes nodes inside `code`, `pre`, and the KaTeX root.
function decorateTokens(el) {
    if (!el) return;
    var SKIP_TAGS = { CODE: 1, PRE: 1, A: 1, KBD: 1 };
    var SKIP_CLASSES = { 'token-workflow': 1, 'token-mention': 1, 'katex': 1, 'katex-display': 1 };
    var TOKEN_RE = /([@&])([a-z0-9_]+)\b/g;

    function shouldSkip(node) {
        var n = node.parentNode;
        while (n && n !== el) {
            if (n.nodeType === 1) {
                if (SKIP_TAGS[n.tagName]) return true;
                if (n.classList) {
                    for (var c in SKIP_CLASSES) {
                        if (n.classList.contains(c)) return true;
                    }
                }
            }
            n = n.parentNode;
        }
        return false;
    }

    // Collect text nodes first; mutating the tree mid-walk confuses NodeIterator.
    var iter = document.createNodeIterator(el, NodeFilter.SHOW_TEXT);
    var nodes = [];
    var t;
    while ((t = iter.nextNode())) {
        if (!shouldSkip(t) && /[@&][a-z0-9_]+/.test(t.nodeValue)) nodes.push(t);
    }

    nodes.forEach(function(node) {
        var s = node.nodeValue;
        TOKEN_RE.lastIndex = 0;
        var frag = document.createDocumentFragment();
        var cursor = 0;
        var m;
        while ((m = TOKEN_RE.exec(s))) {
            if (m.index > cursor) frag.appendChild(document.createTextNode(s.slice(cursor, m.index)));
            var span = document.createElement('span');
            span.className = (m[1] === '&') ? 'token-workflow' : 'token-mention';
            span.textContent = m[0];
            frag.appendChild(span);
            cursor = m.index + m[0].length;
        }
        if (cursor < s.length) frag.appendChild(document.createTextNode(s.slice(cursor)));
        node.parentNode.replaceChild(frag, node);
    });
}

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
            duolangReadyPlaceholder: 'Type "I\'m ready", or ask a question…',
            duolangContinuePlaceholder: 'Type "yes" to continue, or ask a question…',
            duolangSpeakPlaceholder: 'Use the buttons above to speak — or ask me a question…',
            duolangTab_review: 'Review', duolangTab_understand: 'Understand', duolangTab_speak: 'Pronounce', duolangTab_talk: 'Roleplay', duolangTab_recap: 'Recap',
            duolangLangPair: '{src} → {tgt}',
            duolangStepOf: 'Step {i} of {n}',
            duolangTodayLesson: 'The lesson: {title}',
            duolangYou: 'You',
            duolangAssistantName: 'Duolang Assistant',
            duolangUnitOf: '{unit} {i} of {n}',
            duolangUnitWord: 'Word',
            duolangUnitQuestion: 'Question',
            duolangUnitLine: 'Line',
            duolangActReading: 'Read this',
            duolangActTalking: 'Conversation',
            duolangActRecap: 'One thing to remember',
            duolangDesigning: 'Designing your course',
            duolangDesigningMsg: 'Building a course just for you…',
            duolangDesigningSub: 'I\'m planning your levels and choosing what to teach first. This takes a moment.',
            duolangNewCourse: 'New course',
            duolangReady: 'ready',
            duolangAssistant: 'DMH-Duolang Assistant',
            duolangAssistantSub: 'Tell me what you\'d like to learn and I\'ll design a course for you.',
            duolangTopic: 'What do you want to learn about?',
            duolangTopicPlaceholder: 'Freely describe what you want to learn — any topic, e.g. travel, food, work, small talk.',
            duolangMotivation: 'Why do you want this?',
            duolangMotivationPlaceholder: 'Freely tell me why you want this — e.g. moving abroad, a trip, family, work, or for fun.',
            duolangStyle: 'How do you like to learn?',
            duolangStylePlaceholder: 'Freely describe how you like to learn — e.g. short sessions, lots of examples, by doing.',
            duolangFocus: 'What should we focus on?',
            duolangFocusPlaceholder: 'Freely tell me what to focus on — e.g. speaking, listening, pronunciation, vocabulary.',
            duolangIntensity: 'How intensively?',
            duolangIntensityCasual: 'Casual — a little at a time',
            duolangIntensitySteady: 'Steady — a lesson most days',
            duolangIntensityIntensive: 'Intensive — push me',
            duolangDesignCourse: 'Design my course',
            duolangDesignFailed: 'I couldn\'t design the course. Please try again.',
            duolangCancel: 'Cancel',
            duolangNoCourses: 'No courses yet.',
            duolangDeleteCourse: 'Delete this course? Your vocabulary is kept.',
            duolangTalk_idle: 'Tutor',
            duolangTalk_recall: 'Answer below',
            duolangTalk_read: 'Read it through',
            duolangTalk_check: 'Questions about this',
            duolangTalk_speak: 'Say it aloud',
            duolangTalk_use: 'Conversation',
            duolangTalk_takeaway: 'Wrapping up',
            duolangOf: '{i} of {n}',
            duolangThePassage: 'The passage',
            duolangUseThese: 'Try to use these',
            duolangStep_recall: 'Review',
            duolangStep_read: 'Read',
            duolangStep_check: 'Understand',
            duolangStep_speak: 'Speak',
            duolangStep_use: 'Talk',
            duolangStep_takeaway: 'Recap',
            duolangDoRecall: 'Type each word in the language you are learning.',
            duolangDoRecallBack: 'Just read these over — nothing is marked.',
            duolangDoRead: 'Read it through. Tap a line to hear it.',
            duolangDoReadNew: 'New words, used more than once so they stick. Tap a line to hear it.',
            duolangDoCheck: 'Answer below, in {lang}.',
            duolangDoSpeak: 'Tap to hear a line, then the mic and read it back.',
            duolangDoUse: 'Reply below, in {lang}.',
            duolangDoTakeaway: 'One thing from this lesson.',
            duolangContinue: 'Continue', duolangNextSentence: 'Next sentence', duolangSpeakDone: 'Complete', duolangSentenceOf: 'Sentence {i} of {n}', duolangSkip: 'Skip',
            duolangCheckAnswers: 'Check answers',
            duolangGotIt: 'Got it',
            duolangNextLesson: 'Next lesson',
            duolangChoose: 'Choose a language…',
            duolangAnswerIn: 'Answer in {lang}…',
            duolangUseButtons: 'Use the buttons above to continue',
            duolangSameLanguage: 'Pick a language different from your own.',
            duolangYouCovered: 'You covered', duolangYouMissed: 'You didn\'t mention',
            duolangPressStart: 'Press Start above to begin a lesson.',
            splashDuolang: {
                title: 'Learn with Duolang.',
                lead: 'A private tutor for one language, one short session at a time.',
                bullets: [
                    { strong: 'Read', text: 'A short passage written for what you already know, with a translation beside it.' },
                    { strong: 'Understand', text: 'A few questions in your own language — before any speaking.' },
                    { strong: 'Say it', text: 'The same lines again, spoken. Tap to hear them, tap to read them back.' },
                    { strong: 'Talk', text: 'A short exchange, then one thing to remember.' }
                ],
                outro: 'Press Start above to begin.'
            },
            duolangMode: 'Learn with Duolang', duolangChatMode: 'Chat with Confidant',
            duolangWelcome: 'What would you like to learn?',
            duolangIWantToLearn: 'I want to learn', duolangMyLanguage: 'My language',
            duolangMyGoal: 'What do you want to be able to do?',
            duolangGoalPlaceholder: 'e.g. talk to my partner\u2019s family',
            duolangInterests: 'Things you care about', duolangInterestsPlaceholder: 'cooking, football, travel',
            duolangStartLearning: 'Start learning', duolangStart: 'Start',
            duolangItemsReady: 'about {n} items ready', duolangSomethingNew: 'something new',
            duolangWelcomeBack: 'Welcome back \u2014 we\u2019ll ease in.',
            duolangCoverage: 'You understand roughly {p}% of everyday {lang}',
            duolangWordsPhrases: 'Words & phrases', duolangNoItems: 'Nothing saved yet.',
            duolangDueNow: 'due now', duolangDueIn: 'in {d} days',
            duolangLesson: 'Lesson', duolangStartFailed: 'Could not start the lesson.',
            duolangLoadFailed: 'Could not load.',
            duolangBeatRecall: 'First, a quick review', duolangBeatRecallBack: 'Let\u2019s ease back in',
            duolangBeatRead: 'Read this', duolangBeatReadNew: 'New words, in context',
            duolangBeatCheck: 'What was it about?', duolangBeatSpeak: 'Now say it',
            duolangBeatUse: 'Let\u2019s talk', duolangBeatTakeaway: 'One thing to remember',
            duolangAnswerOnePerLine: 'One answer per line.',
            duolangAnswerYourLanguage: 'Answer in your own language.',
            duolangContinueWhenReady: 'Send anything when you\u2019re ready to go on.',
            duolangSpeakHint: 'Tap \ud83d\udd0a to hear it, then \ud83c\udfa4 to say it \u2014 unlocks Next sentence.',
            duolangUnderstood: 'You got it', duolangPartly: 'Partly there',
            duolangNothingToFix: 'Nothing to correct this time.',
            duolangItemsAdded: '{n} added to your words.',
            duolangLevelUnverified: 'Level not verified for this passage.',
            duolangMic_listening: 'Listening\u2026', duolangMic_ok: 'Heard it',
            duolangMic_retry: 'Try that line again', duolangMic_blocked: 'Microphone blocked',
            duolangMic_unsupported: 'Speech input not available here',
            duolangMic_unavailable: 'This language may need a voice pack installed',
            retry: 'Retry', clear: 'Clear', send: 'Send', cancel: 'Cancel', ok: 'OK', stopGen: 'Stop',
            browserConsentTitle: 'Browser tools — please read',
            browserConsentAccept: 'I understand and accept',
            browserConsentEnabled: 'Browser tools enabled.',
            browserConsentError: 'Could not record acceptance. Please try again from Settings.',
            update: 'Update', rename: 'Rename', delete_: 'Delete', download: '⬇ Download',
            newSession: '+ New Session', newChat: 'New chat',
            typePlaceholder: 'Type a message — Enter to send, Shift-Enter for a new line...', typePlaceholderShort: 'Type a message...', attachFile: 'Attach file',
            ollamaEndpoint: 'Ollama Endpoint',
            cannotConnect: 'Cannot connect to Ollama',
            cannotConnectFull: 'Cannot connect to Ollama. Please correct Ollama URL endpoint.',
            cannotConnectTo: 'Cannot connect to ',
            renameSession: 'Rename session', newSessionName: 'New session name',
            deleteSession: 'Delete session',
            deleteConfirm1: 'Delete "', deleteConfirm2: '"? This cannot be undone.',
            clearSession: 'Clear session',
            clearConfirm1: 'Clear all history in "', clearConfirm2: '"? Any in-flight reply will be interrupted. This cannot be undone.',
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
            voicePermissionDenied: 'Microphone access was denied. Re-enable it in your browser\'s site settings for this page.',
            voiceServiceUnreachable: 'The speech recognition service is unreachable. Check your network connection or disable any extension blocking Google services.',
            voiceAudioCaptureFailed: 'Could not capture audio. Another app may be using the microphone, or no input device is available.',
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
            recQuickAnswer: '⚡ Quick-Wit', recDeepThinker: '💭 Deep-Thinker', recTechExpert: '🛠 Technical Expert', recWordsmith: '💎 Fine-Grain',
            aboutBtn: 'About', aboutDesc: 'A self-hosted, multi-user AI chat platform supporting local and cloud LLMs, real-time web search with answer synthesis, voice input, and rich document and image attachments — designed for private deployment.', aboutLegalTitle: 'Legal & License', aboutLicenseLabel: 'License:', aboutLicenseBody: 'Licensed under the GNU Affero General Public License v3 (AGPL-3.0).', aboutAttrib: 'Pursuant to the Additional Terms (Section 7b), any redistribution or derivative of this software must maintain this attribution and link to the original source.', aboutSourceLabel: 'Source Code:', aboutCommercialLabel: 'Commercial Licensing:', aboutCommercialBody: 'For inquiries regarding commercial use or proprietary licensing, please contact Cuong Truong at tduccuong@gmail.com.', aboutClose: 'Close',
            noModelAvail: 'No model available. Please configure a model in Settings first.',
            convSettings: 'Conversation Settings',
            aiModelSettings: 'AI Model Settings',
            settingsTabPools: 'Pools', settingsTabModels: 'Models', settingsTabConversation: 'Conversation', settingsTabReadAloud: 'Read aloud',
            multimediaSection: 'Multimedia', videoDetailLabel: 'Video analysis depth',
            videoDetailLow: 'Low (4 frames)', videoDetailMedium: 'Medium (8 frames)', videoDetailHigh: 'High (12 frames)',
            processingVideo: 'Processing video, may take a while…', analyzingVideo: 'Analyzing video, may take a while…',
            processingImage: 'Processing image, may take a while…', analyzingImage: 'Analyzing photo, may take a while…',
            thinkingOutLoud: 'Thinking…',
            ttsNoInput: 'Attach an image or type some text after /tts, then resend.',
            ttsNoText: 'No text could be extracted (one or more images errored).',
            ttsNothing: 'Nothing to read.',
            duolangPickerTitle: 'Pick a language',
            duolangFilterPlaceholder: 'Filter languages…',
            duolangNoMatch: 'No languages match.',
            duolangPickLanguage: 'Pick a language, e.g. /duolang <language> <text>.',
            duolangNoInput: 'Type some text after the language, attach an image, or send /duolang <language> alone after I\'ve replied.',
            sessionModalTitle: 'Chat sessions',
            sessionFilterPlaceholder: 'Filter sessions…',
            sessionNoMatch: 'No sessions match.',
            modeConfidant: 'Confidant',
            modeAssistant: 'Assistant',
            hintConfidant: 'Note: For <strong>heavy tasks</strong>, talk to Assistant. Confidant is meant only for <strong>quick answers</strong>.',
            hintAssistant: 'Note: For <strong>quick answers</strong>, talk to Confidant. Assistant is meant only for <strong>heavy tasks</strong>.',
            splashConfidant: {
                title: "Hi, I'm DMH-AI.",
                lead: 'Your confidant for quick, insightful chats and instant answers.',
                bullets: [
                    { strong: 'Multimedia', text: 'Upload photos, videos, or documents to ask questions about them.' },
                    { strong: '/memo &lt;text&gt;', text: 'Save a private note — recalled automatically when it is relevant.' },
                    { strong: '/tts &lt;text&gt;', text: 'Read text out loud in the text\'s language — or a previous answer of mine if no text is given.' },
                    { strong: '/duolang &lt;lang&gt; &lt;text&gt;', text: 'Read text out loud in two languages: the text\'s own and <lang>.' },
                ],
                outro: 'or ask me anything!',
                switchPrompt: 'Need help with a complex project? Try the',
                switchPromptShort: 'A complex project? Try the',
            },
            splashAssistant: {
                title: "Hi, I'm DMH-AI Assistant.",
                lead: 'Built for deep research, complex workflows, and heavy lifting.',
                bullets: [
                    { strong: 'Type: /memo &lt;text&gt;', text: 'Save a private note — recalled automatically when it is relevant.' },
                    { strong: 'Type: /index &lt;source&gt;', text: 'Index a URL, file path, or text into your knowledge base.' },
                    { strong: 'Workflows', text: 'Upload documents along with complex, multi-step instructions.' },
                ],
                switchPrompt: 'Just want a quick conversation? Switch to the',
                switchPromptShort: 'A quick chat? Switch to the',
            },
        },
        vi: {
            duolangTalk_idle: 'Gia sư',
            duolangTalk_recall: 'Trả lời bên dưới',
            duolangTalk_read: 'Đọc hết một lượt',
            duolangTalk_check: 'Câu hỏi về đoạn này',
            duolangTalk_speak: 'Đọc to',
            duolangTalk_use: 'Trò chuyện',
            duolangTalk_takeaway: 'Kết thúc',
            duolangOf: '{i} / {n}',
            duolangThePassage: 'Đoạn văn',
            duolangUseThese: 'Thử dùng những từ này',
            duolangTab_review: 'Ôn', duolangTab_understand: 'Hiểu', duolangTab_speak: 'Phát âm', duolangTab_talk: 'Đóng vai', duolangTab_recap: 'Nhớ',
            duolangStep_recall: 'Ôn',
            duolangStep_read: 'Đọc',
            duolangStep_check: 'Hiểu',
            duolangStep_speak: 'Nói',
            duolangStep_use: 'Chat',
            duolangStep_takeaway: 'Nhớ',
            duolangDoRecall: 'Nhập mỗi từ bằng ngôn ngữ bạn đang học.',
            duolangDoRecallBack: 'Chỉ cần đọc lại — không chấm điểm.',
            duolangDoRead: 'Đọc hết một lượt. Nhấn vào dòng để nghe.',
            duolangDoReadNew: 'Từ mới, lặp lại nhiều lần để nhớ. Nhấn vào dòng để nghe.',
            duolangDoCheck: 'Trả lời bên dưới, bằng {lang}.',
            duolangDoSpeak: 'Nhấn để nghe, rồi nhấn micro và đọc lại.',
            duolangDoUse: 'Trả lời bên dưới, bằng {lang}.',
            duolangDoTakeaway: 'Một điều rút ra từ bài học này.',
            duolangContinue: 'Tiếp tục', duolangNextSentence: 'Câu tiếp theo', duolangSpeakDone: 'Hoàn thành', duolangSentenceOf: 'Câu {i} / {n}', duolangSkip: 'Bỏ qua',
            duolangCheckAnswers: 'Kiểm tra',
            duolangGotIt: 'Đã hiểu',
            duolangNextLesson: 'Bài tiếp theo',
            duolangChoose: 'Chọn ngôn ngữ…',
            duolangAnswerIn: 'Trả lời bằng {lang}…',
            duolangUseButtons: 'Dùng nút ở trên để tiếp tục',
            duolangSameLanguage: 'Hãy chọn ngôn ngữ khác với tiếng của bạn.',
            duolangYouCovered: 'Bạn đã nói được', duolangYouMissed: 'Bạn chưa nhắc tới',
            duolangPressStart: 'Nhấn Bắt đầu ở trên để vào bài học.',
            splashDuolang: {
                title: 'Học với Duolang.',
                lead: 'Gia sư riêng cho một ngôn ngữ, mỗi lần một bài ngắn.',
                bullets: [
                    { strong: 'Đọc', text: 'Đoạn văn viết theo những gì bạn đã biết, kèm bản dịch.' },
                    { strong: 'Hiểu', text: 'Vài câu hỏi bằng tiếng của bạn — trước khi nói.' },
                    { strong: 'Nói', text: 'Vẫn những dòng đó, nhưng đọc to. Nhấn để nghe, nhấn để đọc lại.' },
                    { strong: 'Trò chuyện', text: 'Một đoạn hội thoại ngắn, rồi một điều cần nhớ.' }
                ],
                outro: 'Nhấn Bắt đầu ở trên để vào bài.'
            },
            duolangMode: 'H\u1ecdc v\u1edbi Duolang', duolangChatMode: 'Tr\u00f2 chuy\u1ec7n',
            duolangWelcome: 'B\u1ea1n mu\u1ed1n h\u1ecdc g\u00ec?',
            duolangIWantToLearn: 'T\u00f4i mu\u1ed1n h\u1ecdc', duolangMyLanguage: 'Ng\u00f4n ng\u1eef c\u1ee7a t\u00f4i',
            duolangMyGoal: 'B\u1ea1n mu\u1ed1n l\u00e0m \u0111\u01b0\u1ee3c g\u00ec?',
            duolangGoalPlaceholder: 'v\u00ed d\u1ee5: n\u00f3i chuy\u1ec7n v\u1edbi gia \u0111\u00ecnh',
            duolangInterests: '\u0110i\u1ec1u b\u1ea1n quan t\u00e2m', duolangInterestsPlaceholder: 'n\u1ea5u \u0103n, b\u00f3ng \u0111\u00e1, du l\u1ecbch',
            duolangStartLearning: 'B\u1eaft \u0111\u1ea7u h\u1ecdc', duolangStart: 'B\u1eaft \u0111\u1ea7u',
            duolangItemsReady: 'kho\u1ea3ng {n} m\u1ee5c', duolangSomethingNew: '\u0111i\u1ec1u m\u1edbi',
            duolangWelcomeBack: 'Ch\u00e0o m\u1eebng tr\u1edf l\u1ea1i \u2014 ta s\u1ebd \u0111i t\u1eeb t\u1eeb.',
            duolangCoverage: 'B\u1ea1n hi\u1ec3u kho\u1ea3ng {p}% {lang} h\u1eb1ng ng\u00e0y',
            duolangWordsPhrases: 'T\u1eeb & c\u1ee5m t\u1eeb', duolangNoItems: 'Ch\u01b0a c\u00f3 g\u00ec.',
            duolangDueNow: 'c\u1ea7n \u00f4n', duolangDueIn: 'sau {d} ng\u00e0y',
            duolangLesson: 'B\u00e0i h\u1ecdc', duolangStartFailed: 'Kh\u00f4ng th\u1ec3 b\u1eaft \u0111\u1ea7u.',
            duolangLoadFailed: 'Kh\u00f4ng t\u1ea3i \u0111\u01b0\u1ee3c.',
            duolangBeatRecall: '\u00d4n l\u1ea1i m\u1ed9t ch\u00fat', duolangBeatRecallBack: 'B\u1eaft \u0111\u1ea7u nh\u1eb9 nh\u00e0ng',
            duolangBeatRead: '\u0110\u1ecdc \u0111o\u1ea1n n\u00e0y', duolangBeatReadNew: 'T\u1eeb m\u1edbi trong ng\u1eef c\u1ea3nh',
            duolangBeatCheck: 'N\u1ed9i dung n\u00f3i v\u1ec1 g\u00ec?', duolangBeatSpeak: 'Gi\u1edd h\u00e3y \u0111\u1ecdc to',
            duolangBeatUse: 'C\u00f9ng tr\u00f2 chuy\u1ec7n', duolangBeatTakeaway: 'M\u1ed9t \u0111i\u1ec1u c\u1ea7n nh\u1edb',
            duolangAnswerOnePerLine: 'M\u1ed7i d\u00f2ng m\u1ed9t c\u00e2u tr\u1ea3 l\u1eddi.',
            duolangAnswerYourLanguage: 'Tr\u1ea3 l\u1eddi b\u1eb1ng ti\u1ebfng c\u1ee7a b\u1ea1n.',
            duolangContinueWhenReady: 'G\u1eedi b\u1ea5t k\u1ef3 g\u00ec \u0111\u1ec3 ti\u1ebfp t\u1ee5c.',
            duolangSpeakHint: 'Nh\u1ea5n \ud83d\udd0a \u0111\u1ec3 nghe, \ud83c\udfa4 \u0111\u1ec3 \u0111\u1ecdc l\u1ea1i.',
            duolangUnderstood: 'B\u1ea1n hi\u1ec3u r\u1ed3i', duolangPartly: 'G\u1ea7n \u0111\u00fang',
            duolangNothingToFix: 'L\u1ea7n n\u00e0y kh\u00f4ng c\u00f3 g\u00ec c\u1ea7n s\u1eeda.',
            duolangItemsAdded: '\u0110\u00e3 th\u00eam {n} t\u1eeb.',
            duolangLevelUnverified: 'Ch\u01b0a x\u00e1c minh \u0111\u1ed9 kh\u00f3.',
            duolangMic_listening: '\u0110ang nghe\u2026', duolangMic_ok: '\u0110\u00e3 nghe r\u00f5',
            duolangMic_retry: 'Th\u1eed l\u1ea1i d\u00f2ng n\u00e0y', duolangMic_blocked: 'Micro b\u1ecb ch\u1eb7n',
            duolangMic_unsupported: 'Kh\u00f4ng h\u1ed7 tr\u1ee3 nh\u1eadp gi\u1ecdng n\u00f3i',
            duolangMic_unavailable: 'C\u00f3 th\u1ec3 c\u1ea7n c\u00e0i g\u00f3i gi\u1ecdng n\u00f3i',
            retry: 'Thử lại', clear: 'Xóa', send: 'Gửi', cancel: 'Hủy', ok: 'OK', stopGen: 'Dừng',
            browserConsentTitle: 'Công cụ trình duyệt — vui lòng đọc',
            browserConsentAccept: 'Tôi đã đọc và đồng ý',
            browserConsentEnabled: 'Đã bật công cụ trình duyệt.',
            browserConsentError: 'Không thể ghi nhận chấp thuận. Vui lòng thử lại từ Cài đặt.',
            update: 'Cập nhật', rename: 'Đổi tên', delete_: 'Xóa', download: '⬇ Tải về',
            newSession: '+ Phiên mới', newChat: 'Cuộc trò chuyện mới',
            typePlaceholder: 'Nhập tin nhắn — Enter để gửi, Shift-Enter để xuống dòng...', typePlaceholderShort: 'Nhập tin nhắn...', attachFile: 'Đính kèm tệp',
            ollamaEndpoint: 'Điểm cuối Ollama',
            cannotConnect: 'Không thể kết nối Ollama',
            cannotConnectFull: 'Không thể kết nối Ollama. Vui lòng kiểm tra lại URL endpoint của Ollama.',
            cannotConnectTo: 'Không thể kết nối ',
            renameSession: 'Đổi tên phiên', newSessionName: 'Tên phiên mới',
            deleteSession: 'Xóa phiên',
            deleteConfirm1: 'Xóa "', deleteConfirm2: '"? Không thể hoàn tác.',
            clearSession: 'Xóa phiên',
            clearConfirm1: 'Xóa toàn bộ lịch sử trong "', clearConfirm2: '"? Mọi phản hồi đang diễn ra sẽ bị ngắt. Không thể hoàn tác.',
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
            voicePermissionDenied: 'Quyền truy cập micro đã bị từ chối. Bật lại trong cài đặt trang của trình duyệt cho trang này.',
            voiceServiceUnreachable: 'Không kết nối được dịch vụ nhận dạng giọng nói. Kiểm tra mạng hoặc tắt các tiện ích chặn dịch vụ Google.',
            voiceAudioCaptureFailed: 'Không thể thu âm. Ứng dụng khác có thể đang dùng micro, hoặc không có thiết bị thu.',
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
            recQuickAnswer: '⚡ Trả-Lời-Nhanh', recDeepThinker: '💭 Suy-Tư-Sâu', recTechExpert: '🛠 Kỹ Thuật Gia', recWordsmith: '💎 Suy-Xét-Kỹ',
            aboutBtn: 'Giới thiệu', aboutDesc: 'Nền tảng chat AI đa người dùng tự lưu trữ, hỗ trợ mô hình cục bộ và đám mây, tìm kiếm web thời gian thực với tổng hợp câu trả lời, nhập liệu bằng giọng nói và đính kèm tài liệu, hình ảnh phong phú — được thiết kế cho triển khai riêng tư.', aboutLegalTitle: 'Pháp lý & Giấy phép', aboutLicenseLabel: 'Giấy phép:', aboutLicenseBody: 'Được cấp phép theo Giấy phép Công cộng GNU Affero phiên bản 3 (AGPL-3.0).', aboutAttrib: 'Theo Điều khoản Bổ sung (Mục 7b), mọi sự phân phối lại hoặc phái sinh của phần mềm này phải duy trì thông tin ghi công này và liên kết đến nguồn gốc.', aboutSourceLabel: 'Mã nguồn:', aboutCommercialLabel: 'Cấp phép thương mại:', aboutCommercialBody: 'Để được tư vấn về sử dụng thương mại hoặc cấp phép độc quyền, vui lòng liên hệ Cuong Truong tại tduccuong@gmail.com.', aboutClose: 'Đóng',
            noModelAvail: 'Không có mô hình nào. Vui lòng cấu hình trong Cài đặt trước.',
            convSettings: 'Cài đặt hội thoại',
            aiModelSettings: 'Cài đặt mô hình AI',
            settingsTabPools: 'Pools', settingsTabModels: 'Mô hình', settingsTabConversation: 'Hội thoại', settingsTabReadAloud: 'Đọc to',
            multimediaSection: 'Đa phương tiện', videoDetailLabel: 'Độ chi tiết phân tích video',
            videoDetailLow: 'Thấp (4 khung)', videoDetailMedium: 'Trung bình (8 khung)', videoDetailHigh: 'Cao (12 khung)',
            processingVideo: 'Đang xử lý video, có thể mất một lúc…', analyzingVideo: 'Đang phân tích video, có thể mất một lúc…',
            processingImage: 'Đang xử lý ảnh, có thể mất một lúc…', analyzingImage: 'Đang phân tích ảnh, có thể mất một lúc…',
            thinkingOutLoud: 'Suy nghĩ…',
            ttsNoInput: 'Đính kèm ảnh hoặc nhập văn bản sau /tts, rồi gửi lại.',
            ttsNoText: 'Không trích xuất được văn bản (một hoặc nhiều ảnh bị lỗi).',
            ttsNothing: 'Không có gì để đọc.',
            duolangPickerTitle: 'Chọn ngôn ngữ',
            duolangFilterPlaceholder: 'Lọc ngôn ngữ…',
            duolangNoMatch: 'Không có ngôn ngữ phù hợp.',
            duolangPickLanguage: 'Hãy chọn ngôn ngữ, ví dụ: /duolang <ngôn ngữ> <văn bản>.',
            duolangNoInput: 'Nhập văn bản sau tên ngôn ngữ, đính kèm ảnh, hoặc gửi /duolang <ngôn ngữ> sau khi tôi đã trả lời.',
            sessionModalTitle: 'Phiên trò chuyện',
            sessionFilterPlaceholder: 'Lọc phiên…',
            sessionNoMatch: 'Không có phiên phù hợp.',
            modeConfidant: 'Bạn thân',
            modeAssistant: 'Trợ lý',
            hintConfidant: 'Lưu ý: Với <strong>tác vụ phức tạp</strong>, hãy chuyển sang Trợ lý. Bạn thân chỉ dành cho <strong>câu trả lời nhanh</strong>.',
            hintAssistant: 'Lưu ý: Với <strong>câu trả lời nhanh</strong>, hãy chuyển sang Bạn thân. Trợ lý chỉ dành cho <strong>tác vụ phức tạp</strong>.',
            splashConfidant: {
                title: 'Chào bạn, tôi là DMH-AI.',
                lead: 'Người bạn tâm giao cho những cuộc trò chuyện sâu sắc và phản hồi nhanh.',
                bullets: [
                    { strong: 'Đa phương tiện', text: 'Tải lên ảnh, video hoặc tài liệu để đặt câu hỏi trực tiếp.' },
                    { strong: '/memo &lt;nội dung&gt;', text: 'Lưu ghi chú riêng tư — tự động gợi lại khi liên quan.' },
                    { strong: '/tts &lt;nội dung&gt;', text: 'Đọc to văn bản bằng ngôn ngữ của chính nó — hoặc câu trả lời trước của tôi nếu không nhập nội dung.' },
                    { strong: '/duolang &lt;ngôn ngữ&gt; &lt;nội dung&gt;', text: 'Đọc to bằng hai ngôn ngữ: ngôn ngữ của nội dung và <ngôn ngữ>.' },
                ],
                outro: 'hoặc hỏi tôi bất cứ điều gì!',
                switchPrompt: 'Cần xử lý dự án phức tạp? Hãy thử',
                switchPromptShort: 'Dự án/quy trình phức tạp? Gọi',
            },
            splashAssistant: {
                title: 'Chào bạn, tôi là DMH-AI Trợ lý.',
                lead: 'Chuyên gia xử lý quy trình phức tạp và tác vụ nặng.',
                bullets: [
                    { strong: 'Gõ: /memo &lt;nội dung&gt;', text: 'Lưu & mã hóa ghi chú riêng tư. Truy vấn trong tương lai theo từ khóa.' },
                    { strong: 'Gõ: /index &lt;nguồn&gt;', text: 'Lưu danh mục URL, tệp tài liệu hoặc văn bản vào cơ sở tri thức.' },
                    { strong: 'Quy trình', text: 'Tải tài liệu kèm hướng dẫn xử lý nhiều bước phức tạp.' },
                ],
                switchPrompt: 'Chỉ muốn trò chuyện nhanh? Hãy chuyển sang',
                switchPromptShort: 'Trò chuyện nhanh? Gọi',
            },
        },
        de: {
            duolangTalk_idle: 'Tutor',
            duolangTalk_recall: 'Antworte unten',
            duolangTalk_read: 'Lies den Text',
            duolangTalk_check: 'Fragen dazu',
            duolangTalk_speak: 'Sprich es laut',
            duolangTalk_use: 'Gespräch',
            duolangTalk_takeaway: 'Zum Schluss',
            duolangOf: '{i} von {n}',
            duolangThePassage: 'Der Text',
            duolangUseThese: 'Versuche diese zu benutzen',
            duolangTab_review: 'Üben', duolangTab_understand: 'Verstehen', duolangTab_speak: 'Aussprache', duolangTab_talk: 'Rollenspiel', duolangTab_recap: 'Merken',
            duolangStep_recall: 'Üben',
            duolangStep_read: 'Lesen',
            duolangStep_check: 'Prüfen',
            duolangStep_speak: 'Sprechen',
            duolangStep_use: 'Reden',
            duolangStep_takeaway: 'Merken',
            duolangDoRecall: 'Schreibe jedes Wort in der Sprache, die du lernst.',
            duolangDoRecallBack: 'Lies sie einfach durch — nichts wird bewertet.',
            duolangDoRead: 'Lies den Text. Tippe eine Zeile an, um sie zu hören.',
            duolangDoReadNew: 'Neue Wörter, mehrfach verwendet. Tippe eine Zeile an, um sie zu hören.',
            duolangDoCheck: 'Antworte unten, auf {lang}.',
            duolangDoSpeak: 'Antippen zum Hören, dann Mikro und nachsprechen.',
            duolangDoUse: 'Antworte unten, auf {lang}.',
            duolangDoTakeaway: 'Eine Sache aus dieser Lektion.',
            duolangContinue: 'Weiter', duolangNextSentence: 'Nächster Satz', duolangSpeakDone: 'Fertig', duolangSentenceOf: 'Satz {i} von {n}', duolangSkip: 'Überspringen',
            duolangCheckAnswers: 'Antworten prüfen',
            duolangGotIt: 'Verstanden',
            duolangNextLesson: 'Nächste Lektion',
            duolangChoose: 'Sprache wählen…',
            duolangAnswerIn: 'Antworte auf {lang}…',
            duolangUseButtons: 'Nutze die Schaltflächen oben',
            duolangSameLanguage: 'Wähle eine andere Sprache als deine eigene.',
            duolangYouCovered: 'Erwähnt', duolangYouMissed: 'Nicht erwähnt',
            duolangPressStart: 'Klicke oben auf Starten, um eine Lektion zu beginnen.',
            splashDuolang: {
                title: 'Mit Duolang lernen.',
                lead: 'Ein privater Tutor für eine Sprache, jeweils eine kurze Lektion.',
                bullets: [
                    { strong: 'Lesen', text: 'Ein kurzer Text, geschrieben für das, was du schon kannst — mit Übersetzung daneben.' },
                    { strong: 'Verstehen', text: 'Ein paar Fragen in deiner eigenen Sprache — vor dem Sprechen.' },
                    { strong: 'Sprechen', text: 'Dieselben Zeilen, laut. Antippen zum Hören, antippen zum Nachsprechen.' },
                    { strong: 'Reden', text: 'Ein kurzer Austausch, dann eine Sache zum Merken.' }
                ],
                outro: 'Klicke oben auf Starten.'
            },
            duolangMode: 'Mit Duolang lernen', duolangChatMode: 'Mit Confidant chatten',
            duolangWelcome: 'Was möchtest du lernen?',
            duolangIWantToLearn: 'Ich möchte lernen', duolangMyLanguage: 'Meine Sprache',
            duolangMyGoal: 'Was möchtest du können?',
            duolangGoalPlaceholder: 'z. B. mit der Familie meines Partners sprechen',
            duolangInterests: 'Was dich interessiert', duolangInterestsPlaceholder: 'Kochen, Fußball, Reisen',
            duolangStartLearning: 'Lernen beginnen', duolangStart: 'Starten',
            duolangItemsReady: 'etwa {n} Einträge bereit', duolangSomethingNew: 'etwas Neues',
            duolangWelcomeBack: 'Willkommen zurück — wir fangen ruhig an.',
            duolangCoverage: 'Du verstehst etwa {p}% des alltäglichen {lang}',
            duolangWordsPhrases: 'Wörter & Wendungen', duolangNoItems: 'Noch nichts gespeichert.',
            duolangDueNow: 'jetzt fällig', duolangDueIn: 'in {d} Tagen',
            duolangLesson: 'Lektion', duolangStartFailed: 'Lektion konnte nicht gestartet werden.',
            duolangLoadFailed: 'Konnte nicht geladen werden.',
            duolangBeatRecall: 'Zuerst eine kurze Wiederholung', duolangBeatRecallBack: 'Wir steigen langsam wieder ein',
            duolangBeatRead: 'Lies das hier', duolangBeatReadNew: 'Neue Wörter im Zusammenhang',
            duolangBeatCheck: 'Worum ging es?', duolangBeatSpeak: 'Jetzt sprich es',
            duolangBeatUse: 'Reden wir', duolangBeatTakeaway: 'Eine Sache zum Merken',
            duolangAnswerOnePerLine: 'Eine Antwort pro Zeile.',
            duolangAnswerYourLanguage: 'Antworte in deiner eigenen Sprache.',
            duolangContinueWhenReady: 'Schicke etwas, wenn du weitermachen möchtest.',
            duolangSpeakHint: 'Tippe \ud83d\udd0a zum Hören, \ud83c\udfa4 zum Nachsprechen.',
            duolangUnderstood: 'Verstanden', duolangPartly: 'Teilweise',
            duolangNothingToFix: 'Diesmal gibt es nichts zu korrigieren.',
            duolangItemsAdded: '{n} zu deinen Wörtern hinzugefügt.',
            duolangLevelUnverified: 'Niveau für diesen Text nicht geprüft.',
            duolangMic_listening: 'Hört zu…', duolangMic_ok: 'Verstanden',
            duolangMic_retry: 'Versuch die Zeile noch einmal', duolangMic_blocked: 'Mikrofon blockiert',
            duolangMic_unsupported: 'Spracheingabe hier nicht verfügbar',
            duolangMic_unavailable: 'Für diese Sprache fehlt evtl. ein Sprachpaket',
            retry: 'Wiederholen', clear: 'Löschen', send: 'Senden', cancel: 'Abbrechen', ok: 'OK', stopGen: 'Stopp',
            browserConsentTitle: 'Browser-Tools — bitte lesen',
            browserConsentAccept: 'Ich verstehe und akzeptiere',
            browserConsentEnabled: 'Browser-Tools aktiviert.',
            browserConsentError: 'Bestätigung konnte nicht gespeichert werden. Bitte erneut über Einstellungen versuchen.',
            update: 'Aktualisieren', rename: 'Umbenennen', delete_: 'Löschen', download: '⬇ Herunterladen',
            newSession: '+ Neue Sitzung', newChat: 'Neuer Chat',
            typePlaceholder: 'Nachricht eingeben — Enter zum Senden, Umschalt-Enter für neue Zeile...', typePlaceholderShort: 'Nachricht eingeben...', attachFile: 'Datei anhängen',
            ollamaEndpoint: 'Ollama-Endpunkt',
            cannotConnect: 'Verbindung zu Ollama fehlgeschlagen',
            cannotConnectFull: 'Verbindung zu Ollama fehlgeschlagen. Bitte überprüfen Sie die Ollama-URL-Endpunkt.',
            cannotConnectTo: 'Verbindung fehlgeschlagen: ',
            renameSession: 'Sitzung umbenennen', newSessionName: 'Neuer Sitzungsname',
            deleteSession: 'Sitzung löschen',
            deleteConfirm1: '"', deleteConfirm2: '" löschen? Dies kann nicht rückgängig gemacht werden.',
            clearSession: 'Sitzung leeren',
            clearConfirm1: 'Gesamten Verlauf in "', clearConfirm2: '" löschen? Eine laufende Antwort wird unterbrochen. Dies kann nicht rückgängig gemacht werden.',
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
            voicePermissionDenied: 'Mikrofonzugriff wurde verweigert. Aktivieren Sie ihn in den Site-Einstellungen Ihres Browsers für diese Seite.',
            voiceServiceUnreachable: 'Der Spracherkennungsdienst ist nicht erreichbar. Prüfen Sie Ihre Netzwerkverbindung oder deaktivieren Sie Erweiterungen, die Google-Dienste blockieren.',
            voiceAudioCaptureFailed: 'Audio konnte nicht aufgenommen werden. Möglicherweise verwendet eine andere App das Mikrofon, oder es ist kein Eingabegerät verfügbar.',
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
            recQuickAnswer: '⚡ Quick-Wit', recDeepThinker: '💭 Deep-Thinker', recTechExpert: '🛠 Technischer Experte', recWordsmith: '💎 Fine-Grain',
            aboutBtn: 'Über', aboutDesc: 'Eine selbst gehostete, mehrbenutzer-fähige KI-Chat-Plattform mit Unterstützung für lokale und Cloud-LLMs, Echtzeit-Websuche mit Antwortsynthese, Spracheingabe und umfangreichen Dokument- und Bildanhängen — für private Bereitstellung konzipiert.', aboutLegalTitle: 'Recht & Lizenz', aboutLicenseLabel: 'Lizenz:', aboutLicenseBody: 'Lizenziert unter der GNU Affero General Public License v3 (AGPL-3.0).', aboutAttrib: 'Gemäß den Zusatzbedingungen (Abschnitt 7b) muss jede Weiterverbreitung oder Ableitung dieser Software diese Zuschreibung und den Link zur Originalquelle beibehalten.', aboutSourceLabel: 'Quellcode:', aboutCommercialLabel: 'Kommerzielle Lizenzierung:', aboutCommercialBody: 'Für Anfragen zur kommerziellen Nutzung oder proprietären Lizenzierung wenden Sie sich bitte an Cuong Truong unter tduccuong@gmail.com.', aboutClose: 'Schließen',
            noModelAvail: 'Kein Modell verfügbar. Bitte zuerst in den Einstellungen konfigurieren.',
            convSettings: 'Gesprächseinstellungen',
            aiModelSettings: 'KI-Modell-Einstellungen',
            settingsTabPools: 'Pools', settingsTabModels: 'Modelle', settingsTabConversation: 'Konversation', settingsTabReadAloud: 'Vorlesen',
            multimediaSection: 'Multimedia', videoDetailLabel: 'Videoanalyse-Tiefe',
            videoDetailLow: 'Niedrig (4 Frames)', videoDetailMedium: 'Mittel (8 Frames)', videoDetailHigh: 'Hoch (12 Frames)',
            processingVideo: 'Video wird verarbeitet, das kann einen Moment dauern…', analyzingVideo: 'Video wird analysiert, das kann einen Moment dauern…',
            processingImage: 'Bild wird verarbeitet, das kann einen Moment dauern…', analyzingImage: 'Foto wird analysiert, das kann einen Moment dauern…',
            thinkingOutLoud: 'Denken…',
            ttsNoInput: 'Hänge ein Bild an oder tippe Text nach /tts und sende erneut.',
            ttsNoText: 'Es konnte kein Text extrahiert werden (ein oder mehrere Bilder fehlerhaft).',
            ttsNothing: 'Nichts vorzulesen.',
            duolangPickerTitle: 'Sprache wählen',
            duolangFilterPlaceholder: 'Sprachen filtern…',
            duolangNoMatch: 'Keine passende Sprache.',
            duolangPickLanguage: 'Wähle eine Sprache, z. B. /duolang <Sprache> <Text>.',
            duolangNoInput: 'Tippe Text nach der Sprache, hänge ein Bild an oder sende /duolang <Sprache> allein, nachdem ich geantwortet habe.',
            sessionModalTitle: 'Chat-Sitzungen',
            sessionFilterPlaceholder: 'Sitzungen filtern…',
            sessionNoMatch: 'Keine passende Sitzung.',
            modeConfidant: 'Vertrauter',
            modeAssistant: 'Assistent',
            hintConfidant: 'Hinweis: Für <strong>komplexe Aufgaben</strong> nutze den Assistenten. Vertrauter ist nur für <strong>schnelle Antworten</strong>.',
            hintAssistant: 'Hinweis: Für <strong>schnelle Antworten</strong> nutze den Vertrauten. Assistent ist nur für <strong>komplexe Aufgaben</strong>.',
            splashConfidant: {
                title: 'Hi, ich bin DMH-AI.',
                lead: 'Dein Vertrauter für schnelle, tiefgründige Chats und sofortige Antworten.',
                bullets: [
                    { strong: 'Multimedia', text: 'Lade Fotos, Videos oder Dokumente für direkte Fragen hoch.' },
                    { strong: '/memo &lt;Text&gt;', text: 'Private Notiz speichern — automatisch abgerufen, wenn relevant.' },
                    { strong: '/tts &lt;Text&gt;', text: 'Text in seiner eigenen Sprache vorlesen — oder eine vorherige Antwort von mir, wenn kein Text angegeben ist.' },
                    { strong: '/duolang &lt;Sprache&gt; &lt;Text&gt;', text: 'Text in zwei Sprachen vorlesen: der des Textes und <Sprache>.' },
                ],
                outro: 'oder frag mich einfach alles!',
                switchPrompt: 'Brauchst du Hilfe bei einem komplexen Projekt? Probiere den',
                switchPromptShort: 'Komplexes Projekt? Probiere den',
            },
            splashAssistant: {
                title: 'Hi, ich bin DMH-AI Assistent.',
                lead: 'Entwickelt für tiefe Recherche, komplexe Abläufe und große Aufgaben.',
                bullets: [
                    { strong: 'Tippe: /memo &lt;Text&gt;', text: 'Verschlüsseln & private Notizen speichern. Bereit für zukünftige Abfragen über Schlüsselwörter.' },
                    { strong: 'Tippe: /index &lt;Quelle&gt;', text: 'URL, Datei oder Text in deine Wissensdatenbank aufnehmen.' },
                    { strong: 'Workflows', text: 'Dokumente hochladen und komplexe Aufgaben lösen.' },
                ],
                switchPrompt: 'Möchtest du nur kurz plaudern? Wechsel zum',
                switchPromptShort: 'Kurz plaudern? Wechsel zum',
            },
        },
        es: {
            duolangTalk_idle: 'Tutor',
            duolangTalk_recall: 'Responde abajo',
            duolangTalk_read: 'Léelo entero',
            duolangTalk_check: 'Preguntas sobre esto',
            duolangTalk_speak: 'Dilo en voz alta',
            duolangTalk_use: 'Conversación',
            duolangTalk_takeaway: 'Para terminar',
            duolangOf: '{i} de {n}',
            duolangThePassage: 'El texto',
            duolangUseThese: 'Intenta usar estas',
            duolangTab_review: 'Repaso', duolangTab_understand: 'Entender', duolangTab_speak: 'Pronunciar', duolangTab_talk: 'Rol', duolangTab_recap: 'Resumen',
            duolangStep_recall: 'Repaso',
            duolangStep_read: 'Leer',
            duolangStep_check: 'Ver',
            duolangStep_speak: 'Decir',
            duolangStep_use: 'Hablar',
            duolangStep_takeaway: 'Fin',
            duolangDoRecall: 'Escribe cada palabra en el idioma que estás aprendiendo.',
            duolangDoRecallBack: 'Solo léelas — no se corrige nada.',
            duolangDoRead: 'Léelo entero. Toca una línea para oírla.',
            duolangDoReadNew: 'Palabras nuevas, repetidas para que se fijen. Toca una línea para oírla.',
            duolangDoCheck: 'Responde abajo, en {lang}.',
            duolangDoSpeak: 'Toca para oír, luego el micro y repite.',
            duolangDoUse: 'Responde abajo, en {lang}.',
            duolangDoTakeaway: 'Una cosa de esta lección.',
            duolangContinue: 'Continuar', duolangNextSentence: 'Siguiente frase', duolangSpeakDone: 'Completar', duolangSentenceOf: 'Frase {i} de {n}', duolangSkip: 'Saltar',
            duolangCheckAnswers: 'Comprobar',
            duolangGotIt: 'Entendido',
            duolangNextLesson: 'Siguiente lección',
            duolangChoose: 'Elige un idioma…',
            duolangAnswerIn: 'Responde en {lang}…',
            duolangUseButtons: 'Usa los botones de arriba',
            duolangSameLanguage: 'Elige un idioma distinto al tuyo.',
            duolangYouCovered: 'Mencionaste', duolangYouMissed: 'No mencionaste',
            duolangPressStart: 'Pulsa Empezar arriba para comenzar una lección.',
            splashDuolang: {
                title: 'Aprender con Duolang.',
                lead: 'Un tutor privado para un idioma, una sesión corta cada vez.',
                bullets: [
                    { strong: 'Leer', text: 'Un texto breve escrito para lo que ya sabes, con la traducción al lado.' },
                    { strong: 'Entender', text: 'Unas preguntas en tu propio idioma, antes de hablar.' },
                    { strong: 'Decirlo', text: 'Las mismas frases, en voz alta. Toca para oírlas, toca para repetirlas.' },
                    { strong: 'Hablar', text: 'Un intercambio corto y luego una cosa para recordar.' }
                ],
                outro: 'Pulsa Empezar arriba.'
            },
            duolangMode: 'Aprender con Duolang', duolangChatMode: 'Chatear con Confidant',
            duolangWelcome: '¿Qué te gustaría aprender?',
            duolangIWantToLearn: 'Quiero aprender', duolangMyLanguage: 'Mi idioma',
            duolangMyGoal: '¿Qué quieres poder hacer?',
            duolangGoalPlaceholder: 'p. ej. hablar con la familia de mi pareja',
            duolangInterests: 'Lo que te interesa', duolangInterestsPlaceholder: 'cocina, fútbol, viajes',
            duolangStartLearning: 'Empezar a aprender', duolangStart: 'Empezar',
            duolangItemsReady: 'unos {n} elementos listos', duolangSomethingNew: 'algo nuevo',
            duolangWelcomeBack: 'Bienvenido de nuevo: empezamos con calma.',
            duolangCoverage: 'Entiendes alrededor del {p}% del {lang} cotidiano',
            duolangWordsPhrases: 'Palabras y frases', duolangNoItems: 'Aún no hay nada guardado.',
            duolangDueNow: 'toca ahora', duolangDueIn: 'en {d} días',
            duolangLesson: 'Lección', duolangStartFailed: 'No se pudo iniciar la lección.',
            duolangLoadFailed: 'No se pudo cargar.',
            duolangBeatRecall: 'Primero, un repaso rápido', duolangBeatRecallBack: 'Retomamos con calma',
            duolangBeatRead: 'Lee esto', duolangBeatReadNew: 'Palabras nuevas en contexto',
            duolangBeatCheck: '¿De qué trataba?', duolangBeatSpeak: 'Ahora dilo',
            duolangBeatUse: 'Hablemos', duolangBeatTakeaway: 'Una cosa para recordar',
            duolangAnswerOnePerLine: 'Una respuesta por línea.',
            duolangAnswerYourLanguage: 'Responde en tu propio idioma.',
            duolangContinueWhenReady: 'Envía cualquier cosa cuando quieras seguir.',
            duolangSpeakHint: 'Toca \ud83d\udd0a para escuchar, \ud83c\udfa4 para repetir.',
            duolangUnderstood: 'Lo entendiste', duolangPartly: 'En parte',
            duolangNothingToFix: 'Esta vez no hay nada que corregir.',
            duolangItemsAdded: '{n} añadidos a tus palabras.',
            duolangLevelUnverified: 'Nivel no verificado para este texto.',
            duolangMic_listening: 'Escuchando…', duolangMic_ok: 'Se entendió',
            duolangMic_retry: 'Intenta esa línea otra vez', duolangMic_blocked: 'Micrófono bloqueado',
            duolangMic_unsupported: 'Entrada de voz no disponible aquí',
            duolangMic_unavailable: 'Puede que falte un paquete de voz para este idioma',
            retry: 'Reintentar', clear: 'Limpiar', send: 'Enviar', cancel: 'Cancelar', ok: 'OK', stopGen: 'Detener',
            browserConsentTitle: 'Herramientas de navegador — léelo',
            browserConsentAccept: 'Lo entiendo y acepto',
            browserConsentEnabled: 'Herramientas de navegador activadas.',
            browserConsentError: 'No se pudo registrar la aceptación. Inténtalo de nuevo desde Ajustes.',
            update: 'Actualizar', rename: 'Renombrar', delete_: 'Eliminar', download: '⬇ Descargar',
            newSession: '+ Nueva sesión', newChat: 'Nueva conversación',
            typePlaceholder: 'Escribe un mensaje — Enter para enviar, Mayús-Enter para nueva línea...', typePlaceholderShort: 'Escribe un mensaje...', attachFile: 'Adjuntar archivo',
            ollamaEndpoint: 'Punto de acceso Ollama',
            cannotConnect: 'No se puede conectar a Ollama',
            cannotConnectFull: 'No se puede conectar a Ollama. Verifique la URL del endpoint de Ollama.',
            cannotConnectTo: 'No se puede conectar a ',
            renameSession: 'Renombrar sesión', newSessionName: 'Nombre de nueva sesión',
            deleteSession: 'Eliminar sesión',
            deleteConfirm1: '¿Eliminar "', deleteConfirm2: '"? Esto no se puede deshacer.',
            clearSession: 'Limpiar sesión',
            clearConfirm1: '¿Borrar todo el historial en "', clearConfirm2: '"? Cualquier respuesta en curso será interrumpida. Esto no se puede deshacer.',
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
            voicePermissionDenied: 'Se denegó el acceso al micrófono. Vuelva a habilitarlo en la configuración del sitio de su navegador para esta página.',
            voiceServiceUnreachable: 'El servicio de reconocimiento de voz no está disponible. Verifique su conexión de red o desactive las extensiones que bloqueen los servicios de Google.',
            voiceAudioCaptureFailed: 'No se pudo capturar el audio. Otra aplicación puede estar usando el micrófono, o no hay un dispositivo de entrada disponible.',
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
            recQuickAnswer: '⚡ Quick-Wit', recDeepThinker: '💭 Deep-Thinker', recTechExpert: '🛠 Experto Técnico', recWordsmith: '💎 Fine-Grain',
            aboutBtn: 'Acerca de', aboutDesc: 'Una plataforma de chat de IA multiusuario autohospedada que admite LLMs locales y en la nube, búsqueda web en tiempo real con síntesis de respuestas, entrada de voz y archivos adjuntos de documentos e imágenes — diseñada para implementación privada.', aboutLegalTitle: 'Legal y Licencia', aboutLicenseLabel: 'Licencia:', aboutLicenseBody: 'Con licencia bajo la Licencia Pública General GNU Affero v3 (AGPL-3.0).', aboutAttrib: 'Conforme a los Términos Adicionales (Sección 7b), cualquier redistribución o derivado de este software debe mantener esta atribución y el enlace a la fuente original.', aboutSourceLabel: 'Código fuente:', aboutCommercialLabel: 'Licencias comerciales:', aboutCommercialBody: 'Para consultas sobre uso comercial o licencias propietarias, contacte a Cuong Truong en tduccuong@gmail.com.', aboutClose: 'Cerrar',
            noModelAvail: 'Ningún modelo disponible. Configure uno en Ajustes primero.',
            convSettings: 'Configuración de conversación',
            aiModelSettings: 'Configuración de modelos IA',
            settingsTabPools: 'Pools', settingsTabModels: 'Modelos', settingsTabConversation: 'Conversación', settingsTabReadAloud: 'Leer en voz alta',
            multimediaSection: 'Multimedia', videoDetailLabel: 'Profundidad de análisis de vídeo',
            videoDetailLow: 'Baja (4 fotogramas)', videoDetailMedium: 'Media (8 fotogramas)', videoDetailHigh: 'Alta (12 fotogramas)',
            processingVideo: 'Procesando vídeo, puede tardar un momento…', analyzingVideo: 'Analizando vídeo, puede tardar un momento…',
            processingImage: 'Procesando imagen, puede tardar un momento…', analyzingImage: 'Analizando foto, puede tardar un momento…',
            thinkingOutLoud: 'Pensando…',
            ttsNoInput: 'Adjunta una imagen o escribe texto después de /tts y vuelve a enviar.',
            ttsNoText: 'No se pudo extraer texto (una o más imágenes con error).',
            ttsNothing: 'Nada que leer.',
            duolangPickerTitle: 'Elige un idioma',
            duolangFilterPlaceholder: 'Filtrar idiomas…',
            duolangNoMatch: 'Ningún idioma coincide.',
            duolangPickLanguage: 'Elige un idioma, p. ej. /duolang <idioma> <texto>.',
            duolangNoInput: 'Escribe texto después del idioma, adjunta una imagen o envía /duolang <idioma> solo después de que haya respondido.',
            sessionModalTitle: 'Sesiones de chat',
            sessionFilterPlaceholder: 'Filtrar sesiones…',
            sessionNoMatch: 'Ninguna sesión coincide.',
            modeConfidant: 'Confidant',
            modeAssistant: 'Assistant',
            hintConfidant: 'Nota: Para <strong>tareas complejas</strong>, cambia al Asistente. Confidente es solo para <strong>respuestas rápidas</strong>.',
            hintAssistant: 'Nota: Para <strong>respuestas rápidas</strong>, cambia al Confidente. Asistente es solo para <strong>tareas complejas</strong>.',
            splashConfidant: {
                title: 'Hola, soy DMH-AI.',
                lead: 'Tu confidente para charlas rápidas, profundas y respuestas al instante.',
                bullets: [
                    { strong: 'Multimedia', text: 'Sube fotos, videos o docs para preguntar sobre ellos.' },
                    { strong: '/memo &lt;texto&gt;', text: 'Guarda una nota privada — se recupera automáticamente cuando es relevante.' },
                    { strong: '/tts &lt;texto&gt;', text: 'Lee el texto en voz alta en su propio idioma — o una respuesta mía anterior si no das texto.' },
                    { strong: '/duolang &lt;idioma&gt; &lt;texto&gt;', text: 'Lee en voz alta en dos idiomas: el del texto y <idioma>.' },
                ],
                outro: '¡o pregúntame lo que quieras!',
                switchPrompt: '¿Necesitas ayuda con un proyecto complejo? Prueba el',
                switchPromptShort: '¿Proyecto complejo? Prueba el',
            },
            splashAssistant: {
                title: 'Hola, soy DMH-AI Asistente.',
                lead: 'Diseñado para investigación profunda y flujos de trabajo pesados.',
                bullets: [
                    { strong: 'Escribe: /memo &lt;texto&gt;', text: 'Cifra y guarda notas privadas. Listo para futuras búsquedas por palabras clave.' },
                    { strong: 'Escribe: /index &lt;fuente&gt;', text: 'Indexa URL, archivos o texto en tu base de conocimientos.' },
                    { strong: 'Flujos de trabajo', text: 'Sube documentos para tareas complejas de varios pasos.' },
                ],
                switchPrompt: '¿Solo quieres charlar un rato? Cambia al',
                switchPromptShort: '¿Charla rápida? Cambia al',
            },
        },
        fr: {
            duolangTalk_idle: 'Tuteur',
            duolangTalk_recall: 'Réponds ci-dessous',
            duolangTalk_read: 'Lis le texte',
            duolangTalk_check: 'Questions sur ce texte',
            duolangTalk_speak: 'Dis-le à voix haute',
            duolangTalk_use: 'Conversation',
            duolangTalk_takeaway: 'Pour finir',
            duolangOf: '{i} sur {n}',
            duolangThePassage: 'Le texte',
            duolangUseThese: 'Essaie d\u2019utiliser ceux-ci',
            duolangTab_review: 'Révision', duolangTab_understand: 'Comprendre', duolangTab_speak: 'Prononcer', duolangTab_talk: 'Jeu de rôle', duolangTab_recap: 'Bilan',
            duolangStep_recall: 'Révision',
            duolangStep_read: 'Lire',
            duolangStep_check: 'Vérif',
            duolangStep_speak: 'Dire',
            duolangStep_use: 'Parler',
            duolangStep_takeaway: 'Bilan',
            duolangDoRecall: 'Écris chaque mot dans la langue que tu apprends.',
            duolangDoRecallBack: 'Relis-les simplement — rien n\u2019est noté.',
            duolangDoRead: 'Lis le texte. Touche une ligne pour l\u2019écouter.',
            duolangDoReadNew: 'Mots nouveaux, répétés pour qu\u2019ils restent. Touche une ligne pour l\u2019écouter.',
            duolangDoCheck: 'Réponds ci-dessous, en {lang}.',
            duolangDoSpeak: 'Touche pour écouter, puis le micro et répète.',
            duolangDoUse: 'Réponds ci-dessous, en {lang}.',
            duolangDoTakeaway: 'Une chose à retenir de cette leçon.',
            duolangContinue: 'Continuer', duolangNextSentence: 'Phrase suivante', duolangSpeakDone: 'Terminer', duolangSentenceOf: 'Phrase {i} sur {n}', duolangSkip: 'Passer',
            duolangCheckAnswers: 'Vérifier',
            duolangGotIt: 'Compris',
            duolangNextLesson: 'Leçon suivante',
            duolangChoose: 'Choisis une langue…',
            duolangAnswerIn: 'Réponds en {lang}…',
            duolangUseButtons: 'Utilise les boutons ci-dessus',
            duolangSameLanguage: 'Choisis une langue différente de la tienne.',
            duolangYouCovered: 'Tu as mentionné', duolangYouMissed: 'Tu n\'as pas mentionné',
            duolangPressStart: 'Appuie sur Commencer ci-dessus pour démarrer une leçon.',
            splashDuolang: {
                title: 'Apprendre avec Duolang.',
                lead: 'Un tuteur privé pour une langue, une courte séance à la fois.',
                bullets: [
                    { strong: 'Lire', text: 'Un court texte écrit selon ce que tu sais déjà, avec la traduction à côté.' },
                    { strong: 'Comprendre', text: 'Quelques questions dans ta propre langue, avant de parler.' },
                    { strong: 'Le dire', text: 'Les mêmes lignes, à voix haute. Touche pour écouter, touche pour répéter.' },
                    { strong: 'Parler', text: 'Un bref échange, puis une chose à retenir.' }
                ],
                outro: 'Appuie sur Commencer ci-dessus.'
            },
            duolangMode: 'Apprendre avec Duolang', duolangChatMode: 'Discuter avec Confidant',
            duolangWelcome: 'Que souhaites-tu apprendre ?',
            duolangIWantToLearn: 'Je veux apprendre', duolangMyLanguage: 'Ma langue',
            duolangMyGoal: 'Que veux-tu pouvoir faire ?',
            duolangGoalPlaceholder: 'p. ex. parler avec la famille de mon partenaire',
            duolangInterests: 'Ce qui t\u2019intéresse', duolangInterestsPlaceholder: 'cuisine, football, voyages',
            duolangStartLearning: 'Commencer à apprendre', duolangStart: 'Commencer',
            duolangItemsReady: 'environ {n} éléments prêts', duolangSomethingNew: 'quelque chose de nouveau',
            duolangWelcomeBack: 'Content de te revoir — on reprend en douceur.',
            duolangCoverage: 'Tu comprends environ {p}% du {lang} courant',
            duolangWordsPhrases: 'Mots et expressions', duolangNoItems: 'Rien d\u2019enregistré pour l\u2019instant.',
            duolangDueNow: 'à revoir', duolangDueIn: 'dans {d} jours',
            duolangLesson: 'Leçon', duolangStartFailed: 'Impossible de démarrer la leçon.',
            duolangLoadFailed: 'Chargement impossible.',
            duolangBeatRecall: 'D\u2019abord, une révision rapide', duolangBeatRecallBack: 'On reprend tranquillement',
            duolangBeatRead: 'Lis ceci', duolangBeatReadNew: 'Nouveaux mots en contexte',
            duolangBeatCheck: 'De quoi s\u2019agissait-il ?', duolangBeatSpeak: 'Maintenant, dis-le',
            duolangBeatUse: 'Discutons', duolangBeatTakeaway: 'Une chose à retenir',
            duolangAnswerOnePerLine: 'Une réponse par ligne.',
            duolangAnswerYourLanguage: 'Réponds dans ta propre langue.',
            duolangContinueWhenReady: 'Envoie n\u2019importe quoi quand tu veux continuer.',
            duolangSpeakHint: 'Touche \ud83d\udd0a pour écouter, \ud83c\udfa4 pour répéter.',
            duolangUnderstood: 'Tu as compris', duolangPartly: 'En partie',
            duolangNothingToFix: 'Rien à corriger cette fois.',
            duolangItemsAdded: '{n} ajoutés à tes mots.',
            duolangLevelUnverified: 'Niveau non vérifié pour ce texte.',
            duolangMic_listening: 'Écoute…', duolangMic_ok: 'Bien entendu',
            duolangMic_retry: 'Réessaie cette ligne', duolangMic_blocked: 'Micro bloqué',
            duolangMic_unsupported: 'Saisie vocale indisponible ici',
            duolangMic_unavailable: 'Un pack vocal peut manquer pour cette langue',
            retry: 'Réessayer', clear: 'Effacer', send: 'Envoyer', cancel: 'Annuler', ok: 'OK', stopGen: 'Arrêter',
            browserConsentTitle: 'Outils navigateur — à lire',
            browserConsentAccept: 'J\'ai compris et j\'accepte',
            browserConsentEnabled: 'Outils navigateur activés.',
            browserConsentError: 'Impossible d\'enregistrer l\'acceptation. Réessayez depuis Paramètres.',
            update: 'Mettre à jour', rename: 'Renommer', delete_: 'Supprimer', download: '⬇ Télécharger',
            newSession: '+ Nouvelle session', newChat: 'Nouvelle conversation',
            typePlaceholder: 'Tapez un message — Entrée pour envoyer, Maj-Entrée pour nouvelle ligne...', typePlaceholderShort: 'Tapez un message...', attachFile: 'Joindre un fichier',
            ollamaEndpoint: 'Point d\'accès Ollama',
            cannotConnect: 'Connexion à Ollama impossible',
            cannotConnectFull: 'Connexion à Ollama impossible. Veuillez vérifier l\'URL du endpoint Ollama.',
            cannotConnectTo: 'Connexion impossible à ',
            renameSession: 'Renommer la session', newSessionName: 'Nom de la nouvelle session',
            deleteSession: 'Supprimer la session',
            deleteConfirm1: 'Supprimer "', deleteConfirm2: '" ? Cette action est irréversible.',
            clearSession: 'Effacer la session',
            clearConfirm1: 'Effacer tout l\'historique de "', clearConfirm2: '" ? Toute réponse en cours sera interrompue. Cette action est irréversible.',
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
            voicePermissionDenied: 'L\'accès au microphone a été refusé. Réactivez-le dans les paramètres du site de votre navigateur pour cette page.',
            voiceServiceUnreachable: 'Le service de reconnaissance vocale est injoignable. Vérifiez votre connexion réseau ou désactivez les extensions qui bloquent les services Google.',
            voiceAudioCaptureFailed: 'Impossible de capturer l\'audio. Une autre application utilise peut-être le microphone, ou aucun périphérique d\'entrée n\'est disponible.',
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
            recQuickAnswer: '⚡ Quick-Wit', recDeepThinker: '💭 Deep-Thinker', recTechExpert: '🛠 Expert Technique', recWordsmith: '💎 Fine-Grain',
            aboutBtn: 'À propos', aboutDesc: 'Une plateforme de chat IA multi-utilisateurs auto-hébergée prenant en charge les LLMs locaux et cloud, la recherche web en temps réel avec synthèse des réponses, la saisie vocale et les pièces jointes de documents et d\'images — conçue pour un déploiement privé.', aboutLegalTitle: 'Mentions légales et Licence', aboutLicenseLabel: 'Licence :', aboutLicenseBody: 'Sous licence GNU Affero General Public License v3 (AGPL-3.0).', aboutAttrib: 'Conformément aux Conditions supplémentaires (Section 7b), toute redistribution ou dérivé de ce logiciel doit conserver cette attribution et le lien vers la source originale.', aboutSourceLabel: 'Code source :', aboutCommercialLabel: 'Licences commerciales :', aboutCommercialBody: 'Pour toute demande concernant l\'utilisation commerciale ou une licence propriétaire, veuillez contacter Cuong Truong à tduccuong@gmail.com.', aboutClose: 'Fermer',
            noModelAvail: 'Aucun modèle disponible. Veuillez d\'abord en configurer un dans les Paramètres.',
            convSettings: 'Paramètres de conversation',
            aiModelSettings: 'Paramètres des modèles IA',
            settingsTabPools: 'Pools', settingsTabModels: 'Modèles', settingsTabConversation: 'Conversation', settingsTabReadAloud: 'Lecture vocale',
            multimediaSection: 'Multimédia', videoDetailLabel: 'Profondeur d\'analyse vidéo',
            videoDetailLow: 'Faible (4 images)', videoDetailMedium: 'Moyen (8 images)', videoDetailHigh: 'Élevé (12 images)',
            processingVideo: 'Traitement de la vidéo, cela peut prendre un moment…', analyzingVideo: 'Analyse de la vidéo, cela peut prendre un moment…',
            processingImage: 'Traitement de l\'image, cela peut prendre un moment…', analyzingImage: 'Analyse de la photo, cela peut prendre un moment…',
            thinkingOutLoud: 'Réflexion…',
            ttsNoInput: 'Joins une image ou saisis du texte après /tts, puis renvoie.',
            ttsNoText: 'Aucun texte n\'a pu être extrait (une ou plusieurs images en erreur).',
            ttsNothing: 'Rien à lire.',
            duolangPickerTitle: 'Choisir une langue',
            duolangFilterPlaceholder: 'Filtrer les langues…',
            duolangNoMatch: 'Aucune langue ne correspond.',
            duolangPickLanguage: 'Choisis une langue, p. ex. /duolang <langue> <texte>.',
            duolangNoInput: 'Saisis du texte après la langue, joins une image, ou envoie /duolang <langue> seul après que j\'ai répondu.',
            sessionModalTitle: 'Sessions de chat',
            sessionFilterPlaceholder: 'Filtrer les sessions…',
            sessionNoMatch: 'Aucune session ne correspond.',
            modeConfidant: 'Confidant',
            modeAssistant: 'Assistant',
            hintConfidant: 'Note : Pour des <strong>tâches complexes</strong>, passe à Assistant. Confident est réservé aux <strong>réponses rapides</strong>.',
            hintAssistant: 'Note : Pour des <strong>réponses rapides</strong>, passe à Confident. Assistant est réservé aux <strong>tâches complexes</strong>.',
            splashConfidant: {
                title: 'Salut, je suis DMH-AI.',
                lead: 'Ton confident pour des échanges rapides et des réponses instantanées.',
                bullets: [
                    { strong: 'Multimédia', text: 'Importe photos, vidéos ou docs pour poser tes questions.' },
                    { strong: '/memo &lt;texte&gt;', text: 'Enregistre une note privée — rappelée automatiquement si pertinent.' },
                    { strong: '/tts &lt;texte&gt;', text: 'Lis le texte à voix haute dans sa propre langue — ou une réponse précédente de moi si aucun texte n’est donné.' },
                    { strong: '/duolang &lt;langue&gt; &lt;texte&gt;', text: 'Lis à voix haute en deux langues : celle du texte et <langue>.' },
                ],
                outro: 'ou pose-moi n’importe quelle question !',
                switchPrompt: 'Besoin d’aide pour un projet complexe ? Essaie l’',
                switchPromptShort: 'Projet complexe ? Essaie l’',
            },
            splashAssistant: {
                title: 'Salut, je suis DMH-AI Assistant.',
                lead: 'Conçu pour la recherche approfondie et les flux de travail complexes.',
                bullets: [
                    { strong: 'Tapez: /memo &lt;texte&gt;', text: 'Chiffrez et enregistrez des notes privées. Prêt pour de futures recherches par mots-clés.' },
                    { strong: 'Tapez: /index &lt;source&gt;', text: 'Indexe une URL, un fichier ou du texte dans ta base.' },
                    { strong: 'Workflows', text: 'Importe des documents pour des tâches multi-étapes.' },
                ],
                switchPrompt: 'Juste envie de discuter ? Passe en mode',
                switchPromptShort: 'Discuter ? Passe en mode',
            },
        }
    },
    t: function(key) { return (this._strings[this._lang] || this._strings.en)[key] || this._strings.en[key] || key; },
    setLang: function(lang) { this._lang = lang; localStorage.setItem('lang', lang); },
    get lang() { return this._lang; },
    flags: { en: 'EN', vi: 'VI', de: 'DE', es: 'ES', fr: 'FR' },
    names: { en: 'English', vi: 'Tiếng Việt', de: 'Deutsch', es: 'Español', fr: 'Français' }
};
function t(key) { return I18n.t(key); }

// IP-geolocation fallback for the language picker. Fires only on first-
// ever load (no localStorage 'lang' key) AND when navigator.languages
// gave us nothing supported (i.e., I18n._lang fell through to 'en').
// Asynchronous — UI renders synchronously with whatever I18n._lang
// already resolved to, then re-renders via applyLanguage() if the
// server returns a supported language hint based on client IP.
// Best-effort: any failure leaves the UI on its current default.
async function maybeApplyIpLang() {
    if (localStorage.getItem('lang')) return;

    var supported = { en: 1, vi: 1, de: 1, es: 1, fr: 1 };
    var langs = navigator.languages && navigator.languages.length
        ? navigator.languages
        : [navigator.language || 'en'];
    for (var i = 0; i < langs.length; i++) {
        var code = langs[i].split('-')[0].toLowerCase();
        if (supported[code]) return;
    }

    try {
        var r = await fetch('/detect-lang', { credentials: 'omit' });
        if (!r.ok) return;
        var d = await r.json();
        if (d && d.lang && supported[d.lang] && d.lang !== I18n._lang) {
            I18n._lang = d.lang;
            if (typeof applyLanguage === 'function') applyLanguage();
        }
    } catch (e) { /* best-effort, keep current default */ }
}

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
    options.headers = options.headers || {};
    if (Auth.token) {
        options.headers['Authorization'] = 'Bearer ' + Auth.token;
    }
    // Send the browser's IANA timezone and locally-computed date on every
    // request. The BE's chat handler reads X-Timezone / X-Local-Date and
    // threads them into the system prompt so the model interprets clock
    // times ("9:00 May 11") as the user's local time and uses the right
    // timeZone parameter on calendar / scheduling APIs. The Sweden locale
    // gives an unambiguous YYYY-MM-DD format — never US M/D/YYYY.
    try {
        var tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
        if (tz) options.headers['X-Timezone'] = tz;
        options.headers['X-Local-Date'] = new Date().toLocaleDateString('sv-SE');
    } catch (e) {
        // Older browsers / no Intl support → BE falls back to UTC date.
    }
    return fetch(url, options);
}

function syslog(msg) {
    apiFetch('/log', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({msg}) }).catch(function(){});
}

// ─── Notification Polling ──────────────────────────────────────────────
const NotificationPoller = {
    _interval: null,
    _visHandler: null,
    _lastCheck: Date.now(),
    _pollMs: 5000, // default 5s, overridden by user pref
    _lsKey: 'dmh-notif-last-check',

    start: function(pollMs) {
        this.stop();
        if (pollMs) this._pollMs = pollMs;
        // Restore from localStorage — survive page reload, tab background, screen lock.
        // Fall back to now only if nothing stored (first ever load).
        var stored = parseInt(localStorage.getItem(this._lsKey) || '0', 10);
        this._lastCheck = stored > 0 ? stored : Date.now();
        this._interval = setInterval(this._poll.bind(this), this._pollMs);
        // Immediately catch up when tab becomes visible (unlock, tab switch, app resume).
        this._visHandler = this._onVisible.bind(this);
        document.addEventListener('visibilitychange', this._visHandler);
    },

    stop: function() {
        if (this._interval) {
            clearInterval(this._interval);
            this._interval = null;
        }
        if (this._visHandler) {
            document.removeEventListener('visibilitychange', this._visHandler);
            this._visHandler = null;
        }
    },

    _onVisible: function() {
        if (document.visibilityState === 'visible') this._poll();
    },

    _poll: async function() {
        try {
            var since = this._lastCheck;
            this._lastCheck = Date.now();
            localStorage.setItem(this._lsKey, String(this._lastCheck));
            var res = await apiFetch('/notifications?since=' + since);
            if (!res.ok) return;
            var entries = await res.json();
            if (!entries || !entries.length) return;
            for (var i = 0; i < entries.length; i++) {
                this._handleNotification(entries[i]);
            }
        } catch (e) {
            // silent — polling errors shouldn't disrupt the UI
        }
    },

    _handleNotification: function(entry) {
        var isCurrentSession = typeof UIManager !== 'undefined' && UIManager.currentSession &&
            UIManager.currentSession.id === entry.session_id;
        var isProgress = entry.content && entry.content !== '';

        if (isProgress) {
            // Progress entries no longer surface as a dedicated stacked area —
            // the in-flight chain renders activity directly into the chat via
            // `startProgressPolling`. Kept as a no-op so other-session
            // notifications still fall through to the toast branch below.
        } else {
            // Session-updated sentinel — reload session.
            if (isCurrentSession) {
                SessionStore.getSession(entry.session_id).then(function(session) {
                    if (session) {
                        UIManager.currentSession = session;
                        UIManager.renderChat();
                    }
                });
            } else {
                // User is elsewhere — show toast so they know the result arrived
                if (entry.summary) {
                    UIManager.setStatus('🔔 ' + entry.summary);
                    setTimeout(function() { UIManager.setStatus(''); }, 8000);
                }
            }
        }
    }
};

const AppConfig = {
    get searxngUrl() { return localStorage.getItem('searxng-url') || 'http://localhost:8888'; },
    saveSearxng: function(url) {
        if (url) localStorage.setItem('searxng-url', url);
        else localStorage.removeItem('searxng-url');
    }
};

function getRecommendedCloudModels() {
    return [
        { name: 'gemma4:31b-cloud',               label: t('recWordsmith') },
        { name: 'ministral-3:14b-cloud',          label: t('recQuickAnswer') },
        { name: 'qwen3.5:cloud',                  label: t('recDeepThinker') },
    ];
}
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

// Redact passwords, keystore paths, and SSH key paths from a
// progress-row label string. PURE UI VIEW — applied at render-time
// only. The unredacted text remains in session_progress.label on the
// BE and in session.messages tool_call args.
//
// Patterns covered:
//   - sshpass -p '<pwd>'      (single/double-quote/bare)
//   - --password=<val>, --password <val>
//   - SOMETHING_PASSWORD=, _PASSWD=, _TOKEN=, _SECRET=, _API_KEY=, _PWD= env-var assignments
//   - /data/user_assets/<email>/_keystore/<…> paths
//   - ~/.ssh/<file> and /.ssh/<file> heuristic
//
// Does NOT redact:
//   - bare `-p <val>` (collides with port / preserve flags)
//   - generic high-entropy strings (over-redacts UUIDs, hashes)
//   - URL path tokens (out of scope for now)
function redactProgressLabel(text) {
    if (!text || typeof text !== 'string') return text;

    return text
        // sshpass -p 'pwd' / "pwd" / pwd
        .replace(/(\bsshpass\s+-p\s*)(['"]?)([^\s'"]+)\2/g, '$1$2***$2')
        // --password=val
        .replace(/(--password)=(['"]?)([^\s'"]+)\2/g, '$1=$2***$2')
        // --password val (separated by space)
        .replace(/(--password\s+)(['"]?)([^\s'"]+)\2/g, '$1$2***$2')
        // ENV-style secret assignments: anything ending PASSWORD/PASSWD/TOKEN/SECRET/API_KEY/PWD
        .replace(/\b([A-Z][A-Z0-9_]*(?:PASSWORD|PASSWD|TOKEN|SECRET|API_KEY|PWD))=(['"]?)([^\s'"]+)\2/g,
                 '$1=$2***$2')
        // Keystore paths: /data/user_assets/<email>/_keystore/<...>
        .replace(/\/data\/user_assets\/[^\s'"\/]+\/_keystore\/[^\s'"]+/g, '<keystore>')
        // SSH key paths: ~/.ssh/<file> or /.ssh/<file>
        .replace(/(\.ssh\/)([\w.-]+)/g, '$1<key>');
}
