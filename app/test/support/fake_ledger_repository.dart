/// Shared test double for the ledger screen.
///
/// Not a `_test.dart` file, so `flutter test` does not try to run it.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/models/ledger_entry.dart';
import 'package:app/data/models/party_balance.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/repositories/ledger_repository.dart';

/// Builds a ledger entry with only the fields a test cares about.
///
/// The entry lands on whichever side [partyType] says, because
/// `ledger_entries` has exactly one of the two party columns set (a check
/// constraint enforces it) and a row with neither is not a row this table can
/// hold.
LedgerEntry buildLedgerEntry({
  String id = 'entry-1',
  PartyType partyType = PartyType.supplier,
  String? partyId,
  LedgerReferenceType referenceType = LedgerReferenceType.purchase,
  double debit = 0,
  double credit = 0,
  DateTime? entryDate,
  String? description,
}) => LedgerEntry(
  id: id,
  pharmacyId: 'ph-1',
  entryDate: entryDate ?? DateTime(2026, 9, 18),
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  partyType: partyType,
  referenceType: referenceType,
  debit: debit,
  credit: credit,
  supplierId: partyType == PartyType.supplier ? partyId : null,
  customerId: partyType == PartyType.customer ? partyId : null,
  description: description,
);

/// One payment the fake was asked to record.
class RecordedPayment {
  /// Creates a recorded payment.
  const RecordedPayment({
    required this.partyType,
    required this.partyId,
    required this.amount,
    required this.mode,
    this.referenceNo,
    this.paymentDate,
    this.notes,
  });

  /// Which side of the ledger it settled.
  final PartyType partyType;

  /// The party it settled.
  final String partyId;

  /// How much moved.
  final double amount;

  /// How it moved.
  final PaymentMode mode;

  /// The cheque or UPI reference, if any.
  final String? referenceNo;

  /// The day it was recorded against.
  final DateTime? paymentDate;

  /// Any note attached.
  final String? notes;
}

/// An in-memory [LedgerRepository].
///
/// Implemented with `implements` plus `noSuchMethod` rather than by subclassing:
/// `implements` does not require a constructor, so the fake never needs a
/// Supabase client - which is the whole point, because a real `SupabaseClient`
/// cannot be constructed without an initialised backend.
class FakeLedgerRepository implements LedgerRepository {
  /// Creates a fake over [entries], reporting [balance] for every party.
  FakeLedgerRepository({List<LedgerEntry>? entries, PartyBalance? balance})
    : entries = List<LedgerEntry>.of(entries ?? const <LedgerEntry>[]),
      balance = balance ?? const PartyBalance();

  /// The ledger rows the fake holds.
  final List<LedgerEntry> entries;

  /// What every balance read returns.
  PartyBalance balance;

  /// The payments recorded, in order.
  final List<RecordedPayment> payments = <RecordedPayment>[];

  /// Offsets asked for, in order.
  final List<int> requestedOffsets = <int>[];

  /// When true *every* `entriesFor` call throws, until the test clears it.
  ///
  /// Persistent rather than one-shot on purpose: a read that failed and then
  /// quietly succeeded on a rebuild is not a state a test can assert on.
  bool failEntries = false;

  /// When set, the next payment write throws it and clears it.
  Exception? errorToThrow;

  @override
  Future<List<LedgerEntry>> entriesFor({
    required String pharmacyId,
    required PartyType partyType,
    required String partyId,
    int limit = LedgerRepository.ledgerPageSize,
    int offset = 0,
  }) async {
    requestedOffsets.add(offset);
    if (failEntries) {
      throw const ServerException(message: 'Unable to load that ledger.');
    }

    final mine = entries.where(
      (entry) =>
          entry.partyType == partyType &&
          (partyType == PartyType.supplier
                  ? entry.supplierId
                  : entry.customerId) ==
              partyId,
    );
    return mine.skip(offset).take(limit).toList(growable: false);
  }

  @override
  Future<PartyBalance> balanceFor({
    required String pharmacyId,
    required PartyType partyType,
    required String partyId,
  }) async => balance;

  @override
  Future<void> recordPayment({
    required PartyType partyType,
    required String partyId,
    required double amount,
    required PaymentMode mode,
    String? referenceNo,
    DateTime? paymentDate,
    String? notes,
  }) async {
    // The check the real repository makes before the RPC, so a screen that skips
    // it fails here rather than in front of a user.
    if (amount <= 0) {
      throw const ValidationException(
        message: 'Enter an amount greater than zero.',
      );
    }

    final error = errorToThrow;
    if (error != null) {
      errorToThrow = null;
      throw error;
    }

    payments.add(
      RecordedPayment(
        partyType: partyType,
        partyId: partyId,
        amount: amount,
        mode: mode,
        referenceNo: referenceNo,
        paymentDate: paymentDate,
        notes: notes,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this fake',
  );
}
