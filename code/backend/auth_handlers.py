#!/usr/bin/env python3
# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

import json, re, secrets, sqlite3, time
from db_utils import DB, log, hash_password, verify_password


class AuthMixin:

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

    def _handle_auth_get(self, p, user):
        if p == '/users':
            if user['role'] != 'admin':
                self.send_json(403, {'error': 'Forbidden'})
                return True
            with sqlite3.connect(DB) as c:
                rows = c.execute('SELECT id, email, name, role, created_at FROM users WHERE deleted=0 ORDER BY created_at').fetchall()
            self.send_json(200, [{'id': r[0], 'email': r[1], 'name': r[2], 'role': r[3], 'createdAt': r[4]} for r in rows])
            return True

        if p == '/user/profile':
            with sqlite3.connect(DB) as c:
                row = c.execute('SELECT profile FROM users WHERE id=?', (user['id'],)).fetchone()
            self.send_json(200, {'profile': (row[0] or '') if row else ''})
            return True

        if p == '/users/prefs':
            with sqlite3.connect(DB) as c:
                row = c.execute('SELECT value FROM settings WHERE key=?', (f'prefs_{user["id"]}',)).fetchone()
            prefs = json.loads(row[0]) if row else {}
            self.send_json(200, prefs)
            return True

        return False

    def _handle_auth_post(self, p):
        if p == '/auth/login':
            d = self.body()
            email = (d.get('email') or '').strip().lower()
            password = d.get('password') or ''
            with sqlite3.connect(DB) as c:
                row = c.execute('SELECT id, email, name, role, password_hash, password_changed FROM users WHERE email=? AND deleted=0', (email,)).fetchone()
            if not row or not verify_password(password, row[4]):
                self.send_json(401, {'error': 'Invalid username or password'})
                return True
            token = secrets.token_hex(32)
            with sqlite3.connect(DB) as c:
                c.execute('INSERT INTO auth_tokens (token, user_id, created_at) VALUES (?,?,?)',
                          (token, row[0], int(time.time())))
            display = row[2] or row[1].split('@')[0]
            self.send_json(200, {'token': token, 'user': {'id': row[0], 'email': row[1], 'name': display, 'role': row[3], 'passwordChanged': bool(row[5])}})
            return True

        if p == '/auth/logout':
            auth = self.headers.get('Authorization', '')
            if auth.startswith('Bearer '):
                token = auth[7:].strip()
                with sqlite3.connect(DB) as c:
                    c.execute('DELETE FROM auth_tokens WHERE token=?', (token,))
            self.send_json(200, {'ok': True})
            return True

        if p == '/users':
            user = self.get_auth_user()
            if not user:
                self.send_json(401, {'error': 'Unauthorized'})
                return True
            if user['role'] != 'admin':
                self.send_json(403, {'error': 'Forbidden'})
                return True
            d = self.body()
            email = (d.get('email') or '').strip().lower()
            name = (d.get('name') or '').strip() or None
            password = d.get('password') or ''
            role = d.get('role') or 'user'
            if not email or not password:
                self.send_json(400, {'error': 'Email and password are required'})
                return True
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
                    return True
                uid = secrets.token_hex(8)
                c.execute('INSERT INTO users (id,email,name,password_hash,role,created_at) VALUES (?,?,?,?,?,?)',
                          (uid, email, name, hash_password(password), role, int(time.time())))
            self.send_json(200, {'id': uid, 'email': email, 'name': name, 'role': role})
            return True

        return False

    def _handle_auth_put(self, p, user):
        if p == '/auth/password':
            d = self.body()
            current = d.get('current') or ''
            new_pw = d.get('new') or ''
            if not new_pw:
                self.send_json(400, {'error': 'New password required'})
                return True
            with sqlite3.connect(DB) as c:
                row = c.execute('SELECT password_hash FROM users WHERE id=?', (user['id'],)).fetchone()
            if not row or not verify_password(current, row[0]):
                self.send_json(401, {'error': 'Current password is incorrect'})
                return True
            with sqlite3.connect(DB) as c:
                c.execute('UPDATE users SET password_hash=?, password_changed=1 WHERE id=?', (hash_password(new_pw), user['id']))
            self.send_json(200, {'ok': True})
            return True

        if p == '/user/profile':
            d = self.body()
            profile = str(d.get('profile', ''))[:4000]
            with sqlite3.connect(DB) as c:
                c.execute('UPDATE users SET profile=? WHERE id=?', (profile, user['id']))
            self.send_json(200, {'ok': True})
            return True

        if p == '/users/prefs':
            d = self.body()
            key = f'prefs_{user["id"]}'
            with sqlite3.connect(DB) as c:
                row = c.execute('SELECT value FROM settings WHERE key=?', (key,)).fetchone()
                prefs = json.loads(row[0]) if row else {}
                prefs.update({k: v for k, v in d.items() if k in ('lang', 'model')})
                c.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?,?)', (key, json.dumps(prefs)))
            self.send_json(200, prefs)
            return True

        m_user = re.match(r'^/users/([^/]+)$', p)
        if m_user:
            if user['role'] != 'admin':
                self.send_json(403, {'error': 'Forbidden'})
                return True
            d = self.body()
            uid = m_user.group(1)
            with sqlite3.connect(DB) as c:
                if 'name' in d or 'role' in d:
                    name = (d.get('name') or '').strip() or None
                    role = d.get('role') or 'user'
                    c.execute('UPDATE users SET name=?, role=? WHERE id=?', (name, role, uid))
                if d.get('password'):
                    c.execute('UPDATE users SET password_hash=?, password_changed=1 WHERE id=?', (hash_password(d['password']), uid))
            self.send_json(200, {'ok': True})
            return True

        return False

    def _handle_auth_delete(self, p, user):
        m_user = re.match(r'^/users/([^/]+)$', p)
        if m_user:
            if user['role'] != 'admin':
                self.send_json(403, {'error': 'Forbidden'})
                return True
            uid = m_user.group(1)
            if uid == user['id']:
                self.send_json(400, {'error': 'Cannot delete your own account'})
                return True
            with sqlite3.connect(DB) as c:
                c.execute('UPDATE users SET deleted=1 WHERE id=?', (uid,))
                c.execute('DELETE FROM auth_tokens WHERE user_id=?', (uid,))
            self.send_json(200, {'ok': True})
            return True

        return False
