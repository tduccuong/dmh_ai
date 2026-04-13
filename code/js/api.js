/*
 * Copyright (c) 2026 Cuong Truong
 * This project is licensed under the AGPL v3.
 * See the LICENSE file in the repository root for full details.
 * For commercial inquiries, contact: tduccuong@gmail.com
 */

const SessionStore = {
    BASE: '/sessions',
    getSessions: async function() {
        const res = await apiFetch(this.BASE);
        if (!res.ok) return [];
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
        if (!res.ok) return null;
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

const ImageDescriptionStore = {
    BASE: '/image-descriptions',
    save: async function(sessionId, fileId, name, description) {
        try {
            await apiFetch(this.BASE, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ sessionId: sessionId, fileId: fileId, name: name, description: description })
            });
        } catch (e) {
            console.warn('Failed to save image description:', e);
        }
    },
    loadForSession: async function(sessionId) {
        try {
            const res = await apiFetch(this.BASE + '/' + sessionId);
            if (!res.ok) return [];
            return res.json();
        } catch (e) {
            return [];
        }
    },
    deleteForSession: async function(sessionId) {
        try {
            await apiFetch(this.BASE + '/' + sessionId, { method: 'DELETE' });
        } catch (e) {
            console.warn('Failed to delete image descriptions:', e);
        }
    }
};

const VideoDescriptionStore = {
    BASE: '/video-descriptions',
    save: async function(sessionId, fileId, name, description) {
        try {
            await apiFetch(this.BASE, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ sessionId: sessionId, fileId: fileId, name: name, description: description })
            });
        } catch (e) {
            console.warn('Failed to save video description:', e);
        }
    },
    loadForSession: async function(sessionId) {
        try {
            const res = await apiFetch(this.BASE + '/' + sessionId);
            if (!res.ok) return [];
            return res.json();
        } catch (e) {
            return [];
        }
    },
    deleteForSession: async function(sessionId) {
        try {
            await apiFetch(this.BASE + '/' + sessionId, { method: 'DELETE' });
        } catch (e) {
            console.warn('Failed to delete video descriptions:', e);
        }
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
        if (isCloudModel(model)) { this.capabilityCache[model] = true; return true; }
        try {
            const res = await fetch(this.BASE_URL + '/show', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name: model })
            });
            const data = await res.json();
            this._cacheCapabilities(model, data.capabilities || []);
            return this.capabilityCache[model + ':vision'];
        } catch (e) {
            return false;
        }
    },
    hasVideo: async function(model) {
        if ((model + ':video') in this.capabilityCache) return this.capabilityCache[model + ':video'];
        try {
            const res = await fetch(this.BASE_URL + '/show', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name: model })
            });
            const data = await res.json();
            this._cacheCapabilities(model, data.capabilities || []);
            return this.capabilityCache[model + ':video'];
        } catch (e) {
            return false;
        }
    },
    _cacheCapabilities: function(model, caps) {
        this.capabilityCache[model + ':vision'] = caps.includes('vision');
        this.capabilityCache[model + ':video']  = caps.includes('video');
        // backward-compat key used by existing hasVision callers
        this.capabilityCache[model] = caps.includes('vision');
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
        if (isCloudModel(model)) { this.contextWindowCache[model] = 32768; return 32768; }
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
            return 32768;
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
                            var content = json.message && json.message.content;
                            var thinking = json.message && json.message.thinking;
                            if (content) onChunk(content, false);
                            else if (thinking) onChunk(thinking, true);
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
        return pairs.slice(0, topK).filter(function(p) { return p.score >= MIN_RELEVANCE_SCORE; });
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

        // If the session was cleared while we were summarizing, discard the result
        if (session.messages.length === 0) return;

        session.context = { summary: summary, summaryUpToIndex: keepFrom - 1 };
        await SessionStore.updateSession(session);
    }
};
