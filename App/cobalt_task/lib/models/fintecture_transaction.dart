/// =============================================================================
/// fintecture_transaction.dart
/// =============================================================================
/// Modèle représentant une transaction Request-to-Pay Fintecture.
/// Persisté en SQLite pour le suivi des remboursements.
/// =============================================================================

enum FintectureStatus { pending, paid, expired, failed }

class FintectureTransaction {
  final String id; // UUID = state Fintecture
  final String recipientName;
  final String recipientPhone;
  final double amount;
  final String currency;
  final String note;
  final String paymentUrl;
  final FintectureStatus status;
  final DateTime createdAt;
  final DateTime? paidAt;

  const FintectureTransaction({
    required this.id,
    required this.recipientName,
    required this.recipientPhone,
    required this.amount,
    this.currency = 'EUR',
    this.note = '',
    this.paymentUrl = '',
    this.status = FintectureStatus.pending,
    required this.createdAt,
    this.paidAt,
  });

  FintectureTransaction copyWith({
    FintectureStatus? status,
    String? paymentUrl,
    DateTime? paidAt,
  }) {
    return FintectureTransaction(
      id: id,
      recipientName: recipientName,
      recipientPhone: recipientPhone,
      amount: amount,
      currency: currency,
      note: note,
      paymentUrl: paymentUrl ?? this.paymentUrl,
      status: status ?? this.status,
      createdAt: createdAt,
      paidAt: paidAt ?? this.paidAt,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'recipient_name': recipientName,
        'recipient_phone': recipientPhone,
        'amount': amount,
        'currency': currency,
        'note': note,
        'payment_url': paymentUrl,
        'status': status.name,
        'created_at': createdAt.millisecondsSinceEpoch,
        'paid_at': paidAt?.millisecondsSinceEpoch,
      };

  factory FintectureTransaction.fromMap(Map<String, dynamic> map) {
    return FintectureTransaction(
      id: map['id'] as String,
      recipientName: map['recipient_name'] as String,
      recipientPhone: map['recipient_phone'] as String? ?? '',
      amount: (map['amount'] as num).toDouble(),
      currency: map['currency'] as String? ?? 'EUR',
      note: map['note'] as String? ?? '',
      paymentUrl: map['payment_url'] as String? ?? '',
      status: FintectureStatus.values.firstWhere(
        (s) => s.name == (map['status'] as String? ?? 'pending'),
        orElse: () => FintectureStatus.pending,
      ),
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      paidAt: map['paid_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['paid_at'] as int)
          : null,
    );
  }

  String get formattedAmount {
    return amount == amount.roundToDouble()
        ? '${amount.toInt()}€'
        : '${amount.toStringAsFixed(2)}€';
  }

  String get maskedRecipient => recipientName;
}
