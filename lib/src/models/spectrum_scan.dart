class SpectrumScanCandidate {
  final int centerFrequencyKhz;
  final int occupancyPercent;
  final int peakRssiDbm;
  final int avgRssiDbm;

  const SpectrumScanCandidate({
    required this.centerFrequencyKhz,
    required this.occupancyPercent,
    required this.peakRssiDbm,
    required this.avgRssiDbm,
  });

  double get centerFrequencyMhz => centerFrequencyKhz / 1000.0;
}

class SpectrumScanResult {
  final List<SpectrumScanCandidate> candidates;

  const SpectrumScanResult({required this.candidates});

  SpectrumScanCandidate? get best =>
      candidates.isEmpty ? null : candidates.first;
}
