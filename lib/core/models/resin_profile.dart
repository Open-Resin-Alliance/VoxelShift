/// Resin/material profile exposed by NanoDLP.
class ResinProfile {
  final String name;
  final String profileId;
  final Map<String, dynamic> raw;
  final bool locked;

  const ResinProfile({
    required this.name,
    required this.profileId,
    required this.raw,
    this.locked = false,
  });

  @override
  String toString() => '$name (#$profileId)';

  static String? resolveProfileId(Map<String, dynamic> raw) {
    final candidates = [
      raw['ProfileID'],
      raw['ProfileId'],
      raw['profileId'],
      raw['id'],
      raw['ID'],
    ];
    for (final c in candidates) {
      if (c == null) continue;
      final parsed = int.tryParse('$c');
      if (parsed != null) return parsed.toString();
    }
    return null;
  }

  static String resolveName(Map<String, dynamic> raw) {
    final candidates = [
      raw['Title'],
      raw['title'],
      raw['Name'],
      raw['name'],
      raw['label'],
      raw['display_name'],
    ];
    for (final c in candidates) {
      if (c is String && c.trim().isNotEmpty) return c.trim();
    }
    return 'Unknown Profile';
  }

  static bool resolveLocked(String name, Map<String, dynamic> raw) {
    final locked = raw['locked'];
    if (locked is bool) return locked;
    final re = RegExp(r'^\[([A-Z]{2,5})\]\s*');
    return re.hasMatch(name);
  }
}
