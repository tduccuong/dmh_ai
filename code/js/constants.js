/*
 * Copyright (c) 2026 Cuong Truong
 * This project is licensed under the AGPL v3.
 * See the LICENSE file in the repository root for full details.
 * For commercial inquiries, contact: tduccuong@gmail.com
 */

// ─── Model assignments ──────────────────────────────────────────────────────
// Cloud model for background utility tasks:
// auto-naming, web search detection, search query building.
const ASSISTANT_MODEL = 'ministral-3:14b-cloud';

// Mid-tier cloud model for search result synthesis.
// Needs enough capacity to compress multiple web pages into coherent facts.
const SYNTHESIZER_MODEL = 'ministral-3:14b-cloud';

// ─── Web search pipeline ────────────────────────────────────────────────────
// Maximum number of pages to fetch full content from per search round.
const MAX_FETCH_PAGES = 8;

// Per-fetch abort timeout in milliseconds (covers direct fetch + Jina fallback).
// Must be comfortably above JINA_TIMEOUT_SECS (backend) + server overhead + network.
// Too tight and Jina responses arriving at ~9s get dropped (BrokenPipeError on server).
const FETCH_TIMEOUT_MS = 12000;

// Total character budget distributed proportionally across all fetched pages.
// Higher values give the synthesizer more raw material at the cost of a larger prompt.
const TOTAL_CONTENT_BUDGET = 18000;

// Maximum search results to process after deduplication and filtering.
const MAX_SEARCH_RESULTS = 10;

// Raw content length threshold (chars) above which the synthesizer is invoked.
// Below this the raw content is passed directly to the user model, saving ~9s.
// Set well above TOTAL_CONTENT_BUDGET so typical queries bypass synthesis entirely.
const SYNTHESIS_THRESHOLD_CHARS = 45000;

// Character fallback limit for formatted results when synthesis is unavailable.
const SEARCH_FALLBACK_CHARS = 8000;

// SearXNG snippet truncation per result and message chars for query-building context.
const SEARCH_CONTEXT_CHARS = 300;

// Message character limit used when building detect-web-search context.
const DETECT_CONTEXT_CHARS = 400;

// Character limit per message pair injected as relevant earlier context.
const CONTEXT_PAIR_PREVIEW_CHARS = 600;

// Minimum scraped page length (chars) to be considered usable content.
const MIN_PAGE_CONTENT_CHARS = 500;

// ─── Context window ─────────────────────────────────────────────────────────
// Number of recent user/assistant messages passed to detectWebSearch and naming.
const RECENT_MESSAGES_COUNT = 4;

// Number of relevant earlier message pairs retrieved by keyword search.
const RELEVANT_CONTEXT_TOP_K = 4;

// Minimum keyword relevance score for a prior pair to be injected into context.
const MIN_RELEVANCE_SCORE = 0.25;

// ─── LLM output caps (num_predict) ─────────────────────────────────────────
// Max tokens for the synthesizer; keeps synthesis fast and avoids runaway output.
const SYNTHESIZER_NUM_PREDICT = 1500;

// Max tokens for short utility calls: detect, query building, auto-naming.
const UTILITY_NUM_PREDICT = 300;

// Max tokens when extracting facts from the user profile.
const PROFILE_EXTRACT_NUM_PREDICT = 200;

// Max tokens when condensing the full profile into a compact summary.
const PROFILE_CONDENSE_NUM_PREDICT = 600;

// ─── Network timeouts ───────────────────────────────────────────────────────
// Login request abort timeout in milliseconds.
const LOGIN_TIMEOUT_MS = 10000;

// Cloud account reachability probe timeout in milliseconds.
const CLOUD_PROBE_TIMEOUT_MS = 8000;

// Initial and maximum exponential backoff for failed cloud accounts.
const MIN_CLOUD_BACKOFF_MS = 30000;
const MAX_CLOUD_BACKOFF_MS = 30 * 60 * 1000;

// Debounce delay for cloud model search input before hitting the registry API.
const MODEL_SEARCH_DEBOUNCE_MS = 350;

// ─── Image handling ─────────────────────────────────────────────────────────
// Max pixel dimension when generating a thumbnail for inline display.
const IMAGE_SEND_MAX_PX = 500;

// Max pixel dimension when resizing an image for vision model inference.
const IMAGE_VISION_MAX_PX = 768;

// JPEG compression quality for images sent to the model (0–1).
const IMAGE_JPEG_QUALITY = 0.82;

// Lightbox zoom multiplier applied per scroll tick or pinch step.
const IMAGE_ZOOM_STEP = 1.15;

// Minimum and maximum zoom levels in the image lightbox.
const LIGHTBOX_MIN_ZOOM = 0.5;
const LIGHTBOX_MAX_ZOOM = 10;

// ─── UI limits ──────────────────────────────────────────────────────────────
// Maximum lines shown in a file attachment snippet preview.
const FILE_SNIPPET_MAX_LINES = 5;

// Time window in milliseconds for recognising a double-tap gesture.
const DOUBLE_TAP_MS = 300;
