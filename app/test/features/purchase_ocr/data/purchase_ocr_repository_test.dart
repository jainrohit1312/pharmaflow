/// Unit tests for the rules the bill upload obeys client-side.
///
/// These mirror the bucket's own limits (migration 00022): a 10 MB cap and four
/// accepted types. The mirror is not the authority — the bucket is — but it is
/// what lets the screen say "that photo is too large" before spending a phone's
/// data on it, so it is worth pinning at its boundaries.
library;

import 'package:app/features/purchase_ocr/data/purchase_ocr_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('validatePick', () {
    test('accepts every type the bucket accepts', () {
      for (final mimeType in PurchaseOcrRepository.allowedMimeTypes) {
        expect(
          PurchaseOcrRepository.validatePick(
            mimeType: mimeType,
            sizeInBytes: 1024,
          ),
          isNull,
          reason: mimeType,
        );
      }
      expect(
        PurchaseOcrRepository.allowedMimeTypes,
        <String>['image/jpeg', 'image/png', 'image/webp', 'application/pdf'],
        reason: 'the list mirrors the bucket created by migration 00022',
      );
    });

    test('refuses a type the reader cannot open, and names it', () {
      final refusal = PurchaseOcrRepository.validatePick(
        mimeType: 'image/heic',
        sizeInBytes: 1024,
      );

      expect(refusal, isNotNull);
      expect(refusal, contains('HEIC'));
      expect(refusal, contains('JPEG'));
    });

    test('refuses a file with no type at all', () {
      expect(
        PurchaseOcrRepository.validatePick(mimeType: null, sizeInBytes: 1024),
        isNotNull,
      );
      expect(
        PurchaseOcrRepository.validatePick(mimeType: '   ', sizeInBytes: 1024),
        isNotNull,
      );
    });

    test('refuses an empty file', () {
      expect(
        PurchaseOcrRepository.validatePick(
          mimeType: 'image/jpeg',
          sizeInBytes: 0,
        ),
        isNotNull,
      );
    });

    test('accepts exactly the cap and refuses one byte more', () {
      expect(
        PurchaseOcrRepository.validatePick(
          mimeType: 'image/jpeg',
          sizeInBytes: PurchaseOcrRepository.maxBillBytes,
        ),
        isNull,
      );

      final refusal = PurchaseOcrRepository.validatePick(
        mimeType: 'image/jpeg',
        sizeInBytes: PurchaseOcrRepository.maxBillBytes + 1,
      );
      expect(refusal, isNotNull);
      expect(refusal, contains('10 MB'));
    });
  });

  group('the object path', () {
    test('starts with the tenant, then the year (D-028)', () {
      final path = PurchaseOcrRepository.storagePath(
        pharmacyId: 'ph-1',
        now: DateTime(2026, 9, 19),
        fileName: 'bill.pdf',
      );

      expect(path, 'ph-1/2026/bill.pdf');
      expect(
        path.split('/').first,
        'ph-1',
        reason: 'the storage policy reads this',
      );
    });

    test('a generated name carries the right extension and is unique-ish', () {
      final first = PurchaseOcrRepository.newBillFileName(
        mimeType: 'image/jpeg',
        now: DateTime(2026, 9, 19),
        nonce: 7,
      );
      final second = PurchaseOcrRepository.newBillFileName(
        mimeType: 'image/jpeg',
        now: DateTime(2026, 9, 19),
        nonce: 8,
      );

      expect(first, endsWith('.jpg'));
      expect(first, startsWith('bill-'));
      expect(
        first,
        isNot(second),
        reason: 'a second pick must not overwrite the first',
      );
    });

    test('every accepted type maps to its extension', () {
      expect(PurchaseOcrRepository.extensionFor('image/jpeg'), 'jpg');
      expect(PurchaseOcrRepository.extensionFor('image/png'), 'png');
      expect(PurchaseOcrRepository.extensionFor('image/webp'), 'webp');
      expect(PurchaseOcrRepository.extensionFor('application/pdf'), 'pdf');
    });

    test('a file with no reported type is typed from its name', () {
      expect(
        PurchaseOcrRepository.mimeForFileName('IMG_0042.JPG'),
        'image/jpeg',
      );
      expect(PurchaseOcrRepository.mimeForFileName('scan.jpeg'), 'image/jpeg');
      expect(PurchaseOcrRepository.mimeForFileName('bill.png'), 'image/png');
      expect(PurchaseOcrRepository.mimeForFileName('bill.webp'), 'image/webp');
      expect(
        PurchaseOcrRepository.mimeForFileName('bill.pdf'),
        'application/pdf',
      );
    });

    test('a name that says nothing useful is not guessed at', () {
      expect(PurchaseOcrRepository.mimeForFileName('IMG_0042.HEIC'), isNull);
      expect(PurchaseOcrRepository.mimeForFileName('bill'), isNull);
      expect(PurchaseOcrRepository.mimeForFileName(''), isNull);
    });
  });
}
