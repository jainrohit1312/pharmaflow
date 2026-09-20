/// The settings screen's one real entry.
///
/// The opening stock import is the owner's action - the RPC behind it refuses
/// anyone else - so the entry is offered to an owner and not to a pharmacist.
/// The courtesy is the only thing under test here; the guard itself is the
/// server's, and `supabase/tests/opening_stock_import.sql` proves it.
library;

import 'package:app/core/router/routes.dart';
import 'package:app/data/models/profile.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_opening_stock_repository.dart';
import '../../../support/opening_stock_test_app.dart';

void main() {
  testWidgets('an owner is offered the opening stock import', (tester) async {
    await pumpOpeningStockApp(
      tester,
      repository: FakeOpeningStockRepository(),
      initialLocation: Routes.settings,
    );

    expect(find.text('Opening stock import'), findsOneWidget);
    expect(find.textContaining('Bring your existing stock in'), findsOneWidget);
  });

  testWidgets('a pharmacist is not', (tester) async {
    await pumpOpeningStockApp(
      tester,
      repository: FakeOpeningStockRepository(),
      initialLocation: Routes.settings,
      profile: buildProfile(role: AppRole.pharmacist),
    );

    expect(find.text('Opening stock import'), findsNothing);
    // The Phase 0 marker is still there: hiding one entry does not replace the
    // placeholder screen it sits on.
    expect(find.text('TODO(phase-1)'), findsOneWidget);
  });
}
