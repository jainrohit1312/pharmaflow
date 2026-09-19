/// Helpers for turning free-text user input into PostgREST filters.
///
/// Every list screen in the app needs the same `name ilike %term%` search over
/// several columns, and every one of them would otherwise have to re-derive the
/// escaping. Getting it wrong is silent rather than loud: a stray `,` inside an
/// `or=()` filter splits it into extra conditions (changing the query), and a
/// `%` turns user text into a wildcard.
///
/// The three builders here compose: [buildIlikeOrFilter] for the text branches,
/// [buildInFilter] for an equality branch, and [buildAnyOfFilter] to put them
/// together into one disjunction — which is how a single search box can cover
/// both a document's own text and the rows it points at.
library;

/// Characters that carry meaning inside a PostgREST `or=(...)` filter, an
/// `ilike` pattern, or a quoted SQL literal. Removed from user input.
///
/// Required by DECISIONS.md D-014: a comma typed into a search box would
/// otherwise split the `or=()` filter into an extra condition, which is how a
/// search term could try to bypass a predicate the caller ANDed on
/// (`active=true`, `pharmacy_id = ...`).
///
/// Every character here is replaced with a space rather than deleted, so
/// `para,cetamol` searches for the two words instead of becoming one unknown
/// token.
const List<String> _reserved = <String>[
  ',', // separates conditions inside or=()
  '(', // opens a nested condition group
  ')', // closes a nested condition group
  '%', // SQL wildcard
  '*', // PostgREST alias/operator suffix
  '_', // SQL single-character wildcard (see the note below)
  '"', // quoted identifier
  "'", // quoted literal
  r'\', // escape character
];

/// Strips the PostgREST and SQL metacharacters from [raw] and collapses runs of
/// whitespace.
///
/// Returns an empty string when nothing usable is left, which callers treat as
/// "no search term" rather than as a term that matches everything.
///
/// Note on `_`: unlike the other entries it is not a filter-structure
/// character - it cannot widen which rows the predicate admits, only how many
/// characters a single position matches. It is stripped anyway so that this
/// list matches D-014 exactly, and the visible consequence is that a search for
/// `vitamin_b` is treated as the term `vitamin b`.
String sanitizeSearchTerm(String raw) {
  var cleaned = raw;
  for (final reserved in _reserved) {
    cleaned = cleaned.replaceAll(reserved, ' ');
  }
  return cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Builds the value for PostgREST's `or()` filter matching [term] against every
/// one of [columns], or `null` when [term] holds nothing searchable.
///
/// The result is already inside-out relative to `or()`: pass it straight to
/// `.or(...)`, e.g.
/// `buildIlikeOrFilter(columns: ['name', 'barcode'], term: 'para')`
/// returns `name.ilike.%para%,barcode.ilike.%para%`.
String? buildIlikeOrFilter({
  required List<String> columns,
  required String term,
}) {
  final sanitized = sanitizeSearchTerm(term);
  if (sanitized.isEmpty || columns.isEmpty) {
    return null;
  }
  return columns.map((column) => '$column.ilike.%$sanitized%').join(',');
}

/// Builds one `column.in.(…)` condition, or `null` when [values] holds nothing
/// usable.
///
/// The counterpart of [buildIlikeOrFilter] for an equality branch: a search that
/// also covers "any of these rows" rather than "this text appears somewhere".
///
/// The values are **checked rather than sanitised**, because they come from a
/// column rather than from a user: a value carrying a comma or a parenthesis
/// would split the list into extra conditions — the same silent failure
/// [sanitizeSearchTerm] exists to prevent — and such a value is a bug worth
/// dropping rather than rewriting into a different row's id.
String? buildInFilter({required String column, required List<String> values}) {
  final safe = values.where(_isPlainFilterValue).toList(growable: false);
  if (safe.isEmpty) {
    return null;
  }
  return '$column.in.(${safe.join(',')})';
}

/// Joins [conditions] into one value for PostgREST's `or()` filter — a row that
/// matches **any** of them — or `null` when there are none.
///
/// This is what lets one search box answer more than one question: a purchase is
/// the invoice number somebody typed, a note they wrote on it, **or** a document
/// that came from one of the suppliers whose name they typed. `null` rather than
/// an empty group, because an empty `or=()` is a filter that has quietly stopped
/// filtering.
String? buildAnyOfFilter(Iterable<String?> conditions) {
  final present = conditions.whereType<String>().where(
    (condition) => condition.isNotEmpty,
  );
  return present.isEmpty ? null : present.join(',');
}

/// Whether [value] can go into an `in.(…)` list as it stands.
///
/// Every character that structures the filter (or the SQL literal inside it) is
/// refused: a comma separates values, a parenthesis closes the list, a quote
/// starts a literal, and a backslash or wildcard changes how a value is read.
bool _isPlainFilterValue(String value) =>
    value.isNotEmpty && !RegExp(r'''[,\s()"'\\%*]''').hasMatch(value);
