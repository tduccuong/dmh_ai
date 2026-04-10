#!/usr/bin/env python3
# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

import http.client, json, re, socket, sqlite3, ssl, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import urlparse
from constants import (
    SEARCH_PAGE2_THRESHOLD, MAX_PAGE_CHARS, MIN_USEFUL_PAGE_CHARS,
    DIRECT_FETCH_SIZE_BYTES, JINA_FETCH_SIZE_BYTES,
    OLLAMA_API_TIMEOUT_SECS, ENDPOINT_TEST_TIMEOUT_SECS, REGISTRY_TIMEOUT_SECS,
    SEARXNG_TIMEOUT_SECS, DIRECT_FETCH_TIMEOUT_SECS, JINA_TIMEOUT_SECS,
)
from db_utils import DB, log, _html_to_text, is_domain_blocked, _record_fetch_timeout


class ProxySearchMixin:

    def _handle_proxy_get(self, p):
        if p.startswith('/local-api/'):
            sub = p[len('/local-api/'):]
            endpoint = self._get_local_endpoint()
            parsed = urlparse(endpoint)
            host = parsed.hostname
            port = parsed.port or (443 if parsed.scheme == 'https' else 80)
            try:
                ConnClass = http.client.HTTPSConnection if parsed.scheme == 'https' else http.client.HTTPConnection
                conn = ConnClass(host, port, timeout=OLLAMA_API_TIMEOUT_SECS)
                conn.request('GET', '/api/' + sub)
                resp = conn.getresponse()
                body = resp.read()
                conn.close()
                self.send_response(resp.status)
                self.send_header('Content-Type', resp.getheader('Content-Type', 'application/json'))
                self.send_header('Content-Length', len(body))
                self.end_headers()
                self.wfile.write(body)
            except Exception as e:
                self.send_json(500, {'error': str(e)})
            return True

        return False

    def _handle_proxy_get_auth(self, p, user):
        if p == '/admin/settings':
            with sqlite3.connect(DB) as c:
                row = c.execute('SELECT value FROM settings WHERE key=?', ('admin_cloud_settings',)).fetchone()
            data = json.loads(row[0]) if row else {}
            self.send_json(200, data)
            return True

        if p == '/model-labels':
            with sqlite3.connect(DB) as c:
                row = c.execute('SELECT value FROM settings WHERE key=?', ('admin_cloud_settings',)).fetchone()
            data = json.loads(row[0]) if row else {}
            self.send_json(200, {'modelLabels': data.get('modelLabels', {})})
            return True

        if p == '/admin/test-endpoint':
            if user['role'] != 'admin':
                self.send_json(403, {'error': 'Forbidden'})
                return True
            qs = urllib.parse.parse_qs(urlparse(self.path).query)
            url = (qs.get('url', [''])[0] or '').strip().rstrip('/')
            if not url:
                self.send_json(400, {'error': 'Missing url'})
                return True
            parsed = urlparse(url)
            host = parsed.hostname
            port = parsed.port or (443 if parsed.scheme == 'https' else 80)
            try:
                ConnClass = http.client.HTTPSConnection if parsed.scheme == 'https' else http.client.HTTPConnection
                conn = ConnClass(host, port, timeout=ENDPOINT_TEST_TIMEOUT_SECS)
                conn.request('GET', '/api/tags')
                resp = conn.getresponse()
                body = resp.read()
                conn.close()
                if resp.status != 200:
                    self.send_json(502, {'error': 'Ollama returned ' + str(resp.status)})
                    return True
                self.send_json(200, json.loads(body))
            except Exception as e:
                self.send_json(502, {'error': str(e)})
            return True

        if p.startswith('/cloud-api/'):
            cloud_key = self.headers.get('X-Cloud-Key', '').strip()
            sub = p[len('/cloud-api/'):]
            try:
                ctx = ssl.create_default_context()
                conn = http.client.HTTPSConnection('ollama.com', context=ctx, timeout=OLLAMA_API_TIMEOUT_SECS)
                conn.request('GET', '/api/' + sub, headers={'Authorization': 'Bearer ' + cloud_key})
                resp = conn.getresponse()
                body = resp.read()
                conn.close()
                self.send_response(resp.status)
                self.send_header('Content-Type', resp.getheader('Content-Type', 'application/json'))
                self.send_header('Content-Length', len(body))
                self.end_headers()
                self.wfile.write(body)
            except Exception as e:
                self.send_json(500, {'error': str(e)})
            return True

        if p == '/registry':
            qs = urllib.parse.parse_qs(urlparse(self.path).query)
            q = qs.get('q', [''])[0].strip()
            if not q:
                self.send_json(200, {'models': []})
                return True
            try:
                # Stage 1: search for model names on ollama.com
                _ua = 'Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0'
                url = 'https://ollama.com/search?' + urllib.parse.urlencode({'q': q})
                req = urllib.request.Request(url, headers={'User-Agent': _ua, 'Accept': 'text/html'})
                with urllib.request.urlopen(req, timeout=REGISTRY_TIMEOUT_SECS) as resp:
                    body = resp.read().decode('utf-8', errors='replace')
                model_names = []
                seen_names = set()
                for name in re.findall(r'href=["\'](?:https://ollama\.com)?/library/([\w][\w.-]{0,60})["\']', body):
                    if name not in seen_names:
                        seen_names.add(name)
                        model_names.append(name)

                # Stage 2: fetch each model page in parallel, extract cloud tags only
                def get_cloud_tags(model_name):
                    try:
                        murl = 'https://ollama.com/library/' + model_name
                        mreq = urllib.request.Request(murl, headers={'User-Agent': _ua, 'Accept': 'text/html'})
                        with urllib.request.urlopen(mreq, timeout=REGISTRY_TIMEOUT_SECS) as r:
                            mb = r.read().decode('utf-8', errors='replace')
                        tags = set()
                        # href="/library/model:tag" patterns that contain "cloud"
                        for tag in re.findall(
                            r'/library/' + re.escape(model_name) + r':([\w][^"\'>\s]{0,60})',
                            mb
                        ):
                            if 'cloud' in tag:
                                tags.add(tag)
                        # Any quoted token matching *cloud* that looks like a valid tag
                        if not tags:
                            for tag in re.findall(r'["\']([a-z0-9][a-z0-9._-]*cloud[a-z0-9._-]*)["\']', mb):
                                if re.match(r'^[\w.-]+$', tag) and len(tag) <= 60:
                                    tags.add(tag)
                        return [model_name + ':' + t for t in sorted(tags)]
                    except Exception:
                        return []

                cloud_results = []
                with ThreadPoolExecutor(max_workers=6) as ex:
                    for tags in ex.map(get_cloud_tags, model_names[:8], timeout=REGISTRY_TIMEOUT_SECS):
                        cloud_results.extend(tags)

                self.send_json(200, {'models': [{'name': m} for m in cloud_results[:20]]})
            except Exception as e:
                log(f'[REGISTRY] ERROR: {e}')
                self.send_json(500, {'error': str(e)})
            return True

        if p == '/search':
            qs = urllib.parse.parse_qs(urlparse(self.path).query)
            q = qs.get('q', [''])[0]
            engine = qs.get('engine', [''])[0]
            lang = qs.get('lang', ['auto'])[0] or 'auto'
            if not q or not engine:
                self.send_json(400, {'error': 'Missing q or engine'})
                return True
            try:
                def _fetch_page(pageno):
                    params = {'q': q, 'format': 'json', 'categories': 'general', 'language': lang, 'pageno': pageno}
                    url = engine.rstrip('/') + '/search?' + urllib.parse.urlencode(params)
                    try:
                        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
                        with urllib.request.urlopen(req, timeout=SEARXNG_TIMEOUT_SECS) as resp:
                            return json.loads(resp.read()).get('results', [])
                    except Exception:
                        return []
                log(f'[SEARCH] query="{q}" engine={engine}')
                page1 = _fetch_page(1)
                unblocked_count = sum(1 for r in page1 if not is_domain_blocked(r.get('url', '')))
                page2 = _fetch_page(2) if unblocked_count < SEARCH_PAGE2_THRESHOLD else []
                seen_urls = set()
                all_results = []
                for page in [page1, page2]:
                    for r in page:
                        u = r.get('url', '')
                        if u not in seen_urls:
                            seen_urls.add(u)
                            all_results.append(r)
                # Keep all results — blocked domains still contribute their SearXNG snippet.
                # The frontend skips fetching their full pages via enrichResults.
                results = [{'title': r.get('title',''), 'url': r.get('url',''), 'content': r.get('content','')}
                           for r in all_results][:10]
                log(f'[SEARCH] pool={len(all_results)} returned {len(results)} results: {[r["url"] for r in results]}')
                self.send_json(200, {'results': results})
            except Exception as e:
                log(f'[SEARCH] ERROR: {e}')
                self.send_json(500, {'error': str(e)})
            return True

        if p == '/fetch-page':
            qs = urllib.parse.parse_qs(urlparse(self.path).query)
            url = qs.get('url', [''])[0]
            if not url:
                self.send_json(400, {'error': 'Missing url'})
                return True
            text = ''
            try:
                ua = 'Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0'
                req = urllib.request.Request(url, headers={'User-Agent': ua, 'Accept': 'text/html,text/plain'})
                with urllib.request.urlopen(req, timeout=DIRECT_FETCH_TIMEOUT_SECS) as resp:
                    ct = resp.headers.get('Content-Type', '')
                    if 'html' not in ct and 'text/plain' not in ct:
                        log(f'[FETCH-PAGE] skip non-html: {url[:80]} ct={ct}')
                    else:
                        body = resp.read(DIRECT_FETCH_SIZE_BYTES)
                        text = _html_to_text(body)
                        log(f'[FETCH-PAGE] direct ok url={url[:80]} chars={len(text)}')
            except Exception as e:
                log(f'[FETCH-PAGE] direct err url={url[:80]} err={e}')
                if isinstance(e, (socket.timeout, TimeoutError)) or 'timed out' in str(e).lower():
                    _record_fetch_timeout(url)
            # Fallback to Jina Reader for JS-rendered pages
            if len(text) < MIN_USEFUL_PAGE_CHARS:
                try:
                    jina_req = urllib.request.Request(
                        'https://r.jina.ai/' + url,
                        headers={'User-Agent': 'Mozilla/5.0', 'Accept': 'text/plain', 'X-No-Cache': 'true'}
                    )
                    with urllib.request.urlopen(jina_req, timeout=JINA_TIMEOUT_SECS) as resp:
                        jina_text = resp.read(JINA_FETCH_SIZE_BYTES).decode('utf-8', errors='replace')
                        if len(jina_text) >= MIN_USEFUL_PAGE_CHARS:
                            jina_text = re.sub(r'(\d)([A-Za-z])', r'\1 \2', jina_text)
                            jina_text = re.sub(r'([A-Za-z])(\d)', r'\1 \2', jina_text)
                            jina_text = re.sub(r'([a-z])([A-Z])', r'\1 \2', jina_text)
                            text = jina_text
                            log(f'[FETCH-PAGE] jina ok url={url[:80]} chars={len(text)}')
                        else:
                            log(f'[FETCH-PAGE] jina empty url={url[:80]} chars={len(jina_text)}')
                except Exception as e:
                    log(f'[FETCH-PAGE] jina err url={url[:80]} err={e}')
                    if isinstance(e, (socket.timeout, TimeoutError)) or 'timed out' in str(e).lower():
                        _record_fetch_timeout(url)
            self.send_json(200, {'text': text[:MAX_PAGE_CHARS]})
            return True

        return False

    def _handle_proxy_post(self, p):
        if p.startswith('/local-api/'):
            sub = p[len('/local-api/'):]
            endpoint = self._get_local_endpoint()
            parsed = urlparse(endpoint)
            host = parsed.hostname
            port = parsed.port or (443 if parsed.scheme == 'https' else 80)
            content_len = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_len) if content_len else b''
            try:
                ConnClass = http.client.HTTPSConnection if parsed.scheme == 'https' else http.client.HTTPConnection
                conn = ConnClass(host, port, timeout=None)
                conn.request('POST', '/api/' + sub, body=body, headers={
                    'Content-Type': 'application/json',
                })
                resp = conn.getresponse()
                self.send_response(resp.status)
                self.send_header('Content-Type', resp.getheader('Content-Type', 'application/x-ndjson'))
                self.end_headers()
                try:
                    while True:
                        chunk = resp.read(4096)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, socket.timeout):
                    pass
                finally:
                    conn.close()
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as e:
                log(f'[LOCAL-API] ERROR: {e}')
                try:
                    self.send_json(500, {'error': str(e)})
                except Exception:
                    pass
            return True

        return False

    def _handle_proxy_post_auth(self, p, user):
        if p.startswith('/cloud-api/'):
            cloud_key = self.headers.get('X-Cloud-Key', '').strip()
            if not cloud_key:
                self.send_json(400, {'error': 'Missing cloud API key'})
                return True
            sub = p[len('/cloud-api/'):]
            content_len = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_len) if content_len else b''
            try:
                ctx = ssl.create_default_context()
                conn = http.client.HTTPSConnection('ollama.com', context=ctx, timeout=None)
                conn.request('POST', '/api/' + sub, body=body, headers={
                    'Authorization': 'Bearer ' + cloud_key,
                    'Content-Type': 'application/json',
                })
                resp = conn.getresponse()
                if resp.status >= 400:
                    err_body = resp.read()
                    log(f'[CLOUD-API] upstream error status={resp.status} body={err_body[:300]}')
                    self.send_json(resp.status, {'error': err_body.decode('utf-8', errors='replace')[:500]})
                    conn.close()
                    return True
                self.send_response(resp.status)
                self.send_header('Content-Type', resp.getheader('Content-Type', 'application/x-ndjson'))
                self.end_headers()
                try:
                    while True:
                        chunk = resp.read(4096)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, socket.timeout):
                    pass
                finally:
                    conn.close()
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as e:
                log(f'[CLOUD-API] ERROR: {e}')
                try:
                    self.send_json(500, {'error': str(e)})
                except Exception:
                    pass
            return True

        return False

    def _handle_proxy_put(self, p, user):
        if p == '/admin/settings':
            if user['role'] != 'admin':
                self.send_json(403, {'error': 'Forbidden'})
                return True
            d = self.body()
            allowed = {k: d[k] for k in ('accounts', 'cloudModels', 'ollamaEndpoint', 'compactTurns', 'keepRecent', 'condenseFacts', 'modelLabels') if k in d}
            with sqlite3.connect(DB) as c:
                c.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?,?)',
                          ('admin_cloud_settings', json.dumps(allowed)))
            self.send_json(200, {'ok': True})
            return True

        return False
