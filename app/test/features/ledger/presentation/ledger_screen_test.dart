/// Tests for the ledger screen.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/utils/formatters.dart';
import 'package:app/core/widgets/error_view.dart';
import 'package:app/data/models/customer.dart';
import 'package:app/data/models/ledger_entry.dart';
import 'package:app/data/models/party_balance.dart';
import 'package:app/data/models/sale.dart';
import 'package:app/data/models/supplier.dart';
import 'package:app/data/repositories/ledger_repository.dart';
import 'package:app/features/ledger/application/ledger_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_customers_repository.dart';
import '../../../support/fake_ledger_repository.dart';
import '../../../support/fake_suppliers_repository.dart';
import '../../../support/ledger_test_app.dart';

/// Picks [name] in the screen's party dropdown.
Future<void> _pickParty(WidgetTester tester, String name) async {
  await tester.tap(find.byType(DropdownButtonFormField<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('asks for a party before it reads anything', (tester) async {
    await pumpLedgerApp(
      tester,
      ledger: FakeLedgerRepository(),
      suppliers: <Supplier>[buildSupplier('Arihant Distributors')],
    );

    expect(find.text('Pick a party'), findsOneWidget);
    expect(find.text('Record payment'), findsNothing);
  });

  testWidgets('shows the balance and the entries of the selected supplier', (
    tester,
  ) async {
    final repository = FakeLedgerRepository(
      entries: <LedgerEntry>[
        buildLedgerEntry(
          partyId: 'id-Arihant Distributors',
          credit: 1000,
          description: 'INV-1 · Arihant Distributors',
          entryDate: DateTime(2026, 9, 18),
        ),
        buildLedgerEntry(
          id: 'entry-2',
          partyId: 'id-Arihant Distributors',
          referenceType: LedgerReferenceType.payment,
          debit: 400,
          description: 'Cheque 4012',
          entryDate: DateTime(2026, 9, 20),
        ),
      ],
      balance: const PartyBalance(
        totalDebit: 400,
        totalCredit: 1000,
        entryCount: 2,
      ),
    );

    await pumpLedgerApp(
      tester,
      ledger: repository,
      suppliers: <Supplier>[buildSupplier('Arihant Distributors')],
    );
    await _pickParty(tester, 'Arihant Distributors');

    // The balance, read in the direction a supplier is owed.
    expect(find.text('Payable to the supplier'), findsOneWidget);
    expect(find.text(Formatters.currency(600)), findsOneWidget);
    expect(find.text('Outstanding'), findsOneWidget);
    // And every entry behind it.
    expect(find.text('INV-1 · Arihant Distributors'), findsOneWidget);
    expect(find.text('18 Sep 2026 · Purchase'), findsOneWidget);
    expect(find.text(Formatters.currency(1000)), findsOneWidget);
    expect(find.text('we owe more'), findsOneWidget);
    expect(find.text('Cheque 4012'), findsOneWidget);
    expect(find.text('20 Sep 2026 · Payment'), findsOneWidget);
    expect(find.text(Formatters.currency(400)), findsOneWidget);
    expect(find.text('we paid'), findsOneWidget);
    expect(repository.requestedOffsets, <int>[0]);
  });

  testWidgets('reads a customer the other way round', (tester) async {
    final repository = FakeLedgerRepository(
      entries: <LedgerEntry>[
        buildLedgerEntry(
          partyType: PartyType.customer,
          partyId: 'id-Ravi Kumar',
          referenceType: LedgerReferenceType.sale,
          debit: 300,
          description: 'BILL-7',
          entryDate: DateTime(2026, 9, 18),
        ),
        buildLedgerEntry(
          id: 'entry-2',
          partyType: PartyType.customer,
          partyId: 'id-Ravi Kumar',
          referenceType: LedgerReferenceType.payment,
          credit: 100,
          description: 'UPI 8891',
          entryDate: DateTime(2026, 9, 20),
        ),
      ],
      balance: const PartyBalance(
        totalDebit: 300,
        totalCredit: 100,
        entryCount: 2,
      ),
    );

    await pumpLedgerApp(
      tester,
      ledger: repository,
      customers: <Customer>[buildCustomer('Ravi Kumar')],
    );
    await tester.tap(find.text('Customers'));
    await tester.pumpAndSettle();
    await _pickParty(tester, 'Ravi Kumar');

    expect(find.text('Receivable from the customer'), findsOneWidget);
    expect(find.text(Formatters.currency(200)), findsOneWidget);
    expect(find.text('BILL-7'), findsOneWidget);
    expect(
      find.text('they owe more'),
      findsOneWidget,
      reason: 'the same debit column means the opposite to a customer',
    );
    expect(find.text('UPI 8891'), findsOneWidget);
    expect(find.text('they paid'), findsOneWidget);
    expect(find.text('Take payment'), findsOneWidget);
  });

  testWidgets('a failed first read offers a retry that reads again', (
    tester,
  ) async {
    final repository = FakeLedgerRepository(
      entries: <LedgerEntry>[
        buildLedgerEntry(
          partyId: 'id-Arihant Distributors',
          credit: 1000,
          description: 'INV-1',
        ),
      ],
      balance: const PartyBalance(totalCredit: 1000, entryCount: 1),
    )..failEntries = true;

    await pumpLedgerApp(
      tester,
      ledger: repository,
      suppliers: <Supplier>[buildSupplier('Arihant Distributors')],
      // The party is selected before the first frame, so the entries provider's
      // very first read is the one that fails. A party picked later would find an
      // empty page already on screen, and the failure would be reported without
      // replacing it (the design the load-more case below pins).
      configure: (container) => container
          .read(ledgerSelectionControllerProvider.notifier)
          .party('id-Arihant Distributors'),
    );

    expect(find.byType(ErrorView), findsOneWidget);
    expect(
      find.textContaining('Unable to load that ledger.'),
      findsNWidgets(2),
      reason: 'the body reports the failure and the listener announces it too',
    );

    repository.failEntries = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.byType(ErrorView), findsNothing);
    expect(find.text('INV-1'), findsOneWidget);
  });

  testWidgets('a refused load-more keeps the entries and says so', (
    tester,
  ) async {
    final repository = FakeLedgerRepository(
      entries: <LedgerEntry>[
        for (var index = 0; index < LedgerRepository.ledgerPageSize; index++)
          buildLedgerEntry(
            id: 'entry-$index',
            partyId: 'id-Arihant Distributors',
            credit: 10,
            description: 'ENTRY-${index + 1}',
          ),
      ],
      balance: const PartyBalance(totalCredit: 500, entryCount: 50),
    );

    await pumpLedgerApp(
      tester,
      ledger: repository,
      suppliers: <Supplier>[buildSupplier('Arihant Distributors')],
      size: const Size(1200, 12000),
    );
    await _pickParty(tester, 'Arihant Distributors');

    repository.failEntries = true;
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Unable to load that ledger.'), findsOneWidget);
    expect(
      find.text('ENTRY-1'),
      findsOneWidget,
      reason:
          'a page that failed to load must not blank the page that is there',
    );
    expect(find.text('Load more'), findsOneWidget);
  });

  testWidgets('records a payment against the selected supplier', (
    tester,
  ) async {
    final repository = FakeLedgerRepository(
      entries: <LedgerEntry>[
        buildLedgerEntry(
          partyId: 'id-Arihant Distributors',
          credit: 1000,
          description: 'INV-1',
        ),
      ],
      balance: const PartyBalance(totalCredit: 1000, entryCount: 1),
    );

    await pumpLedgerApp(
      tester,
      ledger: repository,
      suppliers: <Supplier>[buildSupplier('Arihant Distributors')],
    );
    await _pickParty(tester, 'Arihant Distributors');

    await tester.tap(find.text('Record payment'));
    await tester.pumpAndSettle();

    // The sheet opens on what is outstanding, so a settlement is one tap.
    expect(find.widgetWithText(TextFormField, 'Amount'), findsOneWidget);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Record payment'));
    await tester.pumpAndSettle();

    final payment = repository.payments.single;
    expect(payment.partyType, PartyType.supplier);
    expect(payment.partyId, 'id-Arihant Distributors');
    expect(payment.amount, 1000);
    expect(payment.mode, PaymentMode.cash);
    expect(find.text('Payment recorded.'), findsOneWidget);
  });

  testWidgets('a refused payment is reported and leaves the sheet open', (
    tester,
  ) async {
    final repository =
        FakeLedgerRepository(
            entries: <LedgerEntry>[
              buildLedgerEntry(
                partyId: 'id-Arihant Distributors',
                credit: 1000,
                description: 'INV-1',
              ),
            ],
            balance: const PartyBalance(totalCredit: 1000, entryCount: 1),
          )
          ..errorToThrow = const AuthException(
            message: 'that party is not in this pharmacy',
          );

    await pumpLedgerApp(
      tester,
      ledger: repository,
      suppliers: <Supplier>[buildSupplier('Arihant Distributors')],
    );
    await _pickParty(tester, 'Arihant Distributors');
    await tester.tap(find.text('Record payment'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Record payment'));
    await tester.pumpAndSettle();

    expect(find.text('that party is not in this pharmacy'), findsOneWidget);
    expect(
      find.widgetWithText(ElevatedButton, 'Record payment'),
      findsOneWidget,
      reason: 'the sheet stays open so the payment can be corrected',
    );
    expect(repository.payments, isEmpty);
  });

  testWidgets('fetches the next page of entries on request', (tester) async {
    final repository = FakeLedgerRepository(
      entries: <LedgerEntry>[
        for (
          var index = 0;
          index < LedgerRepository.ledgerPageSize + 1;
          index++
        )
          buildLedgerEntry(
            id: 'entry-$index',
            partyId: 'id-Arihant Distributors',
            credit: 10,
            description: 'ENTRY-${index + 1}',
          ),
      ],
      balance: const PartyBalance(totalCredit: 510, entryCount: 51),
    );

    await pumpLedgerApp(
      tester,
      ledger: repository,
      suppliers: <Supplier>[buildSupplier('Arihant Distributors')],
      size: const Size(1200, 12000),
    );
    await _pickParty(tester, 'Arihant Distributors');

    expect(find.text('Load more'), findsOneWidget);
    expect(find.text('ENTRY-51'), findsNothing);

    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();

    expect(repository.requestedOffsets, <int>[
      0,
      LedgerRepository.ledgerPageSize,
    ]);
    expect(find.text('ENTRY-51'), findsOneWidget);
    expect(
      find.text('Load more'),
      findsNothing,
      reason: 'the second page is short',
    );
  });
}
