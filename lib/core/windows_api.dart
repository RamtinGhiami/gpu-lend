// Small pieces of the Windows API used by the app: DPAPI (the device token is stored encrypted for this Windows user) and the
// power status (is the laptop on mains or on battery).
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

final class _PowerStatus extends Struct {
  @Uint8()
  external int acLineStatus;
  @Uint8()
  external int batteryFlag;
  @Uint8()
  external int batteryLifePercent;
  @Uint8()
  external int systemStatusFlag;
  @Uint32()
  external int batteryLifeTime;
  @Uint32()
  external int batteryFullLifeTime;
}

typedef _ProtectNative = Int32 Function(Pointer<_DataBlob>, Pointer<Utf16>, Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_DataBlob>);
typedef _ProtectDart = int Function(Pointer<_DataBlob>, Pointer<Utf16>, Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);
typedef _UnprotectNative = Int32 Function(Pointer<_DataBlob>, Pointer<Pointer<Utf16>>, Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_DataBlob>);
typedef _UnprotectDart = int Function(Pointer<_DataBlob>, Pointer<Pointer<Utf16>>, Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);
typedef _FreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _FreeDart = Pointer<Void> Function(Pointer<Void>);
typedef _PowerNative = Int32 Function(Pointer<_PowerStatus>);
typedef _PowerDart = int Function(Pointer<_PowerStatus>);

class WindowsApi {
  /// Encrypts [text] for the signed-in Windows user. Returns base64, or null when DPAPI is not available (not Windows).
  static String? protect(String text) {
    if (!Platform.isWindows) return null;
    final crypt = DynamicLibrary.open('crypt32.dll');
    final kernel = DynamicLibrary.open('kernel32.dll');
    final protect = crypt.lookupFunction<_ProtectNative, _ProtectDart>('CryptProtectData');
    final free = kernel.lookupFunction<_FreeNative, _FreeDart>('LocalFree');
    final bytes = utf8.encode(text);
    final input = calloc<_DataBlob>();
    final output = calloc<_DataBlob>();
    final buffer = calloc<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      input.ref.cbData = bytes.length;
      input.ref.pbData = buffer;
      final ok = protect(input, nullptr, nullptr, nullptr, nullptr, 0, output);
      if (ok == 0) return null;
      final result = Uint8List.fromList(output.ref.pbData.asTypedList(output.ref.cbData));
      free(output.ref.pbData.cast());
      return base64.encode(result);
    } finally {
      calloc.free(buffer);
      calloc.free(input);
      calloc.free(output);
    }
  }

  /// The reverse of [protect]; null when the data cannot be decrypted (another user or another machine).
  static String? unprotect(String encoded) {
    if (!Platform.isWindows) return null;
    final crypt = DynamicLibrary.open('crypt32.dll');
    final kernel = DynamicLibrary.open('kernel32.dll');
    final unprotect = crypt.lookupFunction<_UnprotectNative, _UnprotectDart>('CryptUnprotectData');
    final free = kernel.lookupFunction<_FreeNative, _FreeDart>('LocalFree');
    final bytes = base64.decode(encoded);
    final input = calloc<_DataBlob>();
    final output = calloc<_DataBlob>();
    final buffer = calloc<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      input.ref.cbData = bytes.length;
      input.ref.pbData = buffer;
      final ok = unprotect(input, nullptr, nullptr, nullptr, nullptr, 0, output);
      if (ok == 0) return null;
      final text = utf8.decode(output.ref.pbData.asTypedList(output.ref.cbData));
      free(output.ref.pbData.cast());
      return text;
    } finally {
      calloc.free(buffer);
      calloc.free(input);
      calloc.free(output);
    }
  }

  /// True when the machine runs on battery. Unknown or desktop machines count as mains.
  static bool onBattery() {
    if (!Platform.isWindows) return false;
    final kernel = DynamicLibrary.open('kernel32.dll');
    final status = kernel.lookupFunction<_PowerNative, _PowerDart>('GetSystemPowerStatus');
    final p = calloc<_PowerStatus>();
    try {
      if (status(p) == 0) return false;
      return p.ref.acLineStatus == 0;
    } finally {
      calloc.free(p);
    }
  }
}
