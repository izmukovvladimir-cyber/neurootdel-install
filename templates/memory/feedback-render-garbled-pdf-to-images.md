---
name: feedback-render-garbled-pdf-to-images
description: "If text extraction returns garbage, try one other extractor, then render the pages and read them."
metadata:
  type: feedback
  origin: installer starter lesson
---

# Read a garbled PDF by rendering its pages to images

When text extraction from a PDF returns garbage (broken fonts or a missing Unicode map), do not cycle through extractors: try one alternative at most, then render the pages to images and read them visually or with OCR. Check OCR text against the page image.

**Why:** Trying extractor after extractor wastes time and may produce confident nonsense.

**How to apply:** Check one page of extracted text; if garbled, try one other extractor; otherwise render pages to PNG and OCR or read them; verify against the image.
