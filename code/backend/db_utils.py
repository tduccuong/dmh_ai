#!/usr/bin/env python3
# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

import base64, hashlib, http.client, json, mimetypes, os, re, secrets, shutil, socket, sqlite3, ssl, threading, time, urllib.request, urllib.parse
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
from blocked_domains import BLOCKED_DOMAINS as _BLOCKED_DOMAINS
from constants import (    SEARCH_PAGE2_THRESHOLD, MAX_PAGE_CHARS, MIN_USEFUL_PAGE_CHARS,
    DIRECT_FETCH_SIZE_BYTES, JINA_FETCH_SIZE_BYTES,
    OLLAMA_API_TIMEOUT_SECS, ENDPOINT_TEST_TIMEOUT_SECS, REGISTRY_TIMEOUT_SECS,
    SEARXNG_TIMEOUT_SECS, DIRECT_FETCH_TIMEOUT_SECS, JINA_TIMEOUT_SECS,
    PASSWORD_HASH_ITERATIONS, DOMAIN_TIMEOUT_BLOCK_THRESHOLD,
)

class _TextExtractor(HTMLParser):
    _SKIP = {'script','style','nav','header','footer','aside','noscript','iframe','svg','button','form','meta','link'}
    def __init__(self):
        super().__init__()
        self._depth = 0
        self._parts = []
    def handle_starttag(self, tag, attrs):
        if tag in self._SKIP: self._depth += 1
    def handle_endtag(self, tag):
        if tag in self._SKIP: self._depth = max(0, self._depth - 1)
    def handle_data(self, data):
        if self._depth == 0:
            t = data.strip()
            if t: self._parts.append(t)

def _html_to_text(raw_bytes):
    try:
        html = raw_bytes.decode('utf-8', errors='replace')
    except Exception:
        return ''
    p = _TextExtractor()
    try:
        p.feed(html)
    except Exception:
        pass
    text = re.sub(r'\s+', ' ', ' '.join(p._parts)).strip()
    # Fix common scraping artifacts: missing spaces between digits and letters
    text = re.sub(r'(\d)([A-Za-z])', r'\1 \2', text)
    text = re.sub(r'([A-Za-z])(\d)', r'\1 \2', text)
    text = re.sub(r'([a-z])([A-Z])', r'\1 \2', text)
    return text

DB = '/data/db/chat.db'
ASSETS_DIR = '/data/user_assets'
LOG_FILE = '/data/system_logs/system.log'

# ─── Dynamic blocked-domain registry ────────────────────────────────────────
# Combines the static list from blocked_domains.py with domains auto-blocked at
# runtime after repeated fetch timeouts.  Stored as a set for O(1) lookup.
_blocked_lock = threading.Lock()
_blocked_set: set = set()          # root domains, e.g. "immowelt.de"
_timeout_counts: dict = {}         # root domain -> timeout count (in-memory only)

def _root_domain(hostname: str) -> str:
    """Return the registrable domain (last two labels) from a hostname."""
    parts = hostname.lower().split('.')
    return '.'.join(parts[-2:]) if len(parts) >= 2 else hostname.lower()

def is_domain_blocked(url: str) -> bool:
    """O(1) blocked-domain check used by both /search and /fetch-page."""
    try:
        h = urlparse(url).hostname or ''
        rd = _root_domain(h)
        with _blocked_lock:
            return rd in _blocked_set
    except Exception:
        return False

def _record_fetch_timeout(url: str):
    """Increment timeout counter for the domain; auto-block if threshold reached."""
    try:
        h = urlparse(url).hostname or ''
        rd = _root_domain(h)
        if not rd:
            return
        should_persist = False
        final_count = 0
        with _blocked_lock:
            if rd in _blocked_set:
                return  # already blocked, nothing to do
            cnt = _timeout_counts.get(rd, 0) + 1
            _timeout_counts[rd] = cnt
            if cnt >= DOMAIN_TIMEOUT_BLOCK_THRESHOLD:
                _blocked_set.add(rd)
                should_persist = True
                final_count = cnt
        if should_persist:
            try:
                with sqlite3.connect(DB) as c:
                    c.execute(
                        'INSERT OR REPLACE INTO blocked_domains (domain, reason, timeout_count, added_at) VALUES (?,?,?,?)',
                        (rd, 'auto:timeout', final_count, int(time.time()))
                    )
            except Exception as e:
                log(f'[BLOCKED] failed to persist {rd}: {e}')
            log(f'[BLOCKED] auto-blocked {rd} after {final_count} timeouts')
    except Exception:
        pass

def _load_blocked_set():
    """Populate _blocked_set from DB at startup, seeding static list if DB is new."""
    try:
        with sqlite3.connect(DB) as c:
            # Seed static domains into DB on first run (INSERT OR IGNORE = no-op if already present).
            c.executemany(
                'INSERT OR IGNORE INTO blocked_domains (domain, reason, timeout_count, added_at) VALUES (?,?,?,?)',
                [(d, 'static', 0, 0) for d in _BLOCKED_DOMAINS]
            )
            rows = c.execute('SELECT domain FROM blocked_domains').fetchall()
            all_domains = {r[0] for r in rows}
    except Exception:
        all_domains = set(_BLOCKED_DOMAINS)
    with _blocked_lock:
        _blocked_set.clear()
        _blocked_set.update(all_domains)
    log(f'[BLOCKED] loaded {len(_blocked_set)} domains')

def log(msg):
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    ts = time.strftime('%Y-%m-%d %H:%M:%S')
    line = f'[{ts}] {msg}\n'
    with open(LOG_FILE, 'a') as f:
        f.write(line)

IMAGE_EXTS = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'}

def hash_password(password):
    salt = secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac('sha256', password.encode(), salt.encode(), PASSWORD_HASH_ITERATIONS).hex()
    return f'{salt}:{h}'

def verify_password(password, stored):
    try:
        salt, h = stored.split(':', 1)
        return hashlib.pbkdf2_hmac('sha256', password.encode(), salt.encode(), PASSWORD_HASH_ITERATIONS).hex() == h
    except Exception:
        return False

def user_asset_dir(email, session_id):
    safe_session = re.sub(r'[^\w\-]', '_', session_id)
    return os.path.join(ASSETS_DIR, email, safe_session)

def init_db():
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    os.makedirs(ASSETS_DIR, exist_ok=True)
    with sqlite3.connect(DB) as c:
        c.execute('''CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY, name TEXT, model TEXT,
            messages TEXT DEFAULT '[]', context TEXT,
            created_at INTEGER)''')
        c.execute('''CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY, value TEXT)''')
        c.execute('''CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY,
            email TEXT UNIQUE NOT NULL,
            name TEXT,
            password_hash TEXT NOT NULL,
            role TEXT NOT NULL DEFAULT 'user',
            created_at INTEGER)''')
        c.execute('''CREATE TABLE IF NOT EXISTS auth_tokens (
            token TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            created_at INTEGER)''')
        # Migrations
        try:
            c.execute('ALTER TABLE sessions ADD COLUMN user_id TEXT DEFAULT ""')
        except sqlite3.OperationalError:
            pass
        try:
            c.execute('ALTER TABLE users ADD COLUMN password_changed INTEGER DEFAULT 0')
        except sqlite3.OperationalError:
            pass
        try:
            c.execute('ALTER TABLE users ADD COLUMN deleted INTEGER DEFAULT 0')
        except sqlite3.OperationalError:
            pass
        try:
            c.execute('ALTER TABLE sessions ADD COLUMN updated_at INTEGER DEFAULT 0')
        except sqlite3.OperationalError:
            pass
        try:
            c.execute('ALTER TABLE users ADD COLUMN profile TEXT DEFAULT ""')
        except sqlite3.OperationalError:
            pass
        c.execute('''CREATE TABLE IF NOT EXISTS blocked_domains (
            domain TEXT PRIMARY KEY,
            reason TEXT,
            timeout_count INTEGER DEFAULT 0,
            added_at INTEGER)''')
        # Seed default admin user
        if not c.execute('SELECT id FROM users WHERE email=?', ('admin@dmhai.local',)).fetchone():
            uid = secrets.token_hex(8)
            c.execute('INSERT INTO users (id,email,name,password_hash,role,created_at) VALUES (?,?,?,?,?,?)',
                      (uid, 'admin@dmhai.local', None, hash_password('dmhai'), 'admin', int(time.time())))

def parse(row):
    d = dict(zip(['id', 'name', 'model', 'messages', 'context', 'created_at', 'updated_at'], row))
    d['messages'] = json.loads(d['messages'] or '[]')
    d['context'] = json.loads(d['context'] or 'null')
    d['createdAt'] = d.pop('created_at')
    d['updatedAt'] = d.pop('updated_at')
    return d

def parse_multipart(rfile, content_type, content_length):
    data = rfile.read(int(content_length or 0))
    boundary = None
    for part in content_type.split(';'):
        part = part.strip()
        if part.startswith('boundary='):
            boundary = part[9:].strip('"\'')
    if not boundary:
        return {}
    sep = b'--' + boundary.encode()
    result = {}
    for chunk in data.split(sep)[1:]:
        if chunk.strip() == b'--':
            break
        if b'\r\n\r\n' not in chunk:
            continue
        head, body = chunk.split(b'\r\n\r\n', 1)
        if body.endswith(b'\r\n'):
            body = body[:-2]
        name = filename = None
        for line in head.split(b'\r\n'):
            if b'content-disposition' in line.lower():
                for item in line.split(b';'):
                    item = item.strip()
                    if item.startswith(b'name='):
                        name = item[5:].strip(b'"\'').decode('utf-8', errors='replace')
                    elif item.startswith(b'filename='):
                        filename = item[9:].strip(b'"\'').decode('utf-8', errors='replace')
        if name:
            result[name] = {'filename': filename, 'data': body}
    return result
