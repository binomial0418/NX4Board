// 以真實 TDX API 驗證 TdxClient 與路段資料能串起來。
//
// 需要 assets/private/tdx.json 的憑證與網路，缺少時略過。
// 國道、台61（Live/Highway 路段車速）、台74（改查 VD 鏈路）各取一段路線測試。
// token 加上各查詢共 5 次，超過限流器的每分鐘 4 次，最後一個會等到視窗滑過，
// 所以整組放寬逾時。
@Timeout(Duration(minutes: 3))
library;
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nx4board/models/tdx_section.dart';
import 'package:nx4board/services/tdx_client.dart';

TdxClient? _loadClient() {
  final f = File('assets/private/tdx.json');
  if (!f.existsSync()) return null;
  final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final id = (j['client_id'] as String? ?? '').trim();
  final secret = (j['client_secret'] as String? ?? '').trim();
  if (id.isEmpty || secret.isEmpty) return null;
  return TdxClient(id, secret);
}

void main() {
  final client = _loadClient();
  final skip = client == null ? '沒有 assets/private/tdx.json 憑證' : null;
  late TdxSectionIndex index;

  setUpAll(() {
    index = TdxSectionIndex.decode(File('assets/tdx_sections.json.gz').readAsBytesSync());
  });
  tearDownAll(() => client?.close());

  List<TdxSection> lineSample(String road, int n) {
    final any = index.sections.firstWhere((s) => s.roadName == road && s.kmSign == 1);
    final line = index.lineOf(any);
    final mid = line.length ~/ 2;
    return line.sublist(mid, (mid + n).clamp(0, line.length));
  }

  test('國道路段車速', () async {
    final secs = lineSample('國道1號', 5);
    final speeds = await client!.sectionSpeeds('Freeway', secs.map((s) => s.id).toList());
    // ignore: avoid_print
    print('  國道1號 ${secs.length} 段，取得 ${speeds.length} 段：$speeds');
    expect(speeds, isNotEmpty);
  }, skip: skip);

  test('台61 路段車速', () async {
    final secs = lineSample('台61線', 10);
    final speeds = await client!.sectionSpeeds('Highway', secs.map((s) => s.id).toList());
    // ignore: avoid_print
    print('  台61線 ${secs.length} 段，取得 ${speeds.length} 段：$speeds');
    expect(speeds, isNotEmpty);
  }, skip: skip);

  test('台74 由 VD 鏈路補車速', () async {
    final secs = lineSample('台74線', 6).where((s) => s.vdLinks.isNotEmpty).toList();
    expect(secs, isNotEmpty);
    final direct = await client!.sectionSpeeds('Highway', secs.map((s) => s.id).toList());
    final vdIds = secs.expand((s) => s.vdLinks.keys).toSet().toList();
    final vd = await client.vdLinkSpeeds(vdIds);
    int filled = 0;
    for (final s in secs) {
      final v = [
        for (final e in s.vdLinks.entries)
          for (final link in e.value)
            if (vd[e.key]?[link] != null) vd[e.key]![link]!
      ];
      if (v.isNotEmpty) filled++;
    }
    // ignore: avoid_print
    print('  台74線 ${secs.length} 段：路段車速 ${direct.length} 段，'
        'VD ${vd.length}/${vdIds.length} 支有資料，補上 $filled 段');
    expect(filled, greaterThan(0));
  }, skip: skip);
}
