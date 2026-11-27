import 'package:xml/xml.dart';

/// What a renderer's device description says that casting needs.
class RendererDescription {
  const RendererDescription({
    required this.udn,
    required this.name,
    required this.maker,
    required this.model,
    required this.avTransport,
    this.renderingControl,
    this.connectionManager,
  });

  final String udn;
  final String name;
  final String maker;
  final String model;

  /// The services' control URLs, absolute.
  final Uri avTransport;
  final Uri? renderingControl;
  final Uri? connectionManager;
}

/// Reads a UPnP device description fetched from [location]; null when it
/// isn't a renderer this package can drive (no AVTransport service).
RendererDescription? parseDescription(String xmlText, Uri location) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xmlText);
  } on XmlException {
    return null;
  }
  String? text(XmlElement scope, String name) {
    final found = scope.findAllElements(name).firstOrNull?.innerText.trim();
    return found == null || found.isEmpty ? null : found;
  }

  final device = doc.findAllElements('device').firstOrNull;
  if (device == null) return null;
  // The play commands go to these: on the renderer's own host only, so a
  // URLBase or a control URL elsewhere is ignored.
  bool onRenderer(Uri url) => url.scheme == 'http' && url.host == location.host;
  final named = Uri.tryParse(text(doc.rootElement, 'URLBase') ?? '');
  final base = named != null && onRenderer(named) ? named : location;
  Uri? control(String service) {
    for (final s in device.findAllElements('service')) {
      final type = text(s, 'serviceType') ?? '';
      final url = Uri.tryParse(text(s, 'controlURL') ?? '');
      if (type.contains(':$service:') && url != null) {
        final resolved = base.resolveUri(url);
        if (onRenderer(resolved)) return resolved;
      }
    }
    return null;
  }

  final av = control('AVTransport');
  if (av == null) return null;
  final model = [
    text(device, 'modelName'),
    text(device, 'modelNumber'),
  ].whereType<String>().toSet().join(' ');
  return RendererDescription(
    udn: text(device, 'UDN') ?? location.toString(),
    name: text(device, 'friendlyName') ?? location.host,
    maker: text(device, 'manufacturer') ?? '',
    model: model,
    avTransport: av,
    renderingControl: control('RenderingControl'),
    connectionManager: control('ConnectionManager'),
  );
}
