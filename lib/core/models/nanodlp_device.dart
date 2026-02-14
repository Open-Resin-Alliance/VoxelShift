/// Represents a NanoDLP printer discovered on the network.
class NanoDlpDevice {
  final String ipAddress;
  final int port;
  final String? hostName;
  final String? printerName;
  final String? firmwareVersion;
  final String? status;
  final String? state;
  final bool? printing;
  final int? layerId;
  final int? layersCount;
  final double? currentHeight;
  final double? progress;
  final int? machineResolutionX;
  final int? machineResolutionY;
  final String? machineProfileLabel;
  final String? machineModelName;
  final String? machineSerial;
  final String? machineLcdType;
  final DateTime? lastSeen;
  bool isOnline;

  NanoDlpDevice({
    required this.ipAddress,
    required this.port,
    this.hostName,
    this.printerName,
    this.firmwareVersion,
    this.status,
    this.state,
    this.printing,
    this.layerId,
    this.layersCount,
    this.currentHeight,
    this.progress,
    this.machineResolutionX,
    this.machineResolutionY,
    this.machineProfileLabel,
    this.machineModelName,
    this.machineSerial,
    this.machineLcdType,
    this.lastSeen,
    this.isOnline = false,
  });

  String get baseUrl => 'http://$ipAddress:$port';

  String get cacheKey => '$ipAddress:$port';

  String get displayName {
    if (hostName != null && hostName!.isNotEmpty) return hostName!;
    if (printerName != null && printerName!.isNotEmpty) return printerName!;
    return ipAddress;
  }

  Map<String, dynamic> toJson() => {
        'ipAddress': ipAddress,
        'port': port,
        'hostName': hostName,
        'printerName': printerName,
        'firmwareVersion': firmwareVersion,
      'status': status,
      'state': state,
      'printing': printing,
      'layerId': layerId,
      'layersCount': layersCount,
      'currentHeight': currentHeight,
      'progress': progress,
        'machineResolutionX': machineResolutionX,
        'machineResolutionY': machineResolutionY,
        'machineProfileLabel': machineProfileLabel,
        'machineModelName': machineModelName,
        'machineSerial': machineSerial,
        'machineLcdType': machineLcdType,
      'lastSeen': lastSeen?.toIso8601String(),
      };

  factory NanoDlpDevice.fromJson(Map<String, dynamic> json) => NanoDlpDevice(
        ipAddress: json['ipAddress']?.toString() ?? '',
        port: int.tryParse('${json['port']}') ?? 80,
        hostName: json['hostName']?.toString(),
        printerName: json['printerName']?.toString(),
        firmwareVersion: json['firmwareVersion']?.toString(),
      status: json['status']?.toString(),
      state: json['state']?.toString(),
      printing: json['printing'] is bool ? json['printing'] as bool : null,
      layerId: int.tryParse('${json['layerId']}'),
      layersCount: int.tryParse('${json['layersCount']}'),
      currentHeight: double.tryParse('${json['currentHeight']}'),
      progress: double.tryParse('${json['progress']}'),
      machineResolutionX: int.tryParse('${json['machineResolutionX']}'),
      machineResolutionY: int.tryParse('${json['machineResolutionY']}'),
      machineProfileLabel: json['machineProfileLabel']?.toString(),
      machineModelName: json['machineModelName']?.toString(),
      machineSerial: json['machineSerial']?.toString(),
      machineLcdType: json['machineLcdType']?.toString(),
      lastSeen: json['lastSeen'] != null
      ? DateTime.tryParse('${json['lastSeen']}')
      : null,
        isOnline: false,
      );
}
