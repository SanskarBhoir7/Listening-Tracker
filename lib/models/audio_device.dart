/// Persistent representation of an audio device (Bluetooth, wired, USB).
///
/// Supports stable identification across reconnects.
class AudioDevice {
  final String id;
  final String name;
  final String deviceType;
  final String connectionType;
  final String? address;
  final DateTime firstSeen;
  final DateTime lastSeen;

  const AudioDevice({
    required this.id,
    required this.name,
    required this.deviceType,
    required this.connectionType,
    this.address,
    required this.firstSeen,
    required this.lastSeen,
  });

  /// Generates a stable identifier for an audio device.
  ///
  /// - Uses hardware address if provided and non-empty.
  /// - Falls back to sanitized name + connectionType.
  static String generateStableId({
    required String name,
    required String connectionType,
    String? address,
  }) {
    if (address != null && address.trim().isNotEmpty) {
      final sanitizedAddr = address.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
      return 'addr_$sanitizedAddr';
    }
    final cleanName = name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
    final cleanConn = connectionType.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
    return '${cleanConn}_$cleanName';
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'device_type': deviceType,
      'connection_type': connectionType,
      'address': address ?? '',
      'first_seen': firstSeen.millisecondsSinceEpoch,
      'last_seen': lastSeen.millisecondsSinceEpoch,
    };
  }

  factory AudioDevice.fromMap(Map<String, dynamic> map) {
    return AudioDevice(
      id: map['id'] as String,
      name: map['name'] as String,
      deviceType: map['device_type'] as String,
      connectionType: map['connection_type'] as String,
      address: (map['address'] as String?)?.isNotEmpty == true ? map['address'] as String : null,
      firstSeen: DateTime.fromMillisecondsSinceEpoch(map['first_seen'] as int),
      lastSeen: DateTime.fromMillisecondsSinceEpoch(map['last_seen'] as int),
    );
  }

  AudioDevice copyWith({
    String? name,
    String? deviceType,
    String? connectionType,
    String? address,
    DateTime? lastSeen,
  }) {
    return AudioDevice(
      id: id,
      name: name ?? this.name,
      deviceType: deviceType ?? this.deviceType,
      connectionType: connectionType ?? this.connectionType,
      address: address ?? this.address,
      firstSeen: firstSeen,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}
