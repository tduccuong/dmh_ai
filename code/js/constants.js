/*
 * Copyright (c) 2026 Cuong Truong
 * This project is licensed under the AGPL v3.
 * See the LICENSE file in the repository root for full details.
 * For commercial inquiries, contact: tduccuong@gmail.com
 */

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

// Maximum file size for image and video uploads (300 MB).
const MEDIA_MAX_SIZE_BYTES = 300 * 1024 * 1024;

// ─── Video frame extraction ─────────────────────────────────────────────────
// Max width/height when scaling video frames before sending to LLM (360p).
const VIDEO_FRAME_MAX_WIDTH = 640;
const VIDEO_FRAME_MAX_HEIGHT = 360;

// JPEG quality for extracted video frames (0–1).
const VIDEO_FRAME_JPEG_QUALITY = 0.75;

// Minimum gap between sampled frames (seconds).
const VIDEO_FRAME_MIN_INTERVAL = 2;

// ─── UI limits ──────────────────────────────────────────────────────────────
// Maximum lines shown in a file attachment snippet preview.
const FILE_SNIPPET_MAX_LINES = 5;

// Time window in milliseconds for recognising a double-tap gesture.
const DOUBLE_TAP_MS = 300;
