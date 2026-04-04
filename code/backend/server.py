#!/usr/bin/env python3
import base64, hashlib, json, mimetypes, os, re, secrets, shutil, sqlite3, time, urllib.request, urllib.parse
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

DB = '/data/db/chat.db'
ASSETS_DIR = '/data/user_assets'
LOG_FILE = '/data/system_logs/system.log'

def log(msg):
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    ts = time.strftime('%Y-%m-%d %H:%M:%S')
    line = f'[{ts}] {msg}\n'
    with open(LOG_FILE, 'a') as f:
        f.write(line)

IMAGE_EXTS = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp'}

def hash_password(password):
    salt = secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac('sha256', password.encode(), salt.encode(), 100000).hex()
    return f'{salt}:{h}'

def verify_password(password, stored):
    try:
        salt, h = stored.split(':', 1)
        return hashlib.pbkdf2_hmac('sha256', password.encode(), salt.encode(), 100000).hex() == h
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

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send_json(self, code, data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(body))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = int(self.headers.get('Content-Length', 0))
        return json.loads(self.rfile.read(n)) if n else {}

    def get_auth_user(self):
        auth = self.headers.get('Authorization', '')
        if not auth.startswith('Bearer '):
            return None
        token = auth[7:].strip()
        with sqlite3.connect(DB) as c:
            row = c.execute(
                'SELECT u.id, u.email, u.name, u.role, u.password_changed FROM auth_tokens t JOIN users u ON t.user_id=u.id WHERE t.token=? AND u.deleted=0',
                (token,)
            ).fetchone()
        if row:
            return {'id': row[0], 'email': row[1], 'name': row[2] or row[1].split('@')[0], 'role': row[3], 'passwordChanged': bool(row[4])}
        return None

    def require_auth(self):
        user = self.get_auth_user()
        if not user:
            self.send_json(401, {'error': 'Unauthorized'})
        return user

    def current_session_key(self, user_id):
        return f'current_session_{user_id}'

    def do_GET(self):
        p = urlparse(self.path).path

        if p == '/auth/me':
            user = self.get_auth_user()
            if not user:
                self.send_json(401, {'error': 'Unauthorized'})
                return
            self.send_json(200, user)
            return

        user = self.require_auth()
        if not user:
            return

        if p == '/users':
            if user['role'] != 'admin':
                self.send_json(403, {'error': 'Forbidden'})
                return
            with sqlite3.connect(DB) as c:
                rows = c.execute('SELECT id, email, name, role, created_at FROM users WHERE deleted=0 ORDER BY created_at').fetchall()
            self.send_json(200, [{'id': r[0], 'email': r[1], 'name': r[2], 'role': r[3], 'createdAt': r[4]} for r in rows])
            return

        if p == '/users/prefs':
            with sqlite3.connect(DB) as c:
                row = c.execute('SELECT value FROM settings WHERE key=?', (f'prefs_{user["id"]}',)).fetchone()
            prefs = json.loads(row[0]) if row else {}
            self.send_json(200, prefs)
            return

        if p == '/search':
            qs = urllib.parse.parse_qs(urlparse(self.path).query)
            q = qs.get('q', [''])[0]
            engine = qs.get('engine', [''])[0]
            if not q or not engine:
                self.send_json(400, {'error': 'Missing q or engine'})
                return
            try:
                search_url = engine.rstrip('/') + '/search?' + urllib.parse.urlencode({
                    'q': q, 'format': 'json', 'categories': 'general', 'language': 'en'
                })
                log(f'[SEARCH] query="{q}" url={search_url}')
                req = urllib.request.Request(search_url, headers={'User-Agent': 'Mozilla/5.0'})
                with urllib.request.urlopen(req, timeout=10) as resp:
                    data = json.loads(resp.read())
                results = [{'title': r.get('title',''), 'url': r.get('url',''), 'content': r.get('content','')}
                           for r in data.get('results', [])[:8]]
                log(f'[SEARCH] returned {len(results)} results: {[r["url"] for r in results]}')
                self.send_json(200, {'results': results})
            except Exception as e:
                log(f'[SEARCH] ERROR: {e}')
                self.send_json(500, {'error': str(e)})
            return

        m = re.match(r'^/assets/([^/]+)/([^/]+)$', p)
        if m:
            session_id, file_id = m.group(1), m.group(2)
            session_dir = user_asset_dir(user['email'], session_id)
            file_path = os.path.realpath(os.path.join(session_dir, file_id))
            if file_path.startswith(os.path.realpath(ASSETS_DIR)) and os.path.isfile(file_path):
                mime = mimetypes.guess_type(file_path)[0] or 'application/octet-stream'
                display_name = re.sub(r'^\d+_', '', file_id)
                with open(file_path, 'rb') as f:
                    data = f.read()
                self.send_response(200)
                self.send_header('Content-Type', mime)
                self.send_header('Content-Length', len(data))
                self.send_header('Content-Disposition', 'attachment; filename="' + display_name + '"')
                self.end_headers()
                self.wfile.write(data)
            else:
                self.send_json(404, {'error': 'Not found'})
            return

        with sqlite3.connect(DB) as c:
            if p == '/sessions':
                rows = c.execute(
                    'SELECT id,name,model,messages,context,created_at,updated_at FROM sessions WHERE user_id=? ORDER BY COALESCE(updated_at,created_at) DESC',
                    (user['id'],)
                ).fetchall()
                self.send_json(200, [parse(r) for r in rows])
            elif p == '/sessions/current':
                key = self.current_session_key(user['id'])
                row = c.execute('SELECT value FROM settings WHERE key=?', (key,)).fetchone()
                self.send_json(200, {'id': row[0] if row else None})
            else:
                m = re.match(r'^/sessions/([^/]+)$', p)
                if m:
                    row = c.execute(
                        'SELECT id,name,model,messages,context,created_at,updated_at FROM sessions WHERE id=? AND user_id=?',
                        (m.group(1), user['id'])
                    ).fetchone()
                    self.send_json(200 if row else 404, parse(row) if row else {'error': 'Not found'})
                else:
                    self.send_json(404, {'error': 'Not found'})

    def do_POST(self):
        p = urlparse(self.path).path

        if p == '/auth/login':
            d = self.body()
            email = (d.get('email') or '').strip().lower()
            password = d.get('password') or ''
            with sqlite3.connect(DB) as c:
                row = c.execute('SELECT id, email, name, role, password_hash, password_changed FROM users WHERE email=? AND deleted=0', (email,)).fetchone()
            if not row or not verify_password(password, row[4]):
                self.send_json(401, {'error': 'Invalid username or password'})
                return
            token = secrets.token_hex(32)
            with sqlite3.connect(DB) as c:
                c.execute('INSERT INTO auth_tokens (token, user_id, created_at) VALUES (?,?,?)',
                          (token, row[0], int(time.time())))
            display = row[2] or row[1].split('@')[0]
            self.send_json(200, {'token': token, 'user': {'id': row[0], 'email': row[1], 'name': display, 'role': row[3], 'passwordChanged': bool(row[5])}})
            return

        if p == '/auth/logout':
            auth = self.headers.get('Authorization', '')
            if auth.startswith('Bearer '):
                token = auth[7:].strip()
                with sqlite3.connect(DB) as c:
                    c.execute('DELETE FROM auth_tokens WHERE token=?', (token,))
            self.send_json(200, {'ok': True})
            return

        user = self.require_auth()
        if not user:
            return

        if p == '/users':
            if user['role'] != 'admin':
                self.send_json(403, {'error': 'Forbidden'})
                return
            d = self.body()
            email = (d.get('email') or '').strip().lower()
            name = (d.get('name') or '').strip() or None
            password = d.get('password') or ''
            role = d.get('role') or 'user'
            if not email or not password:
                self.send_json(400, {'error': 'Email and password are required'})
                return
            with sqlite3.connect(DB) as c:
                existing = c.execute('SELECT id, deleted FROM users WHERE email=?', (email,)).fetchone()
                if existing:
                    if existing[1] == 1:
                        # Reactivate soft-deleted user
                        c.execute(
                            'UPDATE users SET name=?, password_hash=?, role=?, deleted=0, password_changed=0 WHERE id=?',
                            (name, hash_password(password), role, existing[0])
                        )
                        self.send_json(200, {'id': existing[0], 'email': email, 'name': name, 'role': role})
                    else:
                        self.send_json(409, {'error': 'Email already exists'})
                    return
                uid = secrets.token_hex(8)
                c.execute('INSERT INTO users (id,email,name,password_hash,role,created_at) VALUES (?,?,?,?,?,?)',
                          (uid, email, name, hash_password(password), role, int(time.time())))
            self.send_json(200, {'id': uid, 'email': email, 'name': name, 'role': role})
            return

        if p == '/log':
            d = self.body()
            log(d.get('msg', ''))
            self.send_json(200, {'ok': True})
            return

        if p == '/sessions':
            d = self.body()
            with sqlite3.connect(DB) as c:
                now = int(time.time() * 1000)
                c.execute(
                    'INSERT INTO sessions (id,name,model,messages,context,created_at,updated_at,user_id) VALUES (?,?,?,?,?,?,?,?)',
                    (d['id'], d['name'], d.get('model', ''),
                     json.dumps(d.get('messages', [])),
                     json.dumps(d.get('context')),
                     d['createdAt'], now, user['id'])
                )
            self.send_json(200, d)
        elif p == '/assets':
            ctype = self.headers.get('Content-Type', '')
            clen = self.headers.get('Content-Length', '0')
            parts = parse_multipart(self.rfile, ctype, clen)
            if 'file' not in parts:
                self.send_json(400, {'error': 'No file field'})
                return
            item = parts['file']
            filename = item['filename'] or 'upload'
            raw = item['data']
            session_id = parts.get('sessionId', {}).get('data', b'default').decode('utf-8', errors='replace')
            ext = os.path.splitext(filename)[1].lower()
            session_dir = user_asset_dir(user['email'], session_id)
            os.makedirs(session_dir, exist_ok=True)
            safe_name = str(int(time.time() * 1000)) + '_' + re.sub(r'[^\w.\-]', '_', filename)
            with open(os.path.join(session_dir, safe_name), 'wb') as f:
                f.write(raw)
            result = {'id': safe_name, 'name': filename, 'size': len(raw)}
            if ext in IMAGE_EXTS:
                mime = mimetypes.guess_type(filename)[0] or 'image/png'
                result['type'] = 'image'
                result['mime'] = mime
                result['base64'] = base64.b64encode(raw).decode()
            else:
                result['type'] = 'text'
                try:
                    result['content'] = raw.decode('utf-8')
                except Exception:
                    result['content'] = raw.decode('latin-1')
            self.send_json(200, result)
        else:
            self.send_json(404, {'error': 'Not found'})

    def do_PUT(self):
        p = urlparse(self.path).path

        if p == '/auth/password':
            user = self.require_auth()
            if not user:
                return
            d = self.body()
            current = d.get('current') or ''
            new_pw = d.get('new') or ''
            if not new_pw:
                self.send_json(400, {'error': 'New password required'})
                return
            with sqlite3.connect(DB) as c:
                row = c.execute('SELECT password_hash FROM users WHERE id=?', (user['id'],)).fetchone()
            if not row or not verify_password(current, row[0]):
                self.send_json(401, {'error': 'Current password is incorrect'})
                return
            with sqlite3.connect(DB) as c:
                c.execute('UPDATE users SET password_hash=?, password_changed=1 WHERE id=?', (hash_password(new_pw), user['id']))
            self.send_json(200, {'ok': True})
            return

        if p == '/users/prefs':
            user = self.require_auth()
            if not user:
                return
            d = self.body()
            key = f'prefs_{user["id"]}'
            with sqlite3.connect(DB) as c:
                row = c.execute('SELECT value FROM settings WHERE key=?', (key,)).fetchone()
                prefs = json.loads(row[0]) if row else {}
                prefs.update({k: v for k, v in d.items() if k in ('lang', 'model')})
                c.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?,?)', (key, json.dumps(prefs)))
            self.send_json(200, prefs)
            return

        m_user = re.match(r'^/users/([^/]+)$', p)
        if m_user:
            user = self.require_auth()
            if not user:
                return
            if user['role'] != 'admin':
                self.send_json(403, {'error': 'Forbidden'})
                return
            d = self.body()
            uid = m_user.group(1)
            name = (d.get('name') or '').strip() or None
            role = d.get('role') or 'user'
            with sqlite3.connect(DB) as c:
                c.execute('UPDATE users SET name=?, role=? WHERE id=?', (name, role, uid))
                if d.get('password'):
                    c.execute('UPDATE users SET password_hash=? WHERE id=?', (hash_password(d['password']), uid))
            self.send_json(200, {'ok': True})
            return

        user = self.require_auth()
        if not user:
            return
        d = self.body()
        with sqlite3.connect(DB) as c:
            if p == '/sessions/current':
                key = self.current_session_key(user['id'])
                c.execute('INSERT OR REPLACE INTO settings (key,value) VALUES (?,?)', (key, d['id']))
                self.send_json(200, d)
            else:
                m = re.match(r'^/sessions/([^/]+)$', p)
                if m:
                    now = int(time.time() * 1000)
                    c.execute(
                        'UPDATE sessions SET name=?,model=?,messages=?,context=?,updated_at=? WHERE id=? AND user_id=?',
                        (d['name'], d.get('model', ''),
                         json.dumps(d.get('messages', [])),
                         json.dumps(d.get('context')),
                         now, m.group(1), user['id'])
                    )
                    self.send_json(200, d)
                else:
                    self.send_json(404, {'error': 'Not found'})

    def do_DELETE(self):
        p = urlparse(self.path).path
        user = self.require_auth()
        if not user:
            return

        m_user = re.match(r'^/users/([^/]+)$', p)
        if m_user:
            if user['role'] != 'admin':
                self.send_json(403, {'error': 'Forbidden'})
                return
            uid = m_user.group(1)
            if uid == user['id']:
                self.send_json(400, {'error': 'Cannot delete your own account'})
                return
            with sqlite3.connect(DB) as c:
                c.execute('UPDATE users SET deleted=1 WHERE id=?', (uid,))
                c.execute('DELETE FROM auth_tokens WHERE user_id=?', (uid,))
            self.send_json(200, {'ok': True})
            return

        m = re.match(r'^/sessions/([^/]+)$', p)
        if m:
            session_id = m.group(1)
            with sqlite3.connect(DB) as c:
                c.execute('DELETE FROM sessions WHERE id=? AND user_id=?', (session_id, user['id']))
            session_dir = user_asset_dir(user['email'], session_id)
            if os.path.isdir(session_dir):
                shutil.rmtree(session_dir, ignore_errors=True)
            self.send_json(200, {'ok': True})
        else:
            self.send_json(404, {'error': 'Not found'})

if __name__ == '__main__':
    init_db()
    print('Sessions API on :3000')
    ThreadingHTTPServer(('127.0.0.1', 3000), H).serve_forever()
