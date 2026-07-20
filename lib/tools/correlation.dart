/// Signal-identification helpers for reverse engineering.
///
/// When a DID sweep finds many unknown DIDs, the way to identify which one is
/// (say) state-of-charge is to log candidate DID values alongside a *reference*
/// the human can read from the car's own display (SOC %, odometer, speed) while
/// driving/charging, then rank candidates by correlation with that reference.
///
/// Pure math — no I/O — so it is fully unit-tested.
library;

import 'dart:math' as math;

/// Pearson correlation coefficient between two equal-length series.
/// Returns 0 when a series has zero variance or the inputs are too short.
double pearson(List<double> a, List<double> b) {
  final n = a.length;
  if (n != b.length || n < 2) return 0;
  double sa = 0, sb = 0;
  for (int i = 0; i < n; i++) {
    sa += a[i];
    sb += b[i];
  }
  final ma = sa / n, mb = sb / n;
  double cov = 0, va = 0, vb = 0;
  for (int i = 0; i < n; i++) {
    final da = a[i] - ma, db = b[i] - mb;
    cov += da * db;
    va += da * da;
    vb += db * db;
  }
  if (va == 0 || vb == 0) return 0;
  return cov / (math.sqrt(va) * math.sqrt(vb));
}

class CandidateRanking {
  final String candidateId;
  final double correlation;
  const CandidateRanking(this.candidateId, this.correlation);
}

/// Rank candidate series (id -> values) by |correlation| against [reference].
/// All series must align 1:1 with [reference] by sample index. Series shorter
/// than [reference] are skipped. Highest |r| first.
List<CandidateRanking> rankByCorrelation(
  List<double> reference,
  Map<String, List<double>> candidates,
) {
  final out = <CandidateRanking>[];
  for (final e in candidates.entries) {
    if (e.value.length != reference.length) continue;
    out.add(CandidateRanking(e.key, pearson(reference, e.value)));
  }
  out.sort((x, y) => y.correlation.abs().compareTo(x.correlation.abs()));
  return out;
}
