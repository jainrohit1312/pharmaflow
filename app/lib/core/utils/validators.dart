/// Reusable form validators for PharmaFlow input fields.
library;

/// Stateless validators that return `null` when the input is acceptable and a
/// user-facing message otherwise, matching the `FormFieldValidator` contract.
abstract final class Validators {
  /// Validates an email address.
  static String? email(String? value) {
    final email = value?.trim() ?? '';
    if (email.isEmpty) {
      return 'Email is required';
    }
    if (!_email.hasMatch(email)) {
      return 'Enter a valid email address';
    }
    return null;
  }

  /// Validates a password: at least 8 characters with one uppercase letter,
  /// one lowercase letter and one digit.
  static String? password(String? value) {
    final password = value ?? '';
    if (password.isEmpty) {
      return 'Password is required';
    }
    if (password.length < 8) {
      return 'Password must be at least 8 characters';
    }
    if (!_uppercase.hasMatch(password)) {
      return 'Password must contain an uppercase letter';
    }
    if (!_lowercase.hasMatch(password)) {
      return 'Password must contain a lowercase letter';
    }
    if (!_digit.hasMatch(password)) {
      return 'Password must contain a number';
    }
    return null;
  }

  /// Validates that [value] repeats [original] exactly.
  static String? confirmPassword(String? value, String? original) {
    if (value == null || value.isEmpty) {
      return 'Confirm your password';
    }
    if (value != original) {
      return 'Passwords do not match';
    }
    return null;
  }

  /// Validates an Indian mobile number: 10 digits starting with 6-9.
  static String? phone(String? value) {
    final phone = value?.trim() ?? '';
    if (phone.isEmpty) {
      return 'Phone number is required';
    }
    if (!_phone.hasMatch(phone)) {
      return 'Enter a valid 10-digit mobile number';
    }
    return null;
  }

  /// Validates that [value] is not blank, naming [fieldName] in the message.
  static String? required(String? value, [String fieldName = 'This field']) {
    if (value == null || value.trim().isEmpty) {
      return '$fieldName is required';
    }
    return null;
  }

  /// Validates a 15-character Indian GSTIN.
  ///
  /// Layout: 2 digits, 5 uppercase letters, 4 digits, 1 uppercase letter,
  /// 1 alphanumeric, the literal `Z`, 1 alphanumeric.
  static String? gstin(String? value) {
    final gstin = value?.trim().toUpperCase() ?? '';
    if (gstin.isEmpty) {
      return 'GSTIN is required';
    }
    if (!_gstin.hasMatch(gstin)) {
      return 'Enter a valid 15-character GSTIN';
    }
    return null;
  }

  static final RegExp _email = RegExp(r'^[\w.+-]+@[\w-]+(\.[\w-]+)+$');
  static final RegExp _uppercase = RegExp('[A-Z]');
  static final RegExp _lowercase = RegExp('[a-z]');
  static final RegExp _digit = RegExp(r'\d');
  static final RegExp _phone = RegExp(r'^[6-9]\d{9}$');
  static final RegExp _gstin = RegExp(
    r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$',
  );
}
