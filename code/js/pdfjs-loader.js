// pdfjs-loader.js — bootstraps the PDF.js library on the global
// scope. Extracted from an inline `<script type="module">` block in
// index.html so the deployed CSP can drop `'unsafe-inline'` from
// `script-src`. ES module syntax is retained because pdf.min.js is
// itself an ES module.
import * as pdfjsLib from '/pdf.min.js';
pdfjsLib.GlobalWorkerOptions.workerSrc = '/pdf.worker.min.js';
window.pdfjsLib = pdfjsLib;
