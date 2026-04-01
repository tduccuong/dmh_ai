#!/usr/bin/env python3
import base64, json, mimetypes, os, re, shutil, sqlite3, time, urllib.request, urllib.parse
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

def parse(row):
    d = dict(zip(['id', 'name', 'model', 'messages', 'context', 'created_at'], row))
    d['messages'] = json.loads(d['messages'] or '[]')
    d['context'] = json.loads(d['context'] or 'null')
    d['createdAt'] = d.pop('created_at')
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

    def do_GET(self):
        p = urlparse(self.path).path
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
        with sqlite3.connect(DB) as c:
            if p == '/sessions':
                rows = c.execute(
                    'SELECT id,name,model,messages,context,created_at FROM sessions ORDER BY created_at'
                ).fetchall()
                self.send_json(200, [parse(r) for r in rows])
            elif p == '/sessions/current':
                row = c.execute('SELECT value FROM settings WHERE key=?', ('current_session',)).fetchone()
                self.send_json(200, {'id': row[0] if row else None})
            else:
                m = re.match(r'^/sessions/([^/]+)$', p)
                if m:
                    row = c.execute(
                        'SELECT id,name,model,messages,context,created_at FROM sessions WHERE id=?',
                        (m.group(1),)
                    ).fetchone()
                    self.send_json(200 if row else 404, parse(row) if row else {'error': 'Not found'})
                else:
                    self.send_json(404, {'error': 'Not found'})

    def do_POST(self):
        p = urlparse(self.path).path
        if p == '/log':
            d = self.body()
            log(d.get('msg', ''))
            self.send_json(200, {'ok': True})
            return
        if p == '/sessions':
            d = self.body()
            with sqlite3.connect(DB) as c:
                c.execute(
                    'INSERT INTO sessions (id,name,model,messages,context,created_at) VALUES (?,?,?,?,?,?)',
                    (d['id'], d['name'], d.get('model', ''),
                     json.dumps(d.get('messages', [])),
                     json.dumps(d.get('context')),
                     d['createdAt'])
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
            session_dir = os.path.join(ASSETS_DIR, re.sub(r'[^\w\-]', '_', session_id))
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
        d = self.body()
        with sqlite3.connect(DB) as c:
            if p == '/sessions/current':
                c.execute('INSERT OR REPLACE INTO settings (key,value) VALUES (?,?)',
                          ('current_session', d['id']))
                self.send_json(200, d)
            else:
                m = re.match(r'^/sessions/([^/]+)$', p)
                if m:
                    c.execute(
                        'UPDATE sessions SET name=?,model=?,messages=?,context=? WHERE id=?',
                        (d['name'], d.get('model', ''),
                         json.dumps(d.get('messages', [])),
                         json.dumps(d.get('context')),
                         m.group(1))
                    )
                    self.send_json(200, d)
                else:
                    self.send_json(404, {'error': 'Not found'})

    def do_DELETE(self):
        p = urlparse(self.path).path
        m = re.match(r'^/sessions/([^/]+)$', p)
        if m:
            session_id = m.group(1)
            with sqlite3.connect(DB) as c:
                c.execute('DELETE FROM sessions WHERE id=?', (session_id,))
            session_dir = os.path.join(ASSETS_DIR, re.sub(r'[^\w\-]', '_', session_id))
            if os.path.isdir(session_dir):
                shutil.rmtree(session_dir, ignore_errors=True)
            self.send_json(200, {'ok': True})
        else:
            self.send_json(404, {'error': 'Not found'})

if __name__ == '__main__':
    init_db()
    print('Sessions API on :3000')
    ThreadingHTTPServer(('127.0.0.1', 3000), H).serve_forever()
