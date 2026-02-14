import 'package:flutter_test/flutter_test.dart';

import 'package:voxelshift/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const VoxelShiftApp());
    expect(find.text('VoxelShift'), findsOneWidget);
  });
}
