import 'package:obd_battery_diagnostics/tools/correlation.dart';
import 'package:obd_battery_diagnostics/tools/uds_scanner.dart';
import 'package:obd_battery_diagnostics/transport/data_source.dart';
import 'package:test/test.dart';

void main() {
  group('UdsScanner.classify', () {
    test('responded returns data payload', () {
      final r = UdsScanner.classify(0xDDBC, [0x62, 0xDD, 0xBC, 0x03, 0x20]);
      expect(r.status, DidStatus.responded);
      expect(r.data, [0x03, 0x20]);
      expect(r.isInteresting, isTrue);
      expect(r.didHex, 'DDBC');
    });

    test('0x31 negative -> outOfRange', () {
      final r = UdsScanner.classify(0x1234, [0x7F, 0x22, 0x31]);
      expect(r.status, DidStatus.outOfRange);
      expect(r.nrc, 0x31);
      expect(r.isInteresting, isFalse);
    });

    test('other negative -> negativeOther', () {
      final r = UdsScanner.classify(0x1234, [0x7F, 0x22, 0x33]); // securityDenied
      expect(r.status, DidStatus.negativeOther);
    });

    test('empty -> noData', () {
      final r = UdsScanner.classify(0x1234, []);
      expect(r.status, DidStatus.noData);
    });
  });

  group('UdsScanner.sweep over ReplaySource', () {
    test('finds only the responding DID', () async {
      // DID 0xDD01 responds; others return NO DATA.
      final source = ReplaySource({
        '0722DD01': '607 05 62 DD 01 12 34\r>',
      });
      // Unmapped commands return the benign prompt (parsed as no frames).
      await source.connect();
      final scanner = UdsScanner(
        source: source,
        requestHeader: '6F1',
        responseFilter: '607',
        extendedAddress: 0x07,
      );
      final results = <DidScanResult>[];
      final hits = await scanner.sweep(
        startDid: 0xDD00,
        endDid: 0xDD02,
        onResult: results.add,
      );
      expect(results, hasLength(3));
      expect(hits, hasLength(1));
      expect(hits.single.didHex, 'DD01');
      expect(hits.single.data, [0x12, 0x34]);
    });

    test('drafts commands from hits', () async {
      final source = ReplaySource({
        '0722DD01': '607 05 62 DD 01 12 34\r>',
      });
      await source.connect();
      final scanner = UdsScanner(
        source: source,
        requestHeader: '6F1',
        responseFilter: '607',
        extendedAddress: 0x07,
      );
      final hits = await scanner.sweep(startDid: 0xDD00, endDid: 0xDD01);
      final drafts =
          draftCommandsFromHits(hits, hdr: '6F1', rax: '607', eax: '07');
      expect(drafts, hasLength(1));
      expect(drafts.single.service, '22');
      expect(drafts.single.payload, 'DD01');
      expect(drafts.single.signals.single.id, 'UNKNOWN_DD01');
    });
  });

  group('correlation', () {
    test('perfect positive correlation ~= 1', () {
      expect(pearson([1, 2, 3, 4], [2, 4, 6, 8]), closeTo(1.0, 1e-9));
    });
    test('perfect negative correlation ~= -1', () {
      expect(pearson([1, 2, 3, 4], [8, 6, 4, 2]), closeTo(-1.0, 1e-9));
    });
    test('zero variance -> 0', () {
      expect(pearson([1, 1, 1], [1, 2, 3]), 0);
    });

    test('ranks the SOC-like candidate highest', () {
      // reference = displayed SOC descending during a drive.
      final ref = <double>[80, 78, 76, 74, 70, 65];
      final candidates = <String, List<double>>{
        // tracks SOC closely (a scaled version)
        'DID_A': [800, 780, 760, 740, 700, 650],
        // unrelated noise
        'DID_B': [1, 9, 2, 8, 3, 7],
        // inverse (still high |r|, but A should win on closeness=1.0)
        'DID_C': [10, 12, 14, 16, 20, 25],
      };
      final ranked = rankByCorrelation(ref, candidates);
      expect(ranked.first.candidateId, 'DID_A');
      expect(ranked.first.correlation, closeTo(1.0, 1e-9));
    });
  });
}
