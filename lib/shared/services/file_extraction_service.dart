import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:xml/xml.dart';

/// Extracts plain text from teacher-uploaded lesson files.
///
/// Supported formats:
///   - **PDF** — a self-contained content-stream parser that locates every
///     `stream … endstream` section in the PDF binary, attempts zlib
///     decompression (FlateDecode), then pulls text out of the standard PDF
///     text-showing operators: `Tj`, `TJ`, and `'` (quote).  Works for the
///     vast majority of digitally-created PDFs; scanned-image PDFs that
///     contain no embedded text layer will return an empty string.
///   - **DOCX** — treated as a ZIP archive; the embedded `word/document.xml`
///     is parsed with the `xml` package and all `<w:t>` run-text elements are
///     concatenated.
///
/// All public methods are safe to call without `try/catch` at the call site —
/// every error path returns an empty string and logs to stderr rather than
/// rethrowing.
///
/// Usage:
/// ```dart
/// final service = FileExtractionService();
/// final text   = await service.extractText('/path/to/lesson.pdf');
/// ```
class FileExtractionService {
  // ──────────────────────────────────────────────────────────────
  // Public API
  // ──────────────────────────────────────────────────────────────

  /// Detects the file type from [filePath]'s extension and delegates to the
  /// appropriate extraction method.
  ///
  /// Returns the extracted plain text (trimmed), or an empty string when:
  ///   - the extension is not `.pdf` or `.docx`
  ///   - the file cannot be read or parsed
  Future<String> extractText(String filePath) async {
    try {
      final lower = filePath.toLowerCase();
      if (lower.endsWith('.pdf')) {
        return await extractFromPdf(filePath);
      } else if (lower.endsWith('.docx')) {
        return await extractFromDocx(filePath);
      }
      // Unsupported format — caller receives an empty string gracefully.
      return '';
    } catch (e, stack) {
      _logError('extractText', filePath, e, stack);
      return '';
    }
  }

  // ──────────────────────────────────────────────────────────────
  // PDF extraction
  // ──────────────────────────────────────────────────────────────

  /// Reads [filePath] as a PDF binary and extracts embedded text by parsing
  /// its content streams.
  ///
  /// Strategy:
  ///   1. Read the entire file into a `Uint8List`.
  ///   2. Locate every `stream … endstream` section using byte-level search.
  ///   3. Attempt zlib decompression on each section (handles FlateDecode).
  ///      Uncompressed streams are used as-is when decompression fails.
  ///   4. Apply PDF text-operator regexes (`Tj`, `TJ`, `'`) to each stream.
  ///   5. Decode PDF string escape sequences and join all fragments.
  Future<String> extractFromPdf(String filePath) async {
    try {
      final bytes = File(filePath).readAsBytesSync();
      return _parsePdfText(bytes);
    } catch (e, stack) {
      _logError('extractFromPdf', filePath, e, stack);
      return '';
    }
  }

  /// Walks the raw PDF bytes, extracts each content stream, decompresses it
  /// when possible, and collects all text-operator output into a single string.
  String _parsePdfText(List<int> fileBytes) {
    final buffer = StringBuffer();

    // Represent the file as a Latin-1 string so that String character indices
    // map 1-to-1 with byte offsets.  Bytes 0-127 are identical to ASCII;
    // bytes 128-255 become Unicode code points U+0080–U+00FF.
    // All ASCII pattern searches ('stream', 'endstream', 'Tj', etc.) remain
    // exact, and `fileBytes.sublist(start, end)` retrieves the correct bytes.
    final content = String.fromCharCodes(fileBytes);

    int searchPos = 0;
    while (searchPos < content.length) {
      // ── Locate the next 'stream' keyword ──────────────────────────────────
      final streamKeyIdx = content.indexOf('stream', searchPos);
      if (streamKeyIdx == -1) break;

      // The keyword 'endstream' also contains the substring 'stream', so
      // confirm the character immediately before is not 'end'.
      final possibleEnd = streamKeyIdx >= 3
          ? content.substring(streamKeyIdx - 3, streamKeyIdx)
          : '';
      if (possibleEnd == 'end') {
        searchPos = streamKeyIdx + 6;
        continue;
      }

      // PDF spec: the stream data starts after 'stream' then \r\n or \n.
      int dataStart = streamKeyIdx + 6; // skip 'stream'
      if (dataStart < content.length && content[dataStart] == '\r') {
        dataStart++;
      }
      if (dataStart < content.length && content[dataStart] == '\n') {
        dataStart++;
      }

      // ── Locate the matching 'endstream' keyword ────────────────────────────
      final endStreamIdx = content.indexOf('endstream', dataStart);
      if (endStreamIdx == -1) break;

      // Trim the optional line-ending that precedes 'endstream'.
      int dataEnd = endStreamIdx;
      if (dataEnd > dataStart && content[dataEnd - 1] == '\n') dataEnd--;
      if (dataEnd > dataStart && content[dataEnd - 1] == '\r') dataEnd--;

      if (dataEnd > dataStart) {
        // Extract the raw stream bytes for this section.
        final streamBytes = fileBytes.sublist(dataStart, dataEnd);

        // ── Decompress or pass through ───────────────────────────────────────
        // Most PDF content streams use FlateDecode (zlib with a 2-byte header
        // and Adler-32 trailer).  dart:io's `zlib.decode` handles this format
        // exactly.  Non-zlib streams (e.g. raw image data, JPEG) will throw,
        // and we fall back to treating the bytes as plain text.
        String streamText;
        try {
          final decompressed = zlib.decode(streamBytes);
          streamText = String.fromCharCodes(decompressed);
        } catch (_) {
          // Either already plain text, or a format we cannot decode (image
          // streams, etc.).  Using the raw characters is harmless: the text
          // operator regex will simply match nothing in binary noise.
          streamText = String.fromCharCodes(streamBytes);
        }

        _extractTextOperators(streamText, buffer);
      }

      searchPos = endStreamIdx + 9; // advance past 'endstream'
    }

    // Collapse runs of whitespace introduced by operator boundaries.
    return buffer.toString().replaceAll(RegExp(r' {2,}'), ' ').trim();
  }

  /// Scans a decoded PDF content stream for text-showing operators and appends
  /// their string content to [out].
  ///
  /// Handled operators:
  ///   - `(string) Tj`   — show a single literal string
  ///   - `[(…) …] TJ`   — show an array of strings (kerning pairs ignored)
  ///   - `(string) '`    — move to next line, then show a literal string
  void _extractTextOperators(String stream, StringBuffer out) {
    // ── Tj: (string) Tj ───────────────────────────────────────────────────────
    // Inner pattern handles escape sequences (`\.`) and treats everything else
    // as literal text.  Nested balanced parentheses are intentionally not
    // supported here; they are extremely rare in practice.
    final tjRe = RegExp(r'\(([^)\\]*(?:\\.[^)\\]*)*)\)\s*Tj');
    for (final m in tjRe.allMatches(stream)) {
      final decoded = _decodePdfString(m.group(1) ?? '');
      if (decoded.isNotEmpty) {
        out.write(decoded);
        out.write(' ');
      }
    }

    // ── TJ: [(string-or-number) …] TJ ────────────────────────────────────────
    // Numeric kerning adjustments are skipped; only string literals matter.
    final tjArrayRe = RegExp(r'\[([^\]]*)\]\s*TJ', dotAll: true);
    for (final arrayMatch in tjArrayRe.allMatches(stream)) {
      final innerRe = RegExp(r'\(([^)\\]*(?:\\.[^)\\]*)*)\)');
      bool wroteAny = false;
      for (final inner in innerRe.allMatches(arrayMatch.group(1) ?? '')) {
        final decoded = _decodePdfString(inner.group(1) ?? '');
        if (decoded.isNotEmpty) {
          out.write(decoded);
          wroteAny = true;
        }
      }
      if (wroteAny) out.write(' ');
    }

    // ── Quote operator: (string) ' ───────────────────────────────────────────
    // Semantically "move to next line then show string"; we emit a newline.
    final quoteRe = RegExp(r"\(([^)\\]*(?:\\.[^)\\]*)*)\)\s+'");
    for (final m in quoteRe.allMatches(stream)) {
      final decoded = _decodePdfString(m.group(1) ?? '');
      if (decoded.isNotEmpty) {
        out.write(decoded);
        out.write('\n');
      }
    }
  }

  /// Converts PDF string escape sequences to their plain-text equivalents.
  ///
  /// Handles: `\n`, `\r`, `\t`, `\(`, `\)`, `\\`.
  /// Octal escapes (`\053` etc.) are left as-is — uncommon in body text.
  String _decodePdfString(String raw) {
    return raw
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\r', '\r')
        .replaceAll(r'\t', '\t')
        .replaceAll(r'\(', '(')
        .replaceAll(r'\)', ')')
        .replaceAll(r'\\', r'\');
  }

  // ──────────────────────────────────────────────────────────────
  // DOCX extraction
  // ──────────────────────────────────────────────────────────────

  /// Treats [filePath] as a DOCX file (which is a ZIP archive internally),
  /// locates `word/document.xml`, and joins the text content of every
  /// `<w:t>` element with a single space.
  ///
  /// Returns an empty string when:
  ///   - the file cannot be read or is not a valid ZIP
  ///   - `word/document.xml` is absent from the archive
  ///   - the XML cannot be parsed
  Future<String> extractFromDocx(String filePath) async {
    try {
      // Read the raw file bytes synchronously — DOCX files are typically
      // small enough that this does not block the UI thread perceptibly, and
      // keeping the extraction on the calling isolate avoids spawn overhead.
      final bytes = File(filePath).readAsBytesSync();

      // Decode the ZIP container.
      final archive = ZipDecoder().decodeBytes(bytes);

      // Locate the main document XML inside the archive.
      ArchiveFile? documentXmlFile;
      for (final file in archive) {
        if (file.name == 'word/document.xml') {
          documentXmlFile = file;
          break;
        }
      }

      if (documentXmlFile == null) {
        // Not a standard DOCX layout — return empty rather than crash.
        return '';
      }

      final xmlBytes = documentXmlFile.content as List<int>;
      final xmlString = utf8.decode(xmlBytes);

      // Parse and extract all run-text elements (<w:t>).
      final xmlDocument = XmlDocument.parse(xmlString);
      final text = xmlDocument
          .findAllElements('w:t')
          .map((element) => element.innerText)
          .join(' ');

      return text.trim();
    } catch (e, stack) {
      _logError('extractFromDocx', filePath, e, stack);
      return '';
    }
  }

  // ──────────────────────────────────────────────────────────────
  // Internal helpers
  // ──────────────────────────────────────────────────────────────

  /// Writes a structured error message to stderr.
  ///
  /// Kept deliberately lightweight — no logging package dependency so this
  /// service stays portable and testable without Flutter bindings.
  void _logError(
    String method,
    String filePath,
    Object error,
    StackTrace stack,
  ) {
    stderr.writeln(
      '[FileExtractionService.$method] Failed for "$filePath": $error\n$stack',
    );
  }
}
