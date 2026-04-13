#!/usr/bin/env python3
# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

import base64, json, mimetypes, os, re, shutil, sqlite3, time
from db_utils import DB, ASSETS_DIR, log, parse, parse_multipart, user_asset_dir, IMAGE_EXTS


class DataMixin:

    def _handle_data_get(self, p, user):
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
            return True

        with sqlite3.connect(DB) as c:
            if p == '/sessions':
                rows = c.execute(
                    'SELECT id,name,model,messages,context,created_at,updated_at FROM sessions WHERE user_id=? ORDER BY COALESCE(updated_at,created_at) DESC',
                    (user['id'],)
                ).fetchall()
                result = [parse(r) for r in rows]
                log(f'[SESSIONS] GET user={user["id"]} count={len(result)} ids={[r["id"] for r in result]}')
                self.send_json(200, result)
                return True
            elif p == '/sessions/current':
                key = self.current_session_key(user['id'])
                row = c.execute('SELECT value FROM settings WHERE key=?', (key,)).fetchone()
                self.send_json(200, {'id': row[0] if row else None})
                return True
            else:
                m = re.match(r'^/sessions/([^/]+)$', p)
                if m:
                    row = c.execute(
                        'SELECT id,name,model,messages,context,created_at,updated_at FROM sessions WHERE id=? AND user_id=?',
                        (m.group(1), user['id'])
                    ).fetchone()
                    self.send_json(200 if row else 404, parse(row) if row else {'error': 'Not found'})
                    return True

        m = re.match(r'^/image-descriptions/([^/]+)$', p)
        if m:
            session_id = m.group(1)
            with sqlite3.connect(DB) as c:
                owns = c.execute('SELECT id FROM sessions WHERE id=? AND user_id=?', (session_id, user['id'])).fetchone()
                if not owns:
                    self.send_json(404, {'error': 'Not found'})
                    return True
                rows = c.execute(
                    'SELECT file_id, name, description, created_at FROM image_descriptions WHERE session_id=?',
                    (session_id,)
                ).fetchall()
            self.send_json(200, [{'file_id': r[0], 'name': r[1], 'description': r[2], 'created_at': r[3]} for r in rows])
            return True

        return False

    def _handle_data_post(self, p, user):
        if p == '/log':
            d = self.body()
            log(d.get('msg', ''))
            self.send_json(200, {'ok': True})
            return True

        if p == '/image-descriptions':
            d = self.body()
            session_id = d.get('sessionId', '')
            file_id = d.get('fileId', '')
            description = d.get('description', '').strip()
            if not session_id or not file_id or not description:
                self.send_json(400, {'error': 'Missing fields'})
                return True
            with sqlite3.connect(DB) as c:
                owns = c.execute('SELECT id FROM sessions WHERE id=? AND user_id=?', (session_id, user['id'])).fetchone()
                if not owns:
                    self.send_json(403, {'error': 'Forbidden'})
                    return True
                c.execute(
                    'INSERT OR REPLACE INTO image_descriptions (session_id, file_id, name, description, created_at) VALUES (?,?,?,?,?)',
                    (session_id, file_id, d.get('name', ''), description, int(time.time() * 1000))
                )
            self.send_json(200, {'ok': True})
            return True

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
            return True

        if p == '/assets':
            ctype = self.headers.get('Content-Type', '')
            clen = self.headers.get('Content-Length', '0')
            parts = parse_multipart(self.rfile, ctype, clen)
            if 'file' not in parts:
                self.send_json(400, {'error': 'No file field'})
                return True
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
            return True

        return False

    def _handle_data_put(self, p, user):
        d = self.body()
        with sqlite3.connect(DB) as c:
            if p == '/sessions/current':
                key = self.current_session_key(user['id'])
                c.execute('INSERT OR REPLACE INTO settings (key,value) VALUES (?,?)', (key, d['id']))
                self.send_json(200, d)
                return True
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
                    return True

        return False

    def _handle_data_delete(self, p, user):
        m = re.match(r'^/sessions/([^/]+)$', p)
        if m:
            session_id = m.group(1)
            with sqlite3.connect(DB) as c:
                c.execute('DELETE FROM sessions WHERE id=? AND user_id=?', (session_id, user['id']))
                c.execute('DELETE FROM image_descriptions WHERE session_id=?', (session_id,))
            session_dir = user_asset_dir(user['email'], session_id)
            if os.path.isdir(session_dir):
                shutil.rmtree(session_dir, ignore_errors=True)
            self.send_json(200, {'ok': True})
            return True

        m = re.match(r'^/image-descriptions/([^/]+)$', p)
        if m:
            session_id = m.group(1)
            with sqlite3.connect(DB) as c:
                owns = c.execute('SELECT id FROM sessions WHERE id=? AND user_id=?', (session_id, user['id'])).fetchone()
                if not owns:
                    self.send_json(404, {'error': 'Not found'})
                    return True
                c.execute('DELETE FROM image_descriptions WHERE session_id=?', (session_id,))
            self.send_json(200, {'ok': True})
            return True

        return False
