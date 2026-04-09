#!/usr/bin/env python3
# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

import json, sqlite3
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
from db_utils import DB, init_db, _load_blocked_set
from auth_handlers import AuthMixin
from data_handlers import DataMixin
from proxy_handlers import ProxySearchMixin


class H(AuthMixin, DataMixin, ProxySearchMixin, BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _get_local_endpoint(self):
        with sqlite3.connect(DB) as c:
            row = c.execute('SELECT value FROM settings WHERE key=?', ('admin_cloud_settings',)).fetchone()
        data = json.loads(row[0]) if row else {}
        ep = data.get('ollamaEndpoint', '').rstrip('/')
        return ep if ep else 'http://127.0.0.1:11434'

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

        if self._handle_proxy_get(p):
            return

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

        if self._handle_auth_get(p, user):
            return
        if self._handle_proxy_get_auth(p, user):
            return
        if self._handle_data_get(p, user):
            return

        self.send_json(404, {'error': 'Not found'})

    def do_POST(self):
        p = urlparse(self.path).path

        if self._handle_auth_post(p):
            return

        if self._handle_proxy_post(p):
            return

        user = self.require_auth()
        if not user:
            return

        if self._handle_proxy_post_auth(p, user):
            return
        if self._handle_data_post(p, user):
            return

        self.send_json(404, {'error': 'Not found'})

    def do_PUT(self):
        p = urlparse(self.path).path

        user = self.require_auth()
        if not user:
            return

        if self._handle_auth_put(p, user):
            return
        if self._handle_proxy_put(p, user):
            return
        if self._handle_data_put(p, user):
            return

        self.send_json(404, {'error': 'Not found'})

    def do_DELETE(self):
        p = urlparse(self.path).path
        user = self.require_auth()
        if not user:
            return

        if self._handle_auth_delete(p, user):
            return
        if self._handle_data_delete(p, user):
            return

        self.send_json(404, {'error': 'Not found'})


if __name__ == '__main__':
    init_db()
    _load_blocked_set()
    print('Sessions API on :3000')
    ThreadingHTTPServer(('127.0.0.1', 3000), H).serve_forever()
