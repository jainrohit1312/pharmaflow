/// Unit tests for the OCR flow's controller: the upload, the read, and the one
/// retry a busy reader earns (D-032).
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/core/errors/error_message.dart';
import 'package:app/features/auth/application/pharmacy_scope.dart';
import 'package:app/features/purchase_ocr/application/purchase_ocr_controller.dart';
import 'package:app/features/purchase_ocr/data/purchase_ocr_repository.dart';
import 'package:app/services/ocr_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/fake_purchase_ocr_repository.dart';

/// A container wired to [repository], with no real waiting.
ProviderContainer _container(FakePurchaseOcrRepository repository) {
  final container = ProviderContainer(
    // Inferred, not `<Override>[...]`: the type lives in `riverpod`, which
    // `flutter_riverpod` does not re-export.
    overrides: [
      purchaseOcrRepositoryProvider.overrideWithValue(repository),
      requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
      ocrRetryDelayProvider.overrideWith((ref) => Duration.zero),
    ],
  );
  addTearDown(container.dispose);
  // What a screen does by watching the controller: without a listener the
  // provider is auto-disposed the moment the flow awaits, and every state write
  // after that gap lands on a disposed ref.
  container.listen<PurchaseOcrState>(
    purchaseOcrControllerProvider,
    (previous, next) {},
    fireImmediately: true,
  );
  return container;
}

void main() {
  group('pickAndScan', () {
    test('uploads the picked bill and stores what the reader said', () async {
      final repository = FakePurchaseOcrRepository();
      final container = _container(repository);

      await container
          .read(purchaseOcrControllerProvider.notifier)
          .pickAndScan(bytes: List<int>.filled(64, 1), mimeType: 'image/jpeg');

      final state = container.read(purchaseOcrControllerProvider);
      expect(repository.uploads, 1);
      expect(repository.parses, 1);
      expect(repository.uploadedFor.single, 'ph-1');
      expect(state.isBusy, isFalse);
      expect(state.error, isNull);
      expect(state.hasScan, isTrue);
      expect(state.scan!.bill!.document.supplierName, 'ARIHANT DISTRIBUTORS');
      expect(state.scan!.mimeType, 'image/jpeg');
    });

    test('stores the bill under the tenant that paid for it', () async {
      final repository = FakePurchaseOcrRepository();
      final container = _container(repository);

      await container
          .read(purchaseOcrControllerProvider.notifier)
          .pickAndScan(bytes: List<int>.filled(64, 1), mimeType: 'image/png');

      final path = repository.parsedPaths.single;
      expect(path.split('/').first, 'ph-1');
      expect(path, endsWith('.png'));
    });

    test('a file the bucket would refuse never reaches the reader', () async {
      final repository = FakePurchaseOcrRepository();
      final container = _container(repository);

      await container
          .read(purchaseOcrControllerProvider.notifier)
          .pickAndScan(
            bytes: List<int>.filled(PurchaseOcrRepository.maxBillBytes + 1, 1),
            mimeType: 'image/jpeg',
          );

      final state = container.read(purchaseOcrControllerProvider);
      expect(state.error, isA<ValidationException>());
      expect(state.errorIsRetryable, isFalse);
      expect(state.hasScan, isFalse);
      expect(repository.parses, 0, reason: 'nothing to read');
    });

    test(
      'a bill the reader will not open is refused before any read',
      () async {
        final repository = FakePurchaseOcrRepository();
        final container = _container(repository);

        await container
            .read(purchaseOcrControllerProvider.notifier)
            .pickAndScan(
              bytes: List<int>.filled(64, 1),
              mimeType: 'image/heic',
            );

        final state = container.read(purchaseOcrControllerProvider);
        expect(state.error, isA<ValidationException>());
        expect(repository.parses, 0);
      },
    );
  });

  group('a busy reader', () {
    test('is retried once, with the retry visible while it waits', () async {
      final repository = FakePurchaseOcrRepository();
      repository.parseFailures.addAll(<Exception?>[busyReaderFailure(), null]);
      final container = _container(repository);

      final seen = <PurchaseOcrState>[];
      container.listen<PurchaseOcrState>(
        purchaseOcrControllerProvider,
        (previous, next) => seen.add(next),
        fireImmediately: true,
      );

      await container
          .read(purchaseOcrControllerProvider.notifier)
          .pickAndScan(bytes: List<int>.filled(64, 1), mimeType: 'image/jpeg');

      expect(repository.parses, 2, reason: 'one attempt, one retry');
      expect(
        repository.uploads,
        1,
        reason: 'the retry re-reads, never re-uploads',
      );

      final state = container.read(purchaseOcrControllerProvider);
      expect(state.hasScan, isTrue);
      expect(state.error, isNull);
      expect(state.isRetrying, isFalse);

      expect(
        seen.any((state) => state.isRetrying && state.isBusy),
        isTrue,
        reason: 'the wait has to be visible, or a user taps again',
      );
    });

    test(
      'is not retried a third time, and says it is worth trying yourself',
      () async {
        final repository = FakePurchaseOcrRepository();
        repository.parseFailures.add(busyReaderFailure());
        final container = _container(repository);

        await container
            .read(purchaseOcrControllerProvider.notifier)
            .pickAndScan(
              bytes: List<int>.filled(64, 1),
              mimeType: 'image/jpeg',
            );

        final state = container.read(purchaseOcrControllerProvider);
        expect(repository.parses, 2, reason: 'two attempts is the limit');
        expect(state.error, isA<ServerException>());
        expect(state.errorIsRetryable, isTrue);
        expect(state.isBusy, isFalse);
        expect(
          state.hasScan,
          isTrue,
          reason: 'it uploaded, so the bill is up there and can be read again',
        );
        expect(state.hasBill, isFalse);
        expect(
          describeError(state.error!),
          'The bill reader is busy right now. Try again in a moment.',
        );
      },
    );

    test('a read that never reached the reader is worth a retry too', () async {
      final repository = FakePurchaseOcrRepository();
      repository.parseFailures.add(
        const NetworkException(message: 'offline', code: unreachableOcrCode),
      );
      final container = _container(repository);

      await container
          .read(purchaseOcrControllerProvider.notifier)
          .pickAndScan(bytes: List<int>.filled(64, 1), mimeType: 'image/jpeg');

      expect(repository.parses, 2);
      expect(
        container.read(purchaseOcrControllerProvider).errorIsRetryable,
        isTrue,
      );
    });

    test('a flow whose screen went away finishes quietly', () async {
      final repository = FakePurchaseOcrRepository();
      repository.parseFailures.add(busyReaderFailure());

      // Deliberately no listener: this is the screen navigating away mid-read, so
      // the provider is disposed while the upload and the retry are in flight.
      final container = ProviderContainer(
        overrides: [
          purchaseOcrRepositoryProvider.overrideWithValue(repository),
          requirePharmacyIdProvider.overrideWith((ref) => 'ph-1'),
          ocrRetryDelayProvider.overrideWith((ref) => Duration.zero),
        ],
      );

      final pending = container
          .read(purchaseOcrControllerProvider.notifier)
          .pickAndScan(bytes: List<int>.filled(64, 1), mimeType: 'image/jpeg');
      container.dispose();

      await expectLater(
        pending,
        completes,
        reason: 'a write to a disposed ref would surface here as an error',
      );
    });
  });

  group('failures that will fail the same way twice', () {
    test('are not retried', () async {
      final repository = FakePurchaseOcrRepository();
      repository.parseFailures.add(unreadableBillFailure());
      final container = _container(repository);

      await container
          .read(purchaseOcrControllerProvider.notifier)
          .pickAndScan(bytes: List<int>.filled(64, 1), mimeType: 'image/jpeg');

      final state = container.read(purchaseOcrControllerProvider);
      expect(repository.parses, 1);
      expect(state.error, isA<NotFoundException>());
      expect(state.errorIsRetryable, isFalse);
    });
  });

  group('rescan', () {
    test(
      'reads the stored bill again without uploading a second copy',
      () async {
        final repository = FakePurchaseOcrRepository();
        final container = _container(repository);
        final controller = container.read(
          purchaseOcrControllerProvider.notifier,
        );

        await controller.pickAndScan(
          bytes: List<int>.filled(64, 1),
          mimeType: 'image/jpeg',
        );
        await controller.rescan();

        expect(repository.uploads, 1);
        expect(repository.parses, 2);
        expect(
          repository.parsedPaths.toSet(),
          hasLength(1),
          reason: 'the same object, read twice',
        );
      },
    );

    test('does nothing when there is no bill yet', () async {
      final repository = FakePurchaseOcrRepository();
      final container = _container(repository);

      await container.read(purchaseOcrControllerProvider.notifier).rescan();

      expect(repository.parses, 0);
      expect(container.read(purchaseOcrControllerProvider).hasScan, isFalse);
    });

    test('keeps the first parse on screen when the re-read fails', () async {
      final repository = FakePurchaseOcrRepository();
      final container = _container(repository);
      final controller = container.read(purchaseOcrControllerProvider.notifier);

      await controller.pickAndScan(
        bytes: List<int>.filled(64, 1),
        mimeType: 'image/jpeg',
      );
      repository.parseFailures.add(unreadableBillFailure());
      await controller.rescan();

      final state = container.read(purchaseOcrControllerProvider);
      expect(state.hasScan, isTrue);
      expect(state.scan!.bill!.lines, isNotEmpty);
      expect(
        state.error,
        isNotNull,
        reason: 'the stale parse must not be mistaken for a fresh one (T-3)',
      );
    });

    test(
      'a first read that failed keeps the bill, so it can be read again',
      () async {
        final repository = FakePurchaseOcrRepository();
        repository.parseFailures.add(unreadableBillFailure());
        final container = _container(repository);
        final controller = container.read(
          purchaseOcrControllerProvider.notifier,
        );

        await controller.pickAndScan(
          bytes: List<int>.filled(64, 1),
          mimeType: 'image/jpeg',
        );

        final failed = container.read(purchaseOcrControllerProvider);
        expect(
          failed.hasScan,
          isTrue,
          reason: 'it uploaded, so there is a path',
        );
        expect(failed.hasBill, isFalse, reason: 'and nothing was read from it');
        expect(failed.error, isNotNull);

        repository.parseFailures.clear();
        await controller.rescan();

        final retried = container.read(purchaseOcrControllerProvider);
        expect(
          repository.uploads,
          1,
          reason: 'reading again is not uploading again',
        );
        expect(repository.parses, 2);
        expect(retried.hasBill, isTrue);
        expect(retried.error, isNull);
      },
    );
  });

  group('clear', () {
    test('forgets the bill and its failure', () async {
      final repository = FakePurchaseOcrRepository();
      repository.parseFailures.add(busyReaderFailure());
      final container = _container(repository);
      final controller = container.read(purchaseOcrControllerProvider.notifier);

      await controller.pickAndScan(
        bytes: List<int>.filled(64, 1),
        mimeType: 'image/jpeg',
      );
      controller.clear();

      final state = container.read(purchaseOcrControllerProvider);
      expect(state.hasScan, isFalse);
      expect(state.error, isNull);
      expect(state.errorIsRetryable, isFalse);
    });
  });

  group('the reads one bill is allowed', () {
    test(
      'counts the read, and the automatic retry is not a second one',
      () async {
        final repository = FakePurchaseOcrRepository();
        repository.parseFailures.addAll(<Exception?>[
          busyReaderFailure(),
          null,
        ]);
        final container = _container(repository);

        await container
            .read(purchaseOcrControllerProvider.notifier)
            .pickAndScan(
              bytes: List<int>.filled(64, 1),
              mimeType: 'image/jpeg',
            );

        final state = container.read(purchaseOcrControllerProvider);
        expect(
          repository.parses,
          2,
          reason: 'the automatic retry is a second request to the reader',
        );
        expect(
          state.reads,
          1,
          reason: 'but it is the same read given its second chance (D-032)',
        );
        expect(state.nextRead, 2);
        expect(state.canReadAgain, isTrue);
      },
    );

    test(
      'counts a read that failed, because it still spent a request',
      () async {
        final repository = FakePurchaseOcrRepository();
        repository.parseFailures.add(busyReaderFailure());
        final container = _container(repository);

        await container
            .read(purchaseOcrControllerProvider.notifier)
            .pickAndScan(
              bytes: List<int>.filled(64, 1),
              mimeType: 'image/jpeg',
            );

        final state = container.read(purchaseOcrControllerProvider);
        expect(state.error, isNotNull);
        expect(
          state.reads,
          1,
          reason: 'a limit that counted only answers would bound nothing',
        );
      },
    );

    test('saturates at the cap, however many times the bill is read', () async {
      final repository = FakePurchaseOcrRepository();
      final container = _container(repository);
      final controller = container.read(purchaseOcrControllerProvider.notifier);

      await controller.pickAndScan(
        bytes: List<int>.filled(64, 1),
        mimeType: 'image/jpeg',
      );
      for (var read = 0; read < 4; read++) {
        await controller.rescan();
      }

      final state = container.read(purchaseOcrControllerProvider);
      expect(repository.parses, 5);
      expect(state.reads, PurchaseOcrState.maxReads);
      expect(state.nextRead, PurchaseOcrState.maxReads);
      expect(state.canReadAgain, isFalse);
    });

    test(
      'belongs to the bill: forgetting it starts the allowance over',
      () async {
        final repository = FakePurchaseOcrRepository();
        final container = _container(repository);
        final controller = container.read(
          purchaseOcrControllerProvider.notifier,
        );

        await controller.pickAndScan(
          bytes: List<int>.filled(64, 1),
          mimeType: 'image/jpeg',
        );
        await controller.rescan();
        expect(container.read(purchaseOcrControllerProvider).reads, 2);

        controller.clear();
        await controller.pickAndScan(
          bytes: List<int>.filled(64, 1),
          mimeType: 'image/jpeg',
        );

        final state = container.read(purchaseOcrControllerProvider);
        expect(state.hasBill, isTrue);
        expect(
          state.reads,
          1,
          reason: 'another bill is another allowance, in the same session',
        );
      },
    );
  });
}
