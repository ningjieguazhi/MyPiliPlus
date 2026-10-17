// ignore_for_file: constant_identifier_names

enum VideoDecodeFormatType {
  // dvhe 是杜比视界 Profile 5，没有 HDR10 基线；仍归到这一档，避免 fromString 抛错。
  DVH1(['dvh1', 'dvhe']),
  AV1(['av01']),
  HEVC(['hev1', 'hvc1']),
  AVC(['avc1']),
  ;

  String get description => name;
  final List<String> codes;

  const VideoDecodeFormatType(this.codes);

  static VideoDecodeFormatType fromString(String val) =>
      values.firstWhere((i) => i.codes.any(val.startsWith));
}
