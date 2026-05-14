"""Minimal multi-threaded HTTP server for the docs-site demo fixture.

The URL pipeline's BFS fetches the seed plus same-prefix children in
parallel. The stdlib `python3 -m http.server` is single-threaded and
drops concurrent requests as "connection closed". This wrapper uses
`ThreadingHTTPServer` so the crawl can run unmolested.

Usage:
  python3 demo/layer-0.2/fixtures/docs-site/serve.py [port]
  (port defaults to 8085 to match 03_kb_docs_site.md)
"""
import sys, os
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8085
docs_dir = os.path.dirname(os.path.abspath(__file__))
os.chdir(docs_dir)

srv = ThreadingHTTPServer(("127.0.0.1", port), SimpleHTTPRequestHandler)
print(f"serving {docs_dir} at http://127.0.0.1:{port}/ (threading)", flush=True)
try:
    srv.serve_forever()
except KeyboardInterrupt:
    srv.shutdown()
