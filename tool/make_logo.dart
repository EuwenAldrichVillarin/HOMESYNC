// Turns the full HomeSync brand lockup into the app's logo asset.
//
// Run from the project root:
//   dart run tool/make_logo.dart <source.png>
//
// The source artwork is the whole lockup: house mark, "HOMESYNC"
// wordmark and tagline, on a white background. The app only wants the
// house mark — the wordmark and tagline are already Text widgets on the
// login and sign-up pages, so baking them into the image would both
// duplicate them and stop them scaling with the layout.
//
// The background is removed by flooding inwards from the edges rather
// than by keying out every white pixel. That distinction matters here:
// the wifi arcs inside the house are white too, and a plain
// "white becomes transparent" pass would punch holes straight through
// them. Only white that is reachable from the border is background.
import 'dart:io';
import 'package:image/image.dart' as img;

/// How close to white a pixel must be to count as background.
const int _whiteCutoff = 235;

/// Fraction of the source height that holds the mark, above the wordmark.
const double _markHeightFraction = 0.60;

/// Longest edge of the asset that gets written out.
const int _outputSize = 512;

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/make_logo.dart <source.png>');
    exit(64);
  }

  final source = File(args.first);
  if (!source.existsSync()) {
    stderr.writeln('No such file: ${source.path}');
    exit(66);
  }

  final decoded = img.decodeImage(source.readAsBytesSync());
  if (decoded == null) {
    stderr.writeln('Could not decode ${source.path}');
    exit(65);
  }
  stdout.writeln('source      ${decoded.width}x${decoded.height}');

  // 1. Keep only the band containing the mark.
  var image = img.copyCrop(
    decoded,
    x: 0,
    y: 0,
    width: decoded.width,
    height: (decoded.height * _markHeightFraction).round(),
  );

  // 2. Make sure there is an alpha channel to write into.
  image = image.convert(numChannels: 4);

  // 3. Flood the background inwards from every edge pixel.
  _clearBackground(image);

  // 4. Trim the now-transparent margin so the mark fills the asset.
  image = img.trim(image, mode: img.TrimMode.transparent);
  stdout.writeln('trimmed     ${image.width}x${image.height}');

  // 5. Square it off, so it sits predictably in a square container.
  final side = image.width > image.height ? image.width : image.height;
  final square = img.Image(width: side, height: side, numChannels: 4);
  img.compositeImage(
    square,
    image,
    dstX: (side - image.width) ~/ 2,
    dstY: (side - image.height) ~/ 2,
  );

  final output = img.copyResize(
    square,
    width: _outputSize,
    height: _outputSize,
    interpolation: img.Interpolation.average,
  );

  File('assets/logo.png').writeAsBytesSync(img.encodePng(output));
  stdout.writeln('wrote       assets/logo.png (${output.width}x${output.height})');
}

/// Clears every near-white pixel connected to the image border.
///
/// Iterative flood fill with an explicit stack — the recursive version
/// overflows on an image this size.
void _clearBackground(img.Image image) {
  final w = image.width;
  final h = image.height;
  final seen = List<bool>.filled(w * h, false);
  final stack = <int>[];

  bool isBackground(int x, int y) {
    final p = image.getPixel(x, y);
    return p.r >= _whiteCutoff && p.g >= _whiteCutoff && p.b >= _whiteCutoff;
  }

  void push(int x, int y) {
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    final i = y * w + x;
    if (seen[i]) return;
    seen[i] = true;
    if (!isBackground(x, y)) return;
    stack.add(i);
  }

  for (var x = 0; x < w; x++) {
    push(x, 0);
    push(x, h - 1);
  }
  for (var y = 0; y < h; y++) {
    push(0, y);
    push(w - 1, y);
  }

  var cleared = 0;
  while (stack.isNotEmpty) {
    final i = stack.removeLast();
    final x = i % w;
    final y = i ~/ w;

    image.setPixelRgba(x, y, 0, 0, 0, 0);
    cleared++;

    push(x - 1, y);
    push(x + 1, y);
    push(x, y - 1);
    push(x, y + 1);
  }

  stdout.writeln('background  $cleared px cleared');
}
