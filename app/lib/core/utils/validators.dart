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

  /// Validates an email address when one was entered.
  ///
  /// Both masters may legitimately have no email on file, so a blank value
  /// passes; anything actually typed still has to be well formed. Without this,
  /// the email fields would have no validator at all, because [email] treats
  /// empty input as an error.
  static String? emailIfPresent(String? value) {
    if ((value?.trim() ?? '').isEmpty) {
      return null;
    }
    return email(value);
  }

  /// Validates a GSTIN when one was entered, and accepts a blank value.
  ///
  /// Registration is optional on both masters: a small unregistered supplier
  /// and a walk-in customer are both legitimate records.
  static String? gstinIfPresent(String? value) {
    if ((value?.trim() ?? '').isEmpty) {
      return null;
    }
    return gstin(value);
  }

  /// Validates a state drug licence number when one was entered.
  ///
  /// Deliberately loose. Formats differ by state and by form (20B, 21B, 20C),
  /// so a tighter pattern would reject valid licences; only the shape is
  /// checked - no spaces, letters/digits and the usual separators.
  static String? drugLicenseIfPresent(String? value) {
    final licence = value?.trim().toUpperCase() ?? '';
    if (licence.isEmpty) {
      return null;
    }
    if (!_drugLicense.hasMatch(licence)) {
      return 'Enter a valid drug licence number';
    }
    return null;
  }

  /// Validates an Indian mobile number when one was entered.
  static String? phoneIfPresent(String? value) {
    if ((value?.trim() ?? '').isEmpty) {
      return null;
    }
    return phone(value);
  }

  /// Validates a 6-digit Indian PIN code when one was entered.
  static String? pincodeIfPresent(String? value) {
    final pincode = value?.trim() ?? '';
    if (pincode.isEmpty) {
      return null;
    }
    if (!_pincode.hasMatch(pincode)) {
      return 'Enter a valid 6-digit PIN code';
    }
    return null;
  }

  /// Validates a whole number that is zero or greater, e.g. credit days.
  ///
  /// Required by default, because the backing columns are `not null` with a
  /// default of 0 - a blank field would silently become 0 otherwise.
  static String? nonNegativeInt(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) {
      return 'This field is required';
    }
    final parsed = int.tryParse(raw);
    if (parsed == null) {
      return 'Enter a whole number';
    }
    if (parsed < 0) {
      return 'Cannot be negative';
    }
    return null;
  }

  /// Validates a whole number of at least one, e.g. a quantity.
  ///
  /// Distinct from [nonNegativeInt] because zero is not a valid quantity
  /// anywhere in the schema: `purchase_items.qty`, `purchase_return_items.qty`
  /// and `stock_adjustments.qty` all carry `check (qty > 0)`.
  static String? positiveInt(String? value) {
    final parsed = int.tryParse(value?.trim() ?? '');
    if (parsed == null) {
      return 'Enter a whole number';
    }
    if (parsed <= 0) {
      return 'Must be more than zero';
    }
    return null;
  }

  /// Validates a decimal amount that is zero or greater, e.g. opening balance.
  static String? nonNegativeDecimal(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) {
      return 'This field is required';
    }
    final parsed = double.tryParse(raw);
    if (parsed == null) {
      return 'Enter a valid amount';
    }
    if (parsed < 0) {
      return 'Cannot be negative';
    }
    return null;
  }

  /// Validates a decimal amount when one was entered, and accepts a blank value.
  ///
  /// For a field whose blank state has a meaning of its own: a tender left empty
  /// at the counter means "the exact amount was paid", which is not the same as
  /// zero and is certainly not an error.
  static String? nonNegativeDecimalIfPresent(String? value) {
    if ((value?.trim() ?? '').isEmpty) {
      return null;
    }
    return nonNegativeDecimal(value);
  }

  /// Validates a percentage between 0 and 100 when one was entered.
  ///
  /// Blank passes: a line with no discount and no tax is a real line, and forcing
  /// the counter to type `0` twice would be friction for nothing.
  static String? percentIfPresent(String? value) {
    final raw = value?.trim() ?? '';
    if (raw.isEmpty) {
      return null;
    }
    final parsed = double.tryParse(raw);
    if (parsed == null) {
      return 'Enter a number';
    }
    if (parsed < 0 || parsed > 100) {
      return 'Must be between 0 and 100';
    }
    return null;
  }

  static final RegExp _email = RegExp(r'^[\w.+-]+@[\w-]+(\.[\w-]+)+$');
  static final RegExp _uppercase = RegExp('[A-Z]');
  static final RegExp _lowercase = RegExp('[a-z]');
  static final RegExp _digit = RegExp(r'\d');
  static final RegExp _phone = RegExp(r'^[6-9]\d{9}$');
  static final RegExp _pincode = RegExp(r'^[1-9][0-9]{5}$');
  static final RegExp _gstin = RegExp(
    r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$',
  );
  static final RegExp _drugLicense = RegExp(r'^[A-Z0-9][A-Z0-9/.:-]{0,29}$');
}
