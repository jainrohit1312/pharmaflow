/// Data access for pharmacy onboarding.
library;

import 'package:app/core/errors/app_exception.dart';
import 'package:app/data/datasources/supabase_client.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

part 'onboarding_repository.g.dart';

/// Exposes the single [OnboardingRepository].
@riverpod
OnboardingRepository onboardingRepository(Ref ref) =>
    OnboardingRepository(ref.watch(supabaseClientProvider));

/// What the onboarding form collects.
class OnboardingDetails {
  /// Creates onboarding details; every optional field may be null.
  const OnboardingDetails({
    required this.pharmacyName,
    this.gstin,
    this.drugLicense,
    this.phone,
    this.city,
    this.state,
    this.pincode,
  });

  /// The pharmacy's display name.
  final String pharmacyName;

  /// GSTIN, when the pharmacy is registered.
  final String? gstin;

  /// State drug licence number.
  final String? drugLicense;

  /// Contact number.
  final String? phone;

  /// City.
  final String? city;

  /// State.
  final String? state;

  /// PIN code.
  final String? pincode;
}

/// Creates the caller's pharmacy.
class OnboardingRepository {
  /// Creates a repository backed by the shared Supabase client.
  OnboardingRepository(this._client);

  final sb.SupabaseClient _client;

  /// The RPC that creates a pharmacy and links the caller to it as owner.
  ///
  /// A server-side function rather than two client writes, because
  /// `profiles.role` and `profiles.pharmacy_id` are not updatable by the
  /// `authenticated` role (D-017). A client could otherwise promote itself to
  /// owner, or point its own row at another tenant's id and inherit their scope.
  static const String rpcName = 'onboard_pharmacy';

  /// Error codes this RPC raises, plus the unique GSTIN index behind it.
  ///
  /// All of them are things the user can act on, so their own messages are shown
  /// rather than a generic fallback. Anything else is a server failure and gets
  /// a message that does not pretend to explain it.
  static const Set<String> _actionableCodes = <String>{
    '22023', // invalid parameter value: the name was blank
    '23505', // already linked, or that GSTIN already exists
    'P0002', // no profile row for this account
    '23514', // check violation
  };

  /// Creates a pharmacy for the signed-in user and returns its id.
  Future<String> createPharmacy(OnboardingDetails details) async {
    try {
      return await _client.rpc<String>(
        rpcName,
        params: <String, dynamic>{
          'p_pharmacy_name': details.pharmacyName,
          'p_gstin': details.gstin,
          'p_drug_license': details.drugLicense,
          'p_phone': details.phone,
          'p_city': details.city,
          'p_state': details.state,
          'p_pincode': details.pincode,
        },
      );
    } on sb.PostgrestException catch (error) {
      final message = error.message.trim();
      if (error.code == '42501') {
        throw AuthException(
          message: message.isEmpty ? 'You must be signed in.' : message,
          code: error.code,
          cause: error,
        );
      }
      if (_actionableCodes.contains(error.code) && message.isNotEmpty) {
        throw ValidationException(
          message: message,
          code: error.code,
          cause: error,
        );
      }
      throw ServerException(
        message: 'Unable to create your pharmacy.',
        code: error.code,
        cause: error,
      );
    } on Object catch (error) {
      throw ServerException(
        message: 'Unable to create your pharmacy.',
        cause: error,
      );
    }
  }
}
