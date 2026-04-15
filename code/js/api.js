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
    createSession: async function(name, mode) {
        const session = {
            id: Date.now().toString(),
            name: name || 'New Session',
            mode: mode || 'confidant',
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
    get BASE_URL() { return this.endpoint ? '/local-api' : '/api'; },
    setEndpoint: function(url) {
        this.endpoint = url.replace(/\/+$/, '');
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
};

