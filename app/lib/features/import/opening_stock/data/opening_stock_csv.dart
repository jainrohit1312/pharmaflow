/// Reads the opening-stock CSV a pharmacy exported from Marg.
///
/// Deliberately dumb, and that is the design: it splits records, checks the
/// header and hands every value over as **text**. It parses no number, no date
/// and no quantity, and it validates no row's contents. The server is the
/// canonical reader (`preview_opening_stock` and `commit_opening_stock_import`,
/// migration 20260920000031), and a second implementation of those rules in Dart
/// is exactly how a preview comes to promise something the commit then refuses.
///
/// What this file owns is the part the server cannot do: the bytes, the quoting,
/// and the blank lines. It is a small RFC 4180 reader rather than a split on
/// commas because one of these columns can legitimately contain a comma -
/// `normalize_product_name()` strips commas out of item names, which only makes
/// sense if a name may hold one - and a quoted field must survive intact.
library;

/// The six columns the file must carry, in this order.
///
/// The header is compared case-insensitively after trimming, because it comes
/// out of a spreadsheet export: the *order* and the names are the contract, not
/// the capitalisation.
const List<String> openingStockCsvHeader = <String>[
  'item_name',
  'batch_no',
  'expiry_date',
  'qty',
  'purchase_rate',
  'mrp',
];

/// One source row, exactly as the file printed it.
///
/// Every value is trimmed at its edges and untouched inside, so a name like
/// `Eupen 1gm                     INJ` keeps the runs of spaces that separate
/// its words while `  99 F 100ML  ` loses the padding around it. `batch_no` is
/// text on purpose: `0126E038` is a batch number, not the number 126038.
class OpeningStockCsvRow {
  /// Creates a source row.
  const OpeningStockCsvRow({
    required this.rowNumber,
    required this.itemName,
    required this.batchNo,
    required this.expiryDate,
    required this.qty,
    required this.purchaseRate,
    required this.mrp,
  });

  /// Which row this is, counting data rows: 1 is the first row after the header.
  ///
  /// The count matches what the server reports back, because the payload it
  /// reads is this list in this order - so "row 138" means the same thing in the
  /// preview, in a refusal and in the audit trail.
  final int rowNumber;

  /// The item's name as printed, trimmed.
  final String itemName;

  /// The batch number as printed, trimmed. Empty when the source had none.
  final String batchNo;

  /// The expiry date as printed (`YYYY-MM-DD`), trimmed. Empty when unknown.
  final String expiryDate;

  /// The quantity as printed. Never parsed here - the server reads it.
  final String qty;

  /// The purchase rate as printed.
  final String purchaseRate;

  /// The MRP as printed.
  final String mrp;

  /// This row as the RPC's `p_rows` entry.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'item_name': itemName,
    'batch_no': batchNo,
    'expiry_date': expiryDate,
    'qty': qty,
    'purchase_rate': purchaseRate,
    'mrp': mrp,
  };
}

/// Raised when a file cannot be read as an opening-stock CSV at all.
///
/// Structural, not per-row: a wrong header, a record with the wrong number of
/// columns, or an unterminated quote. A value the server will refuse (a blank
/// name, a negative quantity) is *not* raised here - it comes back from the
/// preview as a row-numbered error beside all the others, which is where the
/// owner can act on it.
class OpeningStockCsvException implements Exception {
  /// Creates a parse failure with the sentence to show the user.
  const OpeningStockCsvException(this.message, {this.rowNumber});

  /// What is wrong with the file, in a sentence.
  final String message;

  /// The data row at fault, when one row is at fault rather than the file.
  ///
  /// Carried apart from [message] as well as inside it, because the screen shows
  /// the line as a label beside the sentence rather than reading a number back
  /// out of prose. It is the same count [OpeningStockCsvRow.rowNumber] uses, so
  /// a line named here is the line named in a refusal and in the audit trail.
  final int? rowNumber;

  @override
  String toString() => message;
}

/// Parses [content] into its data rows, or throws [OpeningStockCsvException].
///
/// A UTF-8 byte-order mark is tolerated and blank lines are skipped, including
/// the trailing newline every spreadsheet export ends with - so 314 rows read as
/// 314 rows rather than 315, and an empty file is a failure rather than a
/// one-row import of nothing.
List<OpeningStockCsvRow> parseOpeningStockCsv(String content) =>
    _parse(content);

/// How many data rows [estimateOpeningStockRows] counts.
///
/// A round hundred because the number is read once, at a glance, to answer "is
/// this the file I meant?" - and because a first pass that stops there costs a
/// bounded slice of even a ten-thousand-row export.
const int openingStockEstimateRecordLimit = 100;

/// What a first, partial pass over a file counted.
class OpeningStockEstimate {
  /// Creates an estimate.
  const OpeningStockEstimate({required this.rowCount, required this.truncated});

  /// The data rows counted.
  final int rowCount;

  /// Whether the pass stopped at [openingStockEstimateRecordLimit] rows, so the
  /// file holds *at least* [rowCount] rather than exactly it.
  ///
  /// The screen says "at least 100" for a truncated count rather than "100", and
  /// the real number arrives with the server's preview, which classifies every
  /// row in the file rather than the first slice of it.
  final bool truncated;
}

/// Counts the data rows in the first records of [content].
///
/// This is the first pass the screen shows while the owner is deciding whether
/// to upload at all: it counts at most [recordLimit] rows and reports whether
/// there were more, so a large export is not read twice - the full read happens
/// when the owner presses upload.
///
/// It validates what it reads exactly as the full parse does, because a wrong
/// header or a five-column record is visible in the first records and telling
/// the owner *before* they press upload is the whole point of reading them.
OpeningStockEstimate estimateOpeningStockRows(
  String content, {
  int recordLimit = openingStockEstimateRecordLimit,
}) {
  // Two records more than it counts: the header, the rows being counted, and one
  // more to know whether there is another. Without that last one a file of
  // exactly `recordLimit` rows would count as "at least" that many, which reads
  // as a bigger file than it is.
  final rows = _parse(content, recordLimit: recordLimit + 2);
  final overLimit = rows.length > recordLimit;

  return OpeningStockEstimate(
    rowCount: overLimit ? recordLimit : rows.length,
    truncated: overLimit,
  );
}

/// Parses [content], reading at most [recordLimit] records of it.
///
/// With a limit the reader stops on a record boundary and answers with what it
/// read, so the caller holds whole records and never a half-scanned one. The
/// unterminated-quote check is skipped when it stops early: the file's own
/// ending was not read, so there is nothing to say about it.
List<OpeningStockCsvRow> _parse(String content, {int? recordLimit}) {
  final records = _readRecords(content, recordLimit: recordLimit);

  if (records.isEmpty) {
    throw const OpeningStockCsvException('That file is empty.');
  }

  final header = records.first
      .map((cell) => cell.trim().toLowerCase())
      .toList(growable: false);
  if (!_isExpectedHeader(header)) {
    throw OpeningStockCsvException(
      'That file does not start with the expected columns. Expected '
      '${openingStockCsvHeader.join(',')}, found ${records.first.join(',')}.',
    );
  }

  final rows = <OpeningStockCsvRow>[];
  for (var index = 1; index < records.length; index++) {
    final cells = records[index];
    final rowNumber = rows.length + 1;

    if (cells.length != openingStockCsvHeader.length) {
      throw OpeningStockCsvException(
        'Row $rowNumber has ${cells.length} columns, not '
        '${openingStockCsvHeader.length}.',
        rowNumber: rowNumber,
      );
    }

    rows.add(
      OpeningStockCsvRow(
        rowNumber: rowNumber,
        itemName: cells[0].trim(),
        batchNo: cells[1].trim(),
        expiryDate: cells[2].trim(),
        qty: cells[3].trim(),
        purchaseRate: cells[4].trim(),
        mrp: cells[5].trim(),
      ),
    );
  }

  if (rows.isEmpty) {
    throw const OpeningStockCsvException('That file has a header but no rows.');
  }

  return List<OpeningStockCsvRow>.unmodifiable(rows);
}

/// Whether [header] is the six expected names in the expected order.
bool _isExpectedHeader(List<String> header) {
  if (header.length != openingStockCsvHeader.length) {
    return false;
  }
  for (var i = 0; i < header.length; i++) {
    if (header[i] != openingStockCsvHeader[i]) {
      return false;
    }
  }
  return true;
}

/// Splits [content] into records of cells, honouring RFC 4180 quoting.
///
/// A quoted cell may contain commas, newlines and doubled quotes; the quotes
/// themselves are not part of the value. A carriage return outside quotes is
/// ignored so a CRLF export reads the same as an LF one. Blank records are
/// dropped.
///
/// With [recordLimit] the reader answers as soon as it holds that many records
/// rather than reading to the end, which is what lets [estimateOpeningStockRows]
/// look at a large export without reading all of it. It stops on a record
/// boundary, so every record it answers with is one the file actually ended.
List<List<String>> _readRecords(String content, {int? recordLimit}) {
  final text = content.startsWith('\uFEFF') ? content.substring(1) : content;

  final records = <List<String>>[];
  var cells = <String>[];
  final cell = StringBuffer();
  var inQuotes = false;

  void endRecord() {
    cells.add(cell.toString());
    cell.clear();
    final isBlank = cells.length == 1 && cells.first.trim().isEmpty;
    if (!isBlank) {
      records.add(cells);
    }
    cells = <String>[];
  }

  for (var i = 0; i < text.length; i++) {
    final character = text[i];

    if (inQuotes) {
      if (character != '"') {
        cell.write(character);
        continue;
      }
      // A doubled quote inside a quoted cell is one literal quote.
      if (i + 1 < text.length && text[i + 1] == '"') {
        cell.write('"');
        i++;
      } else {
        inQuotes = false;
      }
      continue;
    }

    if (character == '"') {
      inQuotes = true;
    } else if (character == ',') {
      cells.add(cell.toString());
      cell.clear();
    } else if (character == '\n') {
      endRecord();
      if (recordLimit != null && records.length >= recordLimit) {
        return records;
      }
    } else if (character != '\r') {
      // A carriage return is ignored outside quotes: the newline that follows a
      // CRLF line ending ends the record.
      cell.write(character);
    }
  }

  if (inQuotes) {
    throw const OpeningStockCsvException(
      'That file has an opening quote with no closing quote.',
    );
  }

  if (cell.isNotEmpty || cells.isNotEmpty) {
    endRecord();
  }

  return records;
}
