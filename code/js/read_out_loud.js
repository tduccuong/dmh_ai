// Read-out-loud: Web Speech API wrapper + per-device settings.
//
// Voices are device-specific (`speechSynthesis.getVoices()` exposes what the
// OS provides — Apple voices on Safari, Google voices on Chrome desktop,
// the system list on mobile). We store the user's selection in localStorage
// so it doesn't sync across devices that have different voice catalogs.
//
// Public surface:
//   ReadOutLoud.init()                — populate voices, restore saved selection
//   ReadOutLoud.speak(text)           — speak `text`; opens settings modal first if no voice saved
//   ReadOutLoud.stop()                — cancel any utterance in progress
//   ReadOutLoud.availableVoices()     — current voice list (live)
//   ReadOutLoud.hasSavedVoice()       — true once the user has saved a voice
//   ReadOutLoud.getSettings()         — { voiceURI, rate }
//   ReadOutLoud.saveSettings(s)       — persist to localStorage
//   ReadOutLoud.flushPending()        — speak the deferred sentence after the user picks a voice
const ReadOutLoud = (function() {
    var STORAGE_KEY = 'dmh_ai_read_out_loud_settings';
    var DEFAULT_RATE = 1.0;
    var TEST_SAMPLE_BY_LANG = {
        // Short phrases the user hears when they click "Test voice" — same
        // shape used by the OS settings panels. Pick the language from the
        // selected voice; fall back to English for unknown locales.
        'en':  'The quick brown fox jumps over the lazy dog.',
        'de':  'Der schnelle braune Fuchs springt über den faulen Hund.',
        'fr':  'Le vif renard brun saute par-dessus le chien paresseux.',
        'es':  'El rápido zorro marrón salta sobre el perro perezoso.',
        'it':  'La rapida volpe marrone salta sopra il cane pigro.',
        'pt':  'A rápida raposa marrom salta sobre o cão preguiçoso.',
        'nl':  'De snelle bruine vos springt over de luie hond.',
        'pl':  'Szybki brązowy lis przeskakuje nad leniwym psem.',
        'ja':  '速い茶色のキツネが怠惰な犬を飛び越える。',
        'zh':  '敏捷的棕色狐狸跳过懒狗。'
    };

    var _state = {
        voices: [],
        pendingText: null,
        currentUtterance: null
    };

    function _readSettings() {
        try {
            var raw = localStorage.getItem(STORAGE_KEY);
            if (!raw) return { voiceURI: null, rate: DEFAULT_RATE };
            var parsed = JSON.parse(raw);
            return {
                voiceURI: parsed.voiceURI || null,
                rate: typeof parsed.rate === 'number' ? parsed.rate : DEFAULT_RATE
            };
        } catch (e) {
            return { voiceURI: null, rate: DEFAULT_RATE };
        }
    }

    function _writeSettings(s) {
        try {
            localStorage.setItem(STORAGE_KEY, JSON.stringify({
                voiceURI: s.voiceURI || null,
                rate: typeof s.rate === 'number' ? s.rate : DEFAULT_RATE
            }));
        } catch (e) {}
    }

    function _loadVoices() {
        if (!('speechSynthesis' in window)) {
            _state.voices = [];
            return;
        }
        // Chrome populates voices asynchronously; the first sync call may
        // return [] before `onvoiceschanged` fires. Fire-and-forget — the
        // settings UI re-reads on open.
        _state.voices = window.speechSynthesis.getVoices() || [];
    }

    function _pickVoice(voiceURI) {
        if (!voiceURI) return null;
        for (var i = 0; i < _state.voices.length; i++) {
            if (_state.voices[i].voiceURI === voiceURI) return _state.voices[i];
        }
        return null;
    }

    function _testSampleFor(lang) {
        if (!lang) return TEST_SAMPLE_BY_LANG.en;
        var prefix = String(lang).toLowerCase().split('-')[0];
        return TEST_SAMPLE_BY_LANG[prefix] || TEST_SAMPLE_BY_LANG.en;
    }

    return {
        init: function() {
            if (!('speechSynthesis' in window)) return;
            _loadVoices();
            // Voices populate async on Chrome — reload when the event
            // fires so a freshly-opened settings page sees the full list.
            try {
                window.speechSynthesis.onvoiceschanged = _loadVoices;
            } catch (e) {}
        },

        availableVoices: function() {
            _loadVoices();
            return _state.voices.slice();
        },

        hasSavedVoice: function() {
            return _readSettings().voiceURI != null;
        },

        getSettings: function() {
            return _readSettings();
        },

        saveSettings: function(s) {
            _writeSettings(s);
        },

        // Convenience for the settings modal's "Test voice" button.
        testVoice: function(voiceURI, rate) {
            var voice = _pickVoice(voiceURI);
            var lang = voice ? voice.lang : null;
            var sample = _testSampleFor(lang);
            this._speakWith(sample, voiceURI, rate || DEFAULT_RATE);
        },

        // Speaker-icon click handler. If no voice is saved, defers the
        // sentence + opens the settings modal so the user can pick one;
        // `flushPending` (called from the modal's Save handler) plays the
        // deferred sentence afterwards.
        speak: function(text) {
            if (!text || !('speechSynthesis' in window)) return;
            var s = _readSettings();
            if (!s.voiceURI) {
                _state.pendingText = text;
                if (typeof SettingsModal !== 'undefined' && typeof SettingsModal.open === 'function') {
                    SettingsModal.open('page-read-out-loud');
                }
                return;
            }
            this._speakWith(text, s.voiceURI, s.rate);
        },

        stop: function() {
            if (!('speechSynthesis' in window)) return;
            try { window.speechSynthesis.cancel(); } catch (e) {}
            _state.currentUtterance = null;
        },

        flushPending: function() {
            if (!_state.pendingText) return;
            var t = _state.pendingText;
            _state.pendingText = null;
            this.speak(t);
        },

        clearPending: function() {
            _state.pendingText = null;
        },

        _speakWith: function(text, voiceURI, rate) {
            this.stop();
            var voice = _pickVoice(voiceURI);
            var utter = new SpeechSynthesisUtterance(text);
            if (voice) {
                utter.voice = voice;
                utter.lang = voice.lang;
            }
            utter.rate = typeof rate === 'number' ? rate : DEFAULT_RATE;
            _state.currentUtterance = utter;
            try { window.speechSynthesis.speak(utter); } catch (e) {}
        }
    };
})();
