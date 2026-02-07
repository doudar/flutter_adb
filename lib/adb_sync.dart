// Copyright 2024 Pepe Tiebosch (byme.dev). All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_adb/adb_stream.dart';

class AdbSync {
  static const int ID_SEND = 0x444E4553; 
  static const int ID_RECV = 0x56434552;
  static const int ID_DATA = 0x41544144;
  static const int ID_DONE = 0x454E4F44;
  static const int ID_OKAY = 0x59414B4F;
  static const int ID_FAIL = 0x4C494146;
  static const int ID_QUIT = 0x54495551;

  static const int MAX_CHUNK_SIZE = 64 * 1024;

  final AdbStream stream;
  late final StreamIterator<Uint8List> _iterator;
  List<int> _buffer = [];

  AdbSync(this.stream) {
    _iterator = StreamIterator(stream.onPayload);
  }

  Future<void> sendClose() async {
    await stream.write(Uint8List(0), true);
    stream.sendClose();
  }

  Future<Uint8List> _read(int n) async {
    while (_buffer.length < n) {
      if (!await _iterator.moveNext()) {
        if (_buffer.isNotEmpty && _buffer.length < n) {
           throw Exception('Connection closed with partial data');
        }
        throw Exception('Connection closed');
      }
      _buffer.addAll(_iterator.current);
    }
    Uint8List result = Uint8List.fromList(_buffer.sublist(0, n));
    _buffer = _buffer.sublist(n);
    return result;
  }
  
  Future<void> _writeProtocol(int id, int length) async {
    ByteData header = ByteData(8);
    header.setUint32(0, id, Endian.little);
    header.setUint32(4, length, Endian.little);
    await stream.write(header.buffer.asUint8List(), false);
  }

  Future<void> push(String localPath, String remotePath, {int mode = 0644}) async {
    File file = File(localPath);
    if (!file.existsSync()) {
      throw Exception('Local file not found: $localPath');
    }

    String sendReq = '$remotePath,$mode';
    Uint8List sendReqBytes = utf8.encode(sendReq);

    await _writeProtocol(ID_SEND, sendReqBytes.length);
    await stream.write(sendReqBytes, false);

    Stream<List<int>> fileStream = file.openRead();
    await for (List<int> chunk in fileStream) {
      int offset = 0;
      while (offset < chunk.length) {
        int end = offset + MAX_CHUNK_SIZE;
        if (end > chunk.length) end = chunk.length;
        Uint8List subChunk = Uint8List.fromList(chunk.sublist(offset, end));
        
        await _writeProtocol(ID_DATA, subChunk.length);
        await stream.write(subChunk, false);
        
        offset = end;
      }
    }
    
    int timestamp = (await file.lastModified()).millisecondsSinceEpoch ~/ 1000;
    await _writeProtocol(ID_DONE, timestamp);
    
    await stream.write(Uint8List(0), true); // Flush

    Uint8List idBytes = await _read(4);
    int id = ByteData.view(idBytes.buffer).getUint32(0, Endian.little);
    
    if (id == ID_FAIL) {
       Uint8List lenBytes = await _read(4);
       int len = ByteData.view(lenBytes.buffer).getUint32(0, Endian.little);
       Uint8List msgBytes = await _read(len);
       throw Exception('Push failed: ${utf8.decode(msgBytes)}');
    } else if (id != ID_OKAY) {
       throw Exception('Unexpected response: $id');
    }
    
    await _read(4); // consume 4 bytes
  }

  Future<void> pull(String remotePath, String localPath) async {
    File file = File(localPath);
    if (!file.parent.existsSync()) {
        await file.parent.create(recursive: true);
    }
    IOSink sink = file.openWrite();

    Uint8List pathBytes = utf8.encode(remotePath);
    await _writeProtocol(ID_RECV, pathBytes.length);
    await stream.write(pathBytes, true);

    try {
      while (true) {
        Uint8List idBytes = await _read(4);
        int id = ByteData.view(idBytes.buffer).getUint32(0, Endian.little);
        
        if (id == ID_DATA) {
          Uint8List lenBytes = await _read(4);
          int len = ByteData.view(lenBytes.buffer).getUint32(0, Endian.little);
          Uint8List data = await _read(len);
          sink.add(data);
        } else if (id == ID_DONE) {
           await _read(4); // consume unused length
           break;
        } else if (id == ID_FAIL) {
           Uint8List lenBytes = await _read(4);
           int len = ByteData.view(lenBytes.buffer).getUint32(0, Endian.little);
           Uint8List msgBytes = await _read(len);
           throw Exception('Pull failed: ${utf8.decode(msgBytes)}');
        } else {
           throw Exception('Unexpected response: $id');
        }
      }
    } finally {
      await sink.close();
    }
  }
}
