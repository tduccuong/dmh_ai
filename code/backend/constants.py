# Copyright (c) 2026 Cuong Truong
# This project is licensed under the AGPL v3.
# See the LICENSE file in the repository root for full details.
# For commercial inquiries, contact: tduccuong@gmail.com

# ─── Web search pipeline ────────────────────────────────────────────────────
# Fetch a second SearXNG result page only when page 1 yields fewer than this
# many unblocked results. Avoids doubling upstream search engine requests when
# page 1 already has plenty of scrapeable links.
SEARCH_PAGE2_THRESHOLD = 5

# Maximum characters kept per fetched page before handing off to the synthesizer.
# Larger values preserve more detail but increase prompt size.
MAX_PAGE_CHARS = 6000

# Minimum characters a fetched page must contain to be considered useful content.
# Pages below this threshold trigger the Jina Reader fallback.
MIN_USEFUL_PAGE_CHARS = 500

# Maximum bytes read from a direct HTTP page fetch.
DIRECT_FETCH_SIZE_BYTES = 120_000

# Maximum bytes read from a Jina Reader response.
JINA_FETCH_SIZE_BYTES = 200_000

# ─── Network timeouts (seconds) ─────────────────────────────────────────────
# Timeout for connecting to a local or cloud Ollama API endpoint.
OLLAMA_API_TIMEOUT_SECS = 10

# Timeout when probing a newly configured Ollama endpoint for reachability.
ENDPOINT_TEST_TIMEOUT_SECS = 5

# Timeout for queries against the ollama.com public registry.
REGISTRY_TIMEOUT_SECS = 10

# Timeout for SearXNG search requests (both page 1 and page 2).
SEARXNG_TIMEOUT_SECS = 20

# Timeout for direct HTTP page fetches (before Jina fallback).
DIRECT_FETCH_TIMEOUT_SECS = 6

# Timeout for Jina Reader fallback requests.
JINA_TIMEOUT_SECS = 7

# Number of fetch timeouts for a domain before it is auto-added to the blocked list.
DOMAIN_TIMEOUT_BLOCK_THRESHOLD = 3

# ─── Security ───────────────────────────────────────────────────────────────
# PBKDF2-HMAC-SHA256 iteration count for password hashing.
# Increase over time as hardware gets faster (OWASP recommends ≥ 210 000 for SHA-256).
PASSWORD_HASH_ITERATIONS = 100_000
