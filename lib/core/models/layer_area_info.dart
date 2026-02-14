/// Per-layer area and bounding box information.
class LayerAreaInfo {
  final double totalSolidArea;
  final double largestArea;
  final double smallestArea;
  final int minX;
  final int minY;
  final int maxX;
  final int maxY;
  final int areaCount;

  const LayerAreaInfo({
    required this.totalSolidArea,
    required this.largestArea,
    required this.smallestArea,
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
    required this.areaCount,
  });

  static const empty = LayerAreaInfo(
    totalSolidArea: 0,
    largestArea: 0,
    smallestArea: 0,
    minX: 0,
    minY: 0,
    maxX: 0,
    maxY: 0,
    areaCount: 0,
  );

  Map<String, dynamic> toJson() => {
        'TotalSolidArea': totalSolidArea,
        'LargestArea': largestArea,
        'SmallestArea': smallestArea,
        'MinX': minX,
        'MinY': minY,
        'MaxX': maxX,
        'MaxY': maxY,
        'AreaCount': areaCount,
      };
}
