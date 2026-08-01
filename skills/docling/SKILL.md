---
name: docling
description: Extract, parse, and convert complex documents (PDF, DOCX, PPTX, XLSX, HTML, Images, Audio, Video) into Markdown, JSON, YAML, or RAG chunks using the Docling CLI or Python API.
---

# Document Parsing with Docling

> [!NOTE]
> **Environment Setup**:
> - `docling` is pre-installed via `uv tool install docling` and available directly in `PATH`.
> - Use `docling convert` for local processing or `docling convert-remote` for remote server instances.

Docling converts complex documents (PDF, DOCX, PPTX, XLSX, HTML, Images, Audio, Video, EPUB, AsciiDoc) into structured representations such as Markdown, JSON, HTML, or RAG-ready text chunks.

---

## Quick Start

```bash
# Convert a single document (PDF, DOCX, etc.) to Markdown (default format)
docling convert document.pdf

# Convert a document from a URL
docling convert https://arxiv.org/pdf/2408.09869

# Convert to a specific output directory
docling convert report.pdf --output ./parsed_output

# Convert to JSON format
docling convert proposal.docx --to json
```

---

## Supported Input Formats

Docling handles a wide variety of input file formats:
- **Documents**: PDF (`.pdf`), Microsoft Word (`.docx`), Microsoft PowerPoint (`.pptx`), Microsoft Excel (`.xlsx`), OpenDocument formats (`.odt`, `.ods`, `.odp`), EPUB (`.epub`), AsciiDoc (`.adoc`), Markdown (`.md`)
- **Web & Code**: HTML (`.html`, `.htm`), XML (`.xml`)
- **Images (via OCR)**: PNG (`.png`), JPEG (`.jpg`, `.jpeg`), TIFF (`.tiff`), BMP (`.bmp`)
- **Audio / Video (via ASR)**: MP3, WAV, MP4, MKV (transcribes speech to text)

---

## CLI Usage (`docling convert`)

### Export Formats (`--to`)

Default export format is `md` (Markdown).

```bash
# Export as Markdown (default)
docling convert doc.pdf --to md

# Export as JSON (complete docling document object model)
docling convert doc.pdf --to json

# Export as YAML
docling convert doc.pdf --to yaml

# Export as HTML
docling convert doc.pdf --to html

# Export as plain text
docling convert doc.pdf --to text

# Export as DocTags (token representations of document layout)
docling convert doc.pdf --to doctags

# Export as RAG Chunks directly
docling convert doc.pdf --to chunks
```

---

### Image Export Options (`--image-export-mode`)

Control how embedded images within documents are exported:

```bash
# Embedded mode (default): embeds images as base64 strings in output format
docling convert report.pdf --image-export-mode embedded

# Referenced mode: saves images as PNG files in output dir and references them
docling convert report.pdf --image-export-mode referenced --output ./out

# Placeholder mode: marks image position without extracting bitmap data
docling convert report.pdf --image-export-mode placeholder
```

---

### OCR Controls

Docling uses OCR for scanned PDFs and image inputs.

```bash
# Enable OCR (default behavior for scanned/bitmap content)
docling convert scanned.pdf --ocr

# Disable OCR (faster for digital-native PDFs with existing text layer)
docling convert document.pdf --no-ocr

# Force OCR (replace all native text with OCR extracted text)
docling convert scanned.pdf --force-ocr

# Specify OCR engine (auto, easyocr, tesseract, mac, rapidocr, paddleocr)
docling convert scanned.pdf --ocr-engine easyocr
```

---

### Table Structure Extraction

Table parsing is enabled by default.

```bash
# Enable table structure extraction (default)
docling convert financials.pdf --tables

# Disable table structure extraction (faster speed if tables aren't needed)
docling convert simple.pdf --no-tables
```

---

### Document Chunking for RAG (`--to chunks`)

Generate pre-chunked outputs suitable for vector indexing or LLM contexts.

```bash
# Hybrid chunker (default, structure-aware + token bounded)
docling convert article.pdf --to chunks --chunks-type hybrid --chunks-max-tokens 512

# Hierarchical chunker (preserves document section hierarchy)
docling convert book.pdf --to chunks --chunks-type hierarchical
```

---

### Batch Conversion & Formatting Filters

```bash
# Convert all supported files in a directory
docling convert ./input_docs/ --output ./output_docs/

# Convert only PDF and DOCX files in a directory
docling convert ./input_docs/ --from pdf --from docx --output ./output_docs/
```

---

### Performance & Hardware Options

```bash
# Set thread count (default: 4)
docling convert heavy.pdf --num-threads 8

# Set device accelerator (auto, cpu, cuda, mps [Apple Silicon], xpu)
docling convert heavy.pdf --device mps
```

---

## Python API Usage

When writing Python scripts to process documents, use the `docling` Python library.

### Basic Conversion

```python
from docling.document_converter import DocumentConverter

converter = DocumentConverter()
result = converter.convert("document.pdf")

# Export to Markdown text
markdown_output = result.document.export_to_markdown()

# Export to Python dictionary / JSON structure
json_output = result.document.export_to_dict()

# Access document metadata
title = result.document.name
```

---

### Advanced PDF Pipeline Configuration

```python
from docling.datamodel.base_models import InputFormat
from docling.datamodel.pipeline_options import PdfPipelineOptions, EasyOcrOptions
from docling.document_converter import DocumentConverter, PdfFormatOption

# Configure custom pipeline options for PDF processing
pipeline_options = PdfPipelineOptions()
pipeline_options.do_ocr = True
pipeline_options.do_table_structure = True
pipeline_options.ocr_options = EasyOcrOptions(force_full_page_ocr=False)

converter = DocumentConverter(
    format_options={
        InputFormat.PDF: PdfFormatOption(pipeline_options=pipeline_options)
    }
)

result = converter.convert("scanned_doc.pdf")
print(result.document.export_to_markdown())
```

---

### RAG Chunking in Python

```python
from docling.document_converter import DocumentConverter
from docling.chunking import HybridChunker

converter = DocumentConverter()
result = converter.convert("report.pdf")

# Initialize hybrid chunker
chunker = HybridChunker()
chunks = list(chunker.chunk(result.document))

for chunk in chunks:
    print(f"Chunk text: {chunk.text}")
    print(f"Meta: {chunk.meta}")
```

---

## Best Practices for AI Agents

1. **Reading Documents for Context**:
   Convert target PDFs/DOCX/PPTX to Markdown using `docling convert document.pdf --output ./tmp_out` and read the resulting `.md` file to analyze document contents cleanly.
2. **Scanned PDFs & Low-Quality Inputs**:
   Use `--force-ocr` or `--ocr-engine easyocr` when native text extraction returns missing or scrambled content.
3. **Structured Data Extraction**:
   Use `--to json` to programmatically inspect document hierarchy, table cells, headers, and bounding boxes.
4. **Large Documents & Long Contexts**:
   Use `--to chunks` with `--chunks-max-tokens 512` to break down massive PDFs into manageable context chunks.
